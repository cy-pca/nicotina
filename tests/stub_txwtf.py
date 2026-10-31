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
  GET  /social/timeline/home?limit=&before_id=&mode=, /social/timeline/public?...
                             Bearer -> TimelineResponse: the posts of the people the user
                             follows (ada follows three authors; grace no one), or everyone's,
                             newest first, paged by before_id. Their attachments are pictures,
                             a video, a recording and a PDF; one post is a repost, one is paid
                             for and withheld
  GET  /social/posts/{id}    Bearer -> PostResponse, with its reactions_summary
  GET  /uploads/..., /static/img/...
                             no auth (as txwtf's /uploads mount): a small PNG drawn here, the
                             same picture for the same path, or a recording from
                             tests/fixtures (engine.mp4, lecture.ogg); 404 for a path nothing
                             names

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


# Authors in the feed who are not accounts here: no password, no token.
AUTHORS = {
    "charles": {"id": 7, "name": "Charles Babbage", "avatar_url": "/uploads/u7/avatar-c4b1.png",
                "status": "busy", "country": "GB"},
    # a video avatar, which txwtf's web app plays as a muted loop
    "alan@peer.example": {"id": 8, "name": "Alan Turing", "status": "online", "country": "GB",
                          "avatar_url": "/uploads/u8/avatar-loop.webm"},
}

# Attachments, as txwtf lists them (get_post_attachments): a mime type, never a kind, and
# root-relative /uploads URLs that need no sign-in. FILES holds what /uploads serves for each.
FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")
FILES = {
    "/uploads/media/engine-diagram.png": ("image/png", None),
    "/uploads/media/moth.png": ("image/png", None),
    "/uploads/media/relay-70.png": ("image/png", None),
    "/uploads/media/log-book.png": ("image/png", None),
    "/uploads/media/engine.mp4": ("video/mp4", "engine.mp4"),
    "/uploads/u5/avatar-loop.mp4": ("video/mp4", "engine.mp4"),  # bob's avatar: a video
    "/uploads/u8/avatar-loop.webm": ("video/webm", "engine.mp4"),  # alan's: a video too
    "/uploads/media/lecture.ogg": ("audio/ogg", "lecture.ogg"),
    "/uploads/media/cobol-notes.pdf": ("application/pdf", b"%PDF-1.4\n% nicotina test\n%%EOF\n"),
}


def attachment(aid, path, size, alt=None):
    mime = FILES[path][0]
    return {"id": aid, "filename": path.rsplit("/", 1)[1], "mime_type": mime, "file_size": size,
            "url": path, "preview_url": None, "display_order": 0, "alt_text": alt,
            "description": None, "deleted": False}


def brief(username):
    """A post's author, as txwtf's _get_user_brief gives it: emblems carry `type` here."""
    u = USERS.get(username) or AUTHORS[username]
    return {
        "id": u["id"],
        "username": username,
        "name": u["name"],
        "avatar_url": u.get("avatar_url", DEFAULT_AVATAR),
        "status": u.get("status", "offline"),
        "is_admin": u.get("is_admin", False),
        "emblems": [{"type": e["emblem_type"], "name": e["name"], "icon": e["icon"],
                     "color": e["color"]} for e in u.get("emblems", [])],
        "last_login_country": u.get("country", "US"),
    }


def post(author, pid, created, content, reply_to=None, counts=(0, 0, 0, 0), attachments=(),
         repost=None, price=None):
    """A post: counts are replies, reposts, reactions and views. Content is what txwtf stores:
    plain text, or the rich editor's HTML. repost is the reposted post; price makes it a paid
    post this viewer hasn't unlocked, which txwtf withholds."""
    return {"author": author, "id": pid, "created": created, "content": content,
            "reply_to": reply_to, "counts": counts, "attachments": list(attachments),
            "repost": repost, "price": price}


# Each account's posts, newest first.
POSTS = {
    "ada": [
        post("ada", 107, "2026-10-30T09:15:00",
             "Finished the notes on Menabrea's paper. Note G is the long one.", None, (2, 1, 5, 40)),
        post("ada", 106, "2026-10-29T18:02:00",
             "Agreed: the engine might compose music, given the rules of harmony.", 90, (0, 0, 3, 12)),
        post("ada", 105, "2026-10-28T11:30:00",
             "<p>The <strong>Analytical Engine</strong> weaves algebraic patterns just as the "
             "Jacquard loom weaves flowers &amp; leaves.</p>", None, (4, 2, 9, 77)),
        post("ada", 104, "2026-10-27T16:45:00", "The engine's mill, drawn from the plans.", None,
             (1, 0, 2, 30)),
        post("ada", 103, "2026-10-26T08:00:00",
             "Bernoulli numbers, step by step, in a table anyone can follow.", None, (0, 1, 1, 19)),
        post("ada", 102, "2026-10-25T21:10:00", "Thank you, Mr. Babbage.", 80, (0, 0, 1, 8)),
        post("ada", 101, "2026-10-24T07:00:00", "Hello, TX.WTF.", None, (3, 0, 6, 51)),
        post("ada", 100, "2026-10-23T23:59:00", "Testing, testing.", None, (0, 0, 0, 4)),
    ],
}

# The home feed: posts by the people ada follows, newest first, two pages of ten. Grace follows
# no one, so hers is empty, as txwtf's is then. The public feed has these, linus's and ada's.
FEED = [
    post("charles", 312, "2026-10-30T22:40:00", "The Difference Engine No. 2, working at last.",
         None, (5, 3, 21, 310),
         [attachment(901, "/uploads/media/engine-diagram.png", 48213, "The engine, from the side"),
          attachment(902, "/uploads/media/engine.mp4", 11142)]),
    post("grace", 311, "2026-10-30T21:05:00",
         "A ship in port is safe, but that's not what ships are built for. Sail out to sea and do "
         "new things. It's easier to ask forgiveness than it is to get permission, and the most "
         "dangerous phrase in the language is: we've always done it this way. Nanoseconds are "
         "about a foot of wire.", None, (12, 8, 64, 900)),
    post("alan@peer.example", 310, "2026-10-30T19:30:00",
         "Lecture on computable numbers, part one.", None, (2, 0, 7, 120),
         [attachment(903, "/uploads/media/lecture.ogg", 4680, "Lecture, part one")]),
    post("charles", 309, "2026-10-30T18:00:00", "", None, (0, 0, 1, 15),
         repost=post("ada", 107, "2026-10-30T09:15:00",
                     "Finished the notes on Menabrea's paper. Note G is the long one.", None,
                     (2, 1, 5, 40))),
    post("grace", 308, "2026-10-30T15:45:00",
         "<p>Found a <em>moth</em> in relay 70.</p><p>First actual case of bug being found.</p>",
         None, (9, 4, 33, 410),
         [attachment(904, "/uploads/media/moth.png", 30120, "The moth, taped into the log book")]),
    post("charles", 307, "2026-10-30T12:00:00", "Plans for the Analytical Engine, all of them.",
         None, (0, 0, 2, 40), price="5"),
    post("alan@peer.example", 306, "2026-10-29T20:00:00", "Can machines think?", None,
         (40, 12, 88, 2000)),
    post("grace", 305, "2026-10-29T16:20:00", "Notes from the COBOL meeting, and the log.", None,
         (1, 0, 4, 60),
         [attachment(905, "/uploads/media/cobol-notes.pdf", 2048),
          attachment(906, "/uploads/media/relay-70.png", 31000),
          attachment(907, "/uploads/media/log-book.png", 29000)]),
    post("charles", 304, "2026-10-29T10:00:00", "Notes on the mill.", None, (0, 0, 1, 9)),
    post("grace", 303, "2026-10-28T09:00:00", "Nanoseconds, in wire.", None, (0, 0, 2, 14)),
    post("alan@peer.example", 302, "2026-10-27T11:00:00", "On morphogenesis.", None, (0, 0, 3, 22)),
    post("charles", 301, "2026-10-26T08:30:00", "The engine needs more brass.", None, (0, 0, 0, 5)),
    post("grace", 300, "2026-10-25T07:15:00", "Good morning, TX.WTF.", None, (1, 0, 2, 30)),
]
FOLLOWS = {"ada": {"charles", "grace", "alan@peer.example"}}
# In the public feed only: someone ada doesn't follow.
PUBLIC_ONLY = [post("linus", 313, "2026-10-30T23:00:00", "Hello from someone you don't follow.",
                    None, (0, 0, 1, 3))]
# A post's reactions, by emoji name, as GET /social/posts/{id} sums them (dislikes left out).
REACTIONS = {312: [{"emoji": "thumbsup", "count": 12}, {"emoji": "heart", "count": 9}],
             308: [{"emoji": "bug", "count": 30}, {"emoji": "laughing", "count": 3}]}


def post_response(p):
    replies, reposts, reactions, views = p["counts"]
    locked = p["price"] is not None
    a = brief(p["author"])
    r = p["repost"]
    return {  # PostResponse: the fields a client reads, and the required ones
        "id": p["id"],
        "user_id": a["id"],
        # txwtf withholds a locked post's content and attachments (_redact_locked_post)
        "content": f"\U0001f512 This post is locked. Pay {p['price']} scrip to unlock." if locked
        else p["content"],
        "content_html": None,
        "visibility": "public",
        "reply_to_id": p["reply_to"],
        "repost_id": r["id"] if r else None,
        "thread_root_id": p["reply_to"],
        "reply_count": replies,
        "repost_count": reposts,
        "reaction_count": reactions,
        "view_count": views,
        "created_at": p["created"],
        "updated_at": None,
        "tip_count": 0,
        "tip_total_scrip": None,
        "show_tip_total": False,
        "is_paid_content": locked,
        "price_scrip": p["price"],
        "is_locked": locked,
        "unlock_count": 0,
        "revenue_scrip": None,
        "expires_at": None,
        "time_remaining_seconds": None,
        "is_ephemeral": False,
        "is_promoted": False,
        "promoted_until": None,
        "promotion_tier": None,
        "author": a,
        "reactions_summary": None,  # the timeline leaves it out
        "attachments": [] if locked else p["attachments"],
        # txwtf's reposted-post brief (asoc:992): created_at an ISO string, author the same brief
        "reposted_post": {
            "id": r["id"], "user_id": brief(r["author"])["id"], "content": r["content"],
            "content_html": None, "created_at": r["created"], "author": brief(r["author"]),
            "attachments": r["attachments"], "reaction_count": r["counts"][2],
            "reply_count": r["counts"][0], "repost_count": r["counts"][1], "link_previews": None,
            "is_paid_content": False, "is_locked": False, "price_scrip": None,
        } if r else None,
        "link_previews": None,
    }


def page_of(posts, has_more):
    return {
        "posts": [post_response(p) for p in posts],
        "has_more": has_more,
        "next_before_id": posts[-1]["id"] if posts else None,
        "total": None,
        "feed_mode": None,
        "tag": None,
        "pinned_post": None,
    }


def user_timeline(user_id, query):
    """GET /social/timeline/user/{id}: offset paging, as the web app pages a profile's posts."""
    username = next((n for n, u in USERS.items() if u["id"] == user_id), None)
    posts = POSTS.get(username, [])
    if query.get("include_replies", ["true"])[0] == "false":
        posts = [p for p in posts if p["reply_to"] is None]
    limit = min(int(query.get("limit", ["20"])[0]), 100)
    offset = int(query.get("offset", ["0"])[0])
    return page_of(posts[offset:offset + limit], offset + limit < len(posts))


def feed(username, which, query):
    """GET /social/timeline/home and /public: before_id paging (no offset), replies left out."""
    if which == "home":
        posts = [p for p in FEED if p["author"] in FOLLOWS.get(username, set())]
    else:
        posts = sorted(FEED + PUBLIC_ONLY + [p for p in POSTS["ada"] if p["reply_to"] is None],
                       key=lambda p: p["id"], reverse=True)
    before = query.get("before_id", [None])[0]
    if before is not None:
        posts = [p for p in posts if p["id"] < int(before)]
    limit = min(int(query.get("limit", ["50"])[0]), 100)
    return page_of(posts[:limit], len(posts) > limit)


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
        u[k] for u in list(USERS.values()) + list(AUTHORS.values())
        for k in ("avatar_url", "header_image_url", "card_image_url") if u.get(k)
    } | {f for f, (mime, _) in FILES.items() if mime == "image/png"}
    if path not in known:
        return None
    if "header" in path:
        return png(300, 100, lambda x, y: (40 + x * 180 // 300, 90 + y, 160 - x * 60 // 300))
    if "card" in path:
        return png(240, 120, lambda x, y: (20 + x // 8, 24 + y // 8, 48))
    if "/media/" in path:  # a post's picture: 4:3, stripes in a colour of its own
        tint = [(200, 90, 60), (60, 140, 200), (90, 170, 90), (180, 160, 60)][sum(path.encode()) % 4]
        return png(160, 120, lambda x, y: tint if (x // 16 + y // 16) % 2 else (230, 225, 210))
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
                mime, source = FILES.get(path, ("image/png", None))
                if isinstance(source, str):  # a recording in tests/fixtures
                    with open(os.path.join(FIXTURES, source), "rb") as f:
                        data = f.read()
                else:
                    data = source if source is not None else picture(path)
                if data is None:
                    return self.reply(404, {"detail": "Not Found"}), None
                return self.reply_bytes(200, data, mime), None
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
            if method == "GET" and path in ("/social/timeline/home", "/social/timeline/public"):
                return self.reply(200, feed(user, path.rsplit("/", 1)[1], query)), user
            if method == "GET" and path.startswith("/social/posts/"):
                found = [p for p in FEED + POSTS["ada"] if str(p["id"]) == path.rsplit("/", 1)[1]]
                if not found:
                    return self.reply(404, {"detail": "Post not found"}), user
                body = post_response(found[0])
                # GET /social/posts/{id} fills in the reactions the timeline leaves out
                body["reactions_summary"] = REACTIONS.get(found[0]["id"], [])
                return self.reply(200, body), user
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
