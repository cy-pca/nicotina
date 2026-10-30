#!/usr/bin/env python3
"""Check the live cyberpcangel.com sites against a staged payload.

    deploy/cyberpcangel/verify.py PAYLOAD [BASE_URL]

PAYLOAD is stage.sh's OUT. For each site (nicotina, nicotina-term) every staged file must be
served byte for byte, uncompressed, with the page's Content-Security-Policy; the site's directory
URL must serve its page (index.html, or ari.html for the terminal), and the URL without the
trailing slash must redirect to it. Python's urllib only (the CI runner's curl is broken).
"""
import pathlib
import sys
import urllib.error
import urllib.request

PAGES = {"nicotina": "index.html", "nicotina-term": "ari.html"}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def get(url, follow=True):
    req = urllib.request.Request(url, headers={"Accept-Encoding": "identity",
                                               "Cache-Control": "no-cache"})
    opener = urllib.request.build_opener() if follow else urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(req, timeout=60) as r:
            return r.status, r.headers, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, b""


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    payload = pathlib.Path(sys.argv[1])
    base = (sys.argv[2] if len(sys.argv) == 3 else "https://cyberpcangel.com").rstrip("/")
    ok = True

    def check(cond, what):
        nonlocal ok
        print(f"  {'OK  ' if cond else 'FAIL'} {what}")
        ok = ok and cond

    for site, page in PAGES.items():
        root = payload / site
        print(f"{base}/{site}/")
        status, headers, body = get(f"{base}/{site}/")
        check(status == 200 and body == (root / page).read_bytes(), f"/{site}/ serves {page}")
        csp = headers.get("Content-Security-Policy", "")
        check("'wasm-unsafe-eval'" in csp, "Content-Security-Policy set")
        status, headers, _ = get(f"{base}/{site}", follow=False)
        check(status in (301, 302) and headers.get("Location", "").endswith(f"/{site}/"),
              f"/{site} redirects to /{site}/")
        for f in sorted(p for p in root.rglob("*") if p.is_file()):
            rel = f.relative_to(root).as_posix()
            status, _, body = get(f"{base}/{site}/{rel}")
            check(status == 200 and body == f.read_bytes(), rel)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
