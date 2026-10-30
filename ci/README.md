# CI

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs nicotina's tests on every push to
`main` and every pull request:

| Job | What |
|---|---|
| `hosts` | `ari` and `arigl` from libcvc master plus the libcvc pull requests nicotina still needs (`LIBCVC_PRS`), cached by the merged libcvc tree |
| `unit` | `tests/run.sh`: the client against the stub instance (`tests/stub_txwtf.py`) |
| `integration` | `tests/local.sh`: the client against a real txwtf server on a fresh SQLite database. `atxcf/txwtf-cp312` is installed from cvcpkg.org |

[`.github/workflows/llm-gate.yml`](../.github/workflows/llm-gate.yml) fails commits that carry AI
attribution, as in the other cy-pca repositories.

Both run on GitHub-hosted runners only. The repository is public, and a pull request's workflows
must never reach the self-hosted runners on catx-03. Everything comes from cvcpkg; nothing comes
from apt:

- the hosts' libraries, cmake and ninja;
- txwtf;
- tmux, Xvfb and Mesa.

**The integration job needs one secret.** txwtf's repository is private, and txwtf publishes
`txwtf-cp312` only to cvcpkg.org's private `atxcf` organization. So the job needs
`CVCPKG_ATXCF_READ_TOKEN`: a cvcpkg.org token with read access to `atxcf`.
- Only the install step sees it, never the tests.
- A pull request from a fork gets no secrets and skips the job with a notice.
- On a push or a same-repository pull request, a missing secret fails the job.

## The same, locally

The dependencies are published cvcpkg packages. libcvc needs history for the merges.

```bash
git clone --filter=blob:none https://github.com/transfix/libcvc /tmp/libcvc
LIBCVC_PRS="883 887" ci/libcvc-prs.sh /tmp/libcvc
ci/build-hosts.sh /tmp/libcvc ~/nicotina-ci                # ari, arigl: ~/nicotina-ci/build/bin

# txwtf, either published (with a token that can read atxcf) or from a txwtf checkout:
CVCPKG_TOKEN=... cvcpkg install atxcf/txwtf-cp312 --prefix ~/nicotina-txwtf --config release --link shared
ci/build-txwtf.sh ~/src/txwtf ~/nicotina-txwtf             # same prefix, built from its recipes/

eval "$(ci/test-env.sh ~/nicotina-ci)"                      # tmux; Xvfb on :99 with Mesa
ARI=~/nicotina-ci/build/bin/ari ARIGL=~/nicotina-ci/build/bin/arigl tests/run.sh
TXWTF_PREFIX=~/nicotina-txwtf ARI=~/nicotina-ci/build/bin/ari ARIGL=~/nicotina-ci/build/bin/arigl tests/local.sh
```

On 2026-10-30 this took libcvc 5d0a62f8 plus #883 and #887, and txwtf v0.4.0 built with
`ci/build-txwtf.sh`. `tests/run.sh` passed 54 checks and `tests/local.sh` 43, with no skips.

On GitHub (a check run of #1's tests), the `hosts` job built cold in 8.5 minutes, and `unit`
passed 54/54.

- **Hosts cache:** about 900 MB (`deps` 763 MB, `tools` 130 MB, `build` 29 MB). It is rebuilt only
  when the merged libcvc tree or `ci/build-hosts.sh` changes.
- **txwtf prefix:** about 700 MB, installed fresh on each run.

When `LIBCVC_PRS` have all merged, empty it in both workflows (here and in
`deploy-cyberpcangel.yml`); a merged one is skipped anyway.
