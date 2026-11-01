#!/usr/bin/env bash
# ci/test-env.sh: what the tests need besides the hosts, from cvcpkg, on a runner with no desktop.
#
#   ci/test-env.sh ROOT
#
# ROOT is ci/install-hosts.sh's. Installs tmux (the tests type at the client in a tmux pane) into
# ROOT/tools, and Xvfb with Mesa's software GL into ROOT/deps, beside vtk's libglvnd, which finds
# Mesa through its $ORIGIN RUNPATH (as libcvc's CI does for cvcGL's render tests). Starts Xvfb on
# :99, so arigl can open a window for tests/run.sh's PNG snapshot. Then writes PATH and the
# display settings to $GITHUB_ENV, or prints them as exports when there is none.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 ROOT" >&2; exit 2; }
root=$(cd "$1" && pwd)
tools=$root/tools deps=$root/deps

cvcpkg install tmux --prefix "$tools" --config release --link shared
cvcpkg install xvfb mesa --prefix "$deps" --config release --link shared

log=$root/xvfb.log
"$deps/bin/Xvfb" :99 -screen 0 1280x1024x24 >"$log" 2>&1 &
for _ in $(seq 1 50); do
  [ -e /tmp/.X11-unix/X99 ] && break
  sleep 0.2
done
[ -e /tmp/.X11-unix/X99 ] || { echo "::error::Xvfb did not come up on :99" >&2; cat "$log" >&2; exit 1; }

env_lines=("DISPLAY=:99" "LIBGL_ALWAYS_SOFTWARE=1" "GALLIUM_DRIVER=llvmpipe")
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "$tools/bin" >>"$GITHUB_PATH"
  printf '%s\n' "${env_lines[@]}" >>"$GITHUB_ENV"
else
  printf 'export %q\n' "PATH=$tools/bin:$PATH" "${env_lines[@]}"
fi
"$tools/bin/tmux" -V
