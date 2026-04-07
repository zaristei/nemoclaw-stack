#!/usr/bin/env python3
"""WhatsApp ↔ Honeypot bridge (polling mode).

Polls Twilio for new WhatsApp messages every 10 seconds and writes
them to the inbox. Polls the outbox for replies and sends them via
Twilio API. No webhook/tunnel needed.

Usage:
    TWILIO_SID=ACxxx TWILIO_AUTH_TOKEN=xxx python3 whatsapp_bridge.py

Env:
    TWILIO_SID              Twilio Account SID
    TWILIO_AUTH_TOKEN        Twilio Auth Token
    TWILIO_WHATSAPP_FROM     Sandbox number (default: whatsapp:+14155238886)
    POLL_INTERVAL            Seconds between polls (default: 10)
    INBOX_PATH               Incoming messages (default: /sandbox/data/messages/inbox.json)
    OUTBOX_PATH              Outgoing replies (default: /sandbox/data/messages/outbox.json)
    BRIDGE_PORT              Health check port (default: 9090)
"""

import json
import os
import time
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlencode
from urllib.request import Request, urlopen, ProxyHandler, build_opener
from urllib.error import URLError
import base64
import ssl

# SSL context for self-signed certs (proxy)
_ssl_ctx = ssl.create_default_context()
_ssl_ctx.check_hostname = False
_ssl_ctx.verify_mode = ssl.CERT_NONE

# Build opener with proxy support
_proxy_url = os.environ.get("HTTPS_PROXY", os.environ.get("https_proxy", ""))
if _proxy_url:
    _opener = build_opener(ProxyHandler({"https": _proxy_url, "http": _proxy_url}))
else:
    _opener = build_opener()

TWILIO_SID = os.environ["TWILIO_SID"]
TWILIO_AUTH_TOKEN = os.environ["TWILIO_AUTH_TOKEN"]
TWILIO_FROM = os.environ.get("TWILIO_WHATSAPP_FROM", "whatsapp:+14155238886")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "10"))
INBOX_PATH = os.environ.get("INBOX_PATH", "/sandbox/data/messages/inbox.json")
OUTBOX_PATH = os.environ.get("OUTBOX_PATH", "/sandbox/data/messages/outbox.json")
BRIDGE_PORT = int(os.environ.get("BRIDGE_PORT", "9090"))

inbox = []
seen_sids = set()
outbox_sent = set()
credentials = base64.b64encode(f"{TWILIO_SID}:{TWILIO_AUTH_TOKEN}".encode()).decode()


def twilio_get(path):
    url = f"https://api.twilio.com/2010-04-01/Accounts/{TWILIO_SID}/{path}"
    req = Request(url, headers={"Authorization": f"Basic {credentials}"})
    with _opener.open(req, timeout=15) as resp:
        return json.loads(resp.read())


def twilio_post(path, data):
    url = f"https://api.twilio.com/2010-04-01/Accounts/{TWILIO_SID}/{path}"
    encoded = urlencode(data).encode()
    req = Request(url, data=encoded, headers={"Authorization": f"Basic {credentials}"})
    with _opener.open(req, timeout=15) as resp:
        return json.loads(resp.read())


def load_inbox():
    global inbox, seen_sids
    try:
        with open(INBOX_PATH) as f:
            inbox = json.load(f)
            seen_sids = {m["id"] for m in inbox if "id" in m}
    except (FileNotFoundError, json.JSONDecodeError):
        inbox = []


def save_inbox():
    os.makedirs(os.path.dirname(INBOX_PATH), exist_ok=True)
    with open(INBOX_PATH, "w") as f:
        json.dump(inbox, f, indent=2)


def poll_twilio():
    """Poll Twilio for new inbound WhatsApp messages."""
    while True:
        try:
            # Fetch recent messages sent TO the sandbox number
            encoded_from = TWILIO_FROM.replace("+", "%2B").replace(":", "%3A")
            result = twilio_get(f"Messages.json?To={encoded_from}&PageSize=50")
            messages = result.get("messages", [])

            new_count = 0
            for msg in messages:
                sid = msg["sid"]
                if sid in seen_sids:
                    continue
                if msg["direction"] not in ("inbound",):
                    continue

                seen_sids.add(sid)
                entry = {
                    "id": sid,
                    "from": msg["from"],
                    "to": msg["to"],
                    "body": msg["body"],
                    "timestamp": msg["date_created"],
                }
                inbox.append(entry)
                new_count += 1
                print(f"[bridge] New message from {msg['from']}: {msg['body'][:80]}")

            if new_count > 0:
                save_inbox()
                print(f"[bridge] {new_count} new message(s), total: {len(inbox)}")

        except Exception as e:
            print(f"[bridge] Poll error: {e}")

        time.sleep(POLL_INTERVAL)


def poll_outbox():
    """Poll the outbox file for replies to send."""
    while True:
        try:
            if os.path.exists(OUTBOX_PATH):
                with open(OUTBOX_PATH) as f:
                    messages = json.load(f)
                for msg in messages:
                    msg_id = msg.get("id", "")
                    if msg_id and msg_id not in outbox_sent:
                        to = msg.get("to", "")
                        body = msg.get("body", "")
                        if to and body:
                            try:
                                result = twilio_post("Messages.json", {
                                    "To": to,
                                    "From": TWILIO_FROM,
                                    "Body": body,
                                })
                                outbox_sent.add(msg_id)
                                print(f"[bridge] Replied to {to}: {body[:80]}")
                            except Exception as e:
                                print(f"[bridge] Reply failed to {to}: {e}")
        except (json.JSONDecodeError, KeyError):
            pass
        time.sleep(5)


class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            data = {"status": "ok", "inbox_count": len(inbox), "outbox_sent": len(outbox_sent)}
        elif self.path == "/inbox":
            data = inbox
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data, indent=2).encode())

    def log_message(self, format, *args):
        pass


def main():
    load_inbox()
    print(f"[bridge] WhatsApp bridge starting (polling mode, {POLL_INTERVAL}s interval)")
    print(f"[bridge] Twilio SID: {TWILIO_SID[:10]}...")
    print(f"[bridge] From: {TWILIO_FROM}")
    print(f"[bridge] Inbox: {INBOX_PATH} ({len(inbox)} existing)")
    print(f"[bridge] Outbox: {OUTBOX_PATH}")

    threading.Thread(target=poll_twilio, daemon=True).start()
    threading.Thread(target=poll_outbox, daemon=True).start()

    server = HTTPServer(("0.0.0.0", BRIDGE_PORT), HealthHandler)
    print(f"[bridge] Health: http://localhost:{BRIDGE_PORT}/health")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[bridge] Shutting down")


if __name__ == "__main__":
    main()
