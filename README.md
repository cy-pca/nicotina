# nicotina

**nicotina** is a client for [TX.WTF](https://tx.wtf) instances, written as
[Ariadne](https://github.com/transfix/libcvc/blob/master/docs/ARIADNE.md)
documents. The same documents run as a native desktop app, **in the terminal**, and in
the browser.

> **Status: M0 drafted.** You can sign in (username, password and the emailed code) and see
> your profile and SCRIP balance, in `arigl`, in `ari` with either terminal backend, and from
> the launcher. It needs libcvc features that are still open pull requests, so for now it
> runs only against a local libcvc build that merges them. See
> [Running M0 today](#running-m0-today) and [docs/ROADMAP.md](docs/ROADMAP.md).

## How it runs

The client is **documents only**: `.ari` files plus `.ari` components. It runs
in **unmodified** Ariadne hosts from [cvcpkg](https://cvcpkg.org), with no
custom host binary, compiled-in widget or patch.

```bash
cvcpkg install nicotina
nicotina --instance https://tx.wtf
```

The `nicotina` package depends on `ari` and `arigl`. It installs:

- `share/nicotina/`: the documents and components (`main.ari`, `ui/*.ari`).
- `bin/nicotina` (`nicotina.cmd` on Windows): a launcher script. It runs the
  client's main document in a stock host, with the host flags the client needs: the
  network for the chosen instance's origin and nothing else, and a credential store for
  the session token:
  - `arigl` (ImGui) on a desktop;
  - `ari run` in a terminal. It runs over SSH, uses either of ari's terminal
    backends (FTXUI, tvision), and is selected with `--terminal` or picked
    automatically when there's no display.

**The terminal is a first-class target, not a fallback.** Every feature has to
work and be tested in `ari` as well as `arigl`. The windows are laid out for an 80x24
terminal first; ImGui adds to them (a Details window) rather than the other way round.

In the browser, an instance serves the same documents next to the generic arigl
wasm shell, at `https://<instance>/apps/nicotina/`.

### The launcher

```
nicotina [--instance URL] [--terminal] [--backend ftxui|tvision] [host flags...] [-- doc args...]
```

| Option | What |
|---|---|
| `--instance URL` | the TX.WTF instance, `https://tx.wtf` by default |
| `--terminal` | run in the terminal even where there is a display |
| `--backend ftxui\|tvision` | the terminal backend (FTXUI by default); implies `--terminal` |
| `--dry-run` | print the host command instead of running it |
| other options | go to the host, before the document (`--fps 30`, `--no-mouse`, ...) |
| after `--` | go to the document: `--user NAME` fills in the sign-in form |

It picks the terminal when there is no display: no `DISPLAY` or `WAYLAND_DISPLAY` on
Linux and the BSDs, or an SSH session without X forwarding anywhere. It runs

```
arigl run --net --net-allow <origin> --credential-store <config>/nicotina/credentials \
  <prefix>/share/nicotina/main.ari --instance <URL>
```

or `ari run [--backend tvision] ...` in a terminal (or `arigl run --terminal ...` where only
arigl is installed). `<config>` is `$XDG_CONFIG_HOME` or `~/.config`, and `%APPDATA%` on
Windows. `<prefix>` is the launcher's own directory's parent, so it works from an install
and from a checkout alike. It takes `ari` and `arigl` from `<prefix>/bin`, else from `PATH`;
`NICOTINA_ARI` and `NICOTINA_ARIGL` name others.

### The session token

The host holds the token, never the documents:

- Sign-in posts to `/user/login` with `capture_auth`. The host takes `token` out of the reply,
  keeps it as credential `txwtf` for the instance's origin, and hands the document the reply
  with `"[redacted]"` in its place.
- Every later request names the credential (`auth: txwtf`) and the host adds the
  `Authorization` header.
- With `--credential-store`, the host keeps it across runs in an owner-only file (0600 in a
  0700 directory), and the next start signs in from it. Sign-out posts `/user/logout` and
  drops it (`net-auth-forget`).
- So it never enters the state tree, a frame or a log. `tests/run.sh` checks that no output
  carries one.

The document declares `requires: [net, net.auth, ...]`, so a host started without `--net`
refuses to load it and says what is missing.

## Running M0 today

M0 needs four open libcvc pull requests:

- [transfix/libcvc#888](https://github.com/transfix/libcvc/pull/888): the network policy flags
  and host-owned credentials;
- [transfix/libcvc#883](https://github.com/transfix/libcvc/pull/883): `json-parse`,
  `json-encode` and `state-set-tree`;
- [transfix/libcvc#885](https://github.com/transfix/libcvc/pull/885): `state-set` keeps a float's
  digits;
- [transfix/libcvc#887](https://github.com/transfix/libcvc/pull/887): URL-loaded documents, and
  the `arigl` and `arigl-web` packages.

Build `ari` (and `arigl`, which needs cvcGL) from a local branch that merges them. libcvc's
README lists the dependencies; tvision needs `CVC_ARIADNE_TVISION=ON` with tvision and
ncursesw found.

```bash
cd ~/src/libcvc
git worktree add -b local/nicotina-m0 ../libcvc-nicotina origin/master
cd ../libcvc-nicotina
for n in 888 883 885 887; do git fetch origin "pull/$n/head" && git merge --no-edit FETCH_HEAD; done
```

Two of the merges conflict, only where two pull requests add lines at the same place: #883
and #887 each add a test block to `src/ari/CMakeLists.txt` where #888 adds one (keep every
block), and #887 adds `ariadne/doc_fetch.cpp ariadne/web_document.cpp` to the source list in
`src/cvc/CMakeLists.txt` where #888 adds `ariadne/net_host.cpp` (keep all three). Then:

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=<your deps> \
  -DCVC_BUILD_ARI=ON -DCVC_BUILD_ARIGL=ON -DCVC_BUILD_CVCGL=ON -DCVC_ARIADNE_TVISION=ON \
  -DCVC_BUILD_TESTS=OFF
ninja -C build ari arigl
```

Run the client from this checkout, pointing the launcher at that build:

```bash
export NICOTINA_ARI=~/src/libcvc-nicotina/build/bin/ari
export NICOTINA_ARIGL=~/src/libcvc-nicotina/build/bin/arigl
bin/nicotina --instance https://dev.tx.wtf                      # a window
bin/nicotina --terminal --instance https://dev.tx.wtf           # FTXUI
bin/nicotina --backend tvision --instance https://dev.tx.wtf    # tvision
```

In the terminal, Tab moves between fields and buttons and Enter presses a button. F10 opens
the menu (Refresh, Sign out, Quit); Ctrl-C quits.

### With cvcpkg

Once the `ari` and `arigl` packages publish with these features, `cvcpkg install ari arigl`
and put that prefix's `bin` on `PATH`; `bin/nicotina` from a checkout then finds them. Once
the `nicotina` recipe lands (M4), `cvcpkg install nicotina` installs the launcher beside them.

### In the browser

Serve the `arigl-web` package's files, the contents of `share/nicotina/`, and
[web/ariadne.config.json](web/ariadne.config.json) in one directory, such as `/apps/nicotina/`
on the instance itself:

```
/apps/nicotina/index.html arigl-web.js arigl-web.css arigl.js arigl.wasm   (arigl-web)
/apps/nicotina/ari.html ari.js ari.wasm ari-web.js ari-web.css xterm/      (arigl-web, the terminal page)
/apps/nicotina/main.ari ui/signin.ari ui/home.ari                          (share/nicotina)
/apps/nicotina/ariadne.config.json                                         (web/)
```

`/apps/nicotina/` is the ImGui client and `/apps/nicotina/ari.html` the terminal one. The
config passes `--net`, which lets the document reach the page's own origin and no other,
and `--instance` for that origin. The pages substitute `{origin}` only in host flags, not in
document arguments, so an instance other than tx.wtf changes `args` in its copy. A browser
keeps the token in memory, so a reload signs out. This path is not tested yet: it needs
txwtf to serve `/apps/` (T2 in txwtf's roadmap) and a wasm build with the pull requests above.

## Tests

`tests/run.sh` runs the client against a stub TX.WTF instance
([tests/stub_txwtf.py](tests/stub_txwtf.py), Python stdlib only) that answers `/user/login`,
`/user/login/2fa`, `/user/`, `/billing/scrip/balance` and `/user/logout` with the shapes
txwtf's API uses:

```bash
ARI=$NICOTINA_ARI ARIGL=$NICOTINA_ARIGL tests/run.sh
```

- `bin/nicotina --dry-run`: the host, the flags and the credential store it picks.
- `ari check`: without `--net` the document refuses to load, naming what it needs.
- `ari snapshot`, FTXUI and tvision: the sign-in form; a stored session resumed (profile and
  balance); an expired one (back to the form, and the host forgets it); an instance that
  doesn't answer.
- `arigl snapshot`, as text (`--terminal`) and as a PNG.
- `bin/nicotina` in a tmux pane, FTXUI and tvision, typed at like a person: sign in, start
  again still signed in, sign out; a wrong password; the emailed code, wrong and then right;
  an account that must change its password first.
- Every output is searched for the stub's tokens: none may appear.

`ari snapshot` lays a frame out with FTXUI whichever backend it is given, so the tmux runs are
what check the tvision desktop itself. They need tmux, and Linux for now.

**TODO: CI.** A GitHub Actions job that runs `tests/run.sh` needs published `ari` and `arigl`
packages with the pull requests above; it comes once they publish.

## What it talks to

The client uses only an instance's public API:

- the REST API, documented at `/docs` on any instance. M0 uses `POST /user/login`,
  `POST /user/login/2fa`, `GET /user/` (the signed-in user's profile),
  `GET /billing/scrip/balance` and `POST /user/logout`;
- from M1, the `/ws/events` WebSocket for live updates, and OIDC sign-in (instances
  support public PKCE clients and loopback redirects).

## Known gaps

- The password field shows what you type: Ariadne's `input_text` has no masked mode yet
  (L11 in the roadmap). The document clears the password from its state as soon as it sends
  it.
- Nothing has focus when a form opens; press Tab to reach the first field.

## Layout

```
share/nicotina/        main.ari and ui/*.ari: the documents
bin/                   nicotina (POSIX sh) and nicotina.cmd (Windows): the launchers
web/                   ariadne.config.json for the browser pages
tests/                 run.sh and the stub TX.WTF instance
recipe/                the cvcpkg recipe (M4)
docs/ROADMAP.md        milestones and the libcvc features each one needs
```

## License

MIT. See [LICENSE](LICENSE). The Ariadne hosts and libcvc are LGPL-2.1 and
are installed separately through cvcpkg.
