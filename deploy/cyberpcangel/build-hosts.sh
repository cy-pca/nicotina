#!/usr/bin/env bash
# build-hosts.sh: build the browser hosts (libcvc's arigl-web package, single-threaded and lean)
# from a libcvc checkout, first merging the libcvc pull requests nicotina needs that are still open.
#
#   deploy/cyberpcangel/build-hosts.sh LIBCVC_DIR BUILD_DIR INSTALL_DIR
#
# LIBCVC_DIR is a full clone of transfix/libcvc (not shallow: the merges need history), at master.
# The package lands in INSTALL_DIR/share/arigl-web. Environment:
#
#   LIBCVC_PRS        pull request numbers to merge, in order, while they are open; a merged one is
#                     skipped, a closed one fails the build (default: none)
#   CVC_EMSDK_DIR     the emsdk (with emsdk_env.sh)
#   CVC_DEPS_PREFIX   the single-threaded wasm deps prefix (cvcpkg install --platform wasm)
#   GH_TOKEN          optional, for the GitHub API (pull request states)
#
# Single-threaded, so the pages need no COOP/COEP headers. Lean (CVC_ARIGL_WEB_LEAN=1): no
# ImageMagick, assimp, mesher, SDF or libigl, which a widget client doesn't use (PNG and JPEG still
# load): arigl.wasm is 34.9 MB, 9.4 MB gzipped as Apache sends it (the full build: 49 MB, 13.8 MB).
set -euo pipefail

[[ $# -eq 3 ]] || { echo "usage: $0 LIBCVC_DIR BUILD_DIR INSTALL_DIR" >&2; exit 2; }
src=$1 build=$2 install=$3

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

git -C "$src" config user.name nicotina-deploy
git -C "$src" config user.email nightly@cyberpcangel.com
echo "libcvc master: $(git -C "$src" rev-parse HEAD)"
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

recipe="$src/cvcpkg/recipes/arigl-web/build-wasm.sh"
[[ -f "$recipe" ]] || { echo "::error::$recipe is missing (transfix/libcvc#887 neither merged nor listed)" >&2; exit 1; }
CVC_SOURCE_DIR="$src" CVC_BUILD_DIR="$build" CVC_INSTALL_DIR="$install" CVC_PLATFORM=wasm \
  CVC_ARIGL_WEB_LEAN=1 bash "$recipe"
