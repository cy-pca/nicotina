#!/usr/bin/env bash
# tests/e2ee.sh: an end-to-end encrypted conversation between nicotina, on a host that keeps the
# keys (libcvc 3.7.14's --e2ee-store, the e2ee-* verbs), and TX.WTF's own web client crypto
# (txwtf/static/js/e2ee.js, in tests/e2ee_peer.js), through the stub instance.
#
#   ARI=/path/to/ari TXWTF_JS=<txwtf>/txwtf/static/js tests/e2ee.sh
#
# ada is nicotina; mary is e2ee.js, in conversation 902 (encrypted, empty at the start):
#  1. ada opens it: the host makes her keys and publishes them, and it is empty, with a box.
#  2. mary (e2ee.js) writes first: X3DH from ada's bundle, a Double Ratchet message.
#  3. ada opens it again: the host opens mary's message.
#  4. ada answers in a tmux pane, as a person types (bin/nicotina --terminal): the host seals it.
#  5. mary (e2ee.js) opens ada's answer.
# And what may never happen: the stub (the server) holding either text, an output or the screen
# showing a private key or a token, the key store open to others.
#
# It needs a host with --e2ee-store, node 18+ with libsodium-wrappers-sumo 0.7.15 on NODE_PATH
# (the build TX.WTF's page loads), TXWTF_JS, and tmux; without one of them it says so and skips.
set -uo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
stub_pid=
stop_stub() { [ -z "$stub_pid" ] || kill "$stub_pid" 2>/dev/null; }
on_exit stop_stub

why_not=
ari_help=$("$ARI" --help 2>&1 || true) # whole: grep -q on a pipe can SIGPIPE ari under pipefail
grep -q -- '--e2ee-store' <<<"$ari_help" || why_not="this ari has no --e2ee-store (libcvc 3.7.14)"
command -v node >/dev/null || why_not="no node"
[ -n "${TXWTF_JS:-}" ] && [ -f "$TXWTF_JS/e2ee.js" ] || why_not="TXWTF_JS names no txwtf/static/js"
node -e "require('libsodium-wrappers-sumo')" 2>/dev/null || why_not="node has no libsodium-wrappers-sumo"
command -v tmux >/dev/null || why_not="no tmux"
if [ -n "$why_not" ]; then
  skip "the encrypted round trip: $why_not"
  finish
  exit
fi

python3 -I -B -c "
import sys; sys.path.insert(0, sys.argv[1]); import stub_txwtf as s
for name, token in s.TOKENS.items(): print(name, token)" "$here" >"$work/token-names"
awk '{ print $2 }' "$work/token-names" >"$work/tokens"
token_file() { # token_file NAME: a file holding NAME's token, owner-only
  (umask 077 && awk -v n="$1" '$1 == n { print $2 }' "$work/token-names" >"$work/token-$1")
  printf '%s' "$work/token-$1"
}
python3 -I -B "$here/stub_txwtf.py" --port 0 --port-file "$work/port" --log "$out/stub.log" \
  --signed-in ada --signed-in mary 2>"$out/stub.stderr" &
stub_pid=$!
for _ in $(seq 100); do [ -s "$work/port" ] && break; sleep 0.05; done
[ -s "$work/port" ] || { echo "tests: the stub did not start" >&2; exit 2; }
base="http://127.0.0.1:$(cat "$work/port")"
hostport=${base#http://}

# ada's config, as bin/nicotina keeps it: the session and, beside it, the host's key store.
xdg=$work/xdg
mkdir -p "$xdg/nicotina" && chmod 700 "$xdg/nicotina"
(umask 077 && printf 'txwtf %s %s\n' "$base" "$(cat "$(token_file ada)")" >"$xdg/nicotina/credentials")
keys=$xdg/nicotina/e2ee
dm_snap() { # dm_snap NAME: ada's conversation 902, a 80x40 frame
  "$ARI" snapshot --width 80 --height 40 --net-allow "$base" \
    --credential-store "$xdg/nicotina/credentials" --e2ee-store "$keys" "$main" \
    --instance "$base" --start dm:902 >"$out/e2ee-$1.txt" 2>&1
}
peer() { # peer ARGS...: mary, through e2ee.js
  node "$here/e2ee_peer.js" --base "$base" --token-file "$(token_file mary)" --js "$TXWTF_JS" \
    --state "$work/mary-e2ee.json" "$@"
}

# 1. ada first: her keys made and published, the conversation empty.
dm_snap empty
check "e2ee: ada opens the encrypted conversation: empty, with a box" "$out/e2ee-empty.txt" \
  "@mary@$hostport" "End-to-end encrypted: the server sees ciphertext only." "No messages yet." \
  "Message: ["
check "e2ee: ... the host published her keys" "$out/stub.log" '"path": "/e2ee/keys", "status": 200'
if [ "$(mode_of "$keys")" = 600 ] && [ "$(mode_of "$(dirname "$keys")")" = 700 ]; then
  pass "e2ee: the key store is owner-only (0600 in 0700)"
else
  fail "e2ee: the key store is $(mode_of "$keys")"
fi

# 2. mary writes, with TX.WTF's own client.
first="Hello Ada, sealed by TX.WTF's own e2ee.js. ✓"
peer send 902 1 "$first" >"$out/e2ee-peer-send.txt" 2>&1
check "e2ee: mary (e2ee.js) seals and sends the first message" "$out/e2ee-peer-send.txt" "sent "

# 3. ada opens it.
dm_snap opened
check "e2ee: the host opens e2ee.js's message" "$out/e2ee-opened.txt" "@mary@$hostport" \
  "  Hello Ada, sealed by TX.WTF's own e2ee.js. ✓" "Message: ["
check_not "e2ee: ... nothing it could not open" "$out/e2ee-opened.txt" "could not be decrypted" \
  "another device"

# 4. ada answers, typed in the client.
answer="Hi Mary, sealed by nicotina's host."
start ftxui "$xdg" "$base" -- --start dm:902
step "e2ee: nicotina in a terminal, the conversation" "Hello Ada, sealed by" "Message: ["
type_text "$answer"
keys Enter
step "e2ee: ada's answer, sealed and sent" "Sent." "  $answer"
stop

# 5. mary opens it.
peer recv 902 >"$out/e2ee-peer-recv.txt" 2>&1
check "e2ee: mary (e2ee.js) opens ada's answer" "$out/e2ee-peer-recv.txt" "ok $first" "ok $answer"

# The server never had either text, and no key or token was shown anywhere.
curl -s -H "Authorization: Bearer $(cat "$(token_file mary)")" \
  "$base/e2ee/dm/conversations/902/messages" >"$out/e2ee-server-view.json"
check "e2ee: the server holds the conversation" "$out/e2ee-server-view.json" '"ciphertext"'
check_not "e2ee: ... as ciphertext only" "$out/e2ee-server-view.json" "Hello Ada" "Hi Mary"
grep -o 'priv": *"[^"]*"\|"RK": *"[^"]*"' "$keys" | sed 's/.*"\([^"]*\)"$/\1/' |
  awk 'length >= 40' >"$work/secrets"
if [ -s "$work/secrets" ]; then pass "e2ee: the host's store holds ada's keys"; else
  fail "e2ee: no keys in the host's store"
fi
cat "$work/tokens" >>"$work/secrets"
no_secrets_in_output "$work/secrets"
finish
