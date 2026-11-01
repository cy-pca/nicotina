# nicotina on cyberpcangel.com

The browser builds of nicotina, public and not login-gated:

| URL | Client | Page |
|---|---|---|
| https://cyberpcangel.com/nicotina/ | ImGui | libcvc arigl-web's `index.html` (arigl) |
| https://cyberpcangel.com/nicotina-term/ | terminal (FTXUI in xterm.js) | arigl-web's `ari.html` |
| https://cyberpcangel.com/nicotina-term/ari_tvision.html | terminal (tvision) | arigl-web's `ari_tvision.html`, when the build has it |

Both run `main.ari` against **https://tx.wtf**. cyberpcangel.com is not a TX.WTF instance, so the
API is cross-origin and the page config names the instance explicitly
([ariadne.config.json](ariadne.config.json)):

```json
"flags": ["--net-allow", "https://tx.wtf"],
"args":  ["--instance", "https://tx.wtf"],
"src_param": false
```

`--net-allow` lets the document reach that origin and no other. `src_param: false` pins the page to
`main.ari`, so a `?src=` link can't run another document with these flags. A browser keeps the
session token in memory (`--credential-store` is refused there), so a reload signs out.

**CORS.** The instance must allow the origin `https://cyberpcangel.com`. txwtf reads its allowlist
from `TXWTF_CORS_ORIGINS`; docker deployments pass it to the backend container from
atx-crypto-club/txwtf#312 on. tx.wtf does: `TXWTF_CORS_ORIGINS=https://cyberpcangel.com` is in its
`.env.production`, and prod runs #312 (prod 5c04fff, from 2026-10-30). Checked on 2026-10-31:
- the preflights for `/user/login`, `/user/login/2fa`, `/user/`, `/billing/scrip/balance` and
  `/user/logout` answer 200, allowing this origin, while an unlisted origin still gets 400;
- a sign-in from the terminal page reaches tx.wtf.

Without CORS the browser blocks the sign-in, and the page says "Can't reach tx.wtf".

To use another instance, change both URLs in `ariadne.config.json`. The pages' Content-Security-Policy
(`connect-src`) allows tx.wtf and dev.tx.wtf; another instance also needs adding to `CONNECT` in
[nicotina-deploy.sh](nicotina-deploy.sh), and that instance's CORS.

## How it deploys

The [deploy-cyberpcangel](../../.github/workflows/deploy-cyberpcangel.yml) workflow publishes what
CI has tested. It runs after the [`ci`](../../.github/workflows/ci.yml) workflow succeeds on a push
to `main` in this repository, and deploys that commit. It also runs on demand: Actions →
deploy-cyberpcangel → Run workflow, where `ref` picks the branch or commit whose documents to
publish. It uses the same chain as the other cyberpcangel.com deployments (the cvcGL gallery,
cvcdbg, the imperial lexicon):

```
catx-03 runner (label cvcpkg-prod: the cy-pca org runner catx-03-cy-pca, user github-runner)
  cvcpkg install   arigl-web (wasm, single-threaded) from cvcpkg.org -> share/arigl-web
  stage.sh         + share/nicotina + ariadne.config.json            -> payload/{nicotina,nicotina-term}
  tar czf - | ssh -i ~/.ssh/id_ed25519_cyberpcangel_deploy tfx@catx-00.tx.wtf deploy-nicotina
catx-00 forced command (~tfx/bin/txwtf-deploy-cyberpcangel)
  deploy-nicotina -> lxc exec cyberpcangel --project catx -- /root/nicotina-deploy.sh
cyberpcangel instance
  nicotina-deploy.sh  checks the payload, replaces $DOCROOT/nicotina and $DOCROOT/nicotina-term,
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
  - the files that shape the payload: `ariadne.config.json`, `stage.sh` and the workflow.

  A change to this README, `verify.py` or `nicotina-deploy.sh` doesn't republish. A run compares
  the fingerprint with the live one and stops when they match; `force` publishes anyway. Until
  nicotina's `main` has `share/nicotina/main.ari`, a run from `main` finds nothing to publish.
- **Only what CI passed.** A failing `ci` run, a pull request's run, and a run from a fork (whose
  branch may also be called `main`) don't trigger it.
- **The payload runs nothing.** `nicotina-deploy.sh` is installed once and fixed; it refuses
  links, special files and any file a page doesn't serve (no `.php`, no `.htaccess`), writes the
  Apache config itself, and leaves the files owned by root, so WordPress (`www-data`) can't change
  them. Each site is replaced whole, by a rename.
- **Apache** (`nicotina.conf`, scoped to the two directories): `application/wasm`, deflate, no
  directory listings, no rewrites into WordPress, `DirectoryIndex ari.html` for the terminal site,
  `Cache-Control: no-cache` (a redeploy shows on the next load), and
  `Content-Security-Policy: default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; connect-src 'self' https://tx.wtf https://dev.tx.wtf; ...; frame-ancestors 'self'`.
  `'unsafe-inline'` styles are for xterm.js's DOM renderer, which it falls back to without WebGL2.

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
tar czf - -C /tmp/payload nicotina nicotina-term \
  | ssh tfx@catx-00.tx.wtf 'lxc exec cyberpcangel --project catx -- /root/nicotina-deploy.sh'
python3 deploy/cyberpcangel/verify.py /tmp/payload
```

## One-time setup (done 2026-10-30)

1. `/root/nicotina-deploy.sh` in the cyberpcangel instance, from this directory (its header has the
   command). Re-run that after changing the script.
2. The `deploy-nicotina` action in catx-00's `~tfx/bin/txwtf-deploy-cyberpcangel`, the forced
   command of the runner's deploy key (`github-runner-cyberpcangel@catx-03`). The full script is
   recorded in atx-crypto-club/vm-provisioning (`docs/CYBERPCANGEL-DEPLOYS.md`).
3. The runner: nothing new. The workflow installs arigl-web into its own prefix,
   `/home/github-runner/cvc-wasm/deps-wasm`, on its first run.
