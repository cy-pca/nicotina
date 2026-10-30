# Roadmap

Every milestone ends with the same documents running in **stock** `arigl`, in
`ari` (the terminal host) where the feature makes sense, and in the browser,
all against a development TX.WTF instance.

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
| L5 | Multi-line text input, a scrolling or virtualized list, wrapped text, and images from `https://`, in the ImGui **and** terminal backends | M1 |
| L6 | A general WebSocket verb whose frames arrive as `on_signal` | M1 |
| L7 | Sign-in with auth code + PKCE: loopback plus the system browser natively, redirect in wasm, a pairing grant in `ari` | M1 |
| L8 | A generic arigl wasm shell that loads `?src=<same-origin .ari URL>` | M0 (browser) |
| L9 | `open-url`: the system browser natively, `window.open` in wasm | M3 |
| L10 | An `arigl` cvcpkg package (today only `ari` has one) and the wasm shell as a package | M0 |

## Milestones

- **M0, hello:** sign in with username, password and 2FA; show the profile and
  SCRIP balance. Ship the launcher script. Measure the wasm bundle size and the
  time to first paint.
- **M1, read:** PKCE sign-in, which also covers federated users; the home
  feed, profiles and live notifications.
- **M2, write:** posts, replies, reactions, and non-E2EE direct messages.
  E2EE threads open in the browser.
- **M3, SCRIP:** live balance, top-up through hosted checkout in the system
  browser, and the metered prompt chat.
- **M4, ship:** publish the cvcpkg recipe for linux-x86_64, macOS and Windows,
  with an end-to-end smoke test in CI against a development instance.
- **M5, apps on TX.WTF:** the instance's app launcher lists this client and
  other Ariadne apps, all signing in with TX.WTF.
