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
  GET  /user/                Bearer -> UserProfileResponse (the signed-in user), with the
                             avatar, header and card image URLs txwtf resolves (/uploads/...,
                             or its default avatar under /static/), emblems, presence and groups
  GET  /billing/scrip/balance  Bearer -> ScripBalanceResponse
  GET  /social/timeline/user/{id}?include_replies=&limit=&offset=
                             Bearer -> TimelineResponse: that user's posts, newest first
  GET  /uploads/..., /static/img/...
                             no auth (as txwtf's /uploads mount): a small PNG drawn here, the
                             same picture for the same path; 404 for a path no profile names

Accounts (password "correct horse" for all of them):

  ada    plain sign-in
  grace  emailed second factor; the code is 123456
  linus  signs in, but force_password_change is set
  mary   a display name too long for the client's header; her profile takes 3 s, so the
         client's spinner can be watched turning
  slowpoke
         a profile that takes 12 s, longer than `ari snapshot` waits (resumed only)
  bob@peer.example
         a brokered account, named as txwtf names one: <user>@<home domain>. Like a real
         one it has no password here (resumed only)

The instance may sit below a path (--instance http://host:port/txwtf): a route matches from
the first of its known top-level segments (/user/, /billing/, /social/, /uploads/, /static/).

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
import struct
import sys
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

PASSWORD = "correct horse"
TOP_LEVEL = ("/user/", "/billing/", "/social/", "/uploads/", "/static/")
TWO_FACTOR_CODE = "123456"
CHALLENGE = "Q9mUj4Z1x0bR7nVt2LcYw8sDp3HkGfA5"

# JWT-shaped, as txwtf's are. Tests import these to scan output for them.
TOKENS = {
    "ada": "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjoxLCJ1dWlkIjoiYWRhIn0.c3R1Yi1zaWctYWRhLW5pY290aW5h",
    "grace": "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjoyLCJ1dWlkIjoiZ3JhY2UifQ.c3R1Yi1zaWctZ3JhY2Utbmljbw",
    "linus": "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjozLCJ1dWlkIjoibGludXMifQ.c3R1Yi1zaWctbGludXMtbmljbw",
    "mary": "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjo0LCJ1dWlkIjoibWFyeSJ9.c3R1Yi1zaWctbWFyeS1uaWNvdGluYQ",
    "bob@peer.example": "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjo1LCJ1dWlkIjoiYm9iIn0.c3R1Yi1zaWctYm9iLXBlZXItZXhhbXA",
    "slowpoke": "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjo2LCJ1dWlkIjoic2xvdyJ9.c3R1Yi1zaWctc2xvd3Bva2UtbmljbwA",
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
        # Her own pictures, as txwtf resolves uploaded files (/uploads/<storage key>).
        "avatar_url": "/uploads/u1/avatar-3f9c.png",
        "header_image_url": "/uploads/u1/header-77a1.png",
        "card_image_url": "/uploads/u1/card-0b2e.png",
        "is_admin": True,
        "emblems": [{"emblem_type": "verified", "name": "Verified", "icon": "fa-check-circle",
                     "color": "#3e8ed0"}],
        "status": "online",
        "view_count": 1234,
        "country": "GB",
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
    "mary": {
        "id": 4,
        "name": "Mary Kenneth Keller of the University of Wisconsin-Madison",
        "email": "mary@example.org",
        "description": None,
        "post_count": 1,
        "created_time": "2025-12-01T10:00:00",
        "login_2fa_email_enabled": False,
        "force_password_change": False,
        "balance": "3.5000000000",
        "runway_days": 2,
        "cents": 350,
        "groups": ["users"],
        "profile_delay": 3.0,
    },
    "slowpoke": {
        "id": 6,
        "name": "Slow Poke",
        "email": "slowpoke@example.org",
        "description": None,
        "post_count": 0,
        "created_time": "2026-03-03T03:03:03",
        "login_2fa_email_enabled": False,
        "force_password_change": False,
        "balance": "1.0000000000",
        "runway_days": None,
        "cents": 100,
        "groups": [],
        "profile_delay": 12.0,
    },
    "bob@peer.example": {
        "id": 5,
        "name": "Bob",
        "email": "fedauth-0123456789abcdef01234567@peer.example.invalid",
        "description": "Signs in from his home instance.",
        "post_count": 3,
        "created_time": "2026-02-02T02:02:02",
        "login_2fa_email_enabled": False,
        "force_password_change": False,
        "shadow": True,
        # a video avatar, which txwtf's web app plays as a muted loop
        "avatar_url": "/uploads/u5/avatar-loop.mp4",
        "balance": "0E-10",
        "runway_days": None,
        "cents": 0,
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


# Each account's posts, newest first: (id, created_at, content, reply_to_id, counts). counts are
# replies, reposts, reactions and views. Content is what txwtf stores: plain text, or the rich
# editor's HTML.
POSTS = {
    "ada": [
        (107, "2026-10-30T09:15:00", "Finished the notes on Menabrea's paper. Note G is the long one.",
         None, (2, 1, 5, 40)),
        (106, "2026-10-29T18:02:00", "Agreed: the engine might compose music, given the rules of harmony.",
         90, (0, 0, 3, 12)),
        (105, "2026-10-28T11:30:00",
         "<p>The <strong>Analytical Engine</strong> weaves algebraic patterns just as the "
         "Jacquard loom weaves flowers &amp; leaves.</p>", None, (4, 2, 9, 77)),
        (104, "2026-10-27T16:45:00", "The engine's mill, drawn from the plans.", None, (1, 0, 2, 30)),
        (103, "2026-10-26T08:00:00", "Bernoulli numbers, step by step, in a table anyone can follow.",
         None, (0, 1, 1, 19)),
        (102, "2026-10-25T21:10:00", "Thank you, Mr. Babbage.", 80, (0, 0, 1, 8)),
        (101, "2026-10-24T07:00:00", "Hello, TX.WTF.", None, (3, 0, 6, 51)),
        (100, "2026-10-23T23:59:00", "Testing, testing.", None, (0, 0, 0, 4)),
    ],
}


def post_response(username, post):
    pid, created, content, reply_to, (replies, reposts, reactions, views) = post
    u = USERS[username]
    return {  # PostResponse: the fields a client reads, and the required ones
        "id": pid,
        "user_id": u["id"],
        "content": content,
        "content_html": None,
        "visibility": "public",
        "reply_to_id": reply_to,
        "repost_id": None,
        "thread_root_id": reply_to,
        "reply_count": replies,
        "repost_count": reposts,
        "reaction_count": reactions,
        "view_count": views,
        "created_at": created,
        "updated_at": None,
        "tip_count": 0,
        "tip_total_scrip": None,
        "show_tip_total": False,
        "is_paid_content": False,
        "price_scrip": None,
        "is_locked": False,
        "unlock_count": 0,
        "revenue_scrip": None,
        "expires_at": None,
        "time_remaining_seconds": None,
        "is_ephemeral": False,
        "is_promoted": False,
        "promoted_until": None,
        "promotion_tier": None,
        "author": {  # txwtf's brief user: a post author's emblems carry `type`
            "id": u["id"],
            "username": username,
            "name": u["name"],
            "avatar_url": u.get("avatar_url", DEFAULT_AVATAR),
            "status": u.get("status", "offline"),
            "is_admin": u.get("is_admin", False),
            "emblems": [{"type": e["emblem_type"], "name": e["name"], "icon": e["icon"],
                         "color": e["color"]} for e in u.get("emblems", [])],
            "last_login_country": u.get("country", "US"),
        },
        "reactions_summary": None,  # the timeline leaves it out
        "attachments": [],
        "reposted_post": None,
        "link_previews": None,
    }


def user_timeline(user_id, query):
    """GET /social/timeline/user/{id}: offset paging, as the web app pages a profile's posts."""
    username = next((n for n, u in USERS.items() if u["id"] == user_id), None)
    posts = POSTS.get(username, [])
    if query.get("include_replies", ["true"])[0] == "false":
        posts = [p for p in posts if p[3] is None]
    limit = min(int(query.get("limit", ["20"])[0]), 100)
    offset = int(query.get("offset", ["0"])[0])
    page = posts[offset:offset + limit]
    return {
        "posts": [post_response(username, p) for p in page],
        "has_more": offset + limit < len(posts),
        "next_before_id": page[-1][0] if page else None,
        "total": None,
        "feed_mode": None,
        "tag": None,
        "pinned_post": None,
    }


def png(width, height, pixel):
    """A PNG, stdlib only: pixel(x, y) -> (r, g, b)."""
    rows = b"".join(
        b"\x00" + bytes(c for x in range(width) for c in pixel(x, y)) for y in range(height)
    )

    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def picture(path):
    """The picture for a media path a profile names, or None. Each is drawn so a person can tell
    them apart: a banner is a wide gradient, a card a dark one, an avatar a disc on a ground."""
    known = {DEFAULT_AVATAR} | {
        u[k] for u in USERS.values() for k in ("avatar_url", "header_image_url", "card_image_url")
        if u.get(k)
    }
    if path not in known:
        return None
    if "header" in path:
        return png(300, 100, lambda x, y: (40 + x * 180 // 300, 90 + y, 160 - x * 60 // 300))
    if "card" in path:
        return png(240, 120, lambda x, y: (20 + x // 8, 24 + y // 8, 48))
    seed = sum(path.encode()) % 3
    ground = [(70, 110, 200), (200, 120, 60), (90, 160, 90)][seed]
    return png(64, 64, lambda x, y: (240, 230, 210) if (x - 32) ** 2 + (y - 26) ** 2 < 196
               or (x - 32) ** 2 + (y - 70) ** 2 < 900 else ground)


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


# txwtf's default avatar (the default_avatar setting), for an account with none of its own. Header
# and card images have no default: null means the theme's colour.
DEFAULT_AVATAR = "/static/img/atxcf_logo_small.jpg"


def profile_response(username):
    u = USERS[username]
    return {
        "id": u["id"],
        "username": username,
        "email": u["email"],
        "name": u["name"],
        "avatar_url": u.get("avatar_url", DEFAULT_AVATAR),
        "avatar_file_id": 11 if u.get("avatar_url") else None,
        "header_image_url": u.get("header_image_url"),
        "header_image_file_id": 12 if u.get("header_image_url") else None,
        "header_text": None,
        "card_image_url": u.get("card_image_url"),
        "card_image_file_id": 13 if u.get("card_image_url") else None,
        "profile_bg_url": None,
        "profile_bg_file_id": None,
        "email_verified": True,
        "notification_email_enabled": True,
        "login_2fa_email_enabled": u["login_2fa_email_enabled"],
        "description": u["description"],
        "enabled": True,
        "created_time": u["created_time"],
        "last_login": "2026-10-30T11:59:00",
        "last_login_country": u.get("country", "US"),
        "timezone": "UTC",
        "timezone_source": "geoip",
        "view_count": u.get("view_count", 3),
        "post_count": u["post_count"],
        "status": u.get("status", "offline"),  # presence, raw: online, away, busy, ...
        "is_admin": u.get("is_admin", False),
        "storage_limit": None,
        "emblems": u.get("emblems", []),  # the profile's key is emblem_type (a post author's: type)
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

        def reply_bytes(self, status, data, content_type):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            # as txwtf's /uploads mount: never shown inline by a browser
            self.send_header("Content-Disposition", "attachment")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(data)
            return status

        def handle_one(self, method):
            path, _, query = self.path.partition("?")
            query = parse_qs(query)
            # The instance may sit below a path: start at the first known top-level segment.
            starts = [i for i in (path.find(p) for p in TOP_LEVEL) if i >= 0]
            if starts:
                path = path[min(starts):]
            if method == "POST" and path == "/user/login":
                return self.login(), None
            if method == "POST" and path == "/user/login/2fa":
                return self.login_2fa(), None
            if method == "GET" and (path.startswith("/uploads/") or path.startswith("/static/")):
                # no auth, as txwtf serves them
                if path.endswith(".mp4"):
                    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                           "fixtures", "engine.mp4"), "rb") as f:
                        return self.reply_bytes(200, f.read(), "video/mp4"), None
                data = picture(path)
                if data is None:
                    return self.reply(404, {"detail": "Not Found"}), None
                return self.reply_bytes(200, data, "image/png"), None
            user, refused = self.bearer_user()
            if refused:
                return self.reply(401, {"detail": refused}), None
            if method == "GET" and path == "/user/":
                time.sleep(USERS[user].get("profile_delay", 0))  # a slow instance, for the spinner
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
            if method == "GET" and path.startswith("/social/timeline/user/"):
                try:
                    user_id = int(path.rsplit("/", 1)[1])
                except ValueError:
                    return self.reply(422, {"detail": "user_id must be an integer"}), user
                return self.reply(200, user_timeline(user_id, query)), user
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
            if USERS[username].get("shadow"):  # signs in at its home instance only
                return self.reply(400, {"detail": "Access denied! (UserPasswordIncorrect)"})
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
