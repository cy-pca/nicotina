#!/usr/bin/env bash
# ci/build-txwtf.sh: a cvcpkg prefix with txwtf-cp312, the txwtf server tests/local.sh runs.
#
#   ci/build-txwtf.sh TXWTF_DIR PREFIX
#
# TXWTF_DIR is a checkout of atx-crypto-club/txwtf (CI pins a release tag). txwtf-cp312 and
# txwtf-client-cp312 are built with cvcpkg from that checkout's own recipes/: txwtf publishes them
# only to a private cvcpkg organization. Every dependency is a published cvcpkg package
# (--fallback-to-source builds one that has no bundle for this platform). The prefix then has
# bin/txwtf and bin/python3.12, which is what tests/local.sh needs (TXWTF_PREFIX).
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: $0 TXWTF_DIR PREFIX" >&2; exit 2; }
src=$(cd "$1" && pwd)
mkdir -p "$2"
prefix=$(cd "$2" && pwd)

cd "$src"
# The client first, so txwtf-cp312 finds it in the same prefix (txwtf's cvcpkg-publish.yml does
# the same). --recipes-dir: the client is in no public catalog, so a dependency on it resolves
# only to the local recipe.
for r in txwtf-client-cp312 txwtf-cp312; do
  cvcpkg install-deps "recipes/$r" --prefix "$prefix" --recipes-dir recipes --fallback-to-source
  cvcpkg build "$r" --no-deps --recipes-dir recipes --prefix "$prefix"
done
"$prefix/bin/txwtf" version
