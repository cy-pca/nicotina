# nicotina on cyberpcangel.com

The browser builds of nicotina, public and not login-gated:

| URL | Client | Page |
|---|---|---|
| https://cyberpcangel.com/nicotina/ | ImGui | libcvc arigl-web's `index.html` (arigl) |
| https://cyberpcangel.com/nicotina-term/ | terminal (FTXUI in xterm.js) | arigl-web's `ari.html` |
| https://cyberpcangel.com/nicotina-term/ari_tvision.html | terminal (tvision) | arigl-web's `ari_tvision.html`, when the build has it |
| https://cyberpcangel.com/nicotina-pixels/ | terminal, its pictures in real pixels | arigl-web's `ari.html` with `--graphics iterm`, when its `xterm/` has the image addon |

**nicotina-pixels** is the terminal page with one more flag in its config, `--graphics iterm`:
`ari` sends the avatars, banners and attachments as iTerm2 inline images, which xterm.js's image
addon draws in real pixels, scaled to the cells each picture takes. `stage.sh` derives its config
from [ariadne.config.json](ariadne.config.json), and stages the site only when the arigl-web
package's `xterm/` has `addon-image.js`: libcvc's terminal page loads it from transfix/libcvc#1610
on, in the first release after 4.0.10. Before that the page would draw half-blocks, like
nicotina-term. ari also speaks kitty's graphics protocol, but through Unicode placeholders,
which no browser terminal draws yet.

Both run `main.ari` against **https://tx.wtf**. The sign-in form's Site combo offers every site
of the TX.WTF fleet, the 15 in [share/nicotina/fleet.policy](../../share/nicotina/fleet.policy).
cyberpcangel.com is not a TX.WTF instance, so the API is cross-origin, and the page config names
each site explicitly ([ariadne.config.json](ariadne.config.json)):

```json
"flags": ["--net-allow", "https://tx.wtf", "--net-allow", "https://social.sublevels.net", ...,
          "--net-allow", "https://dev2.tx.wtf"],
"args":  ["--instance", "https://tx.wtf"],
"src_param": false
```

The combo offers a fleet site only where the page may reach it. A site needs three things to
join it here:
- its `--net-allow` in the page config;
- its origin in the CSP, which is `INSTANCES` in [nicotina-deploy.sh](nicotina-deploy.sh);
- `https://cyberpcangel.com` in its own CORS (below).

tests/run.sh checks that the page config and `INSTANCES` list fleet.policy's sites, and verify.py
checks that the live CSP lists the page config's sites.

`--net-allow` lets the document reach that origin and no other. `src_param: false` pins the page to
`main.ari`, so a `?src=` link can't run another document with these flags. A browser keeps the
session token in memory (`--credential-store` is refused there), so a reload signs out.

**CORS.** Each site must allow the origin `https://cyberpcangel.com`. txwtf reads its allowlist
from `TXWTF_CORS_ORIGINS` (space-separated):
- **tx.wtf** has `TXWTF_CORS_ORIGINS=https://cyberpcangel.com` in its `.env.production`. Its compose
  file passes the variable to the backend from atx-crypto-club/txwtf#312 on (prod since 2026-10-30).
- **The rest of the fleet** takes it from cy-pca/txwtf-fleet: `fleet.yaml`'s `cors_origins` goes
  into each site's env, and the fleet's compose override passes it to the backend. The fleet's base
  compose is older than #312. cvcpkg.com and dev.tx.wtf have their own override, so their base
  compose carries #312's line instead. The fleet's RUNBOOK says how to add an origin to a live site.

A site allows it when the preflights for `/user/login`, `/user/login/2fa`, `/user/`,
`/billing/scrip/balance` and `/user/logout` answer 200 with
`access-control-allow-origin: https://cyberpcangel.com`. An unlisted origin still gets 400:

```bash
curl -s -o /dev/null -D - -X OPTIONS https://<site>/user/login \
  -H 'Origin: https://cyberpcangel.com' -H 'Access-Control-Request-Method: POST'
```

Without CORS the browser blocks the sign-in, and the page says "Can't reach <site>".

Each site's CSP entry covers requests (`connect-src`) and the video and audio the players stream from
it (`media-src`). To add a site:
1. add it to fleet.policy and main.ari's `fleet-sites`;
2. add it to `ariadne.config.json` and `INSTANCES` (in cy-pca/ops' copy of `nicotina-deploy.sh` too);
3. install `nicotina-deploy.sh` on the box, from cy-pca/ops;
4. give the site CORS.

## How it deploys

cy-pca/ops deploys the sites. It is the private repo that holds cy-pca's production deploys and
their keys; its `cyberpcangel-deploy` workflow runs on that repo's own runner, and its
`cyberpcangel/README.md` has the chain, the secrets and the host setup. Every 15 minutes it takes
the newest push to `main` here whose [`ci`](../../.github/workflows/ci.yml) passed, and deploys it
when something moved; it also runs by hand on any branch, tag or commit. This directory is what the
payload is made of: ops runs `stage.sh` and `verify.py` from the commit it deploys.

```
ops-deploy-00 (catx-01): cy-pca/ops's runner, label deploy
  cvcpkg install   arigl-web (wasm, single-threaded) from cvcpkg.org -> share/arigl-web
  stage.sh         + share/nicotina + ariadne.config.json            -> payload/{nicotina,nicotina-term}
                                                                        (+ nicotina-pixels)
  tar czf - | ssh tfx@catx-00 deploy-nicotina    (a key that only ops' cyberpcangel environment has)
catx-00 forced command (~tfx/bin/txwtf-deploy-cyberpcangel)
  deploy-nicotina -> lxc exec cyberpcangel --project catx -- /root/nicotina-deploy.sh
cyberpcangel instance
  nicotina-deploy.sh  checks the payload, replaces $DOCROOT/nicotina, $DOCROOT/nicotina-term and,
                      when the payload has it, $DOCROOT/nicotina-pixels,
                      owns /etc/apache2/conf-available/nicotina.conf
verify.py          every staged file served byte for byte, the CSP, the redirects
```

- **The stock page.** The pages are the `arigl-web` package as cvcpkg.org publishes it, the
  stock browser host, not a build of libcvc: nicotina targets packaged hosts. A libcvc feature
  reaches the site when a libcvc release publishes it.
- **Single-threaded**, so the pages need no COOP/COEP headers. The package is the full build, with
  the image and mesh I/O a widget client doesn't use. arigl-web 3.7.8 (raw / gzip):
  - arigl.wasm: 51.3 MB / 14.6 MB;
  - ari.wasm and ari_tvision.wasm: 23.7 MB / 7.7 MB each;
  - the lean build this workflow made before (`CVC_ARIGL_WEB_LEAN=1`): arigl.wasm 34.9 MB /
    9.4 MB, and ari.wasm 8.9 MB / 3.1 MB.
- **Only when something moved.** Each site has a `.built-from` whose first word fingerprints:
  - the arigl-web bundle (its version and hash, from the install's lockfile);
  - the documents;
  - the files that shape the payload: `ariadne.config.json`, `stage.sh` and ops' workflow.

  A change to this README, `verify.py` or `nicotina-deploy.sh` doesn't republish. A run compares
  the fingerprint with the live one and stops when they match; `force` publishes anyway. A new
  arigl-web on cvcpkg.org republishes on the next check.
- **Only what CI passed.** The watch takes a push to this repository's `main` whose `ci` run
  passed; a pull request's run doesn't count.
- **The payload runs nothing.** `nicotina-deploy.sh` is installed once and fixed; it refuses
  links, special files and any file a page doesn't serve (no `.php`, no `.htaccess`), writes the
  Apache config itself, and leaves the files owned by root, so WordPress (`www-data`) can't change
  them. Each site is replaced whole, by a rename.
- **Apache** (`nicotina.conf`, scoped to the sites' directories): `application/wasm`, deflate, no
  directory listings, no rewrites into WordPress, `DirectoryIndex ari.html` for the terminal sites,
  `Cache-Control: no-cache` (a redeploy shows on the next load), and
  `Content-Security-Policy: default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; connect-src 'self' https://tx.wtf ... https://dev2.tx.wtf; img-src 'self' data: blob:; media-src 'self' blob: https://tx.wtf ... https://dev2.tx.wtf; ...; frame-ancestors 'self'`, where `...` is the fleet's other sites (`INSTANCES`).
  `'unsafe-inline'` styles are for xterm.js's DOM renderer, which it falls back to without WebGL2.
  `media-src` is for the `video:` and `audio:` players, which are the browser's own `<video>` and
  `<audio>`: without it they fall back to `default-src 'self'`, and Chrome refuses every
  attachment ("Media load rejected by URL safety check").
- **`nicotina-deploy.sh`'s version of record is cy-pca/ops `cyberpcangel/nicotina-deploy.sh`.**
  The copy here is byte-identical, and `tests/run.sh` exercises it; ops' deploy warns when the two
  differ. A change goes into both, then is installed on the box from ops (the command at the top of
  the script); the next deploy rewrites `nicotina.conf`. The script prints its own sha256, and the
  deploy warns when the installed one isn't the record. verify.py checks the live CSP, so a deploy
  fails its check until the installed script matches. A script from before nicotina-pixels refuses
  a payload that has it ("payload has more than nicotina nicotina-term"), and the deploy fails with
  nothing replaced. This one takes a payload with or without the site.

## By hand

Install, stage and check locally:

```bash
cvcpkg install arigl-web --platform wasm --arch wasm32 --prefix /tmp/web \
  --config release --link static
deploy/cyberpcangel/stage.sh /tmp/web/share/arigl-web share/nicotina /tmp/payload
```

The install also lays down the static wasm libraries the package was linked from (its bundle
lists them as deps, about 680 MB), which the pages don't use.

Publish with the house access instead of the deploy key (`tfx` on catx-00):

```bash
tar czf - -C /tmp/payload $(ls /tmp/payload) \
  | ssh tfx@catx-00.tx.wtf 'lxc exec cyberpcangel --project catx -- /root/nicotina-deploy.sh'
python3 deploy/cyberpcangel/verify.py /tmp/payload
```

## Setup

cy-pca/ops `cyberpcangel/README.md` has it: the key in ops' `cyberpcangel` environment (catx-00
takes it only from ops' runner, behind the forced command), the forced command's
`deploy-nicotina` action, and `/root/nicotina-deploy.sh`.

Until 2026-11-28 this repository deployed the sites itself, with a `deploy-cyberpcangel` workflow
on catx-03's cy-pca org runner and that host's `id_ed25519_cyberpcangel_deploy`. The first
deploy (2026-10-30) is recorded in cy-pca/provisioning `docs/CYBERPCANGEL-DEPLOYS.md`.
