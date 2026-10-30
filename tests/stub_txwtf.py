#!/usr/bin/env python3
"""A stub TX.WTF instance for nicotina's tests: just the endpoints M0 uses.

Python stdlib only. It answers with the shapes of the live API's schema
(https://tx.wtf/openapi.json, txwtf 0.4.0, browsable at https://tx.wtf/docs),
and with the errors tx.wtf answers that the schema doesn't list:

  POST /user/login           {username, password} -> LoginResponse, or a
                             LoginChallengeResponse for an account with 2FA,
                             or 400 {"detail": "Access denied! (...)"}
  POST /user/login/2fa       {challenge, code} -> LoginResponse, or 400
  POST /user/logout          Bearer -> {"message": ...}; the token stops working
  GET  /user/                Bearer -> UserProfileResponse (the signed-in user)
  GET  /billing/scrip/balance  Bearer -> ScripBalanceResponse

Accounts (password "correct horse" for all of them):

  ada    plain sign-in
  grace  emailed second factor; the code is 123456
  linus  signs in, but force_password_change is set

Without an Authorization header a request gets 401 {"detail": "Not
authenticated"}, and with a token the server doesn't know (expired, signed out,
forged) 401 {"detail": "Invalid token (InvalidTokenSignature)"}: what tx.wtf
answers.

The tokens are fixed so a test can look for them in output: no output of the
client may ever contain one. The server itself never prints a token or a
password. Its log (--log FILE) is one JSON object a line, with the method,
path, status and whether the request carried a valid bearer token.

  python3 stub_txwtf.py --port 0 --port-file PORTFILE --log LOG
"""

import argparse
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PASSWORD = "correct horse"
TWO_FACTOR_CODE = "123456"
CHALLENGE = "Q9mUj4Z1x0bR7nVt2LcYw8sDp3HkGfA5"

# JWT-shaped, as txwtf's are. Tests import these to scan output for them.
TOKENS = {
    "ada": "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjoxLCJ1dWlkIjoiYWRhIn0.c3R1Yi1zaWctYWRhLW5pY290aW5h",
    "grace": "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjoyLCJ1dWlkIjoiZ3JhY2UifQ.c3R1Yi1zaWctZ3JhY2Utbmljbw",
    "linus": "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjozLCJ1dWlkIjoibGludXMifQ.c3R1Yi1zaWctbGludXMtbmljbw",
}
# A well-formed token this server never issued: a session that has expired.
STALE_TOKEN = "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjoxLCJ1dWlkIjoib2xkIn0.c3R1Yi1zaWctZXhwaXJlZC10b2tlbg"

USERS = {
    "ada": {
        "id": 1,
        "name": "Ada Lovelace",
        "email": "ada@example.org",
        "description": "Writes notes on the analytical engine. Prefers punched cards to paper tape.",
        "post_count": 42,
        "created_time": "2025-03-01T12:34:56.789012",
        "login_2fa_email_enabled": False,
        "force_password_change": False,
        "balance": "1234.5678900000",
        "runway_days": 41,
        "cents": 123457,
        "groups": ["users", "analysts"],
    },
    "grace": {
        "id": 2,
        "name": "Grace Hopper",
        "email": "grace@example.org",
        "description": None,
        "post_count": 7,
        "created_time": "2025-06-09T08:00:00",
        "login_2fa_email_enabled": True,
        "force_password_change": False,
        "balance": "25.0000000000",
        "runway_days": None,
        "cents": 2500,
        "groups": ["users"],
    },
    "linus": {
        "id": 3,
        "name": "Linus",
        "email": "linus@example.org",
        "description": "",
        "post_count": 0,
        "created_time": "2026-01-01T00:00:00",
        "login_2fa_email_enabled": False,
        "force_password_change": True,
        "balance": "0E-10",
        "runway_days": 0,
        "cents": 0,
        "groups": [],
    },
}


class State:
    def __init__(self, log_path):
        self.lock = threading.Lock()
        self.live = {}  # token -> username
        self.log_path = log_path

    def log(self, entry):
        if not self.log_path:
            return
        with self.lock, open(self.log_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry) + "\n")


def login_response(username):
    u = USERS[username]
    user = {  # User; the required fields and the ones the client might read
        "id": u["id"],
        "username": username,
        "email": u["email"],
        "password": "",
        "name": u["name"],
        "created_time": u["created_time"],
        "modified_time": u["created_time"],
        "accessed_time": "2026-10-30T11:59:00",
        "enabled": True,
        "email_verified": True,
        "login_2fa_email_enabled": u["login_2fa_email_enabled"],
        "force_password_change": u["force_password_change"],
    }
    return {
        "user": user,
        "expires": "2026-10-30T13:00:00",
        "token": TOKENS[username],
        "session_uuid": "session-" + username,
        "force_password_change": u["force_password_change"],
    }


def profile_response(username):
    u = USERS[username]
    return {
        "id": u["id"],
        "username": username,
        "email": u["email"],
        "name": u["name"],
        "avatar_url": None,
        "avatar_file_id": None,
        "header_image_url": None,
        "header_image_file_id": None,
        "header_text": None,
        "card_image_url": None,
        "card_image_file_id": None,
        "profile_bg_url": None,
        "profile_bg_file_id": None,
        "email_verified": True,
        "notification_email_enabled": True,
        "login_2fa_email_enabled": u["login_2fa_email_enabled"],
        "description": u["description"],
        "enabled": True,
        "created_time": u["created_time"],
        "last_login": "2026-10-30T11:59:00",
        "last_login_country": "US",
        "timezone": "UTC",
        "timezone_source": "geoip",
        "view_count": 3,
        "post_count": u["post_count"],
        "status": "offline",
        "is_admin": False,
        "storage_limit": None,
        "emblems": [],
        "groups": [
            {"group_id": i + 1, "group_name": g, "is_group_admin": False}
            for i, g in enumerate(u["groups"])
        ],
    }


def make_handler(state):
    class Handler(BaseHTTPRequestHandler):
        server_version = "stub-txwtf/1"

        def log_message(self, fmt, *args):  # quiet: the JSON log is the record
            pass

        def reply(self, status, body):
            data = json.dumps(body).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return status

        def bearer_user(self):
            """(username, None), or (None, the detail to refuse with)."""
            auth = self.headers.get("Authorization")
            scheme, _, token = (auth or "").partition(" ")
            if scheme != "Bearer" or not token:
                return None, "Not authenticated"
            with state.lock:
                user = state.live.get(token)
            return (user, None) if user else (None, "Invalid token (InvalidTokenSignature)")

        def json_body(self):
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n) if n else b""
            try:
                body = json.loads(raw or b"{}")
            except ValueError:
                return None
            return body if isinstance(body, dict) else None

        def handle_one(self, method):
            path = self.path.split("?", 1)[0]
            if method == "POST" and path == "/user/login":
                return self.login(), None
            if method == "POST" and path == "/user/login/2fa":
                return self.login_2fa(), None
            user, refused = self.bearer_user()
            if refused:
                return self.reply(401, {"detail": refused}), None
            if method == "GET" and path == "/user/":
                return self.reply(200, profile_response(user)), user
            if method == "GET" and path == "/billing/scrip/balance":
                u = USERS[user]
                return (
                    self.reply(
                        200,
                        {
                            "symbol": "SCRIP",
                            "balance": u["balance"],
                            "runway_days": u["runway_days"],
                            "cents_equivalent": u["cents"],
                        },
                    ),
                    user,
                )
            if method == "POST" and path == "/user/logout":
                token = self.headers["Authorization"].partition(" ")[2]
                with state.lock:
                    state.live.pop(token, None)
                return (
                    self.reply(200, {"message": "Successfully logged out", "code": 1, "data": None}),
                    user,
                )
            return self.reply(404, {"detail": "Not Found"}), user

        def sign_in(self, username):
            with state.lock:
                state.live[TOKENS[username]] = username
            return self.reply(200, login_response(username))

        def login(self):
            body = self.json_body()
            if body is None or not isinstance(body.get("username"), str) or not isinstance(
                body.get("password"), str
            ):
                return self.reply(
                    422,
                    {"detail": [{"loc": ["body"], "msg": "Field required", "type": "missing"}]},
                )
            username = body["username"]
            if username not in USERS:
                return self.reply(400, {"detail": "Access denied! (UserDoesNotExist)"})
            if body["password"] != PASSWORD:
                return self.reply(400, {"detail": "Access denied! (UserPasswordIncorrect)"})
            if USERS[username]["login_2fa_email_enabled"]:
                return self.reply(
                    200,
                    {
                        "two_factor_required": True,
                        "method": "email",
                        "challenge": CHALLENGE,
                        "expires_in": 300,
                    },
                )
            return self.sign_in(username)

        def login_2fa(self):
            body = self.json_body() or {}
            if body.get("challenge") == CHALLENGE and body.get("code") == TWO_FACTOR_CODE:
                return self.sign_in("grace")
            return self.reply(
                400, {"detail": "Invalid or expired verification code (LoginChallengeInvalid)"}
            )

        def run(self, method):
            status, user = self.handle_one(method)
            state.log(
                {
                    "method": method,
                    "path": self.path,
                    "status": status,
                    "authorization": "valid" if user else (
                        "none" if not self.headers.get("Authorization") else "rejected"
                    ),
                    "user": user,
                }
            )

        def do_GET(self):
            self.run("GET")

        def do_POST(self):
            self.run("POST")

    return Handler


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=0, help="0 picks a free port")
    ap.add_argument("--port-file", help="write the port here once listening")
    ap.add_argument("--log", help="append one JSON line per request here")
    ap.add_argument(
        "--signed-in",
        action="append",
        default=[],
        metavar="USER",
        help="start with USER's token live, as if they had signed in earlier",
    )
    args = ap.parse_args()

    state = State(args.log)
    for user in args.signed_in:
        state.live[TOKENS[user]] = user
    server = ThreadingHTTPServer((args.host, args.port), make_handler(state))
    port = server.server_address[1]
    if args.port_file:
        with open(args.port_file + ".tmp", "w") as f:
            f.write(str(port))
        os.replace(args.port_file + ".tmp", args.port_file)
    print(f"stub txwtf on http://{args.host}:{port}", file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
