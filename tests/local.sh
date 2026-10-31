#!/usr/bin/env bash
# tests/local.sh: nicotina against a real txwtf instance it starts itself, from cvcpkg.
#
#   TXWTF_PREFIX=/path/to/prefix ARI=... ARIGL=... tests/local.sh
#
# TXWTF_PREFIX is a cvcpkg prefix with txwtf-cp312 installed. From a txwtf checkout:
#
#   cvcpkg install-deps recipes/txwtf-cp312 --prefix "$TXWTF_PREFIX" --fallback-to-source
#   cvcpkg build txwtf-client-cp312 --no-deps --prefix "$TXWTF_PREFIX"
#   cvcpkg build txwtf-cp312 --no-deps --prefix "$TXWTF_PREFIX"
#
# The instance is txwtf's own server on a fresh SQLite database (txwtf init-db, txwtf backend).
# tests/txwtf_local.py makes three accounts with txwtf's core functions: ada (1234.56789 SCRIP
# minted), grace (the emailed second factor on) and linus (force_password_change). Its email
# goes to tests/smtp_sink.py, where the tests read grace's sign-in code. Everything the client
# does goes through the real HTTP API.
#
# For each terminal backend (FTXUI, tvision), bin/nicotina --terminal runs in a tmux pane:
#   - ada: a wrong password; the right one, with the profile and the balance the server works
#     out; the session resumed by ari snapshot (and arigl snapshot), and on restart; sign-out,
#     after which the server refuses her old token;
#   - grace: the emailed code, a wrong one and then the one from the email;
#   - linus: told to change his password in the web app first, and no session kept.
# Then, with txwtf's login rate limit on, a sign-in after ten failed ones is told to wait; and
# with the server stopped, a stored session can't reach it. At the end every output is searched
# for the password and for every token the host stored.
set -uo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

prefix=${TXWTF_PREFIX:-}
txwtf=$prefix/bin/txwtf
py=$prefix/bin/python3.12
if [ -z "$prefix" ] || [ ! -x "$txwtf" ] || [ ! -x "$py" ]; then
  echo "tests: set TXWTF_PREFIX to a cvcpkg prefix with txwtf-cp312 (see the top of $0)" >&2
  exit 2
fi
command -v tmux >/dev/null || { echo "tests: local.sh needs tmux" >&2; exit 2; }

backend_pid='' sink_pid=''
stop_servers() {
  [ -z "$backend_pid" ] || kill "$backend_pid" 2>/dev/null
  [ -z "$sink_pid" ] || kill "$sink_pid" 2>/dev/null
}
on_exit stop_servers

free_port() { python3 -I -B -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
password='Correct#horse9'
printf '%s' "$password" >"$work/password"
printf 'not-the-password-%s' "$$" >"$work/wrong"
cp "$work/password" "$work/secrets"

# --- the instance ------------------------------------------------------------------------------

cd "$work" || exit 2 # txwtf makes an uploads/ directory wherever it runs

db=$work/txwtf.db
"$txwtf" init-db --db-file "$db" --skip-root-user >"$out/txwtf-init-db.txt" 2>&1 ||
  { cat "$out/txwtf-init-db.txt" >&2; exit 2; }
python3 -I -B "$here/smtp_sink.py" --dir "$work/mail" --port-file "$work/smtp.port" \
  >"$out/smtp-sink.txt" 2>&1 &
sink_pid=$!
for _ in $(seq 50); do [ -s "$work/smtp.port" ] && break; sleep 0.1; done
"$py" -I -B "$here/txwtf_local.py" --db-url "sqlite+aiosqlite:///$db" --password "$password" \
  --smtp-port "$(cat "$work/smtp.port")" >"$out/txwtf-provision.txt" 2>&1 ||
  { cat "$out/txwtf-provision.txt" >&2; exit 2; }

port=$(free_port)
base=http://127.0.0.1:$port
head -c 32 /dev/urandom | base64 >"$work/jwt" && cat "$work/jwt" >>"$work/secrets"
# start_backend LIMIT LOG: txwtf's server, its login rate limit (10 a minute) on or off.
start_backend() {
  (TXWTF_RATE_LIMIT_ENABLED=$1 exec "$txwtf" backend -h 127.0.0.1 -p "$port" \
    --db-file "$db" --jwt-secret "$(cat "$work/jwt")" >"$out/$2" 2>&1) &
  backend_pid=$!
  for _ in $(seq 240); do
    curl -s -o /dev/null -m 2 "$base/openapi.json" && return 0
    sleep 0.25
  done
  echo "tests: txwtf did not start" >&2
  tail -20 "$out/$2" >&2
  exit 2
}
stop_backend() {
  kill "$backend_pid" 2>/dev/null
  wait "$backend_pid" 2>/dev/null
  backend_pid=
}
# The client signs in a dozen times a minute here; the limit gets its own case at the end.
start_backend 0 txwtf-backend.txt
echo "txwtf $("$txwtf" version 2>/dev/null | tail -n 1) at $base; outputs in $out"

# Sign in from the form: Username has the focus (form_focus), Tab to the password, type it, Tab
# to Sign in, Enter. Where this ari masks password fields (transfix/libcvc#906), the screen is
# captured with the password typed: it must show bullets, and the scan at the end makes sure it
# never shows the password.
sign_in() {
  form_focus; keys Tab; type_secret "$1"
  if [ -n "$masked" ]; then
    sign_ins=$((sign_ins + 1))
    step "${t:-sign-in}: the password is masked as it is typed ($sign_ins)" "Password: [•"
  fi
  keys Tab; keys Enter
}
sign_ins=0
masked=
if masks_passwords; then masked=1; else
  skip "the password masked as it is typed (this ari has no password fields; transfix/libcvc#906)"
fi
tokens_from() { awk '!/^#/ && NF == 3 { print $3 }' "$1" >>"$work/secrets"; }

# --- the client --------------------------------------------------------------------------------

for backend in ftxui tvision; do
  xdg=$work/xdg-$backend
  store=$xdg/nicotina/credentials
  t="txwtf ($backend)"

  start "$backend" "$xdg" "$base" -- --user ada
  step "$t: the sign-in form" "Username: [ada" "Instance: $base"
  sign_in "$work/wrong"
  step "$t: a wrong password" "Wrong username or password."
  start "$backend" "$xdg" "$base" -- --user ada
  step "$t: the form again" "Username: [ada"
  sign_in "$work/password"
  step "$t: ada signs in: the profile and balance" "@ada@127.0.0.1:$port  Ada Lovelace" "Email    ada@example.org" \
    "Posts    0" "About    Writes notes on the analytical engine. Pr..." "SCRIP    1234.56789" \
    "Value    \$1234.57" "Runway   -" "Session  kept on this device" "Signed in to 127.0.0.1"
  check_store "$t: the host keeps the session, owner-only (0600 in 0700)" "$store"
  tokens_from "$store"
  cp "$store" "$work/old-session-$backend" # for after sign-out
  cp "$store" "$work/session-for-later"    # for when the server is gone
  stop

  "$ARI" snapshot --backend "$backend" --width 80 --height 24 --net --net-allow "$base" \
    --credential-store "$store" "$main" --instance "$base" >"$out/txwtf-snap-$backend.txt" 2>&1
  check "$t: ari snapshot resumes the session" "$out/txwtf-snap-$backend.txt" \
    "@ada@127.0.0.1:$port  Ada Lovelace" "SCRIP    1234.56789"
  if [ "$backend" = ftxui ] && [ -n "$ARIGL" ] && [ -x "$ARIGL" ]; then
    "$ARIGL" snapshot --terminal --frames 60 --width 80 --height 24 --net --net-allow "$base" \
      --credential-store "$store" "$main" --instance "$base" >"$out/txwtf-arigl.txt" 2>&1
    check "$t: arigl snapshot --terminal resumes it too" "$out/txwtf-arigl.txt" \
      "@ada@127.0.0.1:$port  Ada Lovelace" "SCRIP    1234.56789"
  fi

  start "$backend" "$xdg" "$base"
  step "$t: started again, still signed in" "@ada@127.0.0.1:$port  Ada Lovelace"
  keys Tab; keys Tab; keys Enter # Refresh, Sign out
  step "$t: ada signs out" "Signed out." "Username: [ada"
  if [ "$(sessions_in "$store")" = 0 ]; then pass "$t: sign-out drops the session"; else
    fail "$t: the session is still in the store after signing out"
  fi
  stop
  # The server logged that session out: its token, put back, no longer works.
  "$ARI" snapshot --backend "$backend" --width 80 --height 24 --net --net-allow "$base" \
    --credential-store "$work/old-session-$backend" "$main" --instance "$base" \
    >"$out/txwtf-snap-$backend-old.txt" 2>&1
  check "$t: the server refuses the signed-out token" "$out/txwtf-snap-$backend-old.txt" \
    "Your session has expired. Sign in again."

  start "$backend" "$xdg" "$base" -- --user grace
  step "$t: the form for grace" "Username: [grace"
  sign_in "$work/password"
  step "$t: grace is asked for the emailed code" "Two-step verification" "Signing in as grace" \
    "We emailed you a code. It expires in 5 minutes."
  form_focus; type_text 000000; keys Tab; keys Enter
  step "$t: a wrong code" "That code didn't work. Try again, or go Back." "Code: []"
  if python3 -I -B "$here/smtp_sink.py" --dir "$work/mail" --code-for grace@example.org |
    tr -d '\n' >"$work/code" && [ -s "$work/code" ]; then
    pass "$t: the code came by email"
  else
    fail "$t: no code in the mail the instance sent"
  fi
  keys BTab; type_secret "$work/code"; keys Tab; keys Enter
  step "$t: the emailed code signs grace in" "@grace@127.0.0.1:$port  Grace Hopper" "SCRIP    0" "Value    \$0.00"
  tokens_from "$store"
  keys Tab; keys Tab; keys Enter
  step "$t: grace signs out" "Signed out."

  start "$backend" "$xdg" "$base" -- --user linus
  step "$t: the form for linus" "Username: [linus"
  sign_in "$work/password"
  step "$t: linus must change his password first" "Change your password at 127.0.0.1" \
    "Sign in to TX.WTF"
  if [ "$(sessions_in "$store")" = 0 ]; then pass "$t: and no session is kept"; else
    fail "$t: a session was kept for an account that must change its password"
  fi
  stop
done

# --- the rate limit ----------------------------------------------------------------------------

# With txwtf's limit on, ten wrong passwords in a row use up the minute's sign-ins.
stop_backend
start_backend 1 txwtf-backend-limited.txt
for _ in $(seq 10); do
  curl -s -o /dev/null -m 5 -H 'Content-Type: application/json' \
    -d '{"username": "ada", "password": "wrong"}' "$base/user/login"
done
start ftxui "$work/xdg-limit" "$base" -- --user ada
step "txwtf: the form, once the sign-ins are used up" "Username: [ada"
sign_in "$work/password"
step "txwtf: the client says to wait when txwtf answers 429" \
  "Too many attempts. Wait a minute, then try again."
stop

# --- the server gone ---------------------------------------------------------------------------

stop_backend
"$ARI" snapshot --width 80 --height 24 --net --net-allow "$base" \
  --credential-store "$work/session-for-later" "$main" --instance "$base" \
  >"$out/txwtf-snap-down.txt" 2>&1
check "with the server stopped, the client says it can't reach it" "$out/txwtf-snap-down.txt" \
  "Sign in to TX.WTF" "Can't reach 127.0.0.1:$port"

no_secrets_in_output "$work/secrets"
finish
