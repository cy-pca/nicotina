"""The stub TX.WTF instance's mail endpoints (tests/stub_txwtf.py), for nicotina's Mail view.

Python stdlib only, like the stub. The shapes are txwtf/api/mailbox.py's, the same in txwtf 0.4.0
(the fleet's) and master: AccountListResponse, FolderListResponse, MessageListResponse, MessageOut,
SendRequest and SendResponse, SaveAttachmentResponse.

  GET  /mail/accounts            the caller's mailboxes (AccountOut each)
  GET  /mail/{id}/folders        the mailbox's IMAP folders, with their flags (\\Sent, \\Drafts ...)
  GET  /mail/{id}/folders/{folder}/messages?limit=&offset=
                                 a page of the folder's headers, the newest (highest UID) first,
                                 and how many it holds (IMAP's EXISTS, \\Deleted ones too)
  GET  /mail/{id}/folders/{folder}/messages/{uid}
                                 one message, parsed: its headers (lower-case names), text_body,
                                 html_body, and parts (its attachments). Reading it marks it
                                 \\Seen, as txwtf's FETCH of RFC822 does
  POST /mail/{id}/folders/{folder}/messages/{uid}/flags   {seen}
  DELETE /mail/{id}/folders/{folder}/messages/{uid}
                                 flags it \\Deleted; txwtf doesn't expunge, so it stays listed
  POST /mail/{id}/folders/{folder}/messages/{uid}/attachments/{i}/save-to-files
                                 -> SaveAttachmentResponse: attachment i as one of the caller's
                                 files (a new one each time, as txwtf makes)
  POST /mail/{id}/send           SendRequest -> {message_id}. `to` and `cc` must be addresses
                                 (422 otherwise, as pydantic's EmailStr); existing_file_ids must be
                                 the caller's files (404 otherwise); 413 past 25 MB in all. A copy
                                 goes to Sent, as txwtf's MailboxClient.send APPENDs one. The log
                                 gets a "mail_send" line: who it went to, its subject, text and
                                 the files it carried

Not in txwtf yet, so only with --mail-api next (the change nicotina's Mail view proposes):

  parts[i].url                   in a message: /mail/attachment/{token}, attachment i's bytes,
                                 fetched with no Authorization header (a signed, expiring
                                 capability), so a picture shows inline and a video plays in
                                 hosts whose image: and video: take only a fixed credential
  GET  /mail/attachment/{token}  the bytes, with the part's Content-Type
  POST /mail/{id}/drafts         {to, cc, bcc, subject, body_text, in_reply_to, references,
                                 existing_file_ids, replace_uid} -> {folder, uid}: the draft
                                 APPENDed to Drafts (\\Draft \\Seen), replace_uid's copy gone. The
                                 log gets a "mail_draft" line

Without it, /mail/attachment/... and /mail/{id}/drafts are 404, as txwtf 0.4.0 answers.

Mailboxes: ada has two (31 ada@analytical.example, with mail in every folder she uses, and 32
ada.lovelace@notes.example), grace one (41 grace@navy.example), and no one else any.
"""

import base64
import hashlib
import json
import re
import threading
from urllib.parse import unquote

MAX_ATTACHMENT_TOTAL = 25 * 1024 * 1024
ADDRESS = re.compile(r"^[^@\s<>,;]+@[^@\s<>,;]+\.[^@\s<>,;]+$")

ACCOUNTS = {
    "ada": [(31, "ada@analytical.example", 2048, 3_145_728),
            (32, "ada.lovelace@notes.example", 1024, 20_480)],
    "grace": [(41, "grace@navy.example", 1024, 524_288)],
}

# Each mailbox's folders, as Dovecot (Mail-in-a-Box's) lists them: name and flags.
FOLDERS = [
    ("INBOX", ["\\HasNoChildren"]),
    ("Archive", ["\\HasNoChildren", "\\Archive"]),
    ("Drafts", ["\\HasNoChildren", "\\Drafts"]),
    ("Sent", ["\\HasNoChildren", "\\Sent"]),
    ("Spam", ["\\HasNoChildren", "\\Junk"]),
    ("Trash", ["\\HasNoChildren", "\\Trash"]),
]

GRACE = "Grace Hopper <grace@navy.example>"
CHARLES = "Charles Babbage <charles@engine.example>"
MARY = "Mary Somerville <mary@somerville.example>"
ADA = "ada@analytical.example"

BODY_112 = """Ada,

Here are the drawings of the engine, and a short film of yesterday's test run. The log of the
run is in the PDF: the carry mechanism jammed twice, both times on the fourth column.

Could you check the punched cards for the Bernoulli numbers against it before Friday?

Grace
"""

HTML_111 = """<html><head><style>p { color: #333; } .sig { font-size: small }</style>
<script>var tracker = 1;</script><title>Engine</title></head>
<body><p>Dear Ada,</p>
<p>The <b>second</b> engine&nbsp;needs fewer parts &amp; less brass than the first:</p>
<ul><li>25,000 parts, not 30,000</li><li>three tons, not fifteen</li></ul>
<p>I&#39;d value your notes on it.<br>Yours,<br>Charles</p>
<div class="sig">Sent from the Analytical Society</div></body></html>"""

BODY_5 = """Grace, for Friday:

- the carry mechanism, column four
- the Bernoulli cards
"""


def message(uid, frm, to, subject, date, text=None, html=None, cc="", flags=(), files=(),
            msgid=None, references=None):
    return {"uid": uid, "flags": list(flags), "from": frm, "to": to, "cc": cc,
            "subject": subject, "date": date, "text": text, "html": html, "files": list(files),
            "message_id": msgid or "<%d.%s>" % (uid, frm.split("@")[-1].strip(">")),
            "references": references}


def ada_inbox():
    out = [
        message(112, GRACE, ADA, "Engine drawings and the test run",
                "Tue, 24 Nov 2026 14:02:11 -0600", text=BODY_112,
                html="<p>Ada,</p><p>Here are the drawings of the engine ...</p>", cc=CHARLES,
                files=[("engine-diagram.png", "image/png", "picture"),
                       ("test-run.mp4", "video/mp4", "engine.mp4"),
                       ("test-log.pdf", "application/pdf", "pdf")],
                msgid="<engine-112@navy.example>"),
        message(111, CHARLES, ADA, "Re: The Difference Engine, part two",
                "Mon, 23 Nov 2026 09:15:00 +0000", html=HTML_111, flags=["\\Seen"],
                msgid="<de2-111@engine.example>", references="<de2-100@analytical.example>"),
        message(110, MARY, ADA, "Lunch on Friday?", "Sun, 22 Nov 2026 18:40:00 +0000",
                text="Ada, lunch on Friday at one? Mary\n", flags=["\\Seen", "\\Answered"]),
    ]
    for k in range(9):  # older mail, for a second page
        out.append(message(109 - k, MARY if k % 2 else CHARLES, ADA, "Notes, week %d" % (40 - k),
                           "Fri, %d Nov 2026 08:00:00 +0000" % (20 - 2 * k),
                           text="The notes for week %d.\n" % (40 - k), flags=["\\Seen"]))
    return out


def initial_boxes():
    """(account id, folder) -> its messages, as each run starts."""
    boxes = {(a, f): [] for a in (31, 32, 41) for f, _ in FOLDERS}
    boxes[(31, "INBOX")] = ada_inbox()
    boxes[(31, "Sent")] = [
        message(21, ADA, GRACE, "Re: The punched cards", "Fri, 20 Nov 2026 16:20:00 +0000",
                text="Grace, the cards are in the post.\n", flags=["\\Seen"]),
    ]
    boxes[(31, "Drafts")] = [
        message(5, ADA, "grace@navy.example", "Notes for the meeting",
                "Wed, 25 Nov 2026 10:00:00 +0000", text=BODY_5, flags=["\\Seen", "\\Draft"],
                cc="mary@somerville.example"),
    ]
    boxes[(32, "INBOX")] = [
        message(3, MARY, "ada.lovelace@notes.example", "On the connexion of the sciences",
                "Thu, 19 Nov 2026 12:00:00 +0000", text="A copy for you.\n"),
    ]
    boxes[(41, "INBOX")] = [
        message(7, "Ada Lovelace <ada@analytical.example>", "grace@navy.example",
                "The punched cards", "Thu, 19 Nov 2026 11:30:00 +0000",
                text="Grace, a picture of the cards, and the table.\n",
                files=[("cards.png", "image/png", "picture"),
                       ("bernoulli-table.pdf", "application/pdf", "pdf")]),
    ]
    return boxes


class Mail:
    def __init__(self, api, blob_of, save_file, file_of, log):
        """api: "0.4" (txwtf 0.4.0's routes) or "next" (with the proposed ones too).
        blob_of(kind, name) -> bytes: an attachment's content ("picture", "engine.mp4", "pdf").
        save_file(user, name, mime, data) -> FileUploadResponse; file_of(id) -> the record or
        None; log(entry) appends to the stub's log."""
        self.next_api = api == "next"
        self.blob_of = blob_of
        self.save_file = save_file
        self.file_of = file_of
        self.log = log
        self.lock = threading.Lock()
        self.boxes = initial_boxes()
        self.next_uid = 500
        self.sent_n = 0

    # --- helpers --------------------------------------------------------------------------
    def owned(self, user, account_id):
        for a in ACCOUNTS.get(user, []):
            if a[0] == account_id:
                return a
        return None

    def token(self, account_id, folder, uid, i):
        return hashlib.sha256(("%d/%s/%d/%d" % (account_id, folder, uid, i)).encode()).hexdigest()[:32]

    def part_bytes(self, f):
        name, mime, source = f
        if isinstance(source, bytes):
            return source
        if source == "upload":  # a file sent from here: kept with the message
            return b""
        return self.blob_of(source, name)

    def find(self, account_id, folder, uid):
        for m in self.boxes.get((account_id, folder), []):
            if m["uid"] == uid:
                return m
        return None

    # --- the routes ------------------------------------------------------------------------
    def attachment(self, h, path):
        """GET /mail/attachment/{token}, no auth (--mail-api next); None if not that route."""
        if not path.startswith("/mail/attachment/"):
            return None
        if not self.next_api:
            return h.reply(404, {"detail": "Not Found"})
        tok = path.rsplit("/", 1)[1]
        with self.lock:
            for (acct, folder), msgs in self.boxes.items():
                for m in msgs:
                    for i, f in enumerate(m["files"]):
                        if self.token(acct, folder, m["uid"], i) == tok:
                            data = f[3] if len(f) > 3 else self.part_bytes(f)
                            return h.reply_bytes(200, data, f[1])
        return h.reply(404, {"detail": "Attachment not found"})

    def handle(self, h, method, path, query, user):
        parts = [unquote(p) for p in path.split("/")]  # ['', 'mail', ...]
        if method == "GET" and path == "/mail/accounts":
            return h.reply(200, {"accounts": [
                {"id": a[0], "email": a[1], "domain": a[1].split("@")[1], "address_type": "mailbox",
                 "quota_mb": a[2], "quota_used_bytes": a[3], "status": "active",
                 "created_at": "2026-10-01T10:00:00", "updated_at": "2026-10-01T10:00:00"}
                for a in ACCOUNTS.get(user, [])]})
        if len(parts) < 3 or not parts[2].isdigit():
            return h.reply(404, {"detail": "Not Found"})
        acct = int(parts[2])
        if not self.owned(user, acct):
            if any(acct == a[0] for accts in ACCOUNTS.values() for a in accts):
                return h.reply(403, {"detail": "Mailbox does not belong to caller"})
            return h.reply(404, {"detail": "Mailbox not found"})
        rest = parts[3:]
        if method == "GET" and rest == ["folders"]:
            return h.reply(200, {"folders": [{"name": n, "flags": fl, "delimiter": "."}
                                             for n, fl in FOLDERS]})
        if method == "POST" and rest == ["send"]:
            return self.send(h, acct, user, draft=False)
        if method == "POST" and rest == ["drafts"]:
            if not self.next_api:
                return h.reply(404, {"detail": "Not Found"})
            return self.send(h, acct, user, draft=True)
        if len(rest) < 3 or rest[0] != "folders" or rest[2] != "messages":
            return h.reply(404, {"detail": "Not Found"})
        folder = rest[1]
        if (acct, folder) not in self.boxes:
            h.raw_body()
            return h.reply(502, {"detail": "IMAP error: select %r failed" % folder})
        if len(rest) == 3 and method == "GET":
            limit = int(query.get("limit", ["50"])[0])
            offset = int(query.get("offset", ["0"])[0])
            with self.lock:
                msgs = sorted(self.boxes[(acct, folder)], key=lambda m: -m["uid"])
                page = msgs[offset:offset + limit]
                return h.reply(200, {"total": len(msgs), "limit": limit, "offset": offset,
                                     "messages": [{"uid": m["uid"], "flags": m["flags"],
                                                   "from": m["from"], "to": m["to"], "cc": m["cc"],
                                                   "subject": m["subject"], "date": m["date"],
                                                   "size": 2048 + 512 * len(m["files"])}
                                                  for m in page]})
        if len(rest) < 4 or not rest[3].isdigit():
            return h.reply(404, {"detail": "Not Found"})
        uid = int(rest[3])
        with self.lock:
            m = self.find(acct, folder, uid)
        if m is None:
            h.raw_body()
            return h.reply(502, {"detail": "IMAP error: fetch uid %d failed" % uid})
        tail = rest[4:]
        if method == "GET" and tail == []:
            with self.lock:
                if "\\Seen" not in m["flags"]:
                    m["flags"].append("\\Seen")
                return h.reply(200, self.message_out(acct, folder, m))
        if method == "POST" and tail == ["flags"]:
            body = h.json_body() or {}
            with self.lock:
                if body.get("seen") is True and "\\Seen" not in m["flags"]:
                    m["flags"].append("\\Seen")
                if body.get("seen") is False and "\\Seen" in m["flags"]:
                    m["flags"].remove("\\Seen")
            return h.reply(200, {"uid": uid, "seen": body.get("seen")})
        if method == "DELETE" and tail == []:
            with self.lock:
                if "\\Deleted" not in m["flags"]:
                    m["flags"].append("\\Deleted")
            self.log({"mail_delete": {"account": acct, "folder": folder, "uid": uid}})
            return h.reply(200, {"uid": uid, "deleted": True})
        if (method == "POST" and len(tail) == 3 and tail[0] == "attachments"
                and tail[1].isdigit() and tail[2] == "save-to-files"):
            h.raw_body()
            i = int(tail[1])
            if i >= len(m["files"]):
                return h.reply(502, {"detail": "IMAP error: attachment index %d out of range "
                                               "(uid=%d, folder=%r)" % (i, uid, folder)})
            f = m["files"][i]
            data = f[3] if len(f) > 3 else self.part_bytes(f)
            made = self.save_file(user, f[0], f[1], data)
            self.log({"mail_save_to_files": {"account": acct, "folder": folder, "uid": uid,
                                             "index": i, "file": made["id"]}})
            return h.reply(200, {"id": made["id"], "original_name": made["original_name"],
                                 "mime_type": made["mime_type"], "file_size": made["file_size"],
                                 "url": made["url"]})
        return h.reply(404, {"detail": "Not Found"})

    def message_out(self, acct, folder, m):
        headers = {"from": m["from"], "to": m["to"], "subject": m["subject"], "date": m["date"],
                   "message-id": m["message_id"], "mime-version": "1.0"}
        if m["cc"]:
            headers["cc"] = m["cc"]
        if m["references"]:
            headers["references"] = m["references"]
        parts = []
        for i, f in enumerate(m["files"]):
            data = f[3] if len(f) > 3 else self.part_bytes(f)
            p = {"content_type": f[1], "filename": f[0], "content_id": None, "size": len(data),
                 "is_attachment": True}
            if self.next_api:
                p["url"] = "/mail/attachment/" + self.token(acct, folder, m["uid"], i)
            parts.append(p)
        return {"uid": m["uid"], "flags": list(m["flags"]), "headers": headers,
                "text_body": m["text"], "html_body": m["html"], "parts": parts,
                "raw_size": 4096 + sum(p["size"] for p in parts)}

    def send(self, h, acct, user, draft):
        """POST /mail/{id}/send, or (--mail-api next) /mail/{id}/drafts."""
        body = h.json_body()
        if body is None:
            return h.reply(422, {"detail": "a JSON object"})
        rcpts = {}
        for k in ("to", "cc", "bcc"):
            v = body.get(k) or []
            if not isinstance(v, list):
                return h.reply(422, {"detail": [{"loc": ["body", k], "msg": "Input should be a "
                                                 "valid list", "type": "list_type"}]})
            if not draft:
                for j, a in enumerate(v):
                    if not isinstance(a, str) or not ADDRESS.match(a):
                        return h.reply(422, {"detail": [{
                            "loc": ["body", k, j], "type": "value_error",
                            "msg": "value is not a valid email address: An email address must "
                                   "have an @-sign."}]})
            rcpts[k] = v
        if not draft and not rcpts["to"]:
            return h.reply(422, {"detail": [{"loc": ["body", "to"], "msg": "Field required",
                                             "type": "missing"}]})
        subject = body.get("subject")
        if not isinstance(subject, str):
            return h.reply(422, {"detail": [{"loc": ["body", "subject"], "msg": "Field required",
                                             "type": "missing"}]})
        if "\r" in subject or "\n" in subject:
            return h.reply(400, {"detail": "subject must not contain CR or LF"})
        files, total = [], 0
        for att in body.get("attachments") or []:
            data = base64.b64decode(att.get("data_base64", ""))
            total += len(data)
            files.append((att.get("filename", "attachment"),
                          att.get("content_type", "application/octet-stream"), "upload", data))
        ids = body.get("existing_file_ids") or []
        missing = [i for i in ids if self.file_of(i) is None]
        if missing:
            return h.reply(404, {"detail": "file id(s) not found: %s" % sorted(missing)})
        for i in ids:
            rec = self.file_of(i)
            if rec["user"] != user:
                return h.reply(403, {"detail": "file %d is not accessible to caller" % i})
            total += len(rec["data"])
            files.append((rec["name"], rec["mime"], "upload", rec["data"]))
        if total > MAX_ATTACHMENT_TOTAL:
            return h.reply(413, {"detail": "total attachment size exceeds 25 MB"})
        sender = self.owned(user, acct)[1]
        with self.lock:
            self.next_uid += 1
            uid = self.next_uid
            self.sent_n += 1
            msgid = "<sent-%d@%s>" % (self.sent_n, sender.split("@")[1])
            copy = message(uid, sender, ", ".join(rcpts["to"]), subject,
                           "Thu, 26 Nov 2026 12:00:00 +0000", text=body.get("body_text") or "",
                           cc=", ".join(rcpts["cc"]),
                           flags=["\\Seen", "\\Draft"] if draft else ["\\Seen"],
                           files=files, msgid=msgid, references=body.get("references"))
            folder = "Drafts" if draft else "Sent"
            if draft and body.get("replace_uid") is not None:
                self.boxes[(acct, "Drafts")] = [x for x in self.boxes[(acct, "Drafts")]
                                                if x["uid"] != body.get("replace_uid")]
            self.boxes[(acct, folder)].append(copy)
        self.log({"mail_draft" if draft else "mail_send": {
            "from": sender, "to": rcpts["to"], "cc": rcpts["cc"], "bcc": rcpts["bcc"],
            "subject": subject, "body_text": body.get("body_text"),
            "in_reply_to": body.get("in_reply_to"), "references": body.get("references"),
            "files": [f[0] for f in files], "sizes": [len(f[3]) for f in files],
            "replace_uid": body.get("replace_uid")}})
        if draft:
            return h.reply(200, {"folder": "Drafts", "uid": uid})
        return h.reply(200, {"message_id": msgid})


if __name__ == "__main__":  # the data, as JSON, for a look
    print(json.dumps({"accounts": ACCOUNTS, "folders": FOLDERS}, indent=1))
