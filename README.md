# nicotina

**nicotina** is a client for [TX.WTF](https://tx.wtf) instances, written as
[Ariadne](https://github.com/transfix/libcvc/blob/master/docs/ARIADNE.md)
documents. The same documents run as a native desktop app and in the browser.

> **Status: pre-M0.** Nothing runs yet. The first milestone is waiting on
> generic host features in libcvc; see [docs/ROADMAP.md](docs/ROADMAP.md).

## How it runs

The client is **documents only**: `.ari` files plus `.ari` components. It runs
in **unmodified** Ariadne hosts from [cvcpkg](https://cvcpkg.org), with no
custom host binary, compiled-in widget or patch.

```bash
cvcpkg install nicotina
nicotina --instance https://tx.wtf
```

The `nicotina` package depends on `ari` and `arigl`. It installs:

- `share/nicotina/`: the documents, components and a network policy file.
- `bin/nicotina` (`nicotina.cmd` on Windows): a launcher script. It
  runs `arigl` with the client's main document and the host flags the client
  needs, such as allowing network access to the chosen instance and nothing
  else. When there's no display, or with `--terminal`, it runs `ari run` in
  the terminal instead.

In the browser, an instance serves the same documents next to the generic arigl
wasm shell, at `https://<instance>/apps/nicotina/`.

## What it talks to

The client uses only an instance's public API:

- the REST API, documented at `/docs` on any instance;
- the `/ws/events` WebSocket for live updates;
- OIDC sign-in. Instances support public PKCE clients and loopback redirects.

Auth tokens are held by the host, never by the documents, so they can't leak
into state that Ariadne replicates or logs.

## Layout

```
share/nicotina/   the .ari documents and components (from M0)
bin/              launcher scripts (from M0)
recipe/           the cvcpkg recipe (M4)
docs/ROADMAP.md   milestones and the libcvc features each one needs
```

## License

MIT. See [LICENSE](LICENSE). The Ariadne hosts and libcvc are LGPL-2.1 and
are installed separately through cvcpkg.
