#!/usr/bin/env bash
# ci/install-hosts.sh: install the Ariadne hosts the tests run, ari and arigl, from cvcpkg.org, as
# a person installs them (`cvcpkg install ari arigl`).
#
#   ci/install-hosts.sh ROOT
#
#   ROOT/deps   a cvcpkg prefix with the ari and arigl packages and their runtime closure (libcvc,
#               cvcGL, vtk, ImGui, SDL3, the terminal backends); ROOT/deps/bin/ari and
#               ROOT/deps/bin/arigl find their libraries through their RPATH
#   ROOT/tools  where ci/test-env.sh puts tmux
#
# nicotina targets the stock, packaged hosts, so the tests run the published release, never a
# libcvc build. When nicotina needs a libcvc feature only master has, libcvc cuts a release first.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 ROOT" >&2; exit 2; }
mkdir -p "$1"
root=$(cd "$1" && pwd)
deps=$root/deps

cvcpkg install ari arigl --prefix "$deps" --config release --link shared --no-fallback-to-source
sed -n '/^- name: \(ari\|arigl\|libcvc\)$/{p;n;p;}' "$deps/share/libcvc-deps/lockfile.yaml"

# An ari without one of these would fail the tests for a reason that has nothing to do with
# nicotina. Read the whole report first: grep -q stops at the first match, and under pipefail the
# writer's SIGPIPE would fail the script.
info=$("$deps/bin/ari" info)
for want in ".ari loader (yaml-cpp)" "terminal backend (FTXUI)" "desktop backend (tvision)" \
            "HTTP (cvc::net)"; do
  awk -v w="$want" 'index($0, "  " w " ") == 1 && $NF == "yes" { f = 1 } END { exit !f }' <<<"$info" \
    || { echo "::error::this ari has no $want" >&2; printf '%s\n' "$info" >&2; exit 1; }
done
if ldd "$deps/bin/ari" "$deps/bin/arigl" | grep 'not found'; then
  echo "::error::ari or arigl cannot find a shared library" >&2
  exit 1
fi
