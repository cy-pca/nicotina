#!/usr/bin/env bash
# ci/libcvc-prs.sh: merge the libcvc pull requests nicotina needs onto a libcvc checkout, while
# they are open.
#
#   LIBCVC_PRS="883 887" ci/libcvc-prs.sh LIBCVC_DIR
#
# LIBCVC_DIR is a clone of transfix/libcvc with history (not shallow), at master. Each number in
# LIBCVC_PRS, in order: a merged pull request is skipped, an open one is merged (a conflict fails),
# a closed one fails. GH_TOKEN, if set, is used for the GitHub API. The merges are local commits,
# never pushed. Prints `libcvc master <sha>` and one line per pull request.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: LIBCVC_PRS=\"N...\" $0 LIBCVC_DIR" >&2; exit 2; }
src=$1

pr_state() {  # MERGED, OPEN or CLOSED
  python3 -I - "$1" <<'PY'
import json, os, sys, urllib.request
req = urllib.request.Request(f"https://api.github.com/repos/transfix/libcvc/pulls/{sys.argv[1]}",
                             headers={"Accept": "application/vnd.github+json"})
if os.environ.get("GH_TOKEN"):
    req.add_header("Authorization", f"Bearer {os.environ['GH_TOKEN']}")
with urllib.request.urlopen(req, timeout=30) as r:
    pr = json.load(r)
print("MERGED" if pr.get("merged") else pr["state"].upper())
PY
}

git -C "$src" config user.name nicotina-ci
git -C "$src" config user.email nicotina-ci@cyberpcangel.com
echo "libcvc master $(git -C "$src" rev-parse HEAD)"
for n in ${LIBCVC_PRS:-}; do
  state=$(pr_state "$n")
  case "$state" in
    MERGED) echo "transfix/libcvc#$n: merged, nothing to do" ;;
    OPEN)
      git -C "$src" fetch -q origin "pull/$n/head"
      echo "transfix/libcvc#$n: open, merging $(git -C "$src" rev-parse --short FETCH_HEAD)"
      if ! git -C "$src" merge -q --no-edit FETCH_HEAD; then
        echo "::error::transfix/libcvc#$n does not merge cleanly onto master and the PRs before it:" >&2
        git -C "$src" diff --name-only --diff-filter=U >&2
        exit 1
      fi ;;
    *) echo "::error::transfix/libcvc#$n is $state, not merged: drop it from LIBCVC_PRS or fix it" >&2
       exit 1 ;;
  esac
done
