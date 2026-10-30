#!/usr/bin/env bash
# build-hosts.sh: build the browser hosts (libcvc's arigl-web package, single-threaded and lean)
# from a libcvc checkout, first merging the libcvc pull requests nicotina needs that are still open.
#
#   deploy/cyberpcangel/build-hosts.sh LIBCVC_DIR BUILD_DIR INSTALL_DIR
#
# LIBCVC_DIR is a full clone of transfix/libcvc (not shallow: the merges need history), at master.
# The merges are ci/libcvc-prs.sh's, as the tests' hosts get. The package lands in
# INSTALL_DIR/share/arigl-web. Environment:
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

bash "$(dirname "$0")/../../ci/libcvc-prs.sh" "$src"

recipe="$src/cvcpkg/recipes/arigl-web/build-wasm.sh"
[[ -f "$recipe" ]] || { echo "::error::$recipe is missing (transfix/libcvc#887 neither merged nor listed)" >&2; exit 1; }
CVC_SOURCE_DIR="$src" CVC_BUILD_DIR="$build" CVC_INSTALL_DIR="$install" CVC_PLATFORM=wasm \
  CVC_ARIGL_WEB_LEAN=1 bash "$recipe"
