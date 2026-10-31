#!/usr/bin/env bash
# tests/live.sh: nicotina against a live TX.WTF instance, signed in as a test account.
#
#   NICOTINA_LIVE_ENV=~/.config/nicotina/dev.tx.wtf-test-account.env ARI=... tests/live.sh
#
# The env file is owner-only and lives outside the repository. It holds three lines:
#
#   NICOTINA_TEST_INSTANCE=https://dev.tx.wtf
#   NICOTINA_TEST_USER=<a test account's username>
#   NICOTINA_TEST_PASSWORD=<its password>
#
# Use a test instance and a test account made for this, never a person's account. The account
# needs no second factor and no forced password change.
#
# For each terminal backend (FTXUI, tvision), bin/nicotina --terminal runs in a tmux pane:
#   - a wrong password;
#   - the right one: the home feed and the public one, then the profile, its Posts tab and the
#     Balances tab (SCRIP and its value), and the host keeps the session;
#   - ari snapshot and arigl snapshot --terminal resume that session from the store;
#   - started again, still signed in;
#   - sign out, and the session is dropped.
# The password is typed through a tmux buffer, so it is in no command line. At the end, every
# output is searched for the password and for the session tokens the host stored (read from its
# store, never printed).
set -uo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

env_file=${NICOTINA_LIVE_ENV:-}
if [ -z "$env_file" ] || [ ! -r "$env_file" ]; then
  echo "tests: set NICOTINA_LIVE_ENV to a test account's env file (see the top of $0)" >&2
  exit 2
fi
case $(mode_of "$env_file") in
  600 | 400) ;;
  *) echo "tests: $env_file must be owner-only (chmod 600)" >&2; exit 2 ;;
esac
value() { sed -n "s/^$1=//p" "$env_file" | head -n 1; }
instance=$(value NICOTINA_TEST_INSTANCE)
user=$(value NICOTINA_TEST_USER)
host=${instance#*://}
host=${host%%/*}
(umask 077 && value NICOTINA_TEST_PASSWORD | tr -d '\n' >"$work/password")
(umask 077 && printf 'not-the-password-%s' "$$" >"$work/wrong")
if [ -z "$instance" ] || [ -z "$user" ] || [ ! -s "$work/password" ]; then
  echo "tests: $env_file lacks NICOTINA_TEST_INSTANCE, _USER or _PASSWORD" >&2
  exit 2
fi
cp "$work/password" "$work/secrets"
echo "live: $instance as $user; outputs in $out"
command -v tmux >/dev/null || { echo "tests: live.sh needs tmux" >&2; exit 2; }
STEP_SECONDS=20 # a live instance answers more slowly than the stub

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

for backend in ftxui tvision; do
  xdg=$work/xdg-$backend
  store=$xdg/nicotina/credentials
  t="live $host ($backend)"

  start "$backend" "$xdg" "$instance" -- --user "$user"
  step "$t: the sign-in form" "Username: [$user" "Instance: $instance"
  sign_in "$work/wrong"
  step "$t: a wrong password" "Wrong username or password."

  start "$backend" "$xdg" "$instance" -- --user "$user"
  step "$t: the form again" "Username: [$user"
  sign_in "$work/password"
  step "$t: signed in, the home feed" "@$user@$host" "[ Profile ][ Refresh ][ Sign out ]" \
    "Show: (*) Following" "Signed in to $host."
  keys Tab; keys Tab; keys Tab; keys Tab; keys Right # past Profile, Refresh, Sign out: Everyone
  step "$t: Everyone: the instance's public timeline" "(*) Everyone"
  check_not "$t: ... loaded" "$out/tmux-$(slug "$t: Everyone: the instance's public timeline").txt" \
    "Couldn't load" "Something went wrong"
  keys BTab; keys BTab; keys BTab; keys Enter # back past Sign out and Refresh to Profile
  step "$t: the profile" "Show: (*) Posts" "@$user@$host" "Joined " " posts · " " views" \
    "[ Newer ][ Older ]"
  keys Tab; keys Tab; keys Tab; keys Tab; keys Right; keys Right # the tabs: Balances
  step "$t: the Balances tab" "(*) Balances" "SCRIP    " "Value    \$"
  check_not "$t: ... and no runway" "$out/tmux-$(slug "$t: the Balances tab").txt" "Runway"
  check_store "$t: the host keeps the session, owner-only (0600 in 0700)" "$store"
  # The token the host keeps, for the scan at the end; it is never printed.
  awk '!/^#/ && NF == 3 { print $3 }' "$store" >>"$work/secrets"
  stop

  "$ARI" snapshot --backend "$backend" --width 80 --height 24 --net --net-allow "$instance" \
    --credential-store "$store" "$main" --instance "$instance" >"$out/live-snap-$backend.txt" 2>&1
  check "$t: ari snapshot resumes the stored session" "$out/live-snap-$backend.txt" \
    "@$user@$host" "Show: (*) Following" "Signed in to $host."
  if [ "$backend" = ftxui ] && [ -n "$ARIGL" ] && [ -x "$ARIGL" ]; then
    "$ARIGL" snapshot --terminal --frames 60 --width 80 --height 24 --net --net-allow "$instance" \
      --credential-store "$store" "$main" --instance "$instance" >"$out/live-arigl.txt" 2>&1
    check "$t: arigl snapshot --terminal resumes it too" "$out/live-arigl.txt" "@$user@$host" \
      "Show: (*) Following"
  fi

  start "$backend" "$xdg" "$instance"
  step "$t: started again, still signed in" "@$user@$host" "Show: (*) Following"
  keys Tab; keys Tab; keys Tab; keys Enter # past Profile and Refresh to Sign out
  step "$t: signed out" "Signed out." "Username: [$user"
  if [ "$(sessions_in "$store")" = 0 ]; then pass "$t: sign-out drops the session"; else
    fail "$t: the session is still in the store after signing out"
  fi
  stop
done

no_secrets_in_output "$work/secrets"
finish
