# CI

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs nicotina's tests on every push to
`main` and every pull request:

| Job | What |
|---|---|
| `hosts` | `ari` and `arigl` from libcvc master plus the libcvc pull requests nicotina still needs (`LIBCVC_PRS`), cached by the merged libcvc tree |
| `unit` | `tests/run.sh`: the client against the stub instance (`tests/stub_txwtf.py`) |
| `integration` | `tests/local.sh`: the client against a real txwtf server (`TXWTF_REF`, built with cvcpkg) on a fresh SQLite database |

[`.github/workflows/llm-gate.yml`](../.github/workflows/llm-gate.yml) fails commits that carry AI
attribution, as in the other cy-pca repositories.

Both run on GitHub-hosted runners only. The repository is public, and a pull request's workflows
must never reach the self-hosted runners on catx-03. Everything comes from cvcpkg; nothing comes
from apt:

- the hosts' libraries, cmake and ninja;
- txwtf's dependencies;
- tmux, Xvfb and Mesa.

## The same, locally

The dependencies are published cvcpkg packages. libcvc needs history for the merges, and txwtf is
a release tag.

```bash
git clone --filter=blob:none https://github.com/transfix/libcvc /tmp/libcvc
LIBCVC_PRS="883 887" ci/libcvc-prs.sh /tmp/libcvc
ci/build-hosts.sh /tmp/libcvc ~/nicotina-ci                # ari, arigl: ~/nicotina-ci/build/bin

git clone --depth 1 --branch v0.4.0 https://github.com/atx-crypto-club/txwtf /tmp/txwtf
ci/build-txwtf.sh /tmp/txwtf ~/nicotina-txwtf              # bin/txwtf, bin/python3.12

eval "$(ci/test-env.sh ~/nicotina-ci)"                      # tmux; Xvfb on :99 with Mesa
ARI=~/nicotina-ci/build/bin/ari ARIGL=~/nicotina-ci/build/bin/arigl tests/run.sh
TXWTF_PREFIX=~/nicotina-txwtf ARI=~/nicotina-ci/build/bin/ari ARIGL=~/nicotina-ci/build/bin/arigl tests/local.sh
```

On 2026-10-30 this took libcvc 5d0a62f8 plus #883 and #887, and txwtf v0.4.0.
`tests/run.sh` passed 54 checks and `tests/local.sh` 43, with no skips.

- **Hosts cache:** about 900 MB (`deps` 763 MB, `tools` 130 MB, `build` 29 MB). It is rebuilt only
  when the merged libcvc tree or `ci/build-hosts.sh` changes.
- **txwtf prefix:** about 700 MB, cached by `TXWTF_REF` and `ci/build-txwtf.sh`.

When `LIBCVC_PRS` have all merged, empty it in both workflows (here and in
`deploy-cyberpcangel.yml`); a merged one is skipped anyway.
