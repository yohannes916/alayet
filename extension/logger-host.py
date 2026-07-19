#!/usr/bin/env python3
"""Native messaging host for the Family Activity Monitor extension.

Chromium launches this process and speaks the native-messaging protocol over
stdio: each message is a 4-byte little-endian length followed by that many
bytes of UTF-8 JSON. We append every message as one JSON line to root-owned
logs the child account cannot read or clear:

  /var/log/parental/activity.log   all events (visit / prompt / blocked)
  /var/log/parental/prompts.log    AI prompts only (quick review)
  /var/log/parental/blocked.log    blocked attempts only (feeds `review-denied`)

Optionally forwards to remote syslog if REMOTE_SYSLOG is configured at install.
"""
import json
import os
import struct
import sys
import time
from datetime import datetime, timezone
from urllib.parse import urlparse, parse_qs

LOG_DIR = os.environ.get("PARENTAL_LOG_DIR", "/var/log/parental")
ACTIVITY = os.path.join(LOG_DIR, "activity.log")
PROMPTS = os.path.join(LOG_DIR, "prompts.log")
BLOCKED = os.path.join(LOG_DIR, "blocked.log")
SEARCHES = os.path.join(LOG_DIR, "searches.log")


def google_search_query(url):
    """If url is a Google search (incl. AI Mode udm=50), return (query, mode)."""
    try:
        u = urlparse(url or "")
        host = u.netloc.split(":")[0].lower()
        if not (host == "google.com" or host.endswith(".google.com")):
            return None
        if u.path != "/search":
            return None
        qs = parse_qs(u.query)
        q = (qs.get("q") or [""])[0].strip()
        if not q:
            return None
        mode = "ai-mode" if (qs.get("udm") or [""])[0] == "50" else "web"
        return q, mode
    except Exception:
        return None


def read_message():
    raw_len = sys.stdin.buffer.read(4)
    if len(raw_len) < 4:
        return None
    (length,) = struct.unpack("<I", raw_len)
    data = sys.stdin.buffer.read(length)
    if len(data) < length:
        return None
    try:
        return json.loads(data.decode("utf-8"))
    except Exception:
        return {"type": "parse_error", "raw": data[:500].decode("utf-8", "replace")}


def append(path, obj):
    try:
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(obj, ensure_ascii=False) + "\n")
    except Exception:
        pass


def main():
    os.makedirs(LOG_DIR, exist_ok=True)
    last_q, last_t = None, 0.0     # dedup repeated google searches (redirects)
    while True:
        msg = read_message()
        if msg is None:
            break
        if "ts" not in msg:
            msg["ts"] = datetime.now(timezone.utc).isoformat()
        append(ACTIVITY, msg)
        if msg.get("type") == "prompt":
            append(PROMPTS, msg)
        elif msg.get("type") == "blocked":
            append(BLOCKED, msg)
        elif msg.get("type") == "visit":
            # Google searches (incl. AI Mode) carry the query in the URL; record
            # them as first-class search events so they're easy to review.
            hit = google_search_query(msg.get("url"))
            if hit:
                now = time.monotonic()
                # Google often re-navigates the same query (adds &sei=...); skip a
                # duplicate of the same query within 5s so the log stays clean.
                if not (hit[0] == last_q and now - last_t < 5):
                    append(SEARCHES, {"type": "search", "service": "google",
                                      "query": hit[0], "mode": hit[1],
                                      "url": msg.get("url"), "ts": msg.get("ts")})
                last_q, last_t = hit[0], now


if __name__ == "__main__":
    main()
