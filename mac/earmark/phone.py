"""Earmark on your phone, privately.

Access paths (Earmark never opens itself to the internet):
  * Tailscale (recommended): `tailscale serve` publishes Earmark at https://<mac>.<tailnet>.ts.net,
    reachable only by devices signed in to your tailnet, over WireGuard with a real HTTPS certificate.
  * This Wi-Fi (optional): Earmark also listens on the Mac's local address. Plain HTTP on the network,
    so it is off by default.

Every request that does not come straight from this Mac's own browser must carry a device cookie.
A phone gets one by pairing: the Mac shows a 6-digit code (and a QR code) valid for 10 minutes and
usable once; the phone enters or scans it. Tokens are random 256-bit values, stored only as SHA-256
hashes, and can be revoked from Settings. Pairing and device management only work from the Mac itself.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import shutil
import socket
import subprocess
import time
from typing import Optional

COOKIE = "earmark_device"
CODE_TTL_S = 600
MAX_TRIES = 5
LOCAL_HOSTS = {"localhost", "127.0.0.1", "[::1]", "::1"}


# ---------------------------------------------------------------- who is asking
def is_local(client_host: Optional[str], headers) -> bool:
    """True only for this Mac's own browser talking to 127.0.0.1 directly.
    Anything proxied (Tailscale serve adds forwarding headers) or addressed by another host name is remote."""
    if client_host not in ("127.0.0.1", "::1"):
        return False
    host = (headers.get("host") or "").rsplit(":", 1)[0] if not (headers.get("host") or "").startswith("[") \
        else (headers.get("host") or "").split("]")[0] + "]"
    if host.lower() not in LOCAL_HOSTS:
        return False
    for h in ("x-forwarded-for", "x-forwarded-host", "forwarded", "tailscale-user-login", "tailscale-user-name"):
        if headers.get(h):
            return False
    return True


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


# ---------------------------------------------------------------- pairing + devices (db helpers take a connection)
def init(c):
    c.execute("""CREATE TABLE IF NOT EXISTS devices(
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        token_hash TEXT NOT NULL UNIQUE,
        created_at INTEGER NOT NULL,
        last_seen INTEGER,
        revoked INTEGER NOT NULL DEFAULT 0)""")


def new_code(c) -> dict:
    code = f"{secrets.randbelow(10 ** 6):06d}"
    rec = {"code": code, "exp": int(time.time()) + CODE_TTL_S, "tries": 0}
    c.execute("INSERT OR REPLACE INTO kv(k, v) VALUES('pair_code', ?)", (json.dumps(rec),))
    return rec


def redeem(c, code: str, device_name: str) -> Optional[str]:
    """Returns a new device token, or None. A code works once, for 10 minutes, with 5 attempts."""
    r = c.execute("SELECT v FROM kv WHERE k='pair_code'").fetchone()
    if not r:
        return None
    rec = json.loads(r[0])
    if time.time() > rec["exp"] or rec["tries"] >= MAX_TRIES:
        c.execute("DELETE FROM kv WHERE k='pair_code'")
        return None
    if not hmac.compare_digest(str(code).strip(), rec["code"]):
        rec["tries"] += 1
        c.execute("UPDATE kv SET v=? WHERE k='pair_code'", (json.dumps(rec),))
        return None
    c.execute("DELETE FROM kv WHERE k='pair_code'")
    token = secrets.token_urlsafe(32)
    now = int(time.time())
    c.execute("INSERT INTO devices(name, token_hash, created_at, last_seen) VALUES(?,?,?,?)",
              (device_name[:60] or "Phone", _hash(token), now, now))
    return token


def device_for(c, token: Optional[str]) -> Optional[dict]:
    if not token:
        return None
    r = c.execute("SELECT * FROM devices WHERE token_hash=? AND revoked=0", (_hash(token),)).fetchone()
    if not r:
        return None
    if not r["last_seen"] or time.time() - r["last_seen"] > 60:
        c.execute("UPDATE devices SET last_seen=? WHERE id=?", (int(time.time()), r["id"]))
    return dict(r)


def device_name(user_agent: str) -> str:
    ua = user_agent or ""
    for key, name in (("iPhone", "iPhone"), ("iPad", "iPad"), ("Android", "Android phone"), ("Macintosh", "Mac browser")):
        if key in ua:
            return name
    return "Browser"


# ---------------------------------------------------------------- Tailscale
TS_PATHS = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale"]


def tailscale_bin() -> Optional[str]:
    for p in TS_PATHS:
        if os.path.exists(p):
            return p
    return shutil.which("tailscale")


def _ts(args: list, timeout: int = 20) -> tuple[int, str]:
    b = tailscale_bin()
    if not b:
        return 127, "Tailscale is not installed"
    try:
        p = subprocess.run([b] + args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout + p.stderr).strip()
    except subprocess.TimeoutExpired as e:
        out = ((e.stdout or b"").decode(errors="ignore") if isinstance(e.stdout, bytes) else (e.stdout or "")) + \
              ((e.stderr or b"").decode(errors="ignore") if isinstance(e.stderr, bytes) else (e.stderr or ""))
        return 124, out.strip() or "Tailscale did not answer in time"
    except Exception as e:
        return 1, str(e)


def tailscale_status(port: int) -> dict:
    out = {"installed": bool(tailscale_bin()), "running": False, "name": None, "url": None, "serving": False}
    if not out["installed"]:
        return out
    code, txt = _ts(["status", "--json"], 10)
    if code != 0:
        out["detail"] = txt[:300]
        return out
    try:
        st = json.loads(txt)
    except Exception:
        out["detail"] = txt[:300]
        return out
    out["running"] = st.get("BackendState") == "Running"
    dns = ((st.get("Self") or {}).get("DNSName") or "").rstrip(".")
    out["name"] = dns or None
    if dns:
        out["url"] = f"https://{dns}"
    code, txt = _ts(["serve", "status", "--json"], 10)
    if code == 0 and txt:
        out["serving"] = f"127.0.0.1:{port}" in txt or f"localhost:{port}" in txt
    return out


def tailscale_enable(port: int) -> dict:
    """Publish Earmark to your tailnet only (serve, never funnel)."""
    code, txt = _ts(["serve", "--bg", "--yes", str(port)], 25)
    if code != 0 and ("unknown flag" in txt or "flag provided but not defined" in txt):
        code, txt = _ts(["serve", "--bg", str(port)], 25)
    link = next((w for w in txt.split() if w.startswith("https://login.tailscale.com")), None)
    return {"ok": code == 0, "output": txt[-600:], "enable_link": link}


def tailscale_disable(port: int) -> dict:
    code, txt = _ts(["serve", "--https=443", "off"], 15)
    if code != 0:
        code, txt = _ts(["serve", "reset"], 15)
    return {"ok": code == 0, "output": txt[-300:]}


# ---------------------------------------------------------------- local network
def lan_ip() -> Optional[str]:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))
            ip = s.getsockname()[0]
            return None if ip.startswith("127.") else ip
    except Exception:
        return None


UNPAIRED_PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes"><meta name="theme-color" content="#12161B">
<link rel="apple-touch-icon" href="/static/icon-180.png"><link rel="manifest" href="/static/manifest.webmanifest">
<title>Earmark</title><style>
:root{color-scheme:light dark;--bg:#F3F4F6;--card:#fff;--ink:#14181D;--ink2:#555E68;--line:#CDD2D8;--acc:#2F6FEB;--bad:#B4362F}
@media (prefers-color-scheme:dark){:root{--bg:#12161B;--card:#181D23;--ink:#E7EBEF;--ink2:#A3ADB8;--line:#36404A;--acc:#5B91F5;--bad:#EE7B73}}
*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--ink);
font:16px/1.5 -apple-system,system-ui,sans-serif;padding:24px}
.c{width:100%;max-width:380px;background:var(--card);border:1px solid var(--line);border-radius:14px;padding:26px 22px}
h1{font:500 26px/1.2 Georgia,serif;margin:0 0 6px}p{color:var(--ink2);margin:0 0 18px;font-size:15px}
input{width:100%;font:600 28px/1 ui-monospace,Menlo,monospace;letter-spacing:.35em;text-align:center;padding:14px 10px;border-radius:10px;
border:1px solid var(--line);background:var(--bg);color:var(--ink)}input:focus{outline:none;border-color:var(--acc)}
button{width:100%;margin-top:14px;padding:13px;border:0;border-radius:10px;background:var(--acc);color:#fff;font:600 16px -apple-system,system-ui}
.err{color:var(--bad);font-size:14px;margin-top:10px;min-height:1em}
</style></head><body><form class="c" method="post" action="/pair">
<h1>Earmark</h1><p>Connect this phone to Earmark on your Mac. On the Mac, open <b>Settings → Phone</b> and choose
<b>Pair a phone</b>, then enter the 6-digit code here.</p>
<input name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" maxlength="6" placeholder="000000" required autofocus value="__CODE__">
<button type="submit">Connect</button><div class="err">__ERR__</div></form></body></html>"""
