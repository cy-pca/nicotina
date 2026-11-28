#!/usr/bin/env bash
# stage.sh: assemble the cyberpcangel.com payload from an arigl-web package and nicotina's documents.
#
#   deploy/cyberpcangel/stage.sh WEB_DIR DOCS_DIR OUT [BUILT_FROM]
#
# WEB_DIR is an arigl-web package's share/arigl-web, single-threaded (it has ari.html); DOCS_DIR is
# nicotina's share/nicotina. OUT is created (it must not exist) with the sites:
#
#   OUT/nicotina/         https://cyberpcangel.com/nicotina/         the ImGui client (arigl-web's index.html)
#   OUT/nicotina-term/    https://cyberpcangel.com/nicotina-term/    the terminal client (ari.html; also
#                                                                     ari_tvision.html when the build has it)
#   OUT/nicotina-pixels/  https://cyberpcangel.com/nicotina-pixels/  the terminal client with its pictures
#                                                                     in real pixels (ari.html with
#                                                                     --graphics iterm), when the build
#                                                                     has xterm.js's image addon
#
# Each gets the documents and ariadne.config.json (beside this script). BUILT_FROM, if given, is
# written to each site's .built-from: what the payload was built from, which cy-pca/ops' deploy
# reads back to skip a run when nothing moved.
set -euo pipefail

[[ $# -ge 3 && $# -le 4 ]] || { echo "usage: $0 WEB_DIR DOCS_DIR OUT [BUILT_FROM]" >&2; exit 2; }
web=$1 docs=$2 out=$3 built_from=${4:-}
here=$(cd "$(dirname "$0")" && pwd)

for f in index.html arigl-web.js arigl-web.css arigl.js arigl.wasm \
         ari.html ari.js ari.wasm ari-web.js ari-web.css xterm LICENSE THIRD_PARTY_NOTICES.md; do
  [[ -e "$web/$f" ]] || { echo "stage: $web has no $f (a single-threaded arigl-web package?)" >&2; exit 1; }
done
[[ -f "$docs/main.ari" ]] || { echo "stage: $docs has no main.ari" >&2; exit 1; }
[[ ! -e "$out" ]] || { echo "stage: $out already exists" >&2; exit 1; }

site() {  # site DIR FILE...: the documents, the config, the licenses, then the named host files
  local dir=$1; shift
  install -d "$dir"
  cp -R "$docs/." "$dir/"
  # The launcher's own: fleet.policy is bin/nicotina's --net-policy. A page's network is its
  # config's flags, and the instance serves only a page's files (nicotina-deploy.sh refuses others).
  rm -f "$dir/fleet.policy"
  install -m 644 "$here/ariadne.config.json" "$web/LICENSE" "$web/THIRD_PARTY_NOTICES.md" "$dir/"
  local f
  for f in "$@"; do cp -R "$web/$f" "$dir/"; done
  if [[ -n "$built_from" ]]; then printf '%s\n' "$built_from" > "$dir/.built-from"; fi
}

site "$out/nicotina" index.html arigl-web.js arigl-web.css arigl.js arigl.wasm
term=(ari.html ari.js ari.wasm ari-web.js ari-web.css xterm)
if [[ -f "$web/ari_tvision.html" ]]; then term+=(ari_tvision.html ari_tvision.js ari_tvision.wasm); fi
site "$out/nicotina-term" "${term[@]}"
# The same FTXUI page with --graphics iterm, which an arigl-web whose ari.html loads xterm.js's
# image addon draws in pixels: pictures as iTerm2 inline images, which the terminal scales to their
# cells. An arigl-web without the addon would draw half-blocks there, so no site then.
if [[ -f "$web/xterm/addon-image.js" ]]; then
  site "$out/nicotina-pixels" ari.html ari.js ari.wasm ari-web.js ari-web.css xterm
  sed -i 's/"flags": \[/"flags": [\n    "--graphics", "iterm",/' "$out/nicotina-pixels/ariadne.config.json"
  grep -q '"--graphics", "iterm",' "$out/nicotina-pixels/ariadne.config.json" ||
    { echo "stage: could not add --graphics iterm to nicotina-pixels' config" >&2; exit 1; }
fi

chmod -R u=rwX,go=rX "$out"
echo "staged $(find "$out" -type f | wc -l) files, $(du -sh "$out" | cut -f1), in $out"
