#!/usr/bin/env python3
"""An SMTP server that keeps every message it is sent, for tests. Python stdlib only.

It speaks enough SMTP for Python's smtplib without TLS or auth (HELO/EHLO, MAIL, RCPT, DATA,
RSET, NOOP, QUIT) and writes each message to DIR/<n>.eml. tests/local.sh points a local txwtf
instance's email.smtp settings at it, to read the emailed sign-in code.

  python3 smtp_sink.py --dir DIR --port 0 --port-file PORTFILE
  python3 smtp_sink.py --code-for grace@example.org --dir DIR   # the newest 6-digit code
"""

import argparse
import email
import os
import re
import socketserver
import sys


class Handler(socketserver.StreamRequestHandler):
    def send(self, line):
        self.wfile.write((line + "\r\n").encode())

    def handle(self):
        self.send("220 smtp-sink ready")
        rcpt = []
        while True:
            raw = self.rfile.readline()
            if not raw:
                return
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            verb = line[:4].upper()
            if verb in ("HELO", "EHLO"):
                self.send("250 smtp-sink")
            elif verb == "MAIL":
                rcpt = []
                self.send("250 OK")
            elif verb == "RCPT":
                rcpt.append(line.split(":", 1)[-1].strip().strip("<>"))
                self.send("250 OK")
            elif verb == "DATA":
                self.send("354 end with <CRLF>.<CRLF>")
                data = []
                while True:
                    part = self.rfile.readline()
                    if not part or part in (b".\r\n", b".\n"):
                        break
                    data.append(part[1:] if part.startswith(b"..") else part)
                self.server.keep(rcpt, b"".join(data))
                self.send("250 OK queued")
            elif verb == "RSET":
                rcpt = []
                self.send("250 OK")
            elif verb == "NOOP":
                self.send("250 OK")
            elif verb == "QUIT":
                self.send("221 bye")
                return
            else:
                self.send("502 not implemented")


class Sink(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, addr, directory):
        super().__init__(addr, Handler)
        self.directory = directory
        self.count = 0

    def keep(self, rcpt, data):
        self.count += 1
        path = os.path.join(self.directory, f"{self.count:04d}.eml")
        with open(path, "wb") as f:
            f.write(b"X-Sink-Rcpt: " + ", ".join(rcpt).encode() + b"\r\n" + data)


def text_of(path):
    msg = email.message_from_bytes(open(path, "rb").read())
    parts = msg.walk() if msg.is_multipart() else [msg]
    out = [msg.get("X-Sink-Rcpt", ""), msg.get("Subject", "")]
    for p in parts:
        if p.get_content_maintype() == "text":
            out.append((p.get_payload(decode=True) or b"").decode("utf-8", "replace"))
    return "\n".join(out)


def newest_code(directory, address):
    for name in sorted(os.listdir(directory), reverse=True):
        text = text_of(os.path.join(directory, name))
        if address in text.splitlines()[0]:
            m = re.search(r"\b(\d{6})\b", text.split("\n", 2)[-1])
            if m:
                return m.group(1)
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dir", required=True)
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--port-file")
    ap.add_argument("--code-for", metavar="ADDRESS", help="print the newest code sent to ADDRESS")
    args = ap.parse_args()
    if args.code_for:
        code = newest_code(args.dir, args.code_for)
        if not code:
            sys.exit(1)
        print(code)
        return
    os.makedirs(args.dir, exist_ok=True)
    sink = Sink(("127.0.0.1", args.port), args.dir)
    if args.port_file:
        with open(args.port_file + ".tmp", "w") as f:
            f.write(str(sink.server_address[1]))
        os.replace(args.port_file + ".tmp", args.port_file)
    sink.serve_forever()


if __name__ == "__main__":
    main()
