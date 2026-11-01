# CI

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs nicotina's tests on every push to
`main` and every pull request:

| Job | What |
|---|---|
| `unit` | `tests/run.sh`: the client against the stub instance (`tests/stub_txwtf.py`) |
| `integration` | `tests/local.sh`: the client against a real txwtf server on a fresh SQLite database. `atxcf/txwtf-cp312` is installed from cvcpkg.org |

Both run the `ari` and `arigl` packages from cvcpkg.org (`ci/install-hosts.sh`), as a person
installs them. nicotina targets the stock, packaged hosts, so CI never builds libcvc: a feature
only libcvc master has needs a libcvc release first. The script checks the `ari` it got has the
`.ari` loader, both terminal backends and HTTP, and that neither host misses a library.

[`.github/workflows/llm-gate.yml`](../.github/workflows/llm-gate.yml) fails commits that carry AI
attribution, as in the other cy-pca repositories.

Both run on GitHub-hosted runners only. The repository is public, and a pull request's workflows
must never reach the self-hosted runners on catx-03. Everything comes from cvcpkg; nothing comes
from apt:

- the hosts and their libraries;
- txwtf;
- tmux, Xvfb and Mesa.

**The integration job needs one secret.** txwtf's repository is private, and txwtf publishes
`txwtf-cp312` only to cvcpkg.org's private `atxcf` organization. So the job needs
`CVCPKG_ATXCF_READ_TOKEN`: a cvcpkg.org token with read access to `atxcf`.
- Only the install step sees it, never the tests.
- A pull request from a fork gets no secrets and skips the job with a notice.
- On a push or a same-repository pull request, a missing secret fails the job.

## The same, locally

Everything is a published cvcpkg package.

```bash
ci/install-hosts.sh ~/nicotina-ci                            # ari, arigl: ~/nicotina-ci/deps/bin

# txwtf, either published (with a token that can read atxcf) or from a txwtf checkout:
CVCPKG_TOKEN=... cvcpkg install atxcf/txwtf-cp312 --prefix ~/nicotina-txwtf --config release --link shared
ci/build-txwtf.sh ~/src/txwtf ~/nicotina-txwtf             # same prefix, built from its recipes/

eval "$(ci/test-env.sh ~/nicotina-ci)"                      # tmux; Xvfb on :99 with Mesa
export PATH=~/nicotina-txwtf/bin:$PATH                      # txwtf's scripts run `env python3.12`
ARI=~/nicotina-ci/deps/bin/ari ARIGL=~/nicotina-ci/deps/bin/arigl tests/run.sh
TXWTF_PREFIX=~/nicotina-txwtf ARI=~/nicotina-ci/deps/bin/ari ARIGL=~/nicotina-ci/deps/bin/arigl tests/local.sh
```

- **Hosts prefix:** the packages are the full libcvc build, so the install brings its whole
  runtime closure: 97 packages, about 240 MB to download and 1.9 GB on disk (ari and arigl
  3.7.8, 2026-11-01). Each job installs it fresh.
- **txwtf prefix:** about 700 MB, installed fresh on each run.

A push to `main` whose `ci` run passes also publishes the browser pages
([deploy/cyberpcangel](../deploy/cyberpcangel/README.md)).
