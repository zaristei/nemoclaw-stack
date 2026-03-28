# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Tests for the approval bridge service."""

from __future__ import annotations

import hashlib
import hmac as hmac_mod
import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from aiohttp import web
from aiohttp.test_utils import AioHTTPTestCase, TestClient, TestServer

from main import (
    _escape,
    handle_decisions,
    handle_webhook,
    pending_chunks,
    verify_signature,
)


# ---------------------------------------------------------------------------
# Unit tests: pure functions
# ---------------------------------------------------------------------------


class TestVerifySignature:
    def test_valid_signature(self):
        secret = "test-secret"
        body = b'{"event": "test"}'
        sig = hmac_mod.new(secret.encode(), body, hashlib.sha256).hexdigest()
        assert verify_signature(secret, body, sig)

    def test_invalid_signature(self):
        assert not verify_signature("secret", b"body", "bad-sig")

    def test_empty_body(self):
        secret = "s"
        body = b""
        sig = hmac_mod.new(secret.encode(), body, hashlib.sha256).hexdigest()
        assert verify_signature(secret, body, sig)


class TestEscape:
    def test_ampersand(self):
        assert _escape("a & b") == "a &amp; b"

    def test_angle_brackets(self):
        assert _escape("<script>") == "&lt;script&gt;"

    def test_combined(self):
        assert _escape("a<b>&c") == "a&lt;b&gt;&amp;c"

    def test_no_escape_needed(self):
        assert _escape("hello world") == "hello world"

    def test_empty(self):
        assert _escape("") == ""


# ---------------------------------------------------------------------------
# Integration tests: webhook HTTP handler
# ---------------------------------------------------------------------------


def _make_chunk(chunk_id: str = "chunk-1", **overrides) -> dict:
    """Build a sample chunk payload."""
    base = {
        "id": chunk_id,
        "rule_name": "allow-npm-registry",
        "host": "registry.npmjs.org",
        "port": 443,
        "binary": "/usr/bin/node",
        "rationale": "npm install needs access",
        "confidence": 0.95,
        "hit_count": 3,
    }
    base.update(overrides)
    return base


def _make_payload(chunks: list[dict] | None = None, **overrides) -> dict:
    """Build a sample webhook payload."""
    base = {
        "sandbox_id": "sandbox-abc123",
        "event": "draft_chunks_proposed",
        "chunks": chunks or [_make_chunk()],
    }
    base.update(overrides)
    return base


def _sign(secret: str, body: bytes) -> str:
    return hmac_mod.new(secret.encode(), body, hashlib.sha256).hexdigest()


@pytest.fixture
def mock_telegram_app():
    """Create a mock Telegram application with a mock bot."""
    app = MagicMock()
    app.bot = AsyncMock()
    app.bot.send_message = AsyncMock()
    app.bot_data = {}
    return app


@pytest.fixture
def http_app(mock_telegram_app):
    """Create the aiohttp app with mocked Telegram."""
    app = web.Application()
    app["telegram_app"] = mock_telegram_app
    app.router.add_post("/webhook", handle_webhook)
    app.router.add_get("/decisions", handle_decisions)
    app.router.add_get("/health", lambda _: web.Response(text="ok"))
    return app


@pytest.fixture
def cleanup_pending():
    """Clear pending_chunks before and after each test."""
    pending_chunks.clear()
    yield
    pending_chunks.clear()


class TestWebhookEndpoint:
    @pytest.mark.asyncio
    async def test_valid_webhook_stores_chunk(
        self, aiohttp_client, http_app, mock_telegram_app, cleanup_pending
    ):
        client = await aiohttp_client(http_app)
        payload = _make_payload()
        body = json.dumps(payload).encode()

        resp = await client.post(
            "/webhook",
            data=body,
            headers={"Content-Type": "application/json"},
        )
        assert resp.status == 200
        assert "chunk-1" in pending_chunks
        assert pending_chunks["chunk-1"]["sandbox_id"] == "sandbox-abc123"
        assert pending_chunks["chunk-1"]["rule_name"] == "allow-npm-registry"

    @pytest.mark.asyncio
    async def test_webhook_calls_telegram_send(
        self, aiohttp_client, http_app, mock_telegram_app, cleanup_pending
    ):
        client = await aiohttp_client(http_app)
        payload = _make_payload()

        await client.post(
            "/webhook",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        mock_telegram_app.bot.send_message.assert_called_once()
        call_kwargs = mock_telegram_app.bot.send_message.call_args.kwargs
        assert call_kwargs["parse_mode"] == "HTML"
        assert "allow-npm-registry" in call_kwargs["text"]
        assert "registry.npmjs.org" in call_kwargs["text"]

    @pytest.mark.asyncio
    async def test_webhook_invalid_json(self, aiohttp_client, http_app):
        client = await aiohttp_client(http_app)
        resp = await client.post(
            "/webhook",
            data=b"not json",
            headers={"Content-Type": "application/json"},
        )
        assert resp.status == 400

    @pytest.mark.asyncio
    async def test_webhook_wrong_event_ignored(
        self, aiohttp_client, http_app, cleanup_pending
    ):
        client = await aiohttp_client(http_app)
        payload = _make_payload(event="something_else")

        resp = await client.post(
            "/webhook",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        assert resp.status == 200
        text = await resp.text()
        assert text == "ignored"
        assert len(pending_chunks) == 0

    @pytest.mark.asyncio
    async def test_webhook_skips_chunks_without_id(
        self, aiohttp_client, http_app, mock_telegram_app, cleanup_pending
    ):
        client = await aiohttp_client(http_app)
        payload = _make_payload(chunks=[_make_chunk(chunk_id="")])

        await client.post(
            "/webhook",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        assert len(pending_chunks) == 0
        mock_telegram_app.bot.send_message.assert_not_called()

    @pytest.mark.asyncio
    async def test_webhook_multiple_chunks(
        self, aiohttp_client, http_app, mock_telegram_app, cleanup_pending
    ):
        client = await aiohttp_client(http_app)
        chunks = [_make_chunk("c1"), _make_chunk("c2"), _make_chunk("c3")]
        payload = _make_payload(chunks=chunks)

        await client.post(
            "/webhook",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        assert len(pending_chunks) == 3
        assert mock_telegram_app.bot.send_message.call_count == 3

    @pytest.mark.asyncio
    async def test_webhook_telegram_failure_does_not_crash(
        self, aiohttp_client, http_app, mock_telegram_app, cleanup_pending
    ):
        mock_telegram_app.bot.send_message.side_effect = RuntimeError("bot down")
        client = await aiohttp_client(http_app)
        payload = _make_payload()

        resp = await client.post(
            "/webhook",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        # Should still return 200 — chunk is stored even if Telegram fails.
        assert resp.status == 200
        assert "chunk-1" in pending_chunks

    @pytest.mark.asyncio
    async def test_webhook_message_includes_binary(
        self, aiohttp_client, http_app, mock_telegram_app, cleanup_pending
    ):
        client = await aiohttp_client(http_app)
        payload = _make_payload(
            chunks=[_make_chunk(binary="/usr/bin/curl")]
        )

        await client.post(
            "/webhook",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        text = mock_telegram_app.bot.send_message.call_args.kwargs["text"]
        assert "/usr/bin/curl" in text

    @pytest.mark.asyncio
    async def test_webhook_message_omits_empty_binary(
        self, aiohttp_client, http_app, mock_telegram_app, cleanup_pending
    ):
        client = await aiohttp_client(http_app)
        payload = _make_payload(chunks=[_make_chunk(binary="")])

        await client.post(
            "/webhook",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        text = mock_telegram_app.bot.send_message.call_args.kwargs["text"]
        assert "Binary:" not in text


class TestHmacVerification:
    @pytest.mark.asyncio
    async def test_valid_hmac_accepted(
        self, aiohttp_client, http_app, cleanup_pending
    ):
        client = await aiohttp_client(http_app)
        payload = _make_payload()
        body = json.dumps(payload).encode()
        secret = "test-secret"

        with patch("main.WEBHOOK_SECRET", secret):
            sig = _sign(secret, body)
            resp = await client.post(
                "/webhook",
                data=body,
                headers={
                    "Content-Type": "application/json",
                    "X-OpenShell-Signature": sig,
                },
            )
        assert resp.status == 200

    @pytest.mark.asyncio
    async def test_invalid_hmac_rejected(self, aiohttp_client, http_app):
        client = await aiohttp_client(http_app)
        body = json.dumps(_make_payload()).encode()

        with patch("main.WEBHOOK_SECRET", "real-secret"):
            resp = await client.post(
                "/webhook",
                data=body,
                headers={
                    "Content-Type": "application/json",
                    "X-OpenShell-Signature": "wrong",
                },
            )
        assert resp.status == 401

    @pytest.mark.asyncio
    async def test_no_secret_configured_skips_check(
        self, aiohttp_client, http_app, cleanup_pending
    ):
        client = await aiohttp_client(http_app)
        body = json.dumps(_make_payload()).encode()

        with patch("main.WEBHOOK_SECRET", ""):
            resp = await client.post(
                "/webhook",
                data=body,
                headers={"Content-Type": "application/json"},
            )
        assert resp.status == 200


class TestDecisionsEndpoint:
    @pytest.mark.asyncio
    async def test_empty_decisions(self, aiohttp_client, http_app):
        client = await aiohttp_client(http_app)
        resp = await client.get("/decisions")
        assert resp.status == 200
        data = await resp.json()
        assert data == {"decisions": []}

    @pytest.mark.asyncio
    async def test_decisions_returned_and_flushed(
        self, aiohttp_client, http_app, mock_telegram_app
    ):
        # Pre-populate decisions.
        mock_telegram_app.bot_data["decisions"] = [
            {"chunk_id": "c1", "action": "approve", "reason": "approved by telegram:123"},
            {"chunk_id": "c2", "action": "reject", "reason": "denied by telegram:123"},
        ]

        client = await aiohttp_client(http_app)
        resp = await client.get("/decisions")
        data = await resp.json()
        assert len(data["decisions"]) == 2
        assert data["decisions"][0]["action"] == "approve"
        assert data["decisions"][1]["action"] == "reject"

        # Second call should be empty (flushed).
        resp2 = await client.get("/decisions")
        data2 = await resp2.json()
        assert data2 == {"decisions": []}


class TestHealthEndpoint:
    @pytest.mark.asyncio
    async def test_health(self, aiohttp_client, http_app):
        client = await aiohttp_client(http_app)
        resp = await client.get("/health")
        assert resp.status == 200
        assert await resp.text() == "ok"


# ---------------------------------------------------------------------------
# Telegram button callback handler
# ---------------------------------------------------------------------------


class TestHandleButton:
    @pytest.mark.asyncio
    async def test_approve_button(self, cleanup_pending):
        from main import handle_button

        pending_chunks["chunk-1"] = {
            "sandbox_id": "sb-1",
            "rule_name": "allow-npm",
        }

        query = AsyncMock()
        query.data = "approve:chunk-1"
        query.from_user = MagicMock()
        query.from_user.id = 42

        update = MagicMock(spec=["callback_query"])
        update.callback_query = query

        context = MagicMock()
        context.bot_data = {}

        await handle_button(update, context)

        query.answer.assert_called_once()
        query.edit_message_text.assert_called_once()
        msg = query.edit_message_text.call_args.args[0]
        assert "approved" in msg
        assert "telegram:42" in msg
        assert "chunk-1" not in pending_chunks

        assert len(context.bot_data["decisions"]) == 1
        assert context.bot_data["decisions"][0]["action"] == "approve"

    @pytest.mark.asyncio
    async def test_reject_button(self, cleanup_pending):
        from main import handle_button

        pending_chunks["chunk-2"] = {
            "sandbox_id": "sb-1",
            "rule_name": "allow-pypi",
        }

        query = AsyncMock()
        query.data = "reject:chunk-2"
        query.from_user = MagicMock()
        query.from_user.id = 99

        update = MagicMock(spec=["callback_query"])
        update.callback_query = query

        context = MagicMock()
        context.bot_data = {}

        await handle_button(update, context)

        query.answer.assert_called_once()
        msg = query.edit_message_text.call_args.args[0]
        assert "denied" in msg
        assert "chunk-2" not in pending_chunks
        assert context.bot_data["decisions"][0]["action"] == "reject"

    @pytest.mark.asyncio
    async def test_expired_chunk(self, cleanup_pending):
        from main import handle_button

        query = AsyncMock()
        query.data = "approve:nonexistent"
        query.from_user = MagicMock()
        query.from_user.id = 1

        update = MagicMock(spec=["callback_query"])
        update.callback_query = query

        context = MagicMock()
        context.bot_data = {}

        await handle_button(update, context)

        query.edit_message_text.assert_called_once_with(
            "Decision already recorded or chunk expired."
        )
        assert "decisions" not in context.bot_data

    @pytest.mark.asyncio
    async def test_no_callback_query(self):
        from main import handle_button

        update = MagicMock(spec=["callback_query"])
        update.callback_query = None

        context = MagicMock()
        # Should not raise.
        await handle_button(update, context)

    @pytest.mark.asyncio
    async def test_malformed_callback_data(self, cleanup_pending):
        from main import handle_button

        query = AsyncMock()
        query.data = "no-colon-here"
        query.from_user = MagicMock()

        update = MagicMock(spec=["callback_query"])
        update.callback_query = query

        context = MagicMock()
        context.bot_data = {}

        await handle_button(update, context)

        query.answer.assert_called_once()
        # No edit should happen — malformed data is silently skipped.
        query.edit_message_text.assert_not_called()
