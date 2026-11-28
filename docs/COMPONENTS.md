# nicotina's components: design

*Draft, 2026-11-26. Step N2 is cy-pca/nicotina#47; the rest isn't built. Section 7 lists the decisions, the ones taken and the ones open.*

nicotina's TX.WTF views become components that another Ariadne app can mount beside its own
views: sign-in, the profile, the feed and posts, and direct messages. The first app to use them
is the sublevels client (cy-pca/sublevels `client/`, `docs/CLIENT_UI.md` §1, §4.1, §4.3, CU-D3,
CU-D5). It mounts these views in its own window, signed in once to TX.WTF, and lists TX.WTF DMs
in its one list of conversations.

**The dependency runs one way.** The sublevels client depends on nicotina's components. nicotina
depends on nothing from sublevels or Direct Connect (Joe, 2026-11-26: "nicotina is really just
meant to communicate with txwtf, sublevels-client should build on that"). The components are
TX.WTF only. They have no Direct Connect code, no hub ports and no DC host features. Where this
note names sublevels, it's as a consumer whose own design lives in cy-pca/sublevels.

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

Every name in the host's state is the site's, so the raw state tree says what each subtree is
(3.6 spells the names). One site:

```yaml
# a host's document
import: cvc://components/nicotina/api.ari     # only for its own calls (3.2)
windows:
  - load: cvc://components/nicotina/session.ari   # always walked: outside any tab (3.3)
    as: tx_wtf                                    # its state: includes.tx_wtf
    link:
      args:    {to: sites.tx_wtf, mode: ro}       # instance, user, start (3.1)
      session: {to: sessions.tx_wtf, mode: rw}    # the one session (3.2)
  - window: My app
    children:
      - type: tabs
        children:
          - tab: TX.WTF
            children:
              - load: cvc://components/nicotina/window.ari
                as: tx_wtf_window
                link:
                  session: {to: sessions.tx_wtf, mode: rw}
                  nav:     {to: nav.tx_wtf, mode: rw}       # open requests (3.4)
          - tab: Messages
            children:
              - text: ...                       # the host's own list: sessions.tx_wtf.dm.rows
              - load: cvc://components/nicotina/dm.ari
                as: tx_wtf_dm
                link:
                  session: {to: sessions.tx_wtf, mode: rw}
                  ui:      {to: ui.tx_wtf_dm, mode: rw}     # its view state and commands (3.1)
```

### 3.1 The link holes

Every component takes the same holes, so a host learns them once:

| Hole | Mode | What it is |
|---|---|---|
| `session` | rw | The one session (3.2). Required by every component but `session` itself, which writes it. |
| `args` | ro | `session` only: `instance` (the site's base URL), `user` (a username to fill in), `start` (the first view, today's `--start` grammar), `sites` (the Site combo's other sites, one a line). |
| `ui` | rw | Optional. The component's view state, and `ui.cmd`, the command it takes next. That's how a host's menu or button drives it (`(state-set "ui.tx_wtf_dm.cmd" "dms")`), as `main.ari`'s per-site menus drive `nicotina.ari` today. Without the hole the view state stays in the mount. |
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
session.state        out | guest | signing-in | in | closed (3.7)
session.me.*         id, username, name, avatar, is_admin: you, once signed in
session.site_info.*  name, tagline, version, logo (public /social/site-info)
session.caps.*       what the host can do, asked once (term, pics, media, rich, runs, notify, e2ee ...)
session.cmd          signin-done | adopt | guest | signout | refresh-me: what the others, or the host, ask
                     session to do (3.7, 3.8)
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
  its own subtree and `session.cred`. The components it mounts for a site link that site's subtree
  (3.6).
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

**Why.** A terminal, above all one over SSH, has no browser to send a sign-in to. A password works
there, but not for everyone. A federated user (one who signs in "with your home instance", from
another site in the ring) has no password at this site. And a password typed into a shared machine
is the weakest way in. The roadmap's answer for the terminal (L7, M1) is a pairing code, OAuth's
device grant (RFC 8628):

1. `signin` asks the site for a code. It shows an address and the code (`Visit
   https://tx.wtf/oauth/device and enter WDJB-MJHT`), and where the host draws pictures, a QR code
   of the address.
2. You open the address on any device with a browser, your phone say, sign in there as you always
   do (password and emailed code, or your home instance), and approve "nicotina".
3. `signin` has been polling the site. Once you approve, the host gets OpenID Connect tokens and
   keeps them as `<cred>.oidc`. The document never sees them.
4. `signin` posts `/user/login/oidc` with `auth: <cred>.oidc` and `capture_auth` under
   `session.cred`. TX.WTF trades the access token, which carries its `txwtf.api` scope, for an
   ordinary TX.WTF session, the same kind a password sign-in gives. From there everything in 3.2
   is unchanged.

**What exists.**

- libcvc: `oidc-sign-in` with `flow: device`, the token `oidc.device`, and the tokens kept in the
  credential store (transfix/libcvc#916, merged 2026-10-31).
- txwtf: `/oauth/device_authorization`, the device pages, the device grant at `/oauth/token`, and
  `POST /user/login/oidc` (atx-crypto-club/txwtf#315, merged 2026-11-07). Federated users join the
  default group, so their sessions can use the API (atx-crypto-club/txwtf#318).

**What's missing,** checked 2026-11-26 against tx.wtf, dev.tx.wtf and social.sublevels.net:

1. **The sites run txwtf 0.4.0** (their `/social/site-info`). Their discovery documents
   (`/.well-known/openid-configuration`) list no `device_authorization_endpoint`, and only the
   `authorization_code` and `refresh_token` grants. Each site needs a txwtf with #315. That should
   be 0.5.0 (published 2026-11-15), but I haven't checked that 0.5.0 carries it.
2. **No site has a nicotina client.** Each needs a public, first-party client with the device grant
   and the `txwtf.api` scope, made on the site's server: `txwtf register-oidc-client --name nicotina
   --public --first-party --device-grant --redirect-uri http://127.0.0.1/callback --redirect-uri
   https://<site>/apps/nicotina/ --scopes "openid profile offline_access txwtf.api"` (txwtf TODO
   item 8). Discovery advertises the device grant once a client allows it.
3. **nicotina has to know each site's client id.** If `register-oidc-client` can be given the id,
   use `nicotina` at every site. If not, a table in `site.ari` (or the launcher's `--oidc-client
   ISSUER=ID`) holds them. I haven't checked which.
4. **nicotina's side** is step N6.

Items 1 and 2 are deploys to production sites, so they're Joe's call (CD-5). Until a site has both,
`signin` there shows the password form alone, as today. A host without `oidc.device` does the same.

### 3.6 Several sites at once

A host can be signed in to several TX.WTF sites at once, with one or more views on each. It mounts
one `session` per site, and each view links the subtree of the site it shows.

**Names.** Everything the host keeps for a site is named by the site's **key**: its host in lower
case, with every character that isn't a letter or a digit made `_`, and the port when it has one.
`site.ari` gains `(site-key URL)` for it.

| Site | Key | Its session | Its mounts |
|---|---|---|---|
| `https://tx.wtf` | `tx_wtf` | `sessions.tx_wtf` | `tx_wtf`, `tx_wtf_feed`, `tx_wtf_dm` |
| `https://social.sublevels.net` | `social_sublevels_net` | `sessions.social_sublevels_net` | `social_sublevels_net`, ... |
| `http://127.0.0.1:8000` (a test stub) | `127_0_0_1_8000` | `sessions.127_0_0_1_8000` | ... |

The credential keeps its name, `txwtf.<host>` (`site-cred`). Two hosts that come to one key
(`a-b.com` and `a.b.com`) are told apart by `_2`, as the loader tells apart two mounts of one name.

**Two sites, a feed each, and one list of their conversations:**

```yaml
windows:
  - load: cvc://components/nicotina/session.ari
    as: tx_wtf
    link: {args: {to: sites.tx_wtf, mode: ro}, session: {to: sessions.tx_wtf, mode: rw}}
  - load: cvc://components/nicotina/session.ari
    as: social_sublevels_net
    link: {args: {to: sites.social_sublevels_net, mode: ro},
           session: {to: sessions.social_sublevels_net, mode: rw}}
  - window: Feeds
    children:
      - type: group                      # side by side
        layout: {kind: horizontal}
        children:
          - load: cvc://components/nicotina/feed.ari
            as: tx_wtf_feed
            link: {session: {to: sessions.tx_wtf, mode: rw}, nav: {to: nav.tx_wtf, mode: rw}}
          - load: cvc://components/nicotina/feed.ari
            as: social_sublevels_net_feed
            link: {session: {to: sessions.social_sublevels_net, mode: rw},
                   nav: {to: nav.social_sublevels_net, mode: rw}}
  - window: Messages
    children:
      - text: ...    # the host's list: sessions.tx_wtf.dm.rows and sessions.social_sublevels_net.dm.rows,
                     # each row badged with its site
```

- **Each session is its own:** its sign-in, its token, its poll, its notifications. Each posts to
  the host's one notification feed, named by its site, as nicotina's copies do today.
- **One account a site.** The credential is named by the site's host, so a host can't be signed
  in to two accounts on one site at once. That's nicotina's rule today.
- **Which site a request came from:** `nav.open` says what to open, not where. The host gives
  each site's views their own `nav` hole (`nav.tx_wtf`), so it knows. A merged list badges each
  row with its site.
- **Several views on one site** link the same `sessions.<key>`, as the one-site example does.
- **Every `session` mount is outside tabs** (3.3), one for each site.

**A fixed list of sites, or one that grows.** A host that knows its sites writes one `load:` for
each, as above. A host where the user adds sites while it runs (nicotina's Site combo, its
**Sign in to another site**) needs one more generic libcvc feature, because `repeat:` names its
instances by number only (`{i}`):

- **L27 (libcvc, transfix/libcvc#1585, open):** a repeated `load:` over the children of a state key, with `{key}`, each child's
  name, filled in wherever `{i}` is: `as:`, the `link:` targets and `name:`. Then
  `repeat: {children: sites}` with `as: "{key}"` and `session: {to: "sessions.{key}"}` mounts one
  session for each child of `sites`, each named by its site. ARIADNE_SHELL.md's `mounts:` names its
  entries by key already, but gives them no link holes (4.2: "a later version may take `link:`
  ... per entry"). Either one would do. L27 is the smaller.
- **Until L27,** `main.ari` keeps its numbered slots (`slots.<i>`). It also writes `slot_of.<key>`
  (`slot_of.tx_wtf: 0`), so the raw state tree says which slot is which site.

### 3.7 Guests: browsing without signing in

A guest reads a site's public posts and media and can't do anything that needs an account. It's a
state of `session`: `session.state` is `guest` (alongside `out`, `signing-in`, `in` and `closed`),
with no credential and no `session.me`.

- **What a guest sees:** the public feed, a post with its replies, hashtags and their feeds, search,
  pictures and video, and the site's own page. These calls use txwtf's public routes, which
  tx.wtf's 0.4.0 already answers without a session (checked 2026-11-26):

  | Route | Without a session |
  |---|---|
  | `GET /social/timeline/public/feed` | 200 |
  | `GET /social/posts/{id}/public`, `/social/posts/{id}/replies/public` | 200 |
  | `GET /social/tags`, `/search/search` | 200 |
  | `GET /social/site-info` | 200 |
  | `GET /social/timeline/public`, `/social/posts/{id}` (what nicotina signed in calls) | 401 |
  | `GET /user/profile/{id}` | 401 |

- **What a guest can't do:** like, repost, reply, post, follow, DMs, notifications, mail, admin.
  Where a signed-in client shows one of those buttons, a guest sees **Sign in to like** (and so on),
  which sets `nav.open: signin` (3.4).
- **Starting as a guest:** the sign-in form gets **Browse as a guest**, and a host can start a
  session there (`args.start: guest`). Signing in from a guest session keeps the view you were on.
- **Missing in txwtf** (so it isn't nicotina's to build):
  - a public profile route, a `/public` variant of `/user/profile/{id}` that leaves out what only
    followers may see. Until it exists, a guest's author name opens nothing;
  - an instance setting that turns guest browsing off (`allow_anonymous_browsing`, say). Nothing
    like it exists today; the public routes are always open.
- **The same guest everywhere.** The sublevels app's guests (3.8) are guests on the hub, in a
  conference room, and on TX.WTF at once, so a guest here is just `session` with no credential.

### 3.8 One identity with the host app

nicotina signs in to TX.WTF and nothing else. A host whose own identity spans more services than
TX.WTF, such as the sublevels app (TX.WTF, a conference room on arisrvx, an NMDC hub), signs in once
for all of them. It hands nicotina's components the TX.WTF part, so they never ask again:

- **Adopting a session.** The host signs in by any route its design picks. It ends with a TX.WTF
  session token kept by the host under `session.cred`, for example from `/user/login/oidc` with an
  OIDC token the host already holds. Then it sets `session.cmd` to `adopt`. `session` checks the
  credential (`net-auth-has?`), reads `/user/` into `session.me`, and goes to `in`, as its resume
  does today. `signin` isn't mounted at all.
- **Guests:** a host with no TX.WTF credential sets `session.cmd` to `guest` (3.7).
- **Signing out:** `session.cmd: signout` signs out of TX.WTF only. A host that wants one sign-out
  for everything does its own and then sends that.
- **What nicotina doesn't do:** link a TX.WTF account to a hub nick or a conference identity, or
  know that arisrv exists. That's the host's design. For the sublevels app it belongs in
  cy-pca/sublevels (its roadmap already says "Identity is TX.WTF's") and in txwtf, not here.

## 4. What a host gets, and what it doesn't

- **It gets** the views where it puts them, its own sign-in once for all of them, the published
  rows (`session.dm.rows`, `session.alerts`), the commands (`ui.cmd`) and the open requests
  (`nav.open`).
- **It doesn't get** the token or the keys (they're the host's, as in nicotina), nicotina's menus
  (a mounted component without a `menubar:` adds none: the host's menus send its commands), or
  nicotina's tray. `session` posts TX.WTF's notifications and new DMs to the host's one
  notification feed, named by the site, so the host's bell shows them. A host that wants nicotina's
  mail icon draws its own `tray_icon:` from `session.dm.unread`, as `main.ari` does.

### 4.1 Encrypted DMs in every client

The goal is an encrypted conversation readable and writable from every client that has the
`e2ee-*` verbs. That means several sites in one app, two apps on one machine, the browser, and a
phone beside a desktop. Today's pieces, read in libcvc master, nicotina and txwtf 0.6.0:

- **The key store** (`--e2ee-store`, libcvc `cvc::net::E2eeStore`) is one JSON file. It holds
  any number of *handles*, each with its own identity and its sessions by conversation. Every
  verb names the handle it acts on. nicotina's handle is `txwtf.<host>.<user id>`.
- **It is locked to one store object:** an exclusive lock on `<file>.lock`, held while the store
  is open. A second process gets "the E2EE store ... is in use by another process", and so does a
  second app in the same process. Inside one app, every document and mount shares the one store.
- **TX.WTF keeps one identity per account, not per device.** The server keeps one identity row
  per user. Publishing a different one wipes that user's signed prekey and one-time prekeys. A
  message carries one wrapped key per recipient *user*, and its sessions are keyed by conversation
  only. txwtf's own docs list "per-device identity, no automatic multi-device restore" as a known
  limit.
- **The backup** (`/e2ee/backup`, Argon2id) carries the identity and the signed prekey. It doesn't
  carry the sessions. Two clients restored from one backup share an identity, but each has its own
  ratchet: whichever opens a message first advances, and the other can't read it.
- **The browser has no store yet.** libsodium builds for wasm, but the store refuses to open
  there. A ratchet kept only in memory would die with the page and break the peer's
  (libcvc `docs/E2EE.md`). The next step there is a store on IndexedDB (IDBFS), synced after every
  write.

So, case by case:

| Case | Today | What it needs |
|---|---|---|
| Several sites and accounts in one app | **Works:** one store, a handle per site and account | One fix (N3): the handle is cut at 64 characters, so a host name longer than about 48 drops the user id, and two accounts there would share a handle. Hash a long host instead, and put the scheme in. |
| The sublevels app mounting `dm` | **Works:** the components share the app's store | Nothing: they're one app, so one store and one principal (SH11 keeps it so) |
| nicotina and the sublevels app running at once | **One of them holds the store** | Both must use the **same** store file. If each made its own, each would publish its own identity for the account, wiping the other's prekeys, which TX.WTF's one identity per account can't survive. The app that opens second sees the store in use, and its DMs say so. A store broker (one process holding the lock, the others asking it) would lift this. It's a libcvc feature, not designed. |
| The browser (arigl-web) | **No encrypted DMs** | libcvc: the IDBFS store, and a lock across tabs (Web Locks). Even then, the page and a native app are two copies of one identity, with the same problem as the backup above. |
| A phone and a desktop, or the browser and a native app | **One device holds the account's DMs** | **Multi-device E2EE in TX.WTF**, below |

**Multi-device E2EE** is the change that makes "every client that supports it" true. Nothing
plans it today: not txwtf, not libcvc, not any tracker. It's what Signal calls Sesame: each
device has its own keys, and a sender encrypts to every device of the recipient and to its own
other devices.

- **txwtf:**
  - a device id on the identity and prekey rows (unique on user and device, not user);
  - `GET /e2ee/keys/{user}` returning every device's bundle;
  - a wrapped key per (recipient, device), the sender's own other devices included;
  - a device list with revocation;
  - publishing one device's keys stops wiping the others'.
- **txwtf's web app (`e2ee.js`):** a store keyed by user and device, sessions by conversation and
  peer device, and a send that seals for each device. A new algorithm version (`dr-v2`) keeps
  today's clients reading.
- **libcvc:** a device id per handle, sessions by (conversation, peer, peer device), and seal
  verbs that take a list of bundles and return a list of wrapped keys.
- **nicotina:** its `dm` component seals with the new verbs where the host has them, and lists the
  account's devices beside the key controls. Today's single-device path stays for hosts without
  them.

That is a protocol change in txwtf first. nicotina's part is the last step (N7, section 6), and
it's CD-8.

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
| N3 | **One session.** The keys of 3.2 (`app.base`, `app.cred`, `me.*`, `site_info.*`, `news.*`, the DM unread counts, the host's capabilities) move under `session.*`. `session.ari` takes `use-site`, resume, the poll, the bell and sign-out. `nicotina.ari` loads it and links it. `api.ari` gets the request helpers. `site.ari` gets `site-key`, and `main.ari` writes `slot_of.<key>` (3.6). `session.cmd` takes `adopt` (3.8). The E2EE handle stops dropping the user id on a long host name (4.1). | as N2; a check that no `session.*` key ever holds a token; a host that adopts a session it made itself, and no `/user/login` from nicotina; two accounts on a 60-character host get two handles |
| N4 | **The views as components.** `signin`, `profile`, `feed` and `dm` become mountable: their own `ui.cmd`, `ui.busy` and controller step, the holes of 3.1, `nav.open`. `window` mounts them and keeps the Back stack. `nicotina.ari` becomes `session` + `signin` + `window`. `tests/host.ari`, a host that isn't nicotina (a window of its own with tabs, a text of its own, `session` outside them, `feed`, `profile` and `dm` in tabs, and `nav.open` routed), runs against `tests/stub_txwtf.py`. | `ari snapshot` of `tests/host.ari` in FTXUI and tvision, and `arigl snapshot`, signed in once: the stub counts one `/user/login` while all three components make authorized requests. Sign out in one, and the others say they're signed out. tmux walks: a card's author opens the profile tab, and Message opens the DM. **Two sites** (3.6): `tests/host.ari --two` mounts two sessions against two stubs on two ports, a feed on each side by side and one list of both sites' conversations. Each stub counts one `/user/login` and sees only its own token; signing out of one leaves the other signed in. Where the host has the `e2ee-*` verbs, `tests/e2ee.sh --two` does a round trip with e2ee.js on each site from one store, and checks the store holds two handles. Then run.sh, local.sh and e2ee.sh as before. |
| N4b | **Guests** (3.7): `session.state: guest`, **Browse as a guest** on the sign-in form, the public routes for the feed, posts, replies, tags and search, and **Sign in to ...** in place of what needs an account | `ari snapshot` of the feed, a post and search as a guest in FTXUI and tvision: the stub sees no `Authorization` header on any request; Like reads **Sign in to like**, and opens the sign-in form; signing in from there keeps the post open |
| N5 | **The packages.** `recipes/nicotina-components/` and `recipes/nicotina/`, the shims, the README's install section. CI builds both from the checkout into a prefix and runs `tests/host.ari` there through `cvc://components/nicotina/...` with no `--component-path`. | that CI job, and run.sh against the installed `nicotina` |
| N6 | **The pairing code** (3.5) in `signin`, where the host has `oidc.device` and the site has a nicotina client | the stub grows the device endpoints and `/user/login/oidc`. `ari snapshot` shows the code in FTXUI and tvision. A tmux run approves it at the stub and lands signed in. local.sh runs it against a local txwtf with the client registered. |
| N7 | **Multi-device DMs** (4.1), once txwtf and libcvc have them: `dm` seals for every device of a conversation's people, and lists your own devices beside the key controls | the stub with two devices for one account: a message sent from one is read on both, and on a peer's two |

N2 and N3 change no behaviour, so they can merge before N4 is written. N6 doesn't depend on N4
or N5: it can be written into today's `ui/signin.ari` and move with it.

The consumer's own work, mounting these components in the sublevels shell (§4.1) and listing
`session.dm.rows` beside NMDC PMs in its conversations (§4.3), is sublevels' own, after N4. That's
the reason for `tests/host.ari`: it's the contract test on this side, so nicotina never needs
sublevels to test its components.

## 7. Decisions for Joe

| # | Question | Recommended |
|---|---|---|
| CD-1 | Mount (`load:`) or import? | **Decided (Joe, 2026-11-26): mount.** A component's state stays its own, and the host talks to it through holes. Only `api` is imported. |
| CD-2 | Which components first? | `session`, `signin`, `profile`, `feed`, `dm`, `window` (section 2). Alerts, search, mail and admin come later, on request. |
| CD-3 | Where do the files go? | `share/nicotina/components/` in the repository and the install, with shims under `share/libcvc/ariadne/components/nicotina/` for `cvc://` (section 5). |
| CD-4 | Do two apps on one machine (nicotina and the sublevels app) share their sign-in and their keys? | **Revised after reading the E2EE code (4.1).** Each app keeps its own `--credential-store`, so each signs in once. But both point `--e2ee-store` at **the same file**. Separate stores would each publish an identity for the account and wipe the other's prekeys, because TX.WTF keeps one identity per account. Only one app at a time holds the store; the other's DMs say it's in use. Multi-device E2EE (CD-8) removes the limit. |
| CD-5 | The pairing code needs a nicotina OIDC client on each fleet site. Register them? | Yes, as a deploy step on each site, with one client id everywhere if `register-oidc-client` can be given one (not checked); otherwise a table in `site.ari`. Until then `signin` offers the password form alone. |
| CD-6 | The packages: names, organisation, versions | `nicotina-components` and `nicotina`, under cy-pca, both starting at nicotina's `meta.version` (0.0.1) and moving together. |
| CD-7 | Guests (3.7) | Yes, in N4b. txwtf adds a public profile route and a setting that turns guest browsing off. Both are txwtf changes; nicotina works without them, with authors' names that open nothing for a guest. |
| CD-8 | Multi-device E2EE in TX.WTF (4.1, designed in cy-pca/txwtf#18), the only way to encrypted DMs in every client: phone, browser and desktop at once | **Yes, as a txwtf protocol change first** (device ids, every device's bundle, a wrapped key per device, `dr-v2`), then libcvc's store and verbs, then nicotina (N7). It needs a design in txwtf before any code. |
| CD-9 | One identity across TX.WTF, the conference rooms and the hub (3.8) | **TX.WTF's account is the root,** as sublevels' roadmap already says: arisrvx's authenticate hook accepts the TX.WTF session, and the device key proves the device. That design is cy-pca/sublevels#39. nicotina's part is `adopt` and guests. |
| CD-10 | Site-named mounts for sites added while running (3.6) | L27, a repeated `load:` over a key's children with `{key}` (transfix/libcvc#1585, open). Until it's in a release, `slot_of.<key>`. |

## 8. Not in scope

- Anything Direct Connect: hubs, file sharing, NMDC private messages, hub ports, share folders.
  That's the sublevels client's.
- Merging a person's TX.WTF and NMDC conversations: sublevels' CU-D6. `dm` publishes its rows, and
  the host does the merging.
- cyprty's conference components, which need the same treatment in cy-pca/cyprty.
- The libcvc, txwtf and sublevels work this note asks for, which each repository designs and
  builds:
  - libcvc: L27, the browser's E2EE store, a store broker, and the multi-device verbs;
  - txwtf: the public profile route, the guest setting, multi-device E2EE, and deploying a txwtf
    with the device grant;
  - sublevels: the unified identity of CD-9.

  N2 to N6 run on the packaged hosts, 4.0.9. If N4 finds another gap (a mounted component's
  widgets reached by a host's `keys:`, say), it goes to libcvc as a generic feature, as every
  L-item has.
