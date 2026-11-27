# nicotina's components: design

*Draft, 2026-11-26. Nothing in it is built yet. Section 7 lists the decisions for Joe.*

nicotina's TX.WTF views become components that another Ariadne app can mount beside its own
views: sign-in, the profile, the feed and posts, and direct messages. The first app to use them
is the sublevels client (cy-pca/sublevels `client/`, `docs/CLIENT_UI.md` §1, §4.1, §4.3, CU-D3,
CU-D5). It mounts these views in its own window, signed in once to TX.WTF, and lists TX.WTF DMs
in its one list of conversations.

**The dependency runs one way.** The sublevels client depends on nicotina's components. nicotina
depends on nothing from sublevels or Direct Connect (Joe, 2026-11-26: "nicotina is really just
meant to communicate with txwtf, sublevels-client should build on that"). The components are
TX.WTF only. They have no Direct Connect code, no hub ports and no DC host features. Nothing in
this note names sublevels outside this introduction and the tests' description of a consumer.

nicotina's rules hold for the components as for the app:

- **documents only:** the components are `.ari` files and run in stock `ari` and `arigl` from
  cvcpkg. Anything they need from a host is a generic libcvc feature;
- **the terminal is first-class:** each component works in `ari` with FTXUI and tvision, over
  SSH, and in `arigl` and the browser. A component is done only when an `ari snapshot` test
  covers it, mounted in a host as well as inside nicotina;
- **nicotina keeps working exactly as today:** the same windows, menus, tray, `--start` deep links
  and launcher. `tests/run.sh`, `tests/local.sh` and `tests/e2ee.sh` pass unchanged at every step.

## 1. What exists

- **`nicotina.ari` is already a module.** `main.ari` loads it once for each site
  (`load: nicotina.ari`, repeated, `as: nicotina`). Its link holes are `args` (ro), `ui` (rw: its
  view state and `ui.cmd`, the commands its menus send), `fleet` (ro) and `peers` (ro). The top of
  `nicotina.ari` documents loading it from another document. But it is one module: the sign-in
  windows and the whole TX.WTF window, with every view in it. A host can only have all of it,
  and only as windows of its own.
- **The views are units already.** `ui/signin.ari`, `ui/app.ari`, `ui/home.ari` (profile),
  `ui/feed.ari` (feed, post), `ui/card.ari`, `ui/social.ari` (tags, alerts, search, compose,
  viewer), `ui/dm.ari`, `ui/mail.ari` and `ui/admin.ari` hold `units:` only. `nicotina.ari`
  imports them and includes the windows.
- **The logic is one program.** `nicotina.ari`'s `on_tick:` is about 4,300 lines: 288 `defun`s
  defined again each time a command runs, then about 120 `(if (= cmd ...))` branches over one
  `ui.cmd`, with one `ui.busy`. Its `functions:` block holds one function (`use-site`). The state
  it keeps is at the module's root: `ui.*`, `app.*`, `me.*`, `prof.*`, `feed.*`, `post.*`, `dm.*`,
  `cache.*`, `news.*`, and so on.
- **The session is the host's.** Sign-in posts `/user/login` with `capture_auth`. The host keeps
  the token as the credential `txwtf.<host>` (`site.ari`'s `site-cred`), bound to the site's
  origin, and every request names it (`auth:`). The document never holds the token. With
  `--credential-store` the host keeps it across runs. The end-to-end keys are the host's too
  (`--e2ee-store`, the `e2ee-*` verbs).

Checked on the packaged `ari` 4.0.9+cvc.1 (cvcpkg.org), with throwaway documents:

| Question | Answer |
|---|---|
| Can a host put a `load:` inside one of its own windows, in a tab? | Yes. The module's `root:` widgets are drawn where the `load:` stands, beside the host's own widgets. |
| Does that module keep its own state? | Yes, at `includes.<as>`. A `link:` hole (`session: {to: txwtf, mode: rw}`) reads and writes the host's `txwtf.*`. |
| Does its `on_tick:` run? | Yes, and it writes through the hole. |
| Does a mount in a tab that isn't showing run? | **No.** Its `on_tick:` doesn't run and its state isn't made until the tab is shown. Section 3.3 follows from this. |
| Can a function in `functions:` see a variable the calling program `set`? | **No**, it's a `NameError`. Section 6, step N2, follows from this. |

**libcvc's app shell.** ARIADNE_SHELL.md's `mounts:` (SH1, transfix/libcvc#1566) is still an open
pull request, and SH7 (grants) and SH11 (credentials per principal) aren't started. The components
don't wait for any of them. They're static `load:`s, which every packaged host has had since
3.7. When the shell lands:

- an app the shell mounts (the sublevels client, nicotina) loads its components as it does on its
  own. ARIADNE_SHELL.md 4.12: "What it loads inherits it", so the components run as the app's
  principal and share its credentials;
- under SH11, each app's credentials are its own, so the sublevels client and nicotina, mounted
  side by side in one shell, each sign in once. One sign-in shared between two apps is decision
  CD-4.

## 2. The components

Each component is one file, addressed as `cvc://components/nicotina/<name>.ari` (section 5):

| Component | What it shows and does | From today's |
|---|---|---|
| `session` | No widgets. One site's session: which site, whether it's signed in, who you are, the poll for notifications and new DMs, the posts to the host's bell, and sign-out. Every other component reads it. | `nicotina.ari`'s `init:`, `use-site`, `resume`, `poll`, `signout` |
| `signin` | The sign-in form (username, password, the emailed code, Advanced options, the Site combo with the site's logo and tagline), a new account's form, and in a terminal a **pairing code** (3.5) | `ui/signin.ari` and its commands |
| `profile` | Anyone's profile: the banner, the card, Posts, Replies and Balances, Follow, Message, and your own Settings | `ui/home.ari`, the `profile`/`user`/`tab`/`follow` commands |
| `feed` | The feed (Following, Everyone, Friends) and a hashtag's, the post cards, a post opened whole with its replies and reply box, Like, Dislike, Repost, Delete, a new post with attachments, and the viewer | `ui/feed.ari`, `ui/card.ari`, `ui/social.ari`'s compose and viewer |
| `dm` | Your conversations and one conversation, plaintext and end-to-end encrypted (the `e2ee-*` verbs), and the key controls (Back up, Restore, New keys) | `ui/dm.ari` and the `dm-*` commands |
| `window` | The whole TX.WTF window as today: the bar, Back and Forward, and every view, including tags, alerts, search, mail and admin. It mounts the four above. | `ui/app.ari`, `nicotina.ari`'s windows |
| `api` | No widgets: the functions that call TX.WTF with a session (3.2). A host may import it. | the request helpers in `on_tick:` |

Alerts, search, mail and admin stay inside `window` at first. They can become components of
their own the same way later.

nicotina itself becomes `main.ari`, unchanged, loading `nicotina.ari`, which is now `session`
plus `signin` plus `window`. Section 6 orders the work.

### 2.1 The shape of a component file

Each file holds units, functions and a module, so it follows libcvc's component convention
(ARIADNE.md §6.5) and can be mounted:

```yaml
# feed.ari
meta: {name: TX.WTF feed, min_libcvc: 4.0.9}
requires: [net, net.auth, json-parse, ...]   # what it uses, optional ones marked
import: [api.ari, card.ari]
units:
  feed_view: {...}                           # the view, a group: a host puts it in its own window
  feed_window: {window: TX.WTF feed, ...}    # the same view in a window of its own
functions: |
  (defun feed-step () ...)                   # one command off ui.cmd, the controller's slice
  (defun feed-load (mode before) ...)
  ...
on_tick: (feed-step)                         # mounted, it runs itself
root:
  - include: feed_view                       # mounted, this is what's drawn where the load: stands
```

- **The view is a unit** (`<name>_view`), and so is a window around it (`<name>_window`). The
  `window` component includes the views, and a host that mounts the component gets the view where
  its `load:` stands.
- **The logic is `functions:`**, called by the component's own `on_tick:`. The functions take
  every value they use as a parameter, or read it from state: a function can't see a variable the
  program around it `set` (section 1).
- **A host mounts a component with `load:`. It doesn't `import:` one.** An import would merge
  the component's units and functions, and its state keys, into the host's scope, so a host's
  `ui.*` and the component's would be one. `api` is the exception (3.2).

## 3. How a host mounts them

```yaml
# a host's document
import: cvc://components/nicotina/api.ari     # only for its own calls (3.2)
windows:
  - load: cvc://components/nicotina/session.ari   # always walked: outside any tab (3.3)
    as: tx
    link:
      args:    {to: tx_args, mode: ro}            # site, start, user (3.1)
      session: {to: txwtf, mode: rw}              # the one session (3.2)
  - window: My app
    children:
      - type: tabs
        children:
          - tab: TX.WTF
            children:
              - load: cvc://components/nicotina/window.ari
                as: tx_window
                link:
                  session: {to: txwtf, mode: rw}
                  nav:     {to: tx_nav, mode: rw}  # open requests (3.4)
          - tab: Messages
            children:
              - text: ...                          # the host's own list, which reads txwtf.dm.rows
              - load: cvc://components/nicotina/dm.ari
                as: tx_dm
                link:
                  session: {to: txwtf, mode: rw}
                  ui:      {to: tx_dm_ui, mode: rw}  # its view state and commands (3.1)
```

### 3.1 The link holes

Every component takes the same holes, so a host learns them once:

| Hole | Mode | What it is |
|---|---|---|
| `session` | rw | The one session (3.2). Required by every component but `session` itself, which writes it. |
| `args` | ro | `session` only: `instance` (the site's base URL), `user` (a username to fill in), `start` (the first view, today's `--start` grammar), `sites` (the Site combo's other sites, one a line). |
| `ui` | rw | Optional. The component's view state, and `ui.cmd`, the command it takes next. That's how a host's menu or button drives it (`(state-set "tx_dm_ui.cmd" "dms")`), as `main.ari`'s per-site menus drive `nicotina.ari` today. Without the hole the view state stays in the mount. |
| `nav` | rw | Optional. Open requests (3.4). |

The commands are today's (`home`, `back`, `refresh`, `dms`, `dm-open`, `compose`, ...), each taken
by the component that owns it. Each component has its own `ui.busy`, so the feed can load while a
DM is sent.

### 3.2 One session

The `session` hole is one subtree, which `session` writes and the others read:

```
session.site         the site's base URL ("https://tx.wtf")
session.host         its host, for titles and menus ("tx.wtf")
session.cred         the credential the host keeps the token under ("txwtf.tx.wtf": site-cred)
session.state        out | signing-in | in | closed
session.me.*         id, username, name, avatar, is_admin: you, once signed in
session.site_info.*  name, tagline, version, logo (public /social/site-info)
session.caps.*       what the host can do, asked once (term, pics, media, rich, runs, notify, e2ee ...)
session.cmd          signin-done | signout | refresh-me: what the others ask session to do
session.alerts       the unread notification count
session.dm.unread    the conversations with a message not read here, and their count
session.dm.rows      the conversation list: id, peer, last message's time, encrypted, unread
```

- **The token is never in it.** The host keeps it, as today. `session.cred` is only its name.
- **Signing in once.** `signin` signs in (`/user/login` with `capture_auth` under `session.cred`,
  then the emailed code, or the pairing code of 3.5), then sets `session.cmd` to `signin-done`.
  `session` reads `/user/` into `session.me` and sets `session.state` to `in`. Every other component
  waits for `in` and then makes its requests with `auth: session.cred`. They all use the one token
  the host holds, so there's no second login. A token kept from an earlier run
  (`--credential-store`) is found at start (`net-auth-has?`) and the session resumes, as it does
  today.
- **Signing out.** `session` posts `/user/logout`, drops the credential (`net-auth-forget`), clears
  `session.me` and sets `out`. Each component clears what it holds of the account (its caches,
  drafts, a conversation open) when `session.state` leaves `in`. A component that needs a session
  and has none shows "Signed out of `<host>`" and a **Sign in** button, which asks the host to show
  `signin` (`nav.open: signin`, 3.4).
- **One session a site.** A host that wants several sites mounts one `session` per site, each with
  its own subtree and `session.cred`. The components it mounts for a site link that site's subtree.
  `main.ari` does this today with its slots, and keeps doing it.
- **`api`** is the request layer, in functions that take the session subtree's path:
  `(nic-get S PATH)`, `(nic-get-query S PATH Q)`, `(nic-send S METHOD PATH BODY)`,
  `(nic-signed-in? S)`, `(nic-json R)`, `(nic-ok? R)`. Every function in `api.ari` is named
  `nic-...` and it keeps no state, so a host may import it to make TX.WTF calls of its own with the
  shared session. For example, a host could look up whether a name is a TX.WTF account
  (`GET /user/by-username/{name}`) before it offers that profile.

### 3.3 Where `session` is mounted

A mount that isn't drawn doesn't run (section 1). So `session` must be where the walk always
reaches it, outside any tab, collapsed group or closed window: at the top of `windows:`, as
`main.ari` places `nicotina.ari` today. It has no widgets, so it draws nothing there. The
components that are drawn can come and go with their tabs. `session` keeps the poll, the bell and
the DM count running while they're gone. A view that's mounted again reads what `session` and its
own state under `includes.<as>` kept.

### 3.4 Opening one view from another

A post's author opens a profile, a hashtag opens its feed, and Message on a profile opens a
conversation. Inside `window`, today's Back stack keeps doing that. Between components the host
mounted, the component writes the view it wants opened to its `nav` hole, in today's `--start`
grammar:

```
nav.open    post:ID | tag:NAME | user:ID | profile | dm:ID | dms | compose | signin | ...
nav.from    the component that asked (feed, profile, dm, ...)
```

The host reads `nav.open`, shows the view (it switches to its tab, say, and sets that component's
`ui.cmd`), and clears it. A host that doesn't link `nav` gets the behaviour inside the component:
`feed` opens a post in place, and asks for what it doesn't hold (a profile, a DM) through the
`window` component if the host mounted one, or does nothing.

### 3.5 Signing in with a pairing code

The terminal's sign-in in the roadmap (L7, M1) is a pairing code: the device grant (RFC 8628).
libcvc has had it since transfix/libcvc#916 (`oidc-sign-in` with `flow: device`, token
`oidc.device`). TX.WTF has had it since atx-crypto-club/txwtf#315 (`/oauth/device_authorization`,
and `POST /user/login/oidc`, which trades a `txwtf.api` access token for a TX.WTF session).

- `signin` offers **Sign in with a code** where the host has `oidc.device`, first in a terminal (and
  over SSH), beside the password form. It shows the site's address to visit and the code, and
  waits.
- Once the code is entered on another device, the host keeps the OIDC tokens under
  `<cred>.oidc`. `signin` posts `/user/login/oidc` with `auth: <cred>.oidc` and `capture_auth`
  under `session.cred`. From then on it's the same session as a password sign-in, and the
  rest of 3.2 doesn't change.
- **What it needs on each site:** a public, first-party nicotina OIDC client with the device grant
  (`txwtf register-oidc-client --name nicotina --public --first-party --device-grant ...`, txwtf
  TODO item 8). No site has one yet. Registering one on each fleet site is a deploy step, and
  it's Joe's call (CD-5).
- A host without `oidc.device`, or a site without the client, shows the password form alone, as
  today.

## 4. What a host gets, and what it doesn't

- **It gets** the views where it puts them, its own sign-in once for all of them, the published
  rows (`session.dm.rows`, `session.alerts`), the commands (`ui.cmd`) and the open requests
  (`nav.open`).
- **It doesn't get** the token or the keys (they're the host's, as in nicotina), nicotina's menus
  (a mounted component without a `menubar:` adds none: the host's menus send its commands), or
  nicotina's tray. `session` posts TX.WTF's notifications and new DMs to the host's one
  notification feed, named by the site, so the host's bell shows them. A host that wants nicotina's
  mail icon draws its own `tray_icon:` from `session.dm.unread`, as `main.ari` does.
- **The E2EE store is locked to one running client.** A host that mounts `dm` passes its own
  `--e2ee-store`. Running beside nicotina, it can't open nicotina's store (CD-4).

## 5. Packages and where the files go

In the repository, the components go in `share/nicotina/components/`, beside the app's documents.
`nicotina.ari` imports and loads them by relative path (`components/feed.ari`). A relative path
works the same from a checkout, from an install, and from the browser pages, which load the
documents over https from beside the page (`deploy/cyberpcangel/stage.sh` copies
`share/nicotina/` whole).

Two cvcpkg recipes, in this repository's `recipes/` (as cy-pca/sublevels keeps its own), both
documents only and one build for every platform:

| Package | Installs | Depends on |
|---|---|---|
| `nicotina-components` | `share/nicotina/components/*.ari`; and for each, a one-line shim `share/libcvc/ariadne/components/nicotina/<name>.ari` (`import:` of the real file, or a `load:` passing its holes on: settled in N5), so `cvc://components/nicotina/<name>.ari` resolves in any stock host installed in the same prefix with no flag | `ari` or `arigl` at the `min_libcvc` the components declare (runtime) |
| `nicotina` | `share/nicotina/main.ari`, `nicotina.ari`, `fleet.policy`, `bin/nicotina`, `bin/nicotina.cmd` | `nicotina-components` (the same version), `ari`, `arigl` |

- `nicotina-components` names no app. It ships no launcher and no `fleet.policy`. The host app
  passes its own `--net-allow` or `--net-policy`, `--credential-store` and `--e2ee-store`.
- A host in the browser can't resolve `cvc://components/nicotina/` (a page's wasm build carries only
  libcvc's own components). It loads the components by https URL from a site that serves them, for
  example a TX.WTF instance's `/apps/nicotina/components/`, or stages its own copy beside its page.
- Publishing is Joe's call: the versions, the cvcpkg organisation (cy-pca, as sublevels), and a
  publish workflow like cy-pca/sublevels' `publish-sublevels.yml`.

## 6. The work, in pull requests

Each step is one pull request with tests. nicotina behaves the same at every step.

| Step | What | Tests |
|---|---|---|
| N1 | This note | none |
| N2 | **The logic as functions.** The 288 `defun`s move out of `on_tick:` into `functions:` in the files that will be the components. Each free variable a body reads (`WIDE`, `CARD`, `PAGE`, `MAILPAGE`, `cmd`, `NO` ...) becomes a parameter or a function. `on_tick:` keeps only the dispatch. No state key changes. | run.sh, local.sh and e2ee.sh unchanged and passing; `ari validate` on every file. A frame-time check: the functions are a prelude to every program (ARIADNE.md §6.6), so each `on:` pays for them. Measure, and split the prelude per component if it costs too much. |
| N3 | **One session.** The keys of 3.2 (`app.base`, `app.cred`, `me.*`, `site_info.*`, `news.*`, the DM unread counts, the host's capabilities) move under `session.*`. `session.ari` takes `use-site`, resume, the poll, the bell and sign-out. `nicotina.ari` loads it and links it. `api.ari` gets the request helpers. | as N2, and a check that no `session.*` key ever holds a token |
| N4 | **The views as components.** `signin`, `profile`, `feed` and `dm` become mountable: their own `ui.cmd`, `ui.busy` and controller step, the holes of 3.1, `nav.open`. `window` mounts them and keeps the Back stack. `nicotina.ari` becomes `session` + `signin` + `window`. `tests/host.ari`, a host that isn't nicotina (a window of its own with tabs, a text of its own, `session` outside them, `feed`, `profile` and `dm` in tabs, and `nav.open` routed), runs against `tests/stub_txwtf.py`. | `ari snapshot` of `tests/host.ari` in FTXUI and tvision, and `arigl snapshot`, signed in once: the stub counts one `/user/login` while all three components make authorized requests. Sign out in one, and the others say they're signed out. tmux walks: a card's author opens the profile tab, and Message opens the DM. Then run.sh, local.sh and e2ee.sh as before. |
| N5 | **The packages.** `recipes/nicotina-components/` and `recipes/nicotina/`, the shims, the README's install section. CI builds both from the checkout into a prefix and runs `tests/host.ari` there through `cvc://components/nicotina/...` with no `--component-path`. | that CI job, and run.sh against the installed `nicotina` |
| N6 | **The pairing code** (3.5) in `signin`, where the host has `oidc.device` and the site has a nicotina client | the stub grows the device endpoints and `/user/login/oidc`. `ari snapshot` shows the code in FTXUI and tvision. A tmux run approves it at the stub and lands signed in. local.sh runs it against a local txwtf with the client registered. |

N2 and N3 change no behaviour, so they can merge before N4 is written. N6 doesn't depend on N4
or N5: it can be written into today's `ui/signin.ari` and move with it.

The consumer's own work, mounting these components in the sublevels shell (§4.1) and listing
`session.dm.rows` beside NMDC PMs in its conversations (§4.3), is sublevels' own, after N4. That's
the reason for `tests/host.ari`: it's the contract test on this side, so nicotina never needs
sublevels to test its components.

## 7. Decisions for Joe

| # | Question | Recommended |
|---|---|---|
| CD-1 | Mount (`load:`) or import? | **Mount.** A component's state stays its own, and the host talks to it through holes. Only `api` is imported. Importing all of them would put every component's keys and its 290 functions in the host's scope. |
| CD-2 | Which components first? | `session`, `signin`, `profile`, `feed`, `dm`, `window` (section 2). Alerts, search, mail and admin come later, on request. |
| CD-3 | Where do the files go? | `share/nicotina/components/` in the repository and the install, with shims under `share/libcvc/ariadne/components/nicotina/` for `cvc://` (section 5). |
| CD-4 | Do two apps share one TX.WTF sign-in (nicotina and the sublevels client, side by side)? | **No, each app signs in once.** Each app keeps its own `--credential-store` and `--e2ee-store`. The E2EE store is locked to one running client, and SH11 splits credentials per app anyway. The cost: TX.WTF's E2EE sessions are per device, so an encrypted conversation started in nicotina shows as "encrypted on another device" in the other app, as it does between a phone and a desktop today. |
| CD-5 | The pairing code needs a nicotina OIDC client on each fleet site. Register them? | Yes, as a deploy step on each site, with one client id everywhere if `register-oidc-client` can be given one (not checked); otherwise a table in `site.ari`. Until then `signin` offers the password form alone. |
| CD-6 | The packages: names, organisation, versions | `nicotina-components` and `nicotina`, under cy-pca, both starting at nicotina's `meta.version` (0.0.1) and moving together. |

## 8. Not in scope

- Anything Direct Connect: hubs, file sharing, NMDC private messages, hub ports, share folders.
  That's the sublevels client's.
- Merging a person's TX.WTF and NMDC conversations: sublevels' CU-D6. `dm` publishes its rows, and
  the host does the merging.
- cyprty's conference components, which need the same treatment in cy-pca/cyprty.
- libcvc changes. Everything above runs on the packaged hosts, 4.0.9. If N4 finds a gap (a
  mounted component's widgets reached by a host's `keys:`, say), it goes to libcvc as a generic
  feature, as every L-item has.
