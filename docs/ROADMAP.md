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
| L15 | Rich text: runs with links (hashtags, @mentions, URLs) a click follows, and word wrap, built on the emoji runs of transfix/libcvc#1052 | M2 |
| L16 | Fullscreen for `video:` and `image:`: the OS window, or the browser's fullscreen | M2 |
| L17 | `message_input:` tells the document each edit (a live count, and #tag and @mention completion) | M2 |
| L18 | A file picker that hands the document a host-held file, read in chunks into TX.WTF's resumable upload: attachments | M2 |
| L19 | `(time-now)`: the wall clock, for "2h ago" | M2 |
| L20 | Wheel scrolling of a window in FTXUI and tvision | M2 |
| L21 | End-to-end encrypted messaging in the host: TX.WTF's X3DH and Double Ratchet over libsodium (X25519, Ed25519, XChaCha20-Poly1305, BLAKE2b, Argon2id backup), wire-compatible with the web app, its keys held by the host as the session token is (never in state). Needs a libsodium package on cvcpkg | M2 |

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
  - Next, with L12-L20 (transfix/libcvc, the next release): a card and a picture clickable,
    Copy link, fullscreen video, hashtags and mentions clickable in the text, a live character
    count, "2h ago", attachments, wheel scrolling in a terminal. Then direct messages: plain
    first, then end-to-end encrypted ones in the client itself (L21), never in a browser. Then
    the admin screens an administrator needs: users, groups and permissions, invites, logs,
    emoji and tag moderation, content retention, federation peers and settings, OIDC clients,
    mail status. Billing, wallet and monetization admin wait for M3.
- **M3, SCRIP:** live balance, top-up through hosted checkout in the system
  browser, and the metered prompt chat.
- **M4, ship:** publish the cvcpkg recipe for linux-x86_64, macOS and Windows,
  with an end-to-end smoke test in CI against a development instance.
- **M5, apps on TX.WTF:** the instance's app launcher lists this client and
  other Ariadne apps, all signing in with TX.WTF.
