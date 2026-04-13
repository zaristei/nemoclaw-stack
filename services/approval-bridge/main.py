# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Approval bridge: OpenShell webhook -> Telegram inline buttons -> OpenShell decisions."""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging
import os
import signal
import sys
from typing import Any

import aiohttp
from aiohttp import web
from telegram import ForceReply, InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("approval-bridge")

# ---------------------------------------------------------------------------
# Configuration (from environment)
# ---------------------------------------------------------------------------

TELEGRAM_BOT_TOKEN = os.environ.get("APPROVAL_BOT_TOKEN", "") or os.environ.get("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID = int(os.environ.get("APPROVAL_CHAT_ID", "0") or os.environ.get("TELEGRAM_CHAT_ID", "0"))
WEBHOOK_SECRET = os.environ.get("WEBHOOK_SECRET", "")
LISTEN_HOST = os.environ.get("LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8090"))

# ---------------------------------------------------------------------------
# In-memory pending decisions
# ---------------------------------------------------------------------------

# Maps chunk_id -> chunk info dict (sandbox_id, rule_name, host, port, etc.)
pending_chunks: dict[str, dict[str, Any]] = {}

# Maps proposal_id -> policy proposal info dict
pending_proposals: dict[str, dict[str, Any]] = {}

# Maps Telegram message_id (of a ForceReply prompt) -> deny context awaiting
# the operator's reason text. When the operator replies to that prompt, we
# look up by reply_to_message.message_id and finalize the denial decision.
pending_deny_replies: dict[int, dict[str, Any]] = {}


# ---------------------------------------------------------------------------
# HMAC verification
# ---------------------------------------------------------------------------


def verify_signature(secret: str, body: bytes, signature: str) -> bool:
    """Verify HMAC-SHA256 signature from OpenShell."""
    expected = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature)


# ---------------------------------------------------------------------------
# Webhook receiver (HTTP server)
# ---------------------------------------------------------------------------


async def handle_webhook(request: web.Request) -> web.Response:
    """Receive draft chunk proposals from OpenShell gateway."""
    body = await request.read()

    # Verify HMAC signature.
    signature = request.headers.get("X-OpenShell-Signature", "")
    if WEBHOOK_SECRET and not verify_signature(WEBHOOK_SECRET, body, signature):
        log.warning("Invalid webhook signature")
        return web.Response(status=401, text="invalid signature")

    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        return web.Response(status=400, text="invalid json")

    event = payload.get("event", "")
    if event == "mediator_policy_proposal":
        return await _handle_policy_proposal(request, payload)
    if event == "mediator_syscall_approval":
        # Auto-approve init syscall gate (stale daemon binary still has the
        # per-syscall gate that was removed in source). Store the approval
        # so the daemon's /syscall-decisions poll picks it up.
        approval_id = payload.get("approval_id", "")
        app = request.app["telegram_app"]
        app.bot_data.setdefault("syscall_decisions", []).append(
            {"approval_id": approval_id, "approved": True, "reason": "auto-approved (init syscall gate)"}
        )
        log.info("Auto-approved init syscall: %s %s", payload.get("method", "?"), approval_id)
        return web.Response(status=200, text="auto-approved")
    if event != "draft_chunks_proposed":
        log.info("Ignoring event: %s", event)
        return web.Response(status=200, text="ignored")

    sandbox_id = payload.get("sandbox_id", "unknown")
    chunks = payload.get("chunks", [])

    log.info(
        "Received %d chunks for sandbox %s",
        len(chunks),
        sandbox_id,
    )

    # Send Telegram messages for each chunk.
    app = request.app["telegram_app"]
    for chunk in chunks:
        chunk_id = chunk.get("id", "")
        if not chunk_id:
            continue

        # Store in pending map.
        pending_chunks[chunk_id] = {
            "sandbox_id": sandbox_id,
            **chunk,
        }

        # Build message text.
        host = chunk.get("host", "")
        port = chunk.get("port", 0)
        binary = chunk.get("binary", "")
        rule_name = chunk.get("rule_name", "")
        rationale = chunk.get("rationale", "")
        confidence = chunk.get("confidence", 0)
        hit_count = chunk.get("hit_count", 0)

        text = (
            f"Policy Approval Request\n"
            f"Sandbox: <code>{sandbox_id[:12]}</code>\n"
            f"Rule: <b>{_escape(rule_name)}</b>\n"
            f"Endpoint: <code>{_escape(host)}:{port}</code>\n"
        )
        if binary:
            text += f"Binary: <code>{_escape(binary)}</code>\n"
        if rationale:
            text += f"Rationale: {_escape(rationale)}\n"
        text += f"Confidence: {confidence:.0%} | Hits: {hit_count}"

        keyboard = InlineKeyboardMarkup(
            [
                [
                    InlineKeyboardButton(
                        "Approve", callback_data=f"approve:{chunk_id}"
                    ),
                    InlineKeyboardButton(
                        "Deny", callback_data=f"reject:{chunk_id}"
                    ),
                ]
            ]
        )

        try:
            await app.bot.send_message(
                chat_id=TELEGRAM_CHAT_ID,
                text=text,
                parse_mode="HTML",
                reply_markup=keyboard,
            )
        except Exception:
            log.exception("Failed to send Telegram message for chunk %s", chunk_id)

    # Return empty response (no immediate decisions — they come via button callback).
    return web.Response(status=200, text="")


async def _handle_policy_proposal(
    request: web.Request, payload: dict[str, Any]
) -> web.Response:
    """Handle a mediator policy proposal — send the FULL policy to Telegram.

    Renders header + pretty-printed config (split across multiple messages if
    needed) + Approve/Deny buttons. Truncating any field would let an agent
    hide elevation past the cutoff.
    """
    proposal_id = payload.get("proposal_id", "")
    if not proposal_id:
        return web.Response(status=400, text="missing proposal_id")

    policy_config = payload.get("config", {})
    taint_warnings = payload.get("taint_warnings")
    policy_name = policy_config.get("policy_name", "unknown")
    rationale = policy_config.get("rationale", "")

    pending_proposals[proposal_id] = {
        "config": policy_config,
        "policy_name": policy_name,
    }

    config_pretty = json.dumps(policy_config, indent=2, sort_keys=True, default=str)

    header = (
        f"🔒 <b>Policy Proposal</b>\n"
        f"Name: <code>{_escape(policy_name)}</code>\n"
        f"Rationale: {_escape(rationale) or '<i>(none provided)</i>'}\n"
        f"proposal_id: <code>{_escape(proposal_id)}</code>"
    )

    keyboard = InlineKeyboardMarkup(
        [
            [
                InlineKeyboardButton(
                    "Approve", callback_data=f"policy_approve:{proposal_id}"
                ),
                InlineKeyboardButton(
                    "Deny", callback_data=f"policy_deny:{proposal_id}"
                ),
            ]
        ]
    )

    MAX_BODY = 3500
    chunks: list[str] = []
    if len(config_pretty) <= MAX_BODY:
        chunks.append(config_pretty)
    else:
        current = ""
        for line in config_pretty.splitlines(keepends=True):
            if len(current) + len(line) > MAX_BODY:
                if current:
                    chunks.append(current)
                current = line
            else:
                current += line
        if current:
            chunks.append(current)

    app = request.app["telegram_app"]
    try:
        await app.bot.send_message(
            chat_id=TELEGRAM_CHAT_ID,
            text=header,
            parse_mode="HTML",
        )
        if taint_warnings:
            taint_pretty = json.dumps(taint_warnings, indent=2, sort_keys=True)
            await app.bot.send_message(
                chat_id=TELEGRAM_CHAT_ID,
                text=f"⚠️ <b>Taint warnings:</b>\n<pre>{_escape(taint_pretty[:3500])}</pre>",
                parse_mode="HTML",
            )
        total = len(chunks)
        for idx, chunk in enumerate(chunks, 1):
            label = f"Config ({idx}/{total}):" if total > 1 else "Config:"
            await app.bot.send_message(
                chat_id=TELEGRAM_CHAT_ID,
                text=f"{label}\n<pre>{_escape(chunk)}</pre>",
                parse_mode="HTML",
            )
        await app.bot.send_message(
            chat_id=TELEGRAM_CHAT_ID,
            text=f"Approve policy <code>{_escape(policy_name)}</code>?",
            parse_mode="HTML",
            reply_markup=keyboard,
        )
    except Exception:
        log.exception("Failed to send policy proposal to Telegram")

    log.info(
        "Policy proposal %s for '%s' sent to Telegram (%d chunks, %d chars)",
        proposal_id,
        policy_name,
        len(chunks),
        len(config_pretty),
    )
    return web.Response(status=200, text="")


def _escape(text: str) -> str:
    """Escape HTML special characters for Telegram."""
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


# ---------------------------------------------------------------------------
# Telegram callback handler
# ---------------------------------------------------------------------------


async def handle_button(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Handle approve/deny button presses from Telegram."""
    query = update.callback_query
    if query is None:
        return
    try:
        await query.answer()
    except Exception:
        log.warning("Failed to answer callback query (expired or invalid)")

    data = query.data or ""
    if ":" not in data:
        return

    action, item_id = data.split(":", 1)

    # Handle policy proposals.
    if action in ("policy_approve", "policy_deny"):
        proposal_info = pending_proposals.get(item_id)
        if proposal_info is None:
            await query.edit_message_text("Proposal already decided or expired.")
            return
        user = query.from_user
        actor = f"telegram:{user.id}" if user else "telegram:unknown"
        policy_name = proposal_info.get("policy_name", "unknown")

        if action == "policy_approve":
            pending_proposals.pop(item_id, None)
            await query.edit_message_text(
                f"Policy <b>{_escape(policy_name)}</b> approved by {actor}.",
                parse_mode="HTML",
            )
            log.info("Policy %s approved by %s", item_id, actor)
            context.bot_data.setdefault("policy_decisions", []).append(
                {
                    "proposal_id": item_id,
                    "approved": True,
                    "reason": f"approved by {actor}",
                }
            )
            return

        # Deny path: prompt for a reason via ForceReply, capture in handle_reply.
        await query.edit_message_text(
            f"Denying policy <b>{_escape(policy_name)}</b>... waiting for reason from {actor}.",
            parse_mode="HTML",
        )
        try:
            sent = await context.bot.send_message(
                chat_id=TELEGRAM_CHAT_ID,
                text=(
                    f"Reply with the denial reason for policy "
                    f"<code>{_escape(policy_name)}</code> "
                    f"(or send <code>/skip</code> to deny without one):"
                ),
                parse_mode="HTML",
                reply_markup=ForceReply(selective=False),
            )
            pending_deny_replies[sent.message_id] = {
                "proposal_id": item_id,
                "policy_name": policy_name,
                "actor": actor,
            }
        except Exception:
            log.exception("Failed to send policy deny-reason prompt; finalizing without reason")
            pending_proposals.pop(item_id, None)
            context.bot_data.setdefault("policy_decisions", []).append(
                {
                    "proposal_id": item_id,
                    "approved": False,
                    "reason": f"denied by {actor} (reason prompt failed)",
                }
            )
        return

    # Handle chunk approvals.
    chunk_id = item_id
    chunk_info = pending_chunks.pop(chunk_id, None)

    if chunk_info is None:
        await query.edit_message_text("Decision already recorded or chunk expired.")
        return

    user = query.from_user
    actor = f"telegram:{user.id}" if user else "telegram:unknown"
    sandbox_id = chunk_info.get("sandbox_id", "unknown")
    rule_name = chunk_info.get("rule_name", "")

    status_emoji = "approved" if action == "approve" else "denied"
    await query.edit_message_text(
        f"Rule <b>{_escape(rule_name)}</b> {status_emoji} by {actor}.",
        parse_mode="HTML",
    )

    log.info(
        "Chunk %s %s by %s (sandbox: %s, rule: %s)",
        chunk_id,
        action,
        actor,
        sandbox_id,
        rule_name,
    )

    context.bot_data.setdefault("decisions", []).append(
        {
            "chunk_id": chunk_id,
            "action": action,
            "reason": f"{status_emoji} by {actor}",
        }
    )


async def handle_reply(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Capture text replies to ForceReply prompts (policy deny-with-reason flow).

    Looks up the parent message id in `pending_deny_replies`. If matched,
    finalizes the policy denial with the operator's reason text. If unmatched,
    the reply is ignored — the bridge doesn't otherwise listen for chat messages.
    """
    msg = update.message
    if msg is None or msg.reply_to_message is None:
        return
    parent_id = msg.reply_to_message.message_id
    deny_info = pending_deny_replies.pop(parent_id, None)
    if deny_info is None:
        return

    actor = deny_info.get("actor", "telegram:unknown")
    raw = (msg.text or "").strip()
    if raw.lower() in ("/skip", "skip", ""):
        reason_text = "(no reason given)"
    else:
        reason_text = raw

    proposal_id = deny_info["proposal_id"]
    policy_name = deny_info.get("policy_name", "unknown")
    pending_proposals.pop(proposal_id, None)
    context.bot_data.setdefault("policy_decisions", []).append(
        {
            "proposal_id": proposal_id,
            "approved": False,
            "reason": f"denied by {actor}: {reason_text}",
        }
    )
    log.info("Policy %s denied by %s with reason: %s", proposal_id, actor, reason_text)
    try:
        await msg.reply_text(
            f"✓ Recorded denial for policy {policy_name}\nReason: {reason_text}"
        )
    except Exception:
        log.exception("Failed to send policy denial confirmation")


# ---------------------------------------------------------------------------
# Decision retrieval endpoint (OpenShell can poll this)
# ---------------------------------------------------------------------------


async def handle_decisions(request: web.Request) -> web.Response:
    """Return and flush pending chunk decisions."""
    app = request.app["telegram_app"]
    decisions = app.bot_data.pop("decisions", [])
    return web.json_response({"decisions": decisions})


async def handle_policy_decisions(request: web.Request) -> web.Response:
    """Return and flush pending policy proposal decisions."""
    app = request.app["telegram_app"]
    decisions = app.bot_data.pop("policy_decisions", [])
    return web.json_response({"decisions": decisions})


async def handle_syscall_decisions(request: web.Request) -> web.Response:
    """Return and flush pending syscall approval decisions (auto-approved)."""
    app = request.app["telegram_app"]
    decisions = app.bot_data.pop("syscall_decisions", [])
    return web.json_response({"decisions": decisions})


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


async def run() -> None:
    """Start both the HTTP server and Telegram bot."""
    if not TELEGRAM_BOT_TOKEN:
        log.error("TELEGRAM_BOT_TOKEN is required")
        sys.exit(1)
    if not TELEGRAM_CHAT_ID:
        log.error("TELEGRAM_CHAT_ID is required")
        sys.exit(1)

    # Build Telegram bot application.
    telegram_app = Application.builder().token(TELEGRAM_BOT_TOKEN).build()
    telegram_app.add_handler(CallbackQueryHandler(handle_button))
    # Capture text replies to ForceReply prompts (deny-with-reason flow).
    # Filter to text messages that are replies, so we don't process arbitrary
    # chat noise.
    telegram_app.add_handler(
        MessageHandler(
            filters.TEXT & filters.REPLY & ~filters.COMMAND,
            handle_reply,
        )
    )
    # Also handle /skip as a special command that might come in as a reply.
    telegram_app.add_handler(
        MessageHandler(
            filters.Regex(r"^/skip\b") & filters.REPLY,
            handle_reply,
        )
    )

    # Build HTTP server.
    http_app = web.Application()
    http_app["telegram_app"] = telegram_app
    http_app.router.add_post("/webhook", handle_webhook)
    http_app.router.add_get("/decisions", handle_decisions)
    http_app.router.add_get("/policy-decisions", handle_policy_decisions)
    http_app.router.add_get("/syscall-decisions", handle_syscall_decisions)
    http_app.router.add_get("/health", lambda _: web.Response(text="ok"))

    runner = web.AppRunner(http_app)
    await runner.setup()
    site = web.TCPSite(runner, LISTEN_HOST, LISTEN_PORT)

    # Start both.
    async with telegram_app:
        await telegram_app.updater.start_polling(
            allowed_updates=["callback_query", "message"]
        )
        await telegram_app.start()
        await site.start()
        log.info("Approval bridge listening on %s:%d", LISTEN_HOST, LISTEN_PORT)

        # Wait for shutdown signal.
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, stop.set)
        await stop.wait()

        log.info("Shutting down...")
        await telegram_app.updater.stop()
        await telegram_app.stop()
        await runner.cleanup()


if __name__ == "__main__":
    asyncio.run(run())
