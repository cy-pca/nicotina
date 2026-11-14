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
                             for and withheld, one has a custom and a standard emoji (its
                             content_html renders them as txwtf does)
  GET  /social/posts/{id}    Bearer -> PostResponse, with its reactions_summary
  POST/DELETE /social/posts/{id}/dislike  Bearer -> {message, post_id, disliked}: a private
                             thumbs-down, which clears the user's like (and a like clears it)
  DELETE /social/posts/{id}  Bearer: the author's own post, or for an administrator anyone's
                             (as txwtf does from atx-crypto-club/txwtf#324); else 403
                             "... (PostAccessDenied)"
  GET/PUT /social/settings/read-level  Bearer, {read_level} -> {read_level, ...}: the user's
                             content filter (default -3, clamped to -100..100). The timelines
                             leave out posts scored (likes less dislikes) below it, but never
                             the user's own
  GET  /user/by-username/{name}
                             Bearer -> {id, username, name, avatar_url}: who a mention names
  POST /social/posts         Bearer, PostCreate -> PostResponse: a post, a reply or a repost;
                             attachment_ids attaches files the user uploaded
  POST /social/files         Bearer, multipart/form-data with the file in part "file"
                             -> FileUploadResponse
  POST /social/files/resumable  Bearer, {filename, total_size, mime_type} -> {upload_id,
                             offset, chunk_size, total_size}: a resumable upload, as txwtf's
  PATCH /social/files/resumable/{id}  Bearer, Upload-Offset: N, the chunk as the body ->
                             {upload_id, offset, total_size}; 409 with the server's own
                             Upload-Offset when N is not where the upload is
  GET  /social/files/resumable/{id}   Bearer -> {upload_id, offset, total_size}
  POST /social/files/resumable/{id}/complete  Bearer -> FileUploadResponse (409 if short)
  GET  /social/emojis/12/image
                             no auth: the custom emoji :gear:'s picture
  GET  /site/title, /site/description, ... (public); the admin routes (users, groups, invite
                             codes, site settings, the system log) are in tests/stub_admin.py
  GET  /uploads/..., /static/img/...
                             no auth (as txwtf's /uploads mount): a small PNG drawn here, the
                             same picture for the same path, or a recording from
                             tests/fixtures (engine.mp4, lecture.ogg), or a file uploaded
                             here (/uploads/attached/{id}/{name}); 404 for a path nothing
                             names

Direct messages (ConversationResponse, DMResponse), and the end-to-end encrypted ones as
txwtf/api/e2ee.py keeps them: opaque ciphertext and per-recipient wrapped keys, never a key
it could open them with:

  GET  /social/dm/conversations            Bearer -> the user's conversations, latest first
  POST /social/dm/conversations?other_user_id=N
                                           -> the 1:1 conversation with N, made if need be
  GET  /social/dm/conversations/{id}/messages?limit=&before_id=
                                           -> DMResponse list, newest first ([] once encrypted)
  POST /social/dm/conversations/{id}/messages {content}  -> DMResponse (409 once encrypted)
  POST /social/dm/conversations/{id}/read  -> {"message": ...}
  POST /e2ee/keys, POST /e2ee/keys/one-time, GET /e2ee/keys/me, GET /e2ee/keys/{username}
                                           the key directory (a bundle consumes a one-time key)
  PUT, GET, DELETE /e2ee/backup            the passphrase-wrapped backup, opaque
  POST /e2ee/dm/conversations/{id}/encrypt, POST and GET /e2ee/dm/conversations/{id}/messages

ada's conversations: 900 with grace (plaintext, three messages), 901 with charles (encrypted on
a device that isn't here: ciphertext with no envelope for ada), 902 with mary (encrypted, empty:
a peer script, tests/e2ee_peer.js, writes in it).

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

  eve, ivy
         the emailed second factor too (codes 654321 and 765432): the accounts the admin tests
         disable, enable and turn two-step sign-in off for, one for each terminal backend (no
         API turns the second factor back on)

ada is the instance's administrator (is_admin): the admin routes answer her alone.

The instance may sit below a path (--instance http://host:port/txwtf): a route matches from
the first of its known top-level segments (/user/, /billing/, /social/, /uploads/, /static/).

Without an Authorization header a request gets 401 {"detail": "Not
authenticated"}, and with a token the server doesn't know (expired, signed out,
forged) 401 {"detail": "Invalid token (InvalidTokenSignature)"}: what tx.wtf
answers.

The tokens are fixed so a test can look for them in output: no output of the
client may ever contain one. The server itself never prints a token or a
password. Its log (--log FILE) is one JSON object a line, with the method,
path, status and whether the request carried a valid bearer token; an upload's
file, once whole, gets a line of its own with its name, size and sha256.

  python3 stub_txwtf.py --port 0 --port-file PORTFILE --log LOG
"""

import argparse
import html
import hashlib
import json
import os
import re
import struct
import sys
import threading
import time
import uuid
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # python -I leaves it out
import stub_admin  # noqa: E402

PASSWORD = "correct horse"
TOP_LEVEL = ("/user/", "/billing/", "/social/", "/uploads/", "/static/", "/notifications",
             "/search/", "/site/", "/group/", "/invite/", "/logs/", "/perms/", "/e2ee/")
TWO_FACTOR_CODE = "123456"
CHALLENGE = "Q9mUj4Z1x0bR7nVt2LcYw8sDp3HkGfA5"
# Each account with the second factor: its challenge and its emailed code.
CHALLENGES = {"grace": (CHALLENGE, TWO_FACTOR_CODE),
              "eve": ("Ev7nTq2LmW9xKc4RbY1sZd8HgJ3pFa6U", "654321"),
              "ivy": ("Iv4wPn8QaT2mZr6YcB9kLd3HsX7gFj1E", "765432")}

# JWT-shaped, as txwtf's are. Tests import these to scan output for them.
TOKENS = {
    "ada": "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjoxLCJ1dWlkIjoiYWRhIn0.c3R1Yi1zaWctYWRhLW5pY290aW5h",
    "grace": "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjoyLCJ1dWlkIjoiZ3JhY2UifQ.c3R1Yi1zaWctZ3JhY2Utbmljbw",
    "linus": "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjozLCJ1dWlkIjoibGludXMifQ.c3R1Yi1zaWctbGludXMtbmljbw",
    "mary": "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjo0LCJ1dWlkIjoibWFyeSJ9.c3R1Yi1zaWctbWFyeS1uaWNvdGluYQ",
    "bob@peer.example": "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjo1LCJ1dWlkIjoiYm9iIn0.c3R1Yi1zaWctYm9iLXBlZXItZXhhbXA",
    "slowpoke": "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjo2LCJ1dWlkIjoic2xvdyJ9.c3R1Yi1zaWctc2xvd3Bva2UtbmljbwA",
    "eve": "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjo5LCJ1dWlkIjoiZXZlIn0.c3R1Yi1zaWctZXZlLW5pY290aW5hLWFk",
    "ivy": "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjoxMCwidXVpZCI6Iml2eSJ9.c3R1Yi1zaWctaXZ5LW5pY290aW5hLWFk",
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
        "profile_bg_url": "/uploads/u1/bg-5d2e.png",
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
    "eve": {
        "id": 9,
        "name": "Eve Example",
        "email": "eve@example.org",
        "description": None,
        "post_count": 0,
        "created_time": "2026-04-01T08:00:00",
        "login_2fa_email_enabled": True,
        "force_password_change": False,
        "balance": "0E-10",
        "runway_days": None,
        "cents": 0,
        "groups": ["users"],
    },
    "ivy": {
        "id": 10,
        "name": "Ivy Lane",
        "email": "ivy@example.org",
        "description": None,
        "post_count": 0,
        "created_time": "2026-04-02T08:00:00",
        "login_2fa_email_enabled": True,
        "force_password_change": False,
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
         repost=None, price=None, content_html=None):
    """A post: counts are replies, reposts, reactions and views. Content is what txwtf stores:
    plain text, or the rich editor's HTML. repost is the reposted post; price makes it a paid
    post this viewer hasn't unlocked, which txwtf withholds. content_html is what txwtf renders
    (render_content_html): given here for emoji shortcodes, else rendered from the content as
    the post is answered."""
    return {"author": author, "id": pid, "created": created, "content": content,
            "reply_to": reply_to, "counts": counts, "attachments": list(attachments),
            "repost": repost, "price": price, "content_html": content_html}


# txwtf's rendered emoji (social.py render_emoji_html): an image-backed custom emoji is served by
# GET /social/emojis/{id}/image, public; a standard one is its unicode character.
def custom_emoji_html(name, emoji_id):
    return (f'<img class="custom-emoji" src="/social/emojis/{emoji_id}/image" alt=":{name}:" '
            f'title=":{name}:" draggable="false">')


def unicode_emoji_html(name, char):
    return f'<span class="emoji" title=":{name}:">{char}</span>'


# txwtf's links in a post's text (social.py render_content_html, links.py URL_PATTERN): a mention
# links /user/NAME, a hashtag /tag/NAME, a URL itself; the text is escaped first. Plain text's
# newlines become <br>; in the rich editor's HTML only the text between tags is linked, and not
# inside an <a>, <pre> or <code>.
MENTION = re.compile(r"@(\w+)", re.UNICODE)
HASHTAG = re.compile(r"(?<!&)#(\w+(?:-\w+)*)", re.UNICODE)
URL = re.compile(r"https?://(?:(?:[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?\.)+[A-Z]{2,63}\.?|localhost|"
                 r"\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?::\d+)?(?:/[^\s]*)?", re.IGNORECASE)


def link_text(escaped):
    escaped = MENTION.sub(r'<a href="/user/\1" class="mention">@\1</a>', escaped)
    escaped = HASHTAG.sub(r'<a href="/tag/\1" class="hashtag">#\1</a>', escaped)
    return URL.sub(lambda m: f'<a href="{m.group(0)}" target="_blank" rel="noopener noreferrer" '
                             f'class="post-link" data-original-url="{m.group(0)}">{m.group(0)}</a>',
                   escaped)


def render_content_html(content):
    if not content:
        return ""
    if not re.search(r"<[a-zA-Z][^>]*>", content):
        return link_text(html.escape(content)).replace("\n", "<br>")
    out, skip = [], 0
    for piece in re.split(r"(<[^>]*>)", content):
        if piece.startswith("<"):
            name = piece[1:].split()[0].strip("/>").lower() if len(piece) > 2 else ""
            if name in ("a", "pre", "code"):
                skip += -1 if piece.startswith("</") else 1
            out.append(piece)
        else:
            out.append(piece if skip > 0 else link_text(piece))
    return "".join(out)


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
    post("charles", 312, "2026-10-30T22:40:00",
         "The Difference Engine No. 2, working at last. #engines #brass",
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
    # A mention and a URL (rendered as links in its content_html): a profile here, and a link
    # nicotina copies rather than open.
    post("alan@peer.example", 306, "2026-10-29T20:00:00",
         "Can machines think? Ask @ada, or read https://example.org/computing-machinery", None,
         (40, 12, 88, 2000)),
    post("grace", 305, "2026-10-29T16:20:00", "Notes from the COBOL meeting, and the log.", None,
         (1, 0, 4, 60),
         [attachment(905, "/uploads/media/cobol-notes.pdf", 2048),
          attachment(906, "/uploads/media/relay-70.png", 31000),
          attachment(907, "/uploads/media/log-book.png", 29000)]),
    # Emoji: a custom one (a picture) and a standard one (a character), as txwtf renders them,
    # beside a time whose :50: is no shortcode.
    post("charles", 304, "2026-10-29T10:00:00", "Notes on the mill :gear: :100: at 14:50:47.",
         None, (0, 0, 1, 9),
         content_html="<p>Notes on the mill " + custom_emoji_html("gear", 12) + " "
         + unicode_emoji_html("100", "💯") + " at 14:50:47.</p>"),
    post("grace", 303, "2026-10-28T09:00:00", "Nanoseconds, in wire. #engines", None, (0, 0, 2, 14)),
    post("alan@peer.example", 302, "2026-10-27T11:00:00", "On morphogenesis.", None, (0, 0, 3, 22)),
    post("charles", 301, "2026-10-26T08:30:00", "The engine needs more #brass.", None, (0, 0, 0, 5)),
    post("grace", 300, "2026-10-25T07:15:00", "Good morning, TX.WTF.", None, (1, 0, 2, 30)),
]
FOLLOWS = {"ada": {"charles", "grace", "alan@peer.example"}}
# In the public feed only: someone ada doesn't follow.
PUBLIC_ONLY = [post("linus", 313, "2026-10-30T23:00:00", "Hello from someone you don't follow.",
                    None, (0, 0, 1, 3))]
# A post's dislikes before anyone here dislikes it (Post.dislike_count). Its score is its likes
# (Post.like_count: the hearts alone) less these; each user's timelines leave out the posts
# scored below their read level (txwtf's _read_level_condition). 301 scores -2: shown at the
# default -3, gone at -1.
DISLIKES = {301: 2}
DEFAULT_READ_LEVEL = -3
# Replies, oldest first, as GET /social/posts/{id}/replies lists them (never in a feed).
REPLIES = [
    post("grace", 314, "2026-10-30T22:50:00", "Splendid. How many digits?", 312, (1, 0, 2, 20)),
    post("ada", 315, "2026-10-30T23:05:00", "Thirty-one, and seven orders of differences.", 314,
         (0, 0, 3, 18)),
    post("alan@peer.example", 316, "2026-10-30T23:10:00", "A fine machine. #engines", 312,
         (0, 0, 1, 9)),
]
# Notifications for ada, newest first (NotificationResponse); two not yet viewed.
NOTIFICATIONS = [
    {"id": 503, "notification_type": "reply", "message": "Grace Hopper replied to your post",
     "related_id": 314, "related_type": "post", "created_at": "2026-10-30T22:50:00", "viewed": False},
    {"id": 502, "notification_type": "reaction", "message": "Charles Babbage liked your post",
     "related_id": 107, "related_type": "post", "created_at": "2026-10-30T20:00:00", "viewed": False},
    {"id": 501, "notification_type": "follow", "message": "Alan Turing followed you",
     "related_id": 8, "related_type": "user", "created_at": "2026-10-29T09:00:00", "viewed": True},
]
# A post's reactions, by emoji name, as GET /social/posts/{id} sums them (dislikes left out).
REACTIONS = {312: [{"emoji": "thumbsup", "count": 12}, {"emoji": "heart", "count": 9}],
             308: [{"emoji": "bug", "count": 30}, {"emoji": "laughing", "count": 3}]}


# ada's direct messages, oldest first (DirectMessage), by conversation.
CONVERSATIONS = [
    {"id": 900, "a": "ada", "b": "grace", "encrypted": False, "created_at": "2026-10-20T10:00:00",
     "messages": [
         ("grace", "2026-10-31T08:58:00", "Ada, did you see Charles's engine post?"),
         ("ada", "2026-10-31T09:02:00", "I did. The carry mechanism is lovely."),
         ("grace", "2026-10-31T09:10:00", "Lunch on Thursday? I'll bring the compiler notes, "
                                          "all three binders of them, and the bugs we found."),
     ]},
    {"id": 901, "a": "ada", "b": "charles", "encrypted": True, "created_at": "2026-10-22T10:00:00",
     "messages": []},
    {"id": 902, "a": "ada", "b": "mary", "encrypted": True, "created_at": "2026-10-25T10:00:00",
     "messages": []},
]
# 901's encrypted messages, sealed on charles's and ada's other devices: opaque here, and with no
# X3DH envelope a device without that session could start from.
SEALED_ELSEWHERE = [
    {"id": 7001, "sender": "charles", "at": "2026-10-29T12:00:00",
     "ciphertext": "c3RhbmQtaW4gY2lwaGVydGV4dCwgbm90IGEgcmVhbCBvbmU=",
     "wrapped_key": "c3RhbmQtaW4gd3JhcHBlZCBrZXk=",
     "header": "eyJkaCI6IkFBRUNBd1FGQmdjSUNRb0xEQTBPRHhBUkVoTVVGUllYR0JrYUd4d2RIaDg9IiwicG4iOjAsIm4iOjB9"},
    {"id": 7002, "sender": "ada", "at": "2026-10-29T12:05:00",
     "ciphertext": "YW5vdGhlciBzdGFuZC1pbg==", "wrapped_key": None, "header": None},
]


# What the people signed in have done since the stub started: their likes, follows and posts.
# main() makes it; post_response reads it for the viewer's own fields.
LIVE = None
# The admin side (tests/stub_admin.py): accounts disabled, admins, groups, invite codes, the
# site's settings, the system log. main() makes it.
ADMIN = None


def all_posts():
    """Every post the stub knows, the ones made here first; deleted ones left out."""
    made = LIVE.made if LIVE else []
    gone = LIVE.deleted if LIVE else set()
    return [p for p in made + FEED + PUBLIC_ONLY + POSTS["ada"] + REPLIES if p["id"] not in gone]


def like_count(p):
    """Post.like_count: a post's hearts (REACTIONS's, else every reaction taken for one), and
    the ones given here."""
    base = next((r["count"] for r in REACTIONS.get(p["id"], []) if r["emoji"] == "heart"), None)
    if base is None:
        base = p["counts"][2]
    return base + sum(1 for (_, pid) in (LIVE.likes if LIVE else set()) if pid == p["id"])


def dislike_count(p):
    return DISLIKES.get(p["id"], 0) + sum(1 for (_, pid) in (LIVE.dislikes if LIVE else set())
                                          if pid == p["id"])


def read_level(username):
    return LIVE.read_level.get(username, DEFAULT_READ_LEVEL) if LIVE and username \
        else DEFAULT_READ_LEVEL


def readable(posts, viewer):
    """The posts a viewer's read level lets through: scored at it or above, or their own."""
    level = read_level(viewer)
    return [p for p in posts if like_count(p) - dislike_count(p) >= level or p["author"] == viewer]


def post_response(p, viewer=None):
    replies, reposts, reactions, views = p["counts"]
    replies += sum(1 for q in (LIVE.made if LIVE else []) if q["reply_to"] == p["id"])
    liked = bool(LIVE and viewer and (viewer, p["id"]) in LIVE.likes)
    reactions += sum(1 for (_, pid) in (LIVE.likes if LIVE else set()) if pid == p["id"])
    reposted = bool(LIVE and viewer and any(q["repost"] is p and q["author"] == viewer
                                            for q in LIVE.made))
    locked = p["price"] is not None
    disliked = bool(LIVE and viewer and (viewer, p["id"]) in LIVE.dislikes)
    # only its author is told how many dislike it, and its score
    by_viewer = viewer is not None and viewer == p["author"]
    a = brief(p["author"])
    r = p["repost"]
    return {  # PostResponse: the fields a client reads, and the required ones
        "id": p["id"],
        "user_id": a["id"],
        # txwtf withholds a locked post's content and attachments (_redact_locked_post)
        "content": f"\U0001f512 This post is locked. Pay {p['price']} scrip to unlock." if locked
        else p["content"],
        "content_html": None if locked else (p["content_html"] if p["content_html"] is not None
                                             else render_content_html(p["content"])),
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
        "user_has_reacted": liked,
        "user_has_disliked": disliked,
        "dislike_count": dislike_count(p) if by_viewer else None,
        "score": like_count(p) - dislike_count(p) if by_viewer else None,
        "user_has_reposted": reposted,
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


def page_of(posts, has_more, viewer=None):
    return {
        "posts": [post_response(p, viewer) for p in posts],
        "has_more": has_more,
        "next_before_id": posts[-1]["id"] if posts else None,
        "total": None,
        "feed_mode": None,
        "tag": None,
        "pinned_post": None,
    }


def user_timeline(user_id, query, viewer=None):
    """GET /social/timeline/user/{id}: offset paging, as the web app pages a profile's posts."""
    username = next((n for n, u in list(USERS.items()) + list(AUTHORS.items())
                     if u["id"] == user_id), None)
    posts = readable([p for p in all_posts() if p["author"] == username], viewer)
    if query.get("include_replies", ["true"])[0] == "false":
        posts = [p for p in posts if p["reply_to"] is None]
    limit = min(int(query.get("limit", ["20"])[0]), 100)
    offset = int(query.get("offset", ["0"])[0])
    return page_of(posts[offset:offset + limit], offset + limit < len(posts), viewer)


def tag_feed(tag, query, viewer):
    """GET /social/timeline/tag/{tag}: the posts naming #tag, newest first, offset paging."""
    want = "#" + tag.lower()
    posts = sorted((p for p in readable(all_posts(), viewer)
                    if any(w.strip(".,;:!?").lower() == want for w in p["content"].split())),
                   key=lambda p: p["id"], reverse=True)
    limit = min(int(query.get("limit", ["20"])[0]), 100)
    offset = int(query.get("offset", ["0"])[0])
    page = page_of(posts[offset:offset + limit], offset + limit < len(posts), viewer)
    page["tag"] = tag
    return page


def tag_list(query):
    """GET /social/tags: every hashtag the posts name, with its count (TagResponse)."""
    counts = {}
    for p in all_posts():
        for w in p["content"].split():
            w = w.strip(".,;:!?")
            if w.startswith("#") and len(w) > 1:
                counts[w[1:].lower()] = counts.get(w[1:].lower(), 0) + 1
    tags = [{"id": i + 1, "name": n, "slug": n, "description": None, "owner_user_id": None,
             "owner_username": None, "owner_group_id": None, "owner_group_name": None,
             "pinned_post_id": None, "post_count": c, "created_at": "2026-10-01T00:00:00"}
            for i, (n, c) in enumerate(sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])))]
    limit = min(int(query.get("limit", ["50"])[0]), 100)
    offset = int(query.get("offset", ["0"])[0])
    return {"tags": tags[offset:offset + limit], "total": len(tags), "limit": limit,
            "offset": offset}


def replies_of(pid, query, viewer):
    """GET /social/posts/{id}/replies: the direct replies, oldest first."""
    rs = sorted((p for p in all_posts() if p["reply_to"] == pid), key=lambda p: p["id"])
    limit = min(int(query.get("limit", ["20"])[0]), 100)
    offset = int(query.get("offset", ["0"])[0])
    return {"replies": [post_response(p, viewer) for p in rs[offset:offset + limit]],
            "has_more": offset + limit < len(rs)}


def search(q, viewer):
    """GET /search/search?q=: posts, people and hashtags whose text or name has q, grouped as
    txwtf groups them (results.<category> = {items, total}; an item's author is a brief)."""
    q = q.lower()
    users, posts, tags = [], [], []
    for n, u in list(USERS.items()) + list(AUTHORS.items()):
        if q in n.lower() or q in u["name"].lower():
            users.append({"type": "user", "id": u["id"], "title": u["name"], "snippet": "@" + n,
                          "avatar_url": u.get("avatar_url", DEFAULT_AVATAR),
                          "url": f"/app/profile/{u['id']}", "author": None})
    for p in sorted(all_posts(), key=lambda p: p["id"], reverse=True):
        if p["price"] is None and q in p["content"].lower():
            posts.append({"type": "post", "id": p["id"], "title": None,
                          "snippet": p["content"][:140], "url": f"/app/post/{p['id']}",
                          "author": {"username": p["author"], "name": brief(p["author"])["name"]}})
    for t in tag_list({})["tags"]:
        if q in t["name"]:
            tags.append({"type": "hashtag", "id": t["id"], "title": "#" + t["name"],
                         "snippet": f"{t['post_count']} posts", "url": f"/app/tag/{t['name']}"})
    def bucket(items):
        return {"items": items[:10], "total": len(items)}
    return {"query": q, "results": {"posts": bucket(posts), "users": bucket(users),
                                    "hashtags": bucket(tags)}, "federated": {"items": []}}


def feed(username, which, query):
    """GET /social/timeline/home and /public: before_id paging (no offset), replies left out."""
    follows = LIVE.follows.get(username, set()) if LIVE else FOLLOWS.get(username, set())
    top = [p for p in all_posts() if p["reply_to"] is None]
    made = LIVE.made if LIVE else []
    if which == "home":  # the people followed, and what the user posted here
        posts = [p for p in top if (p["author"] in follows and (p in FEED or p in made))
                 or (p["author"] == username and p in made)]
    elif which == "friends":  # the people who follow back: ada and grace, here
        posts = [p for p in top if p["author"] == "grace" and username == "ada"]
    else:
        posts = top
    posts = sorted(readable(posts, username), key=lambda p: p["id"], reverse=True)
    before = query.get("before_id", [None])[0]
    if before is not None:
        posts = [p for p in posts if p["id"] < int(before)]
    limit = min(int(query.get("limit", ["50"])[0]), 100)
    return page_of(posts[:limit], len(posts) > limit, username)


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
        for k in ("avatar_url", "header_image_url", "card_image_url", "profile_bg_url") if u.get(k)
    } | {f for f, (mime, _) in FILES.items() if mime == "image/png"}
    if path not in known:
        return None
    if "header" in path:
        return png(300, 100, lambda x, y: (40 + x * 180 // 300, 90 + y, 160 - x * 60 // 300))
    if "card" in path:
        return png(240, 120, lambda x, y: (90 + x // 3, 50 + y, 150 - x // 4))
    if "/bg-" in path:  # a page background: soft diagonal bands
        return png(320, 180, lambda x, y: (30, 40 + ((x + y) // 20 % 2) * 20, 60))
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
        self.likes = set()  # (username, post id): a heart from that user
        self.dislikes = set()  # (username, post id): a thumbs-down; never with a heart
        self.read_level = {}  # username -> their content filter, where they set one
        self.follows = {u: set(f) for u, f in FOLLOWS.items()}
        self.made = []  # posts made here, newest first
        self.deleted = set()
        self.next_id = 400
        self.viewed = set()  # notification ids marked viewed
        self.files = {}  # file id -> an uploaded file (upload_record)
        self.next_file = 900
        self.resumable = {}  # upload id -> a resumable upload under way
        # Direct messages: conversations by id, each with its plaintext and its sealed messages.
        self.convs = {}
        for c in CONVERSATIONS:
            self.convs[c["id"]] = {
                "id": c["id"], "a": c["a"], "b": c["b"], "encrypted": c["encrypted"],
                "created_at": c["created_at"],
                "plain": [{"id": 80000 + 10 * c["id"] + i, "sender": m[0], "at": m[1],
                           "content": m[2]} for i, m in enumerate(c["messages"])],
                "sealed": [dict(m, envelope=None, algorithm="dr-v1",
                                keys={"ada": {"wrapped_key": m["wrapped_key"], "header": m["header"]}}
                                if m["wrapped_key"] else {})
                           for m in (SEALED_ELSEWHERE if c["id"] == 901 else [])],
            }
        self.next_conv = 950
        self.next_dm = 90000
        self.keys = {}     # username -> the published identity, signed prekey, one-time prekeys
        self.backups = {}  # username -> the backup blob, as given

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
    body = {
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
        "profile_bg_url": u.get("profile_bg_url"),
        "profile_bg_file_id": 14 if u.get("profile_bg_url") else None,
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
    return ADMIN.patch_profile(username, body) if ADMIN else body


def names_by_id():
    return {v["id"]: n for n, v in list(USERS.items()) + list(AUTHORS.items())}


def names_to_id(username):
    return (USERS.get(username) or AUTHORS[username])["id"]


def public_profile(user_id):
    """GET /user/profile/{id}: an account's profile, or an author's who has no account here."""
    for n, u in USERS.items():
        if u["id"] == user_id:
            return profile_response(n)
    for n, a in AUTHORS.items():
        if a["id"] == user_id:
            body = {"id": a["id"], "username": n, "name": a["name"],
                    "avatar_url": a.get("avatar_url", DEFAULT_AVATAR), "header_image_url": None,
                    "card_image_url": None, "profile_bg_url": None, "description": None,
                    "created_time": "2025-01-01T00:00:00", "last_login_country": a.get("country"),
                    "view_count": 10, "post_count": sum(1 for p in all_posts() if p["author"] == n),
                    "status": a.get("status", "offline"), "is_admin": False, "emblems": [],
                    "groups": [], "enabled": True}
            return ADMIN.patch_profile(n, body) if ADMIN else body
    return None


# Uploads: at most this big (txwtf's storage max_file_size is configurable; this keeps the
# stub's memory bounded), and the chunk size the resumable upload advertises, as txwtf's.
MAX_UPLOAD = 64 * 1024 * 1024
RESUMABLE_CHUNK = 8 * 1024 * 1024


def upload_record(user, name, mime, data, state):
    """Keep an uploaded file (state.lock held); its FileUploadResponse."""
    fid = state.next_file
    state.next_file += 1
    url = "/uploads/attached/%d/%s" % (fid, name)
    state.files[fid] = {"user": user, "name": name, "mime": mime, "data": bytes(data), "url": url}
    return {"id": fid, "original_name": name, "mime_type": mime, "file_size": len(data),
            "url": url, "downsampled": False, "original_size": None, "is_encrypted": False,
            "content_url": "/social/files/%d/content" % fid, "owner_id": USERS[user]["id"],
            "is_private": False}


def multipart_file(content_type, body, field):
    """The part named `field` of a multipart/form-data body: (filename, mime, bytes), or None."""
    _, _, boundary = content_type.partition("boundary=")
    boundary = boundary.strip().strip('"')
    if not boundary:
        return None
    for part in body.split(b"--" + boundary.encode()):
        head, sep, content = part.partition(b"\r\n\r\n")
        if not sep:
            continue
        headers = head.decode("utf-8", "replace")
        if 'name="%s"' % field not in headers or "filename=" not in headers:
            continue
        filename = headers.split('filename="', 1)[1].split('"', 1)[0]
        mime = "application/octet-stream"
        for line in headers.split("\r\n"):
            if line.lower().startswith("content-type:"):
                mime = line.split(":", 1)[1].strip()
        if content.endswith(b"\r\n"):
            content = content[:-2]
        return filename.replace("%22", '"'), mime, content
    return None


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
            if user and ADMIN and ADMIN.disabled(user):  # an admin disabled the account
                return None, f"Disabled user {user}({names_to_id(user)}) (DisabledUser)"
            return (user, None) if user else (None, "Invalid token (InvalidTokenSignature)")

        def profile_of(self, username):
            """GET /user/profile/{id}'s answer for an account (stub_admin's routes reply with it)."""
            return public_profile(names_to_id(username))

        def json_body(self):
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n) if n else b""
            try:
                body = json.loads(raw or b"{}")
            except ValueError:
                return None
            return body if isinstance(body, dict) else None

        def raw_body(self):
            n = int(self.headers.get("Content-Length") or 0)
            return self.rfile.read(n) if n else b""

        def uploaded(self, record):
            """The log's line for a file uploaded whole: its name, size and sha256."""
            state.log({"upload": record["name"], "size": len(record["data"]),
                       "sha256": hashlib.sha256(record["data"]).hexdigest()})

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
            if (method == "GET" and path.startswith("/social/emojis/")
                    and path.endswith("/image")):
                # an image-backed custom emoji, public as txwtf's (a gear: a ring on a square)
                if path != "/social/emojis/12/image":
                    return self.reply(404, {"detail": "Not Found"}), None
                gear = png(32, 32, lambda x, y: (120, 120, 130) if 64 <= (x - 16) ** 2 + (y - 16) ** 2
                           <= 196 else (250, 200, 60))
                return self.reply_bytes(200, gear, "image/png"), None
            if method == "GET" and path.startswith("/site/"):
                # the site's settings, public as txwtf's: the client's window is titled by
                # /site/title; the Admin view's Site section shows the rest
                value = ADMIN.site_value(path[len("/site/"):]) if ADMIN else None
                if value is None:
                    return self.reply(404, {"detail": "Not Found"}), None
                return self.reply(200, value), None
            if method == "GET" and (path.startswith("/uploads/") or path.startswith("/static/")):
                # no auth, as txwtf serves them
                with state.lock:
                    up = next((f for f in state.files.values() if f["url"] == path), None)
                if up:
                    return self.reply_bytes(200, up["data"], up["mime"]), None
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
            if ADMIN:
                done = ADMIN.handle(self, method, unquote(path), query, user)
                if done:
                    return done[0], user
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
            if method == "GET" and path == "/social/timeline/friends":
                return self.reply(200, feed(user, "friends", query)), user
            if method == "GET" and path.startswith("/social/timeline/tag/"):
                return self.reply(200, tag_feed(path.rsplit("/", 1)[1], query, user)), user
            if method == "GET" and path == "/social/tags":
                return self.reply(200, tag_list(query)), user
            if method == "GET" and path == "/search/search":
                return self.reply(200, search(query.get("q", [""])[0], user)), user
            if method == "GET" and path.startswith("/user/by-username/"):
                # who a mention names (txwtf's get_user_by_username: id, username, name, avatar)
                name = path.rsplit("/", 1)[1]
                u = USERS.get(name) or AUTHORS.get(name)
                if u is None:
                    return self.reply(404, {"detail": "User not found"}), user
                return self.reply(200, {"id": u["id"], "username": name, "name": u["name"],
                                        "avatar_url": u.get("avatar_url", DEFAULT_AVATAR)}), user
            if method == "GET" and path.startswith("/user/profile/"):
                tail = path.rsplit("/", 1)[1]
                found = public_profile(int(tail)) if tail.isdigit() else None
                if found is None:
                    return self.reply(404, {"detail": "User not found"}), user
                return self.reply(200, found), user
            if method == "GET" and path.startswith("/social/follow/check/"):
                uid = int(path.rsplit("/", 1)[1])
                with state.lock:
                    following = names_by_id().get(uid) in state.follows.get(user, set())
                return self.reply(200, {"is_following": following, "user_id": uid}), user
            if method == "POST" and path == "/social/follow":
                uid = (self.json_body() or {}).get("user_id")
                if uid not in names_by_id():
                    return self.reply(404, {"detail": "User not found"}), user
                with state.lock:
                    state.follows.setdefault(user, set()).add(names_by_id()[uid])
                return self.reply(200, {"message": "Followed", "following": True}), user
            if method == "DELETE" and path.startswith("/social/follow/"):
                uid = int(path.rsplit("/", 1)[1])
                with state.lock:
                    state.follows.setdefault(user, set()).discard(names_by_id().get(uid))
                return self.reply(200, {"message": "Unfollowed", "following": False}), user
            if method == "GET" and path == "/notifications/count":
                with state.lock:
                    n = sum(1 for x in NOTIFICATIONS
                            if not x["viewed"] and x["id"] not in state.viewed)
                return self.reply(200, {"unviewed_count": n if user == "ada" else 0}), user
            if method == "GET" and path.rstrip("/") == "/notifications":
                with state.lock:
                    items = [dict(x, user_id=1, viewed=x["viewed"] or x["id"] in state.viewed,
                                  extra_data=None, viewed_at=None, stale=False, gone_reason=None)
                             for x in NOTIFICATIONS] if user == "ada" else []
                return self.reply(200, {"notifications": items, "total_count": len(items),
                                        "unviewed_count": sum(1 for x in items if not x["viewed"]),
                                        "limit": 20, "offset": 0}), user
            if method == "POST" and path == "/notifications/viewed":
                with state.lock:
                    state.viewed |= {x["id"] for x in NOTIFICATIONS}
                return self.reply(200, {"message": "Marked viewed", "code": 0, "data": None}), user
            if path == "/social/settings/read-level" and method in ("GET", "PUT"):
                if method == "PUT":
                    body = self.json_body()
                    v = body.get("read_level") if isinstance(body, dict) else None
                    if not isinstance(v, int) or isinstance(v, bool):
                        return self.reply(422, {"detail": "read_level: an integer"}), user
                    with state.lock:
                        state.read_level[user] = max(-100, min(100, v))
                    return self.reply(200, {"read_level": read_level(user)}), user
                return self.reply(200, {"read_level": read_level(user), "min": -100, "max": 100,
                                        "default": DEFAULT_READ_LEVEL}), user
            if method == "POST" and path == "/social/posts":
                return self.create_post(user), user
            if path == "/social/files" or path.startswith("/social/files/resumable"):
                return self.files(method, path, user), user
            parts = path.split("/")  # ['', 'social', 'posts', ID, ...]
            if path.startswith("/social/posts/") and len(parts) >= 4 and parts[3].isdigit():
                pid = int(parts[3])
                target = next((p for p in all_posts() if p["id"] == pid), None)
                if target is None:
                    return self.reply(404, {"detail": "Post not found"}), user
                rest = "/".join(parts[4:])
                if method == "GET" and rest == "replies":
                    return self.reply(200, replies_of(pid, query, user)), user
                if method == "POST" and rest == "reactions":
                    with state.lock:
                        state.likes.add((user, pid))
                        state.dislikes.discard((user, pid))
                    return self.reply(200, {"message": "Reaction added", "emoji": "heart"}), user
                if method == "DELETE" and rest == "reactions":
                    with state.lock:
                        state.likes.discard((user, pid))
                    return self.reply(200, {"message": "Reaction removed"}), user
                if method in ("POST", "DELETE") and rest == "dislike":
                    with state.lock:
                        if method == "POST":
                            state.dislikes.add((user, pid))
                            state.likes.discard((user, pid))
                        else:
                            state.dislikes.discard((user, pid))
                    return self.reply(200, {"message": "Post disliked" if method == "POST"
                                            else "Dislike removed", "post_id": pid,
                                            "disliked": method == "POST"}), user
                if method == "DELETE" and rest == "":
                    if target["author"] != user and not (ADMIN and ADMIN.is_admin(user)):
                        return self.reply(403, {"detail": "Access denied to post %d "
                                                          "(PostAccessDenied)" % pid}), user
                    with state.lock:
                        state.deleted.add(pid)
                    return self.reply(200, {"message": "Post deleted"}), user
            if method == "GET" and path.startswith("/social/posts/"):
                found = [p for p in all_posts() if str(p["id"]) == path.rsplit("/", 1)[1]]
                if not found:
                    return self.reply(404, {"detail": "Post not found"}), user
                body = post_response(found[0], user)
                # GET /social/posts/{id} fills in the reactions the timeline leaves out
                body["reactions_summary"] = REACTIONS.get(found[0]["id"], [])
                return self.reply(200, body), user
            if method == "GET" and path.startswith("/social/timeline/user/"):
                try:
                    user_id = int(path.rsplit("/", 1)[1])
                except ValueError:
                    return self.reply(422, {"detail": "user_id must be an integer"}), user
                return self.reply(200, user_timeline(user_id, query, user)), user
            if method == "POST" and path == "/user/logout":
                token = self.headers["Authorization"].partition(" ")[2]
                with state.lock:
                    state.live.pop(token, None)
                return (
                    self.reply(200, {"message": "Successfully logged out", "code": 1, "data": None}),
                    user,
                )
            if path.startswith("/social/dm/") or path.startswith("/e2ee/"):
                return self.direct(method, path, query, user), user
            return self.reply(404, {"detail": "Not Found"}), user

        def files(self, method, path, user):
            """POST /social/files, and the resumable upload's endpoints (txwtf's social.py)."""
            if method == "POST" and path == "/social/files":
                body = self.raw_body()
                if len(body) > MAX_UPLOAD + 65536:
                    return self.reply(413, {"detail": "File too large. Max size: %d bytes" % MAX_UPLOAD})
                got = multipart_file(self.headers.get("Content-Type", ""), body, "file")
                if got is None:
                    return self.reply(422, {"detail": [{"loc": ["body", "file"],
                                                        "msg": "Field required", "type": "missing"}]})
                name, mime, data = got
                with state.lock:
                    made = upload_record(user, name, mime, data, state)
                    record = state.files[made["id"]]
                self.uploaded(record)
                return self.reply(200, made)
            if method == "POST" and path == "/social/files/resumable":
                body = self.json_body() or {}
                total = body.get("total_size")
                if not isinstance(total, int) or total <= 0:
                    return self.reply(400, {"detail": "total_size must be positive"})
                if total > MAX_UPLOAD:
                    return self.reply(413, {"detail": "File too large. Max size: %d bytes" % MAX_UPLOAD})
                upload_id = str(uuid.uuid4())
                with state.lock:
                    state.resumable[upload_id] = {
                        "user": user, "name": body.get("filename") or "upload",
                        "mime": body.get("mime_type") or "application/octet-stream",
                        "total": total, "data": bytearray()}
                return self.reply(200, {"upload_id": upload_id, "offset": 0,
                                        "chunk_size": RESUMABLE_CHUNK, "total_size": total})
            parts = path.split("/")  # ['', 'social', 'files', 'resumable', ID, ...]
            upload_id = parts[4] if len(parts) > 4 else ""
            with state.lock:
                up = state.resumable.get(upload_id)
            if up is None or up["user"] != user:
                self.raw_body()
                return self.reply(404, {"detail": "Upload session not found"})
            rest = "/".join(parts[5:])
            if method == "GET" and rest == "":
                return self.reply(200, {"upload_id": upload_id, "offset": len(up["data"]),
                                        "total_size": up["total"]})
            if method == "PATCH" and rest == "":
                chunk = self.raw_body()
                with state.lock:
                    have = len(up["data"])
                    if self.headers.get("Upload-Offset") != str(have):
                        mismatch = True
                    else:
                        mismatch = False
                        if not chunk:
                            return self.reply(400, {"detail": "Empty chunk"})
                        if have + len(chunk) > up["total"]:
                            return self.reply(413, {"detail": "Chunk exceeds declared total_size"})
                        up["data"].extend(chunk)
                        have = len(up["data"])
                if mismatch:
                    data = json.dumps({"detail": "Offset mismatch. Expected %d" % have}).encode()
                    self.send_response(409)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Upload-Offset", str(have))
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return 409
                return self.reply(200, {"upload_id": upload_id, "offset": have,
                                        "total_size": up["total"]})
            if method == "POST" and rest == "complete":
                self.raw_body()
                with state.lock:
                    if len(up["data"]) != up["total"]:
                        short = len(up["data"])
                    else:
                        short = None
                        state.resumable.pop(upload_id, None)
                        made = upload_record(user, up["name"], up["mime"], up["data"], state)
                        record = state.files[made["id"]]
                if short is not None:
                    return self.reply(409, {"detail": "Upload incomplete: %d/%d bytes received"
                                                      % (short, up["total"])})
                self.uploaded(record)
                return self.reply(200, made)
            return self.reply(404, {"detail": "Not Found"})

        # --- direct messages and the E2EE key directory -------------------------------------

        def conv_response(self, c, user):
            ids = {n: USERS.get(n, AUTHORS.get(n, {})).get("id") for n in (c["a"], c["b"])}
            msgs = [m["at"] for m in c["plain"]] + [m["at"] for m in c["sealed"]]
            return {"id": c["id"], "name": None, "is_group": False,
                    "participant_1_id": ids[c["a"]], "participant_2_id": ids[c["b"]],
                    "creator_id": ids[c["a"]], "last_message_at": max(msgs) if msgs else None,
                    "created_at": c["created_at"], "default_message_ttl": None,
                    "is_encrypted": c["encrypted"]}

        def dm_response(self, c, m):
            sid = USERS.get(m["sender"], AUTHORS.get(m["sender"], {})).get("id")
            return {"id": m["id"], "conversation_id": c["id"], "sender_id": sid,
                    "content": m["content"], "content_html": None, "created_at": m["at"],
                    "attachments": None, "is_paid_content": False, "price_scrip": None,
                    "is_locked": False, "unlock_count": 0, "reaction_count": 0, "reactions": None,
                    "is_system": False}

        def sealed_response(self, c, m, user):
            """As txwtf/core/e2ee_dm.py's _serialize_message gives it to `user`."""
            sid = USERS.get(m["sender"], AUTHORS.get(m["sender"], {})).get("id")
            mine = m["sender"] == user
            key = m["keys"].get(user)
            return {"id": m["id"], "conversation_id": c["id"], "sender_id": sid,
                    "algorithm": m["algorithm"], "envelope": m["envelope"],
                    "is_paid_content": False, "price_scrip": None, "unlock_count": 0,
                    "is_ephemeral": False, "expires_at": None, "reaction_count": 0,
                    "is_sender": mine, "locked": False, "created_at": m["at"],
                    "ciphertext": m["ciphertext"] if mine or key else None,
                    "wrapped_key": key["wrapped_key"] if key and not mine else None,
                    "header": key["header"] if key and not mine else None}

        def direct(self, method, path, query, user):
            parts = path.strip("/").split("/")
            body = self.json_body() if method in ("POST", "PUT") else {}
            if body is None:
                return self.reply(422, {"detail": "Invalid body"})
            with state.lock:
                # the key directory
                if parts[:2] == ["e2ee", "keys"]:
                    return self.key_directory(method, parts[2:], body, user)
                if parts == ["e2ee", "backup"]:
                    if method == "PUT":
                        state.backups[user] = body
                        return self.reply(200, {"stored": True})
                    if method == "DELETE":
                        return self.reply(200, {"deleted": state.backups.pop(user, None) is not None})
                    if user not in state.backups:
                        return self.reply(404, {"detail": "No key backup (E2EEBackupNotFound)"})
                    return self.reply(200, state.backups[user])
                # conversations
                if parts == ["social", "dm", "conversations"]:
                    if method == "GET":
                        mine = [c for c in state.convs.values() if user in (c["a"], c["b"])]
                        out = [self.conv_response(c, user) for c in mine]
                        out.sort(key=lambda c: c["last_message_at"] or c["created_at"], reverse=True)
                        return self.reply(200, out)
                    other = names_by_id().get(int((query.get("other_user_id") or ["0"])[0]))
                    if other is None:
                        return self.reply(404, {"detail": "User not found"})
                    for c in state.convs.values():
                        if {c["a"], c["b"]} == {user, other}:
                            return self.reply(200, self.conv_response(c, user))
                    c = {"id": state.next_conv, "a": user, "b": other, "encrypted": False,
                         "created_at": "2026-11-01T10:00:00", "plain": [], "sealed": []}
                    state.next_conv += 1
                    state.convs[c["id"]] = c
                    return self.reply(200, self.conv_response(c, user))
                cid = int(parts[3]) if len(parts) > 3 and parts[3].isdigit() else None
                c = state.convs.get(cid)
                if c is None or user not in (c["a"], c["b"]):
                    return self.reply(403 if c else 404, {"detail": "Conversation not found"})
                other = c["b"] if user == c["a"] else c["a"]
                rest = parts[4:]
                if parts[:2] == ["social", "dm"] and rest == ["messages"]:
                    if method == "GET":
                        if c["encrypted"]:
                            return self.reply(200, [])  # the legacy plaintext is hidden
                        limit = int((query.get("limit") or ["50"])[0])
                        return self.reply(200, [self.dm_response(c, m)
                                                for m in reversed(c["plain"])][:limit])
                    if c["encrypted"]:
                        return self.reply(409, {"detail": "Conversation is end-to-end encrypted "
                                                          "(E2EEConversationEncrypted)"})
                    content = body.get("content") or ""
                    if not content.strip() or len(content) > 4096:
                        return self.reply(422, {"detail": "content: 1 to 4096 characters"})
                    m = {"id": state.next_dm, "sender": user, "at": "2026-11-01T10:30:00",
                         "content": content}
                    state.next_dm += 1
                    c["plain"].append(m)
                    return self.reply(200, self.dm_response(c, m))
                if parts[:2] == ["social", "dm"] and rest == ["read"]:
                    return self.reply(200, {"message": "Marked read"})
                if parts[:2] == ["e2ee", "dm"] and rest == ["encrypt"]:
                    c["encrypted"] = True
                    return self.reply(200, {"conversation_id": c["id"], "is_encrypted": True})
                if parts[:2] == ["e2ee", "dm"] and rest == ["messages"]:
                    if method == "GET":
                        return self.reply(200, {"messages": [self.sealed_response(c, m, user)
                                                             for m in reversed(c["sealed"])]})
                    by = {}
                    for k in body.get("recipient_keys") or []:
                        r = k.get("recipient")
                        name = names_by_id().get(r) if isinstance(r, int) else r
                        by[name] = {"wrapped_key": k.get("wrapped_key"), "header": k.get("header")}
                    if set(by) != {other} or not body.get("ciphertext"):
                        return self.reply(400, {"detail": "recipient_keys must cover exactly the "
                                                          "other participants (E2EERecipientKeyMissing)"})
                    m = {"id": state.next_dm, "sender": user, "at": "2026-11-01T10:30:00",
                         "ciphertext": body["ciphertext"],
                         "algorithm": body.get("algorithm") or "dr-v1",
                         "envelope": body.get("envelope"), "keys": by}
                    state.next_dm += 1
                    c["sealed"].append(m)
                    c["encrypted"] = True
                    return self.reply(200, {"id": m["id"], "conversation_id": c["id"],
                                            "sender_id": USERS[user]["id"], "is_paid_content": False,
                                            "is_ephemeral": False, "created_at": m["at"]})
            return self.reply(404, {"detail": "Not Found"})

        def key_directory(self, method, rest, body, user):
            """POST /e2ee/keys[/one-time], GET /e2ee/keys/me, GET /e2ee/keys/{username}."""
            if method == "POST" and rest == []:
                old = state.keys.get(user)
                same = old and old["identity_key_ed25519"] == body.get("identity_key_ed25519")
                spk = body.get("signed_prekey") or {}
                if not (isinstance(spk, dict) and spk.get("public_key") and spk.get("signature")
                        and body.get("identity_key_ed25519") and body.get("identity_key_x25519")):
                    return self.reply(400, {"detail": "Invalid key material (E2EEInvalidKeyMaterial)"})
                # a new identity wipes the old one's prekeys, as txwtf's publish_identity does
                opks = (old["opks"] if same else []) + list(body.get("one_time_prekeys") or [])
                state.keys[user] = {"identity_key_ed25519": body["identity_key_ed25519"],
                                    "identity_key_x25519": body["identity_key_x25519"],
                                    "registration_id": body.get("registration_id") or 0,
                                    "signed_prekey": spk, "opks": opks}
                return self.reply(200, {"published": True, "available_one_time_prekeys": len(opks)})
            if method == "POST" and rest == ["one-time"]:
                k = state.keys.get(user)
                if not k:
                    return self.reply(404, {"detail": "No published keys (E2EEKeysNotFound)"})
                added = list(body.get("one_time_prekeys") or [])
                k["opks"] += added
                return self.reply(200, {"added": len(added),
                                        "available_one_time_prekeys": len(k["opks"])})
            if method == "GET" and len(rest) == 1:
                name = user if rest[0] == "me" else rest[0]
                if name not in USERS and name not in AUTHORS:
                    return self.reply(404, {"detail": "User not found"})
                k = state.keys.get(name)
                if not k:
                    return self.reply(404 if rest[0] == "me" else 409,
                                      {"detail": "No published keys (E2EEKeysNotFound)"})
                out = {"user_id": USERS.get(name, AUTHORS.get(name, {})).get("id"), "username": name,
                       "registration_id": k["registration_id"],
                       "identity_key_ed25519": k["identity_key_ed25519"],
                       "identity_key_x25519": k["identity_key_x25519"],
                       "signed_prekey": k["signed_prekey"]}
                if rest[0] != "me":  # a bundle for another user consumes one one-time prekey
                    out["one_time_prekey"] = k["opks"].pop(0) if k["opks"] else None
                out["available_one_time_prekeys"] = len(k["opks"])
                return self.reply(200, out)
            return self.reply(404, {"detail": "Not Found"})

        def create_post(self, user):
            """POST /social/posts (PostCreate): a post, a reply (reply_to_id) or a repost, with
            the files the user uploaded that attachment_ids names."""
            body = self.json_body()
            if body is None:
                return self.reply(422, {"detail": "Invalid body"})
            attached = []
            for fid in body.get("attachment_ids") or []:
                with state.lock:
                    f = state.files.get(fid) if isinstance(fid, int) else None
                if f is None or f["user"] != user:
                    return self.reply(404, {"detail": "Attachment %s not found" % fid})
                attached.append({"id": fid, "filename": f["name"], "mime_type": f["mime"],
                                 "file_size": len(f["data"]), "url": f["url"],
                                 "preview_url": None, "display_order": len(attached),
                                 "alt_text": None, "description": None, "deleted": False})
            content = body.get("content") or ""
            if len(content) > 4096:
                return self.reply(422, {"detail": "content: at most 4096 characters"})
            repost = None
            if body.get("repost_id") is not None:
                repost = next((p for p in all_posts() if p["id"] == body["repost_id"]), None)
                if repost is None:
                    return self.reply(404, {"detail": "Post not found"})
            elif not content.strip() and not attached:
                return self.reply(400, {"detail": "A post needs content or attachments"})
            with state.lock:
                pid = state.next_id
                state.next_id += 1
                made = post(user, pid, "2026-10-31T09:00:00", content, body.get("reply_to_id"),
                            repost=repost, attachments=attached)
                state.made.insert(0, made)
            return self.reply(201, post_response(made, user))

        def sign_in(self, username):
            if ADMIN and ADMIN.disabled(username):
                # as txwtf's authorized_session_launch refuses it (after the code too, for one
                # disabled while its code was out)
                return self.reply(400, {"detail": f"Disabled user {USERS[username]['id']} (DisabledUser)"})
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
            # The emailed code, where the account has it (an administrator may have turned it
            # off: stub_admin). A disabled account gets none, as txwtf's execute_login: it is
            # refused here (sign_in), after the password.
            uses_code = ADMIN.uses_code(username) if ADMIN else USERS[username]["login_2fa_email_enabled"]
            if uses_code and not (ADMIN and ADMIN.disabled(username)):
                return self.reply(
                    200,
                    {
                        "two_factor_required": True,
                        "method": "email",
                        "challenge": CHALLENGES[username][0],
                        "expires_in": 300,
                    },
                )
            return self.sign_in(username)

        def login_2fa(self):
            body = self.json_body() or {}
            for username, (challenge, code) in CHALLENGES.items():
                if body.get("challenge") == challenge and body.get("code") == code:
                    return self.sign_in(username)
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

        def do_DELETE(self):
            self.run("DELETE")

        def do_PATCH(self):
            self.run("PATCH")

        def do_PUT(self):
            self.run("PUT")

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

    global LIVE, ADMIN
    state = State(args.log)
    LIVE = state
    ADMIN = stub_admin.Admin(
        {**USERS, **AUTHORS},
        avatar_of=lambda n: (USERS.get(n) or AUTHORS[n]).get("avatar_url", DEFAULT_AVATAR),
        posts_of=lambda n: USERS[n]["post_count"] if n in USERS
        else sum(1 for p in all_posts() if p["author"] == n))
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
