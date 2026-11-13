# Roadmap

Every milestone ends with the same documents running in three places, all
against a development TX.WTF instance:

- **stock** `arigl`;
- **stock** `ari` in a terminal, with both the FTXUI and tvision backends;
- the browser.

**The terminal is first-class.** A feature isn't done until it works and is
covered by an `ari snapshot` test in the terminal. Where the terminal can't do
something the same way, design an equivalent: images become half-block
renders, and browser sign-in becomes a pairing code.

Because the client is documents only, any feature it needs from a host has to
be a **generic** Ariadne feature in libcvc, available through host flags or the
document itself. Those features are tracked as L-items below. Server-side work
on TX.WTF is tracked as T-items in the TX.WTF repository.

## libcvc features the client needs

| # | Feature | Needed by |
|---|---------|-----------|
| L1 | Hosts can turn on the HTTP verbs and the `http(s)://` URI handler, with an origin allowlist that denies by default | M0 |
| L2 | Host-owned credentials: `auth: <name>` injects a Bearer header for bound origins; a login token is captured from the response and redacted; optional persistence in a 0600 file. Tokens never enter state | M0 |
| L3 | `json-parse` / `json-encode` verbs, and response headers visible to documents | M0 |
| L4 | Async fetch on the single-threaded wasm scheduler | M3 (streaming) |
| L5 | Multi-line text input, a scrolling or virtualized list, wrapped text, and images from `https://`, in ImGui **and both terminal backends** (FTXUI, tvision) | M1 |
| L6 | A general WebSocket verb whose frames arrive as `on_signal` | M1 |
| L7 | Sign-in with auth code + PKCE: loopback plus the system browser natively, redirect in wasm, and for `ari`, a pairing or device-code grant that works over SSH without a local browser | M1 |
| L8 | A generic arigl wasm shell that loads `?src=<same-origin .ari URL>` | M0 (browser) |
| L9 | `open-url`: the system browser natively, `window.open` in wasm | M3 |
| L10 | An `arigl` cvcpkg package (today only `ari` has one) and the wasm shell as a package | M0 |
| L11 | A masked `input_text` for passwords, in ImGui **and both terminal backends** (`password: true`, transfix/libcvc#906, merged); still wanted: a host-held secret field that keeps it out of state | M0 |
| L12 | `{i}` substituted in a repeated widget's `on_click`, `on_hover`, `on_drag*`, `on_top`, `hint` and `send` (today only `on:` and the binds are) | M2 |
| L13 | A whole group clickable (`on_click:` on a card), with a hover highlight; in a terminal the group takes the focus and Enter fires it. Then a card opens its post and a picture the viewer | M2 |
| L14 | `(clipboard-set TEXT)`: the system clipboard in ImGui and the browser, OSC 52 in a terminal. Copy link | M2 |
| L15 | Rich text: runs with links (hashtags, @mentions, URLs) a click follows, and word wrap, built on the emoji runs of transfix/libcvc#1052 (`runs:` on a `text:`, token `text.runs`: transfix/libcvc#1180) | M2 |
| L16 | Fullscreen for `video:` and `image:`: the OS window, or the browser's fullscreen | M2 |
| L17 | `message_input:` tells the document each edit (a live count, and #tag and @mention completion) | M2 |
| L18 | A file picker that hands the document a host-held file, read in chunks into TX.WTF's resumable upload: attachments (`file-pick` and `http-upload`, transfix/libcvc#1190; the compose view's Attach) | M2 |
| L19 | `(time-now)`: the wall clock, for "2h ago" | M2 |
| L20 | Wheel scrolling of a window in FTXUI and tvision | M2 |
| L21 | End-to-end encrypted messaging in the host: TX.WTF's X3DH and Double Ratchet over libsodium (X25519, Ed25519, XChaCha20-Poly1305, BLAKE2b, Argon2id backup), wire-compatible with the web app, its keys held by the host as the session token is (never in state). Needs a libsodium package on cvcpkg. Drafted: cy-pca/cvcpkg#612 (libsodium), the libcvc E2EE PR (the `e2ee-*` verbs, `--e2ee-store`), and DMs here (ui/dm.ari) | M2 |
| L22 | Loop as a player control: a Loop box beside Mute, and a `loop` key the document reads and writes, as `muted` | M2 |
| L23 | `badge:` on `image:` and `video:`, a label drawn over the picture (the grid's "+N"), with a capability token (`image.badge`). Not `overlay:`, a widget type the loader would take it for | M2 |
| L24 | A reactive expression the per-frame budget skipped is not the document's error: no warning (a big feed's first frame in wasm showed one) | M2 |

## Milestones

- **M0, hello:** sign in with username, password and 2FA; show the profile and
  SCRIP balance, in `arigl`, `ari` (FTXUI and tvision) and the browser. Ship
  the launcher script with `--terminal`. Add `ari snapshot` tests to CI.
  Measure the wasm bundle size and the time to first paint.
  - Drafted: `share/nicotina/`, `bin/nicotina`, `bin/nicotina.cmd` and `tests/run.sh`, run
    against a local libcvc build that merges L1-L3, L8 and L10's pull requests. Left: L11,
    CI (needs the packages), the browser path (needs txwtf T2), and a run against dev.tx.wtf.
    Measured wasm sizes (brotli): `arigl.wasm` 9.5 MB (6.1 MB lean), `ari.wasm` 5.1 MB
    (2.1 MB lean).
- **M1, read:** PKCE sign-in (a pairing code in the terminal), which also
  covers federated users; the home feed, profiles and live notifications.
  - Drafted: the home feed (Following and Everyone, a card a post, Load more, a post opened
    whole) and the profile laid out as the web app's (banner, card, Posts/Replies/Balances
    tabs), in every host. Pictures, video and audio are placeholders until libcvc can show media
    from a URL (L5's images from `https://`, and the media widgets being designed in
    transfix/libcvc#929). Left: PKCE sign-in, live notifications, other users' profiles.
- **M2, write:** posts, replies, reactions, follows, direct messages and the admin screens,
  all in the one TX.WTF window, never sending the user to a browser.
  - Drafted (needs no new host feature): one window, laid out as the web app's single page: a
    bar (Back, Home, Tags, Search, Alerts with the unread count, Profile, Post) above one view at
    a time, Back walking the views visited. The feed (Following, Everyone, Friends) and a
    hashtag's posts; a post with the post it replies to, its hashtags, its replies and a reply
    box; Like and Repost on a card and a post, Delete on your own; anyone's profile, with Follow;
    the hashtags; notifications; search; a new post (text, who sees it); a viewer stepping through
    a post's pictures, videos and recordings. "In browser" is gone: a post shows its link.
    `--start` opens any view (post:ID, tag:NAME, user:ID, view:ID[:N], tags, alerts, search,
    compose).
  - Drafted: a post's pictures and videos as tx.wtf lays them out, one as wide as the card or a
    grid of up to four with "+N" for the rest (where the host measures the line: image.fill,
    libcvc 3.7.13); videos in the feed and a post play muted and looping with no
    controls, the viewer has them, and a click pauses or plays one (L12). The bar and each view
    scope their widgets' IDs, so the search view's Search button is no longer the bar's.
  - Drafted, for libcvc 3.7.13 (L12, L13, L14, L16): a card opens its post when clicked; its
    counts are icons to press (reply, repost, like, coloured once you have); its hashtags are chips
    to click; Copy link; the viewer's Full screen. A terminal and older hosts keep the buttons.
    Hashtags clickable inside the text, and text that wraps as the window narrows, wait for L15.
  - Drafted, for the libcvc release after 3.7.13 (L15): a post's text as rich text, read from
    txwtf's `content_html` as the emoji are: bold, italic and code, its paragraphs, and its
    mentions, hashtags and URLs links. A hashtag opens its posts, a mention the profile
    (`GET /user/by-username/{name}`), a post link the post; anything else is copied. On cards
    (three lines), a post opened whole and its replies (two lines). Older hosts keep the lines.
  - Next, with L12-L20 (transfix/libcvc, the next release): a card and a picture clickable,
    Copy link, fullscreen video, hashtags and mentions clickable in the text, a live character
    count, "2h ago", attachments, wheel scrolling in a terminal. Then direct messages: plain
    first, then end-to-end encrypted ones in the client itself (L21), never in a browser.
  - Drafted (needs no new host feature): the admin screens, for an account the instance makes an
    administrator (is_admin), in the same window behind its bar and Back: the accounts (found by
    username, each disabled or enabled, made an administrator or not, its emailed sign-in code
    turned off), the groups (made, deleted, members added and removed, made a group's admin or
    not) and what each grants (permissions granted by name and revoked), sign-up (open or
    invite-only) and invite codes, the site's title, description and time zone, and the system
    log. The way in is the profile's Admin, the nicotina menu, and the bar where it is icons.
    txwtf has no reports queue, and its post delete doesn't honour an administrator yet, so
    there is no post moderation. Next: emoji and tag moderation, content retention, federation
    peers and settings, OIDC clients, mail status. Billing, wallet and monetization admin wait
    for M3.
- **M3, SCRIP:** live balance, top-up through hosted checkout in the system
  browser, and the metered prompt chat.
- **M4, ship:** publish the cvcpkg recipe for linux-x86_64, macOS and Windows,
  with an end-to-end smoke test in CI against a development instance.
- **M5, apps on TX.WTF:** the instance's app launcher lists this client and
  other Ariadne apps, all signing in with TX.WTF.
