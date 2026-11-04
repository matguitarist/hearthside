"""The dashboard's web server, in the `dashboard` container: the files `home-status` writes, read
only, for anyone at home, and for whoever signs in, the buttons and the settings. Each is a
request file in /requests, named for a server and what to do, which `home-status tick` carries
out within a few seconds; a settings request holds `KEY=value` lines, which it checks again.
Nothing else reaches the host: no Docker socket, no database password.

The password is a PBKDF2 hash in /auth/password, set by `home-status password` (the launcher's
Settings › Home Server), which runs `python3 /dashboard.py password` here with the password on
standard input. Until one is set, nobody can sign in. A new password signs everyone out.

    python3 /dashboard.py            serve on port 80
    python3 /dashboard.py password   set the password from standard input"""

import hashlib
import hmac
import http.cookies
import http.server
import json
import os
import secrets
import sys
import threading
import time

PASSWORD = "/auth/password"
SESSION_DAYS = 30
ACTIONS = {"classic": {"start", "stop", "restart", "backup"}, "pandaria": {"start", "stop", "restart"}}
# Each setting the dashboard may change: its lowest and highest value, and whether it is whole.
RATE = (0.1, 10, False)
SWITCH = (0, 1, True)
SETTINGS = {
    "classic": {"BOTS": (0, 2000, True), "BOTS_NEAR_PLAYERS": SWITCH, "BOTS_SYNC_LEVEL": SWITCH,
                "RATE_XP": RATE, "RATE_LOOT": RATE, "RATE_GOLD": RATE, "RATE_REPUTATION": RATE, "RATE_REST": RATE,
                "AH_ENABLED": SWITCH, "AH_PRICES": (0.05, 10, False), "AH_STOCK": (0, 10, False)},
    "pandaria": {"BOTS": (0, 2000, True), "BOTS_SYNC_LEVEL": SWITCH, "MAP_THREADS": (1, 16, True),
                 "RATE_XP": RATE, "RATE_LOOT": RATE, "RATE_GOLD": RATE, "RATE_REPUTATION": RATE, "RATE_REST": RATE},
}

sessions = {}
lock = threading.Lock()
password_mtime = None


def hash_password(password, salt=None, rounds=300_000):
    salt = salt or secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), rounds).hex()
    return f"pbkdf2_sha256${rounds}${salt}${digest}"


def stored():
    """The stored hash, or None; a changed file ends every session."""
    global password_mtime
    try:
        mtime = os.stat(PASSWORD).st_mtime
        with open(PASSWORD) as f:
            value = f.read().strip()
    except OSError:
        mtime, value = None, None
    with lock:
        if mtime != password_mtime:
            sessions.clear()
            password_mtime = mtime
    return value or None


def check(password):
    value = stored()
    if not value:
        return False
    try:
        _, rounds, salt, _ = value.split("$")
        return hmac.compare_digest(hash_password(password, salt, int(rounds)), value)
    except ValueError:
        return False


def number(value, low, high, whole):
    v = float(value)
    if not low <= v <= high or (whole and v != int(v)):
        raise ValueError(value)
    return str(int(v)) if v == int(v) else f"{v:g}"


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory="/site", **kwargs)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, *args):
        pass

    def reply(self, code, body=None, cookie=None):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(code)
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def token(self):
        cookie = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
        return cookie["session"].value if "session" in cookie else None

    def signed_in(self):
        stored()
        token = self.token()
        with lock:
            expiry = sessions.get(token)
            if expiry and expiry < time.time():
                del sessions[token]
                expiry = None
        return bool(expiry)

    def do_GET(self):
        if self.path.split("?")[0] == "/session":
            return self.reply(200, {"signedIn": self.signed_in(), "passwordSet": stored() is not None})
        return super().do_GET()

    def do_POST(self):
        # JSON only: another site's page can't send that here without asking first, which this
        # server never allows.
        if self.headers.get("Content-Type", "").split(";")[0].strip() != "application/json":
            return self.send_error(415)
        try:
            body = json.loads(self.rfile.read(min(int(self.headers.get("Content-Length", 0)), 4096)))
        except ValueError:
            return self.send_error(400)
        if not isinstance(body, dict):
            return self.send_error(400)
        path = self.path.split("?")[0]
        if path == "/login":
            if not check(str(body.get("password", ""))):
                time.sleep(1)
                return self.reply(403, {"error": "wrong password" if stored() else "no password set"})
            token = secrets.token_urlsafe(32)
            with lock:
                sessions[token] = time.time() + SESSION_DAYS * 86400
            return self.reply(200, {}, f"session={token}; Max-Age={SESSION_DAYS * 86400}; Path=/; HttpOnly; SameSite=Strict")
        if path == "/logout":
            with lock:
                sessions.pop(self.token(), None)
            return self.reply(200, {}, "session=; Max-Age=0; Path=/; HttpOnly; SameSite=Strict")
        if not self.signed_in():
            return self.reply(401, {"error": "sign in first"})
        server = body.get("server")
        if path == "/action":
            if body.get("action") not in ACTIONS.get(server, ()):
                return self.send_error(400)
            return self.queue(f"{server}-{body['action']}", "")
        if path == "/settings":
            values, allowed = body.get("values"), SETTINGS.get(server)
            if not allowed or not isinstance(values, dict) or not values:
                return self.send_error(400)
            try:
                lines = [f"{k}={number(v, *allowed[k])}\n" for k, v in values.items()]
            except (KeyError, ValueError, TypeError):
                return self.send_error(400)
            return self.queue(f"{server}-settings", "".join(lines))
        return self.send_error(404)

    def queue(self, name, content):
        # Written whole under a dot name, which `home-status` passes over, then renamed.
        part = os.path.join("/requests", f".{name}.part")
        with open(part, "w") as f:
            f.write(content)
        os.replace(part, os.path.join("/requests", name))
        self.reply(202, {})


if sys.argv[1:] == ["password"]:
    password = sys.stdin.read().rstrip("\n")
    if len(password) < 6:
        sys.exit("The password needs at least six characters.")
    with open(PASSWORD + ".part", "w") as f:
        f.write(hash_password(password) + "\n")
    os.replace(PASSWORD + ".part", PASSWORD)
    print("password set")
else:
    http.server.ThreadingHTTPServer(("", 80), Handler).serve_forever()
