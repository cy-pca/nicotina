#!/usr/bin/env bash
# tests/run.sh: nicotina's M0 tests, against a stub TX.WTF instance (tests/stub_txwtf.py).
#
#   tests/run.sh                                   # ari and arigl from PATH
#   ARI=/path/to/ari ARIGL=/path/to/arigl tests/run.sh
#
#  1. bin/nicotina --dry-run: the host, flags and credential store it picks.
#  2. ari check: without the network flags the document refuses to load, and says why.
#  3. ari snapshot, FTXUI and tvision: the sign-in form; a stored session, resumed (the profile
#     and the balance); a stored session the server no longer knows (back to the form, and the
#     host forgets it).
#  4. arigl snapshot, if arigl is here: the resumed session as text (--terminal) and in a window
#     (a PNG; checked only for being drawn, since nothing here reads pixels).
#  5. bin/nicotina --terminal in a tmux pane, FTXUI and tvision, typed at the way a person types:
#     sign in, see the profile and balance, start again still signed in, sign out; a wrong
#     password; the emailed code, wrong and then right; an account that must change its password.
#
# `ari snapshot` lays a frame out with FTXUI whatever --backend says, so 5 is what checks the
# tvision desktop itself. 5 needs tmux; without it those cases are skipped.
#
# Every output (frames, panes, the hosts' stderr, the stub's log) is kept in $NICOTINA_TEST_OUT
# (a fresh temp dir by default) and searched for the stub's session tokens at the end: none may
# appear anywhere. Exits non-zero if any check failed.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
root=$(dirname "$here")
main=$root/share/nicotina/main.ari

ARI=${ARI:-$(command -v ari || true)}
ARIGL=${ARIGL:-$(command -v arigl || true)}
if [ -z "$ARI" ] || [ ! -x "$ARI" ]; then
  echo "tests: no ari (put it on PATH, or set ARI=/path/to/ari)" >&2
  exit 2
fi
export LC_ALL=C.UTF-8 LANG=C.UTF-8 # FTXUI and tvision draw box glyphs only in a UTF-8 locale

out=${NICOTINA_TEST_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/nicotina-test.XXXXXX")}
mkdir -p "$out"
work=$(mktemp -d "${TMPDIR:-/tmp}/nicotina-work.XXXXXX") # credential stores: tokens live here
sock="nicotina-test-$$" # a tmux server of our own, never the user's
stub_pid=

cleanup() {
  tmux -L "$sock" kill-server 2>/dev/null || true
  [ -n "$stub_pid" ] && kill "$stub_pid" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

passed=0 failed=0 skipped=0
pass() { passed=$((passed + 1)); printf 'ok    %s\n' "$1"; }
fail() { failed=$((failed + 1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && sed 's/^/      | /' "$2"; }
skip() { skipped=$((skipped + 1)); printf 'skip  %s\n' "$1"; }

# check NAME FILE TEXT...: FILE contains every TEXT, as fixed strings.
check() {
  local name=$1 file=$2 missing='' t
  shift 2
  for t in "$@"; do
    grep -qF -- "$t" "$file" || missing="$missing [$t]"
  done
  if [ -z "$missing" ]; then pass "$name"; else
    fail "$name: missing$missing" "$file"
  fi
}
# check_not NAME FILE TEXT...: FILE contains none of them.
check_not() {
  local name=$1 file=$2 found='' t
  shift 2
  for t in "$@"; do
    grep -qF -- "$t" "$file" && found="$found [$t]"
  done
  if [ -z "$found" ]; then pass "$name"; else fail "$name: found$found" "$file"; fi
}

# --- the stub ---------------------------------------------------------------------------------

python3 -I -c "
import sys; sys.path.insert(0, sys.argv[1]); import stub_txwtf as s
print('\n'.join(list(s.TOKENS.values()) + [s.STALE_TOKEN]))" "$here" >"$work/tokens"
token() { # token NAME (or stale): one line of $work/tokens, never echoed
  case $1 in ada) sed -n 1p "$work/tokens" ;; stale) sed -n 4p "$work/tokens" ;; esac
}

python3 -I "$here/stub_txwtf.py" --port 0 --port-file "$work/port" --log "$out/stub.log" \
  --signed-in ada 2>"$out/stub.stderr" &
stub_pid=$!
for _ in $(seq 100); do [ -s "$work/port" ] && break; sleep 0.05; done
[ -s "$work/port" ] || { echo "tests: the stub did not start" >&2; cat "$out/stub.stderr" >&2; exit 2; }
base="http://127.0.0.1:$(cat "$work/port")"
echo "stub TX.WTF at $base; outputs in $out"

# A credential store holding one session, as the host writes one: owner-only.
seed_store() { # seed_store PATH TOKEN-NAME [ORIGIN]
  mkdir -p "$(dirname "$1")" && chmod 700 "$(dirname "$1")"
  (umask 077 && printf 'txwtf %s %s\n' "${3:-$base}" "$(token "$2")" >"$1")
}
sessions_in() { # sessions_in STORE: how many credentials the host keeps there
  [ -f "$1" ] || { echo 0; return; }
  grep -cv '^#' "$1" || true
}
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# --- 1. the launcher --------------------------------------------------------------------------

launch() { # launch NAME ENV... -- ARGS...: bin/nicotina --dry-run, its output in $out/NAME.txt
  local name=$1
  shift
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  env -u DISPLAY -u WAYLAND_DISPLAY -u SSH_CONNECTION -u SSH_CLIENT -u SSH_TTY -u XDG_CONFIG_HOME \
    NICOTINA_ARI="$ARI" NICOTINA_ARIGL=/bin/true HOME="$work/home" \
    "${envs[@]}" /bin/sh "$root/bin/nicotina" --dry-run "$@" >"$out/$name.txt" 2>&1
}
launch launcher-desktop DISPLAY=:0 -- --instance "$base/"
check "launcher: a display gets arigl, the instance's origin and a credential store" \
  "$out/launcher-desktop.txt" "/bin/true 'run' '--net' '--net-allow' '$base'" \
  "'--credential-store' '$work/home/.config/nicotina/credentials'" "'--instance' '$base'"
launch launcher-nodisplay -- --instance "$base"
check "launcher: no display gets ari" "$out/launcher-nodisplay.txt" "$ARI 'run' '--net'"
launch launcher-ssh DISPLAY= SSH_CONNECTION="10.0.0.2 5000 10.0.0.1 22" -- --instance "$base"
check "launcher: SSH without X forwarding gets ari" "$out/launcher-ssh.txt" "$ARI 'run'"
launch launcher-tvision DISPLAY=:0 XDG_CONFIG_HOME="$work/xdg" -- --backend tvision --fps 30 \
  -- --user ada
check "launcher: --backend tvision, host flags before the document, document args after" \
  "$out/launcher-tvision.txt" "$ARI 'run' '--backend' 'tvision' '--net'" \
  "'$work/xdg/nicotina/credentials' '--fps' '30' '$main' '--instance' 'https://tx.wtf' '--user' 'ada'"
launch launcher-bad -- --instance ftp://example.org
check "launcher: refuses an instance that is not http(s)" "$out/launcher-bad.txt" \
  "--instance must be an http:// or https:// URL"
if PATH=/usr/bin:/bin command -v ari >/dev/null; then
  skip "launcher: without ari (ari is in /usr/bin here)"
else
  launch launcher-nohost NICOTINA_ARI= NICOTINA_ARIGL= PATH=/usr/bin:/bin -- --terminal
  check "launcher: says so when neither host is installed" "$out/launcher-nohost.txt" \
    "neither ari nor arigl is installed"
  launch launcher-arigl-terminal NICOTINA_ARI= PATH=/usr/bin:/bin -- --terminal
  check "launcher: a terminal without ari gets arigl --terminal" \
    "$out/launcher-arigl-terminal.txt" "/bin/true 'run' '--terminal' '--net'"
fi

# --- 2. ari check -----------------------------------------------------------------------------

"$ARI" check "$main" >"$out/check-no-net.txt" 2>&1
echo "exit $?" >>"$out/check-no-net.txt"
check "ari check without --net: the document says it needs the network" \
  "$out/check-no-net.txt" "does not provide what the document requires: net" "exit 1"
"$ARI" check --net-allow "$base" "$main" >"$out/check-net.txt" 2>&1
echo "exit $?" >>"$out/check-net.txt"
check "ari check with --net-allow: it loads" "$out/check-net.txt" "exit 0"

# --- 3. ari snapshot --------------------------------------------------------------------------

snap() { # snap NAME BACKEND STORE [doc args...]
  local name=$1 backend=$2 store=$3
  shift 3
  local flags=(--backend "$backend" --width 80 --height 24 --net --net-allow "$base")
  [ -n "$store" ] && flags+=(--credential-store "$store")
  "$ARI" snapshot "${flags[@]}" "$main" --instance "$base" "$@" >"$out/$name.txt" 2>&1
}

for backend in ftxui tvision; do
  snap "snap-$backend-signin" "$backend" "" --user ada
  check "ari snapshot ($backend): the sign-in form" "$out/snap-$backend-signin.txt" \
    "Sign in to TX.WTF" "Instance: $base" "Username: [ada]" "Password: []" "[ Sign in ]"

  store=$work/snap-$backend/credentials
  seed_store "$store" ada
  snap "snap-$backend-resume" "$backend" "$store"
  check "ari snapshot ($backend): a stored session shows the profile and balance" \
    "$out/snap-$backend-resume.txt" "@ada  Ada Lovelace" "Email    ada@example.org" \
    "Joined   2025-03-01" "Posts    42" "SCRIP    1234.56789" "Value    \$1234.57" \
    "Runway   41 days" "Session  kept on this device" "[ Refresh ][ Sign out ]" \
    "Signed in to 127.0.0.1"

  seed_store "$store" stale
  snap "snap-$backend-expired" "$backend" "$store"
  check "ari snapshot ($backend): an expired session goes back to the sign-in form" \
    "$out/snap-$backend-expired.txt" "Sign in to TX.WTF" "Your session has expired. Sign in again."
  if [ "$(sessions_in "$store")" = 0 ]; then
    pass "ari snapshot ($backend): the host forgot the expired session"
  else
    fail "ari snapshot ($backend): the expired session is still in the store"
  fi
done

# An instance that doesn't answer (port 9, discard, is closed here): back to the form, saying so.
seed_store "$work/snap-down/credentials" ada http://127.0.0.1:9
"$ARI" snapshot --width 80 --height 24 --net-allow http://127.0.0.1:9 \
  --credential-store "$work/snap-down/credentials" "$main" --instance http://127.0.0.1:9 \
  >"$out/snap-unreachable.txt" 2>&1
check "ari snapshot: an instance that doesn't answer" "$out/snap-unreachable.txt" \
  "Sign in to TX.WTF" "Can't reach 127.0.0.1:9"

# --- 4. arigl snapshot ------------------------------------------------------------------------

if [ -n "$ARIGL" ] && [ -x "$ARIGL" ]; then
  # arigl snapshot does not wait for requests as ari's does; 60 frames at 20 fps give them 3 s.
  store=$work/arigl/credentials
  seed_store "$store" ada
  "$ARIGL" snapshot --terminal --frames 60 --width 80 --height 24 --net --net-allow "$base" \
    --credential-store "$store" "$main" --instance "$base" >"$out/arigl-terminal.txt" 2>&1
  check "arigl snapshot --terminal: the profile and balance" "$out/arigl-terminal.txt" \
    "@ada  Ada Lovelace" "SCRIP    1234.56789" "Value    \$1234.57"
  if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || [ -n "${NICOTINA_TEST_PNG:-}" ]; then
    "$ARIGL" snapshot --frames 60 --png "$out/arigl.png" --net --net-allow "$base" \
      --credential-store "$store" "$main" --instance "$base" >"$out/arigl-window.txt" 2>&1
    echo "exit $?" >>"$out/arigl-window.txt"
    if [ -s "$out/arigl.png" ] && grep -q "exit 0" "$out/arigl-window.txt"; then
      pass "arigl snapshot --png: drew the window ($out/arigl.png)"
    else
      fail "arigl snapshot --png: no picture" "$out/arigl-window.txt"
    fi
  else
    skip "arigl snapshot --png: no display (NICOTINA_TEST_PNG=1 tries offscreen anyway)"
  fi
else
  skip "arigl snapshot: no arigl (put it on PATH, or set ARIGL=/path/to/arigl)"
fi

# --- 5. bin/nicotina in tmux ------------------------------------------------------------------

pane() { tmux -L "$sock" capture-pane -p -t app 2>/dev/null; }
slug() { printf '%s' "$1" | tr -cs 'A-Za-z0-9' '-'; }
keys() { tmux -L "$sock" send-keys -t app "$@"; sleep 0.3; }
type_text() { tmux -L "$sock" send-keys -t app -l "$1"; sleep 0.3; }
# start BACKEND XDG [nicotina args...]: the client in a 100x30 pane, as a person would run it.
start() {
  local backend=$1 xdg=$2 cmd _
  shift 2
  stop
  cmd=$(printf '%q ' env TERM=xterm-256color XDG_CONFIG_HOME="$xdg" NICOTINA_ARI="$ARI" \
    sh "$root/bin/nicotina" --terminal --backend "$backend" --instance "$base" "$@")
  # Keep the pane after the client exits, so a crash shows on the screen.
  for _ in 1 2 3; do
    tmux -L "$sock" -f /dev/null new-session -d -s app -x 100 -y 30 \
      "$cmd; echo \"[nicotina exited \$?]\"; sleep 60" 2>/dev/null && return 0
    sleep 0.5
  done
  echo "tests: tmux would not start a session" >&2
}
stop() { # end the client and its tmux server, and wait until the server has gone
  local _
  tmux -L "$sock" kill-server 2>/dev/null || return 0
  for _ in $(seq 50); do
    tmux -L "$sock" has-session 2>/dev/null || return 0
    sleep 0.1
  done
}
# wait_for NAME TEXT [SECONDS]: until the pane shows TEXT; the screen goes to $out/tmux-NAME.txt.
wait_for() {
  local file text=$2 limit=${3:-10} _
  file=$out/tmux-$(slug "$1").txt
  for _ in $(seq $((limit * 10))); do
    pane >"$file"
    grep -qF -- "$text" "$file" && { sleep 0.3; pane >"$file"; return 0; }
    sleep 0.1
  done
  return 1
}
step() { # step NAME TEXT CHECK-TEXT...: wait for TEXT, then check the screen
  local name=$1 text=$2 file
  file=$out/tmux-$(slug "$1").txt
  shift 2
  if wait_for "$name" "$text"; then check "$name" "$file" "$text" "$@"; else
    fail "$name: no [$text] on the screen" "$file"
  fi
}

if ! command -v tmux >/dev/null; then
  skip "bin/nicotina in tmux: no tmux"
else
  for backend in ftxui tvision; do
    xdg=$work/xdg-$backend
    store=$xdg/nicotina/credentials
    t="nicotina --terminal --backend $backend"

    start "$backend" "$xdg"
    step "$t: the sign-in form" "Sign in to TX.WTF" "Instance: $base"
    keys Tab; type_text ada; keys Tab; type_text "correct horse"; keys Tab; keys Enter
    step "$t: signed in, the profile and balance" "@ada  Ada Lovelace" "ada@example.org" \
      "SCRIP    1234.56789" "\$1234.57" "41 days" "kept on this device"
    if [ "$(sessions_in "$store")" = 1 ] && [ "$(mode_of "$store")" = 600 ] &&
      [ "$(mode_of "$(dirname "$store")")" = 700 ]; then
      pass "$t: the host keeps the session, owner-only (0600 in 0700)"
    else
      fail "$t: the store is not one owner-only session ($(mode_of "$store"))"
    fi
    check_not "$t: the password is not on the screen" \
      "$out/tmux-$(slug "$t: signed in, the profile and balance").txt" "correct horse"

    start "$backend" "$xdg"
    step "$t: started again, still signed in" "@ada  Ada Lovelace" "1234.56789"
    keys Tab; keys Tab; keys Enter # Refresh, Sign out
    step "$t: signed out" "Signed out." "Sign in to TX.WTF" "Username: [ada]"
    if [ "$(sessions_in "$store")" = 0 ]; then pass "$t: sign-out drops the session"; else
      fail "$t: the session is still in the store after signing out"
    fi

    keys Tab; keys Tab; type_text "not the password"; keys Tab; keys Enter
    step "$t: a wrong password" "Wrong username or password." "Sign in to TX.WTF"

    start "$backend" "$xdg" -- --user grace
    step "$t: --user fills in the form" "Username: [grace]"
    keys Tab; keys Tab; type_text "correct horse"; keys Tab; keys Enter
    step "$t: the emailed code is asked for" "Two-step verification" "Signing in as grace" \
      "We emailed you a code. It expires in 5 minutes."
    keys Tab; type_text 000000; keys Tab; keys Enter
    step "$t: a wrong code" "That code didn't work. Try again, or go Back." "Code: []"
    keys BTab; type_text 123456; keys Tab; keys Enter
    step "$t: the right code signs in" "@grace  Grace Hopper" "SCRIP    25" "Runway   -"
    keys Tab; keys Tab; keys Enter
    step "$t: grace signs out" "Signed out."

    start "$backend" "$xdg" -- --user linus
    step "$t: the form for linus" "Username: [linus]"
    keys Tab; keys Tab; type_text "correct horse"; keys Tab; keys Enter
    step "$t: a password that must change first" "Change your password at 127.0.0.1" \
      "Sign in to TX.WTF"
    if [ "$(sessions_in "$store")" = 0 ]; then pass "$t: and no session is kept"; else
      fail "$t: a session was kept for an account that must change its password"
    fi
    stop
  done
fi

# --- the tokens -------------------------------------------------------------------------------

if grep -rlF -f "$work/tokens" "$out" >"$work/leaks" 2>/dev/null; then
  fail "no session token in any output: found in $(tr '\n' ' ' <"$work/leaks")"
else
  pass "no session token in any output ($(find "$out" -type f | wc -l | tr -d ' ') files)"
fi
check "the stub refused the expired token and took the valid ones" "$out/stub.log" \
  '"authorization": "rejected"' '"authorization": "valid"'

echo
echo "$passed passed, $failed failed, $skipped skipped; outputs in $out"
[ "$failed" = 0 ]
