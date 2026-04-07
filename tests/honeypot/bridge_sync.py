#!/usr/bin/env python3
"""Bridge sync — runs on HOST, syncs inbox/outbox between Twilio and sandbox.

- Polls Twilio for new WhatsApp messages → writes to sandbox inbox via kubectl cp
- Polls sandbox outbox via kubectl cp → sends replies via Twilio API

The agent runs inside the sandbox. The bridge handles external comms.
"""

import json
import os
import subprocess
import tempfile
import time
import base64
from urllib.parse import urlencode
from urllib.request import Request, urlopen

TWILIO_SID = os.environ["TWILIO_SID"]
TWILIO_AUTH_TOKEN = os.environ["TWILIO_AUTH_TOKEN"]
TWILIO_FROM = os.environ.get("TWILIO_WHATSAPP_FROM", "whatsapp:+14155238886")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "8"))
DOCKER_HOST = os.environ.get("DOCKER_HOST", "unix:///Volumes/macmini1/nemoclaw-stack/colima/default/docker.sock")
SANDBOX_INBOX = "/sandbox/data/messages/inbox.json"
SANDBOX_OUTBOX = "/sandbox/data/messages/outbox.json"
SANDBOX_NAME = "my-assistant"

credentials = base64.b64encode(f"{TWILIO_SID}:{TWILIO_AUTH_TOKEN}".encode()).decode()
seen_sids = set()
outbox_sent = set()


def kubectl(cmd):
    full = ["docker", "-H", DOCKER_HOST, "exec", "openshell-cluster-nemoclaw",
            "kubectl", "exec", "-n", "openshell", SANDBOX_NAME, "-c", "agent", "--", "bash", "-c", cmd]
    r = subprocess.run(full, capture_output=True, text=True, timeout=10)
    return r.stdout.strip(), r.returncode


def kubectl_cp_to(local_path, remote_path):
    tmp = "/tmp/_sync_" + os.path.basename(local_path)
    subprocess.run(["docker", "-H", DOCKER_HOST, "cp", local_path, f"openshell-cluster-nemoclaw:{tmp}"],
                   capture_output=True, timeout=10)
    subprocess.run(["docker", "-H", DOCKER_HOST, "exec", "openshell-cluster-nemoclaw",
                    "kubectl", "cp", tmp, f"openshell/{SANDBOX_NAME}:{remote_path}", "-c", "agent"],
                   capture_output=True, timeout=10)


def kubectl_cp_from(remote_path):
    stdout, rc = kubectl(f"cat {remote_path} 2>/dev/null")
    return stdout if rc == 0 else None


def twilio_get(path):
    url = f"https://api.twilio.com/2010-04-01/Accounts/{TWILIO_SID}/{path}"
    req = Request(url, headers={"Authorization": f"Basic {credentials}"})
    with urlopen(req, timeout=15) as resp:
        return json.loads(resp.read())


def twilio_send(to, body):
    url = f"https://api.twilio.com/2010-04-01/Accounts/{TWILIO_SID}/Messages.json"
    data = urlencode({"To": to, "From": TWILIO_FROM, "Body": body}).encode()
    req = Request(url, data=data, headers={"Authorization": f"Basic {credentials}"})
    try:
        with urlopen(req, timeout=15) as resp:
            r = json.loads(resp.read())
            print(f"[sync] Sent to {to[-4:]}: {body[:60]}")
            return True
    except Exception as e:
        print(f"[sync] Send failed: {e}")
        return False


def poll_twilio_to_sandbox():
    """Poll Twilio for inbound messages, write to sandbox inbox."""
    try:
        encoded_from = TWILIO_FROM.replace("+", "%2B").replace(":", "%3A")
        result = twilio_get(f"Messages.json?To={encoded_from}&PageSize=50")
        messages = result.get("messages", [])

        inbox = []
        new_count = 0
        for m in messages:
            if m["direction"] != "inbound":
                continue
            sid = m["sid"]
            inbox.append({
                "id": sid,
                "from": m["from"],
                "body": m["body"],
                "timestamp": m["date_created"],
            })
            if sid not in seen_sids:
                seen_sids.add(sid)
                new_count += 1
                print(f"[sync] New from {m['from'][-4:]}: {m['body'][:60]}")

        if new_count > 0 or not seen_sids:
            # Write inbox to sandbox
            with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
                json.dump(inbox, f, indent=2)
                tmp = f.name
            kubectl_cp_to(tmp, SANDBOX_INBOX)
            os.unlink(tmp)
            if new_count > 0:
                print(f"[sync] Synced {new_count} new → sandbox ({len(inbox)} total)")

    except Exception as e:
        print(f"[sync] Twilio poll error: {e}")


def poll_sandbox_outbox():
    """Read sandbox outbox, send replies via Twilio."""
    try:
        raw = kubectl_cp_from(SANDBOX_OUTBOX)
        if not raw:
            return
        messages = json.loads(raw)
        for msg in messages:
            mid = msg.get("id", "")
            if mid and mid not in outbox_sent:
                to = msg.get("to", "")
                body = msg.get("body", "")
                if to and body:
                    if twilio_send(to, body):
                        outbox_sent.add(mid)
    except (json.JSONDecodeError, Exception) as e:
        pass


def main():
    print(f"[sync] Bridge sync starting")
    print(f"[sync] Twilio: {TWILIO_SID[:10]}... from {TWILIO_FROM}")
    print(f"[sync] Sandbox: {SANDBOX_NAME}")
    print(f"[sync] Poll interval: {POLL_INTERVAL}s")

    while True:
        poll_twilio_to_sandbox()
        poll_sandbox_outbox()
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
