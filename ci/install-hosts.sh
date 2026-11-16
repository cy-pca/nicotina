#!/usr/bin/env bash
# ci/install-hosts.sh: install the Ariadne hosts the tests run, ari, ari-media and arigl, from
# cvcpkg.org, as a person installs them (`cvcpkg install ari ari-media arigl`).
#
#   ci/install-hosts.sh ROOT
#
#   ROOT/deps   a cvcpkg prefix with the ari, ari-media and arigl packages and their runtime
#               closure (libcvc, cvcGL, vtk, ImGui, SDL3, FFmpeg, the terminal backends);
#               ROOT/deps/bin/ari, ari-media and arigl find their libraries through their RPATH
#   ROOT/media  ari-media's own prefix, when its newest release isn't ari's (below); then
#               ROOT/deps/bin/ari-media links to ROOT/media/bin/ari-media
#   ROOT/tools  where ci/test-env.sh puts tmux
#
# nicotina targets the stock, packaged hosts, so the tests run the published release, never a
# libcvc build. When nicotina needs a libcvc feature only master has, libcvc cuts a release first.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 ROOT" >&2; exit 2; }
mkdir -p "$1"
root=$(cd "$1" && pwd)
deps=$root/deps

install_into() { # install_into PREFIX COMPONENT...
  local prefix=$1
  shift
  cvcpkg install "$@" --prefix "$prefix" --config release --link shared --no-fallback-to-source
  sed -n '/^- name: \(ari\|ari-media\|arigl\|libcvc\)$/{p;n;p;}' \
    "$prefix/share/libcvc-deps/lockfile.yaml"
}
# The newest linux x86_64 shared release build of a package on cvcpkg.org, as "3.7.13+cvc.3";
# with a second argument, the newest of that upstream version. cvcpkg search matches its query
# anywhere (every host's description names libcvc) and pages by 200, so this reads the JSON,
# every page, and keeps the rows named exactly NAME.
newest() { # newest NAME [UPSTREAM]
  python3 - "$@" <<'PY'
import json, re, subprocess, sys
name, upstream = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""
versions, offset = [], 0
while True:
    out = subprocess.run(
        ["cvcpkg", "search", name, "--platform", "linux", "--arch", "x86_64", "--link", "shared",
         "--build-type", "release", "--limit", "200", "--offset", str(offset), "--json"],
        check=True, capture_output=True, text=True).stdout
    page = json.loads(out).get("packages") or []
    versions += [p["version"] for p in page if p.get("name") == name and not p.get("yanked")
                 and (not upstream or p["version"].startswith(upstream + "+"))]
    offset += len(page)
    if len(page) < 200:
        break
def key(v):  # 3.7.13+cvc.3 -> ((3, 7, 13), 3)
    up, _, rev = v.partition("+cvc.")
    return tuple(int(x) for x in re.findall(r"\d+", up)), int(rev or 0)
print(max(versions, key=key) if versions else "")
PY
}

# One prefix holds one libcvc, and each host links the libcvc of its own release. So ari-media
# shares the prefix only when its newest release is ari's. A release can publish one host and
# not another (libcvc 4.0.0 published ari and arigl but no ari-media: transfix/libcvc#1288), and
# then ari-media 3.7.13 beside libcvc 4 can't find libcvc.so.3. Then ari-media gets a prefix of
# its own, with the libcvc it was built against (its recipe names libcvc unversioned, so the pin
# is here), and deps/bin/ari-media is a link to it: still the newest ari-media a person can
# install, run as they would run it.
ari_v=$(newest ari)
media_v=$(newest ari-media)
echo "newest on cvcpkg.org: ari $ari_v, ari-media $media_v"
if [ -n "$media_v" ] && [ "${ari_v%%+*}" = "${media_v%%+*}" ]; then
  install_into "$deps" ari ari-media arigl
else
  install_into "$deps" ari arigl
  libcvc_v=$(newest libcvc "${media_v%%+*}")
  [ -n "$media_v" ] && [ -n "$libcvc_v" ] ||
    { echo "::error::no ari-media, or no libcvc ${media_v%%+*} for it, on cvcpkg.org" >&2; exit 1; }
  echo "::notice::ari-media $media_v lags ari $ari_v: it gets its own prefix, with libcvc $libcvc_v"
  install_into "$root/media" "ari-media==$media_v" "libcvc==$libcvc_v"
  ln -sf "$root/media/bin/ari-media" "$deps/bin/ari-media"
fi

# A host without one of these would fail the tests for a reason that has nothing to do with
# nicotina. ari-media is ari with a player for video: and audio: (FFmpeg, SDL3's sound), so it
# must have that too. Read the whole report first: grep -q stops at the first match, and under
# pipefail the writer's SIGPIPE would fail the script.
for host in ari ari-media; do
  wants=(".ari loader (yaml-cpp)" "terminal backend (FTXUI)" "desktop backend (tvision)"
         "HTTP (cvc::net)")
  [ "$host" = ari-media ] && wants+=("video/audio player")
  info=$("$deps/bin/$host" info)
  for want in "${wants[@]}"; do
    awk -v w="$want" 'index($0, "  " w " ") == 1 && $NF == "yes" { f = 1 } END { exit !f }' <<<"$info" \
      || { echo "::error::this $host has no $want" >&2; printf '%s\n' "$info" >&2; exit 1; }
  done
done
# ldd of the files themselves: through a link, ldd takes $ORIGIN from the link's directory, which
# running the program does not (deps/bin/ari-media may link into ROOT/media).
if ldd "$(readlink -f "$deps/bin/ari")" "$(readlink -f "$deps/bin/ari-media")" \
  "$(readlink -f "$deps/bin/arigl")" | grep 'not found'; then
  echo "::error::ari, ari-media or arigl cannot find a shared library" >&2
  exit 1
fi
