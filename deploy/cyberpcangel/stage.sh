#!/usr/bin/env bash
# stage.sh: assemble the cyberpcangel.com payload from an arigl-web package and nicotina's documents.
#
#   deploy/cyberpcangel/stage.sh WEB_DIR DOCS_DIR OUT [BUILT_FROM]
#
# WEB_DIR is an arigl-web package's share/arigl-web, single-threaded (it has ari.html); DOCS_DIR is
# nicotina's share/nicotina. OUT is created (it must not exist) with the two sites:
#
#   OUT/nicotina/       https://cyberpcangel.com/nicotina/       the ImGui client (arigl-web's index.html)
#   OUT/nicotina-term/  https://cyberpcangel.com/nicotina-term/  the terminal client (ari.html; also
#                                                                 ari_tvision.html when the build has it)
#
# Each gets the documents and ariadne.config.json (beside this script). BUILT_FROM, if given, is
# written to each site's .built-from: what the payload was built from, which the workflow reads back
# to skip a nightly when nothing moved.
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
  install -m 644 "$here/ariadne.config.json" "$web/LICENSE" "$web/THIRD_PARTY_NOTICES.md" "$dir/"
  local f
  for f in "$@"; do cp -R "$web/$f" "$dir/"; done
  if [[ -n "$built_from" ]]; then printf '%s\n' "$built_from" > "$dir/.built-from"; fi
}

site "$out/nicotina" index.html arigl-web.js arigl-web.css arigl.js arigl.wasm
term=(ari.html ari.js ari.wasm ari-web.js ari-web.css xterm)
if [[ -f "$web/ari_tvision.html" ]]; then term+=(ari_tvision.html ari_tvision.js ari_tvision.wasm); fi
site "$out/nicotina-term" "${term[@]}"

chmod -R u=rwX,go=rX "$out"
echo "staged $(find "$out" -type f | wc -l) files, $(du -sh "$out" | cut -f1), in $out"
