#!/usr/bin/env bash
# nicotina-deploy.sh: runs INSIDE the cyberpcangel instance as root, installed at
# /root/nicotina-deploy.sh. Only the catx-00 forced command runs it (txwtf-deploy-cyberpcangel,
# action deploy-nicotina), with a payload tarball (tar czf) on stdin:
#
#   nicotina/        -> $DOCROOT/nicotina       https://cyberpcangel.com/nicotina/
#   nicotina-term/   -> $DOCROOT/nicotina-term  https://cyberpcangel.com/nicotina-term/
#
# The payload is static files only. Nothing in it runs: this script owns the Apache config, and it
# refuses a payload that has anything but plain files and directories, or a file type a browser page
# doesn't need (no .php, no .htaccess). Each site is replaced whole (old files go), by a rename.
# The files are owned by root, so the web server (WordPress runs as www-data) can't change them.
#
# Version of record: cy-pca/nicotina deploy/cyberpcangel/nicotina-deploy.sh. Install or update it:
#   ssh tfx@catx-00.tx.wtf 'lxc exec cyberpcangel --project catx -- bash -c "cat > /root/nicotina-deploy.sh.new && bash -n /root/nicotina-deploy.sh.new && chmod 700 /root/nicotina-deploy.sh.new && mv /root/nicotina-deploy.sh.new /root/nicotina-deploy.sh && echo OK"' \
#     < deploy/cyberpcangel/nicotina-deploy.sh
set -euo pipefail
umask 022

SITES=(nicotina nicotina-term)
# The instances a page may talk to (its CSP connect-src). The page config's --net-allow picks one.
CONNECT="https://tx.wtf https://dev.tx.wtf"
MAX_BYTES=$((512 * 1024 * 1024))
# Overridable only so the script can be tested off the box; the forced command sets neither.
APACHE=${NICOTINA_APACHE_ETC:-/etc/apache2}
TMPBASE=${NICOTINA_TMPDIR:-/root}

WORK=$(mktemp -d "$TMPBASE/nicotina-payload.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

echo "### payload"
tar xzf - -C "$WORK" --no-same-owner --no-same-permissions
for s in "${SITES[@]}"; do
  [[ -d "$WORK/$s" ]] || { echo "FATAL: payload has no $s/"; exit 1; }
done
notsite=(); for s in "${SITES[@]}"; do notsite+=('!' -name "$s"); done
extra=$(find "$WORK" -mindepth 1 -maxdepth 1 "${notsite[@]}" -print)
[[ -z "$extra" ]] || { echo "FATAL: payload has more than ${SITES[*]}: $extra"; exit 1; }
odd=$(find "$WORK" -mindepth 1 ! -type f ! -type d -print)
[[ -z "$odd" ]] || { echo "FATAL: payload has links or special files: $odd"; exit 1; }
bad=$(find "$WORK" -type f ! \( -name '*.html' -o -name '*.js' -o -name '*.css' -o -name '*.wasm' \
        -o -name '*.json' -o -name '*.ari' -o -name '*.md' -o -name '*.txt' -o -name '*.png' \
        -o -name '*.jpg' -o -name '*.svg' -o -name 'LICENSE*' -o -name '.built-from' \) -print)
[[ -z "$bad" ]] || { echo "FATAL: payload has files a page doesn't serve: $bad"; exit 1; }
bytes=$(du -sb "$WORK" | cut -f1)
(( bytes <= MAX_BYTES )) || { echo "FATAL: payload is $bytes bytes, over $MAX_BYTES"; exit 1; }
echo "payload ok: $(find "$WORK" -type f | wc -l) files, $bytes bytes"

echo "### docroot (the enabled vhost that holds wp-config.php)"
DOCROOT=""
CANDS=$(grep -RhE '^[[:space:]]*DocumentRoot' "$APACHE/sites-enabled/" 2>/dev/null \
          | awk '{print $2}' | tr -d '"' | sort -u || true)
for c in $CANDS; do [[ -f "$c/wp-config.php" ]] && { DOCROOT="$c"; break; }; done
[[ -n "$DOCROOT" ]] || { echo "FATAL: no enabled-vhost DocumentRoot has wp-config.php (candidates: ${CANDS:-none})"; exit 1; }
echo "DOCROOT=$DOCROOT"

echo "### apache config"
for m in headers deflate; do
  apache2ctl -M 2>/dev/null | grep -q "${m}_module" || a2enmod -q "$m"
done
CSP="default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; \
connect-src 'self' $CONNECT; img-src 'self' data: blob:; font-src 'self' data:; object-src 'none'; \
base-uri 'self'; form-action 'none'; frame-ancestors 'self'"
CONF="$APACHE/conf-available/nicotina.conf"
NEW=$(mktemp)
{
  echo "# Written by /root/nicotina-deploy.sh (cy-pca/nicotina deploy/cyberpcangel). Edit that, not this."
  for s in "${SITES[@]}"; do
    cat <<CONF
<Directory "$DOCROOT/$s">
    Options -Indexes -ExecCGI +FollowSymLinks
    AllowOverride None
    Require all granted
$( [[ $s == nicotina-term ]] && echo "    DirectoryIndex ari.html" || echo "    DirectoryIndex index.html" )
    <IfModule mod_rewrite.c>
        RewriteEngine Off
    </IfModule>
    AddType application/wasm .wasm
    AddType text/plain .ari
    AddCharset utf-8 .ari .json .js .css .html .md
    <IfModule mod_deflate.c>
        AddOutputFilterByType DEFLATE application/wasm application/javascript text/javascript text/html text/css text/plain application/json
    </IfModule>
    Header always set Content-Security-Policy "$CSP"
    Header always set X-Content-Type-Options "nosniff"
    Header always set Referrer-Policy "no-referrer"
    Header set Cache-Control "no-cache"
</Directory>
CONF
  done
} > "$NEW"
if [[ -f "$CONF" ]] && cmp -s "$NEW" "$CONF"; then
  echo "unchanged: $CONF"
  rm -f "$NEW"
  CONF_CHANGED=0
else
  [[ -f "$CONF" ]] && cp -a "$CONF" "$CONF.prev"
  install -m 644 "$NEW" "$CONF"; rm -f "$NEW"
  a2enconf -q nicotina
  if ! apache2ctl configtest; then
    echo "FATAL: configtest failed; restoring the previous config"
    if [[ -f "$CONF.prev" ]]; then mv "$CONF.prev" "$CONF"; else a2disconf -q nicotina; rm -f "$CONF"; fi
    exit 1
  fi
  CONF_CHANGED=1
fi

echo "### place the sites"
for s in "${SITES[@]}"; do
  dst="$DOCROOT/$s"
  tmp="$DOCROOT/.$s.new.$$" old="$DOCROOT/.$s.old.$$"
  rm -rf "$tmp"
  cp -R "$WORK/$s" "$tmp"
  chown -R root:root "$tmp"
  chmod -R u=rwX,go=rX "$tmp"
  [[ -e "$dst" ]] && mv "$dst" "$old"
  mv "$tmp" "$dst"
  rm -rf "$old"
  echo "$s: $(find "$dst" -type f | wc -l) files"
done

if (( CONF_CHANGED )); then systemctl reload apache2; echo "apache reloaded"; fi
echo "REMOTE_DONE DOCROOT=$DOCROOT SITES=${SITES[*]}"
