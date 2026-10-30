# shellcheck shell=bash
# tests/lib.sh: what tests/run.sh and tests/live.sh share. Sourced, not run.
#
# After sourcing: $root, $main, $ARI, $ARIGL, $out (outputs, kept), $work (credential stores and
# secrets, removed on exit) and $sock (a tmux server of our own, never the user's). A script that
# starts more (a server) names a function to run at exit with on_exit.

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(dirname "$here")
# shellcheck disable=SC2034 # the scripts that source this use it
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
work=$(mktemp -d "${TMPDIR:-/tmp}/nicotina-work.XXXXXX")
sock="nicotina-test-$$"

on_exit_hooks=()
on_exit() { on_exit_hooks+=("$1"); } # on_exit FUNCTION
cleanup() {
  local h
  for h in "${on_exit_hooks[@]}"; do "$h"; done
  tmux -L "$sock" kill-server 2>/dev/null || true
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$sock" # a killed server can leave its socket
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

sessions_in() { # sessions_in STORE: how many credentials the host keeps there
  [ -f "$1" ] || { echo 0; return; }
  grep -cv '^#' "$1" || true
}
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
check_store() { # check_store NAME STORE: one session, owner-only (0600 in a 0700 directory)
  if [ "$(sessions_in "$2")" = 1 ] && [ "$(mode_of "$2")" = 600 ] &&
    [ "$(mode_of "$(dirname "$2")")" = 700 ]; then
    pass "$1"
  else
    fail "$1: the store is not one owner-only session ($(mode_of "$2"))"
  fi
}

# --- the client in tmux -----------------------------------------------------------------------

pane() { tmux -L "$sock" capture-pane -p -t app 2>/dev/null; }
slug() { printf '%s' "$1" | tr -cs 'A-Za-z0-9' '-'; }
keys() { tmux -L "$sock" send-keys -t app "$@"; sleep 0.3; }
type_text() { tmux -L "$sock" send-keys -t app -l "$1"; sleep 0.3; }
# type_secret FILE: type FILE's contents through a tmux buffer, so they are in no command line.
type_secret() {
  tmux -L "$sock" load-buffer -b secret "$1" &&
    tmux -L "$sock" paste-buffer -d -b secret -t app
  sleep 0.3
}
# start BACKEND XDG INSTANCE [nicotina args...]: the client in a 100x30 pane, as a person runs it.
start() {
  local backend=$1 xdg=$2 instance=$3 cmd _
  shift 3
  stop
  cmd=$(printf '%q ' env TERM=xterm-256color XDG_CONFIG_HOME="$xdg" NICOTINA_ARI="$ARI" \
    sh "$root/bin/nicotina" --terminal --backend "$backend" --instance "$instance" "$@")
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
  if wait_for "$name" "$text" "${STEP_SECONDS:-10}"; then check "$name" "$file" "$text" "$@"; else
    fail "$name: no [$text] on the screen" "$file"
  fi
}

# --- the end ----------------------------------------------------------------------------------

# no_secrets_in_output SECRETS: no file in $out holds any line of SECRETS (tokens, passwords).
no_secrets_in_output() {
  if grep -rlF -f "$1" "$out" >"$work/leaks" 2>/dev/null; then
    fail "no secret in any output: found in $(tr '\n' ' ' <"$work/leaks")"
  else
    pass "no secret in any output ($(find "$out" -type f | wc -l | tr -d ' ') files)"
  fi
}
finish() {
  echo
  echo "$passed passed, $failed failed, $skipped skipped; outputs in $out"
  [ "$failed" = 0 ]
}
