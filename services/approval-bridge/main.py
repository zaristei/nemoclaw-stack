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
from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import Application, CallbackQueryHandler, ContextTypes

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

# Maps approval_id -> syscall approval info dict
pending_syscalls: dict[str, dict[str, Any]] = {}


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
        return await _handle_syscall_approval(request, payload)
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
    """Handle a mediator policy proposal — send to Telegram for approval."""
    proposal_id = payload.get("proposal_id", "")
    if not proposal_id:
        return web.Response(status=400, text="missing proposal_id")

    policy_config = payload.get("config", {})
    policy_name = policy_config.get("policy_name", "unknown")
    rationale = policy_config.get("rationale", "")
    http_allowlist = policy_config.get("http_allowlist", [])
    bind_ports = policy_config.get("bind_ports", [])

    pending_proposals[proposal_id] = {
        "config": policy_config,
        "policy_name": policy_name,
    }

    text = (
        f"🔒 Policy Proposal\n"
        f"Name: <b>{_escape(policy_name)}</b>\n"
        f"Rationale: {_escape(rationale)}\n"
        f"HTTP allowlist: <code>{_escape(', '.join(http_allowlist[:5]))}</code>\n"
    )
    if bind_ports:
        text += f"Ports: <code>{bind_ports[0]}–{bind_ports[1]}</code>\n"

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

    app = request.app["telegram_app"]
    try:
        await app.bot.send_message(
            chat_id=TELEGRAM_CHAT_ID,
            text=text,
            parse_mode="HTML",
            reply_markup=keyboard,
        )
    except Exception:
        log.exception("Failed to send policy proposal to Telegram")

    log.info("Policy proposal %s for '%s' sent to Telegram", proposal_id, policy_name)
    return web.Response(status=200, text="")


async def _handle_syscall_approval(
    request: web.Request, payload: dict[str, Any]
) -> web.Response:
    """Handle an init syscall approval request — send to Telegram for approval."""
    approval_id = payload.get("approval_id", "")
    if not approval_id:
        return web.Response(status=400, text="missing approval_id")

    method = payload.get("method", "unknown")
    params = payload.get("params", {})
    policy_name = payload.get("policy_name", "unknown")
    caller = payload.get("caller", "unknown")

    pending_syscalls[approval_id] = {
        "method": method,
        "params": params,
        "policy_name": policy_name,
    }

    # Summarize params for display.
    params_summary = json.dumps(params, indent=None, default=str)
    if len(params_summary) > 200:
        params_summary = params_summary[:200] + "..."

    text = (
        f"⚡ Syscall Approval Request\n"
        f"Caller: <b>{_escape(caller)}</b>\n"
        f"Method: <b>{_escape(method)}</b>\n"
        f"Policy: <code>{_escape(policy_name)}</code>\n"
        f"Params: <code>{_escape(params_summary)}</code>"
    )

    keyboard = InlineKeyboardMarkup(
        [
            [
                InlineKeyboardButton(
                    "Approve", callback_data=f"syscall_approve:{approval_id}"
                ),
                InlineKeyboardButton(
                    "Deny", callback_data=f"syscall_deny:{approval_id}"
                ),
            ]
        ]
    )

    app = request.app["telegram_app"]
    try:
        await app.bot.send_message(
            chat_id=TELEGRAM_CHAT_ID,
            text=text,
            parse_mode="HTML",
            reply_markup=keyboard,
        )
    except Exception:
        log.exception("Failed to send syscall approval to Telegram")

    log.info("Syscall approval %s for '%s' sent to Telegram", approval_id, method)
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

    # Handle syscall approvals.
    if action in ("syscall_approve", "syscall_deny"):
        syscall_info = pending_syscalls.pop(item_id, None)
        if syscall_info is None:
            await query.edit_message_text("Syscall approval already decided or expired.")
            return
        user = query.from_user
        actor = f"telegram:{user.id}" if user else "telegram:unknown"
        method = syscall_info.get("method", "unknown")
        approved = action == "syscall_approve"
        status_text = "approved" if approved else "denied"
        await query.edit_message_text(
            f"Syscall <b>{_escape(method)}</b> {status_text} by {actor}.",
            parse_mode="HTML",
        )
        log.info("Syscall %s %s by %s", item_id, status_text, actor)
        context.bot_data.setdefault("syscall_decisions", []).append(
            {
                "approval_id": item_id,
                "approved": approved,
                "reason": f"{status_text} by {actor}",
            }
        )
        return

    # Handle policy proposals.
    if action in ("policy_approve", "policy_deny"):
        proposal_info = pending_proposals.pop(item_id, None)
        if proposal_info is None:
            await query.edit_message_text("Proposal already decided or expired.")
            return
        user = query.from_user
        actor = f"telegram:{user.id}" if user else "telegram:unknown"
        policy_name = proposal_info.get("policy_name", "unknown")
        approved = action == "policy_approve"
        status_text = "approved" if approved else "denied"
        await query.edit_message_text(
            f"Policy <b>{_escape(policy_name)}</b> {status_text} by {actor}.",
            parse_mode="HTML",
        )
        log.info("Policy %s %s by %s", item_id, status_text, actor)
        context.bot_data.setdefault("policy_decisions", []).append(
            {
                "proposal_id": item_id,
                "approved": approved,
                "reason": f"{status_text} by {actor}",
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
    """Return and flush pending syscall approval decisions."""
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
        await telegram_app.updater.start_polling(allowed_updates=["callback_query"])
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
