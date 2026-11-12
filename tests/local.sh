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
# tests/txwtf_local.py makes four accounts with txwtf's core functions: ada (1234.56789 SCRIP
# minted, two posts and a reply; the administrator), grace (the emailed second factor on), linus
# (force_password_change) and eve (for the Admin view to disable). Its email
# goes to tests/smtp_sink.py, where the tests read grace's sign-in code. Everything the client
# does goes through the real HTTP API.
#
# For each terminal backend (FTXUI, tvision), bin/nicotina --terminal runs in a tmux pane:
#   - ada: a wrong password; the right one: her home feed (empty: she follows no one) and the
#     public one (her posts, as cards), then her profile with her posts and replies from the
#     server's timeline, and the balance it works out; the session resumed by ari snapshot (and
#     arigl snapshot), and on restart; sign-out, after which the server refuses her old token;
#   - grace: the emailed code, a wrong one and then the one from the email; no posts, and a
#     balance of zero;
#   - linus: told to change his password in the web app first, and no session kept.
# Then ada, the instance's administrator, in the Admin view: each part as the server answers it;
# eve (tests/txwtf_local.py's fourth account) disabled, refused at sign-in, enabled; a group made,
# eve added and removed, a permission granted and revoked, the group deleted; an invite code made
# and turned off, where this txwtf has invite codes.
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
# Whether this ari shows pictures from a URL (image.url, libcvc 3.7.9 and later), as run.sh asks:
# then a card's avatar is a picture, not the author's initials.
pictures=
"$ARI" check --net "$main" 2>&1 | grep -q "optional requirement image.url" || pictures=1
ada_card="(AL) Ada Lovelace"
# The bar along the main window's top: its seven buttons are the first seven focus stops, and
# each new view starts with the focus on Back (stop 1): Tab k times reaches stop k + 1.
bar="[ Back ][ Home ][ Tags ][ Search ][ Alerts ][ Profile ][ Post ]"
[ -n "$pictures" ] && ada_card=" Ada Lovelace"

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
  # She follows no one, so her home feed is empty, as txwtf's is then.
  step "$t: ada signs in: her home feed, empty" "$bar" "Show: (*) Following" \
    "Your feed is empty. Follow people, or Show: Everyone." "Signed in to 127.0.0.1"
  for _ in $(seq 7); do keys Tab; done
  keys Right # past the bar to Show: Everyone
  step "$t: Everyone: the public timeline, a card a post" "(*) Everyone" \
    "$ada_card  @ada@127.0.0.1:$port" "│Bernoulli numbers, step by step." \
    "│Hello from the analytical engine." "[ Open ]"
  keys BTab; keys BTab; keys Enter # back past Post to Profile
  step "$t: her profile" "@ada@127.0.0.1:$port  Ada Lovelace" \
    "Writes notes on the analytical engine. Prefers punched cards t..." "Joined " \
    "Show: (*) Posts" "  Bernoulli numbers, step by step." "  Hello from the analytical engine."
  check_not "$t: ... her posts, not her reply" "$out/tmux-$(slug "$t: her profile").txt" \
    "Note G is the long one."
  for _ in $(seq 10); do keys Tab; done
  keys Right # past the bar, Refresh, Sign out and Admin (she is the administrator): Replies
  step "$t: the Replies tab: her reply" "(*) Replies" "  Note G is the long one."
  keys Right
  step "$t: the Balances tab: the balance the server works out" "(*) Balances" \
    "SCRIP    1234.56789" "Value    \$1234.57"
  check_not "$t: ... and no runway" \
    "$out/tmux-$(slug "$t: the Balances tab: the balance the server works out").txt" "Runway"
  check_store "$t: the host keeps the session, owner-only (0600 in 0700)" "$store"
  tokens_from "$store"
  cp "$store" "$work/old-session-$backend" # for after sign-out
  cp "$store" "$work/session-for-later"    # for when the server is gone
  stop

  "$ARI" snapshot --backend "$backend" --width 80 --height 24 --net --net-allow "$base" \
    --credential-store "$store" "$main" --instance "$base" >"$out/txwtf-snap-$backend.txt" 2>&1
  check "$t: ari snapshot resumes the session" "$out/txwtf-snap-$backend.txt" \
    "$bar" "Your feed is empty."
  if [ "$backend" = ftxui ] && [ -n "$ARIGL" ] && [ -x "$ARIGL" ]; then
    "$ARIGL" snapshot --terminal --frames 60 --width 80 --height 24 --net --net-allow "$base" \
      --credential-store "$store" "$main" --instance "$base" --start profile \
      >"$out/txwtf-arigl.txt" 2>&1
    check "$t: arigl snapshot --terminal resumes it too" "$out/txwtf-arigl.txt" \
      "@ada@127.0.0.1:$port  Ada Lovelace" "Hello from the analytical engine."
  fi

  start "$backend" "$xdg" "$base"
  step "$t: started again, still signed in" "$bar" "Show: (*) Following"
  # A post with a hashtag, against the server: Post, type, Enter; its hashtag's posts; Back;
  # Delete (the bar, the post's Tags and Open tag, Like, Repost, Author, Delete).
  for _ in $(seq 6); do keys Tab; done
  keys Enter # Post
  step "$t: a new post" "Who sees it: (*) Public"
  type_text "Hello from nicotina on $backend. #nicotina"
  keys Enter
  step "$t: posted: the post, with its hashtag" "Posted." \
    "Hello from nicotina on $backend. #nicotina" "Tags: (*) #nicotina" "[ Delete ]"
  for _ in $(seq 8); do keys Tab; done
  keys Enter # Open tag
  step "$t: the hashtag's posts, from the server" "#nicotina  ·  1 post" \
    "Hello from nicotina on $backend. #nicotina"
  keys Enter # Back
  step "$t: Back: the post" "Hello from nicotina on $backend. #nicotina" "[ Delete ]"
  for _ in $(seq 12); do keys Tab; done
  keys Enter # Delete
  step "$t: deleted: back to the feed" "Deleted." "Show: (*) Following"
  # The notifications, the hashtags and search, as the server answers them.
  for _ in $(seq 4); do keys Tab; done
  keys Enter # Alerts
  step "$t: the notifications" "otifications"
  keys Tab; keys Tab; keys Enter # Tags
  step "$t: the hashtags" "ashtag"
  keys Tab; keys Tab; keys Tab; keys Enter # Search: its field has the focus
  step "$t: search" "Find: ["
  type_text "Bernoulli"
  keys Enter
  step "$t: search finds her post" "found for \"Bernoulli\"" "Bernoulli numbers"
  start "$backend" "$xdg" "$base"
  step "$t: started again, to sign out" "$bar" "Show: (*) Following"
  for _ in $(seq 5); do keys Tab; done
  keys Enter # Profile
  step "$t: her profile, to sign out" "@ada@127.0.0.1:$port  Ada Lovelace" "[ Sign out ]"
  for _ in $(seq 8); do keys Tab; done
  keys Enter # past the bar and Refresh to Sign out
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
  step "$t: the emailed code signs grace in" "$bar" "Your feed is empty."
  tokens_from "$store"
  for _ in $(seq 5); do keys Tab; done
  keys Enter # Profile
  step "$t: grace's profile" "@grace@127.0.0.1:$port  Grace Hopper" "No posts yet."
  for _ in $(seq 9); do keys Tab; done
  keys Right; keys Right # the tabs: Balances
  step "$t: grace's balance: nothing minted" "(*) Balances" "SCRIP    0" "Value    \$0.00"
  keys BTab; keys Enter # back from the tabs to Sign out
  step "$t: grace signs out" "Signed out."

  start "$backend" "$xdg" "$base" -- --user linus
  step "$t: the form for linus" "Username: [linus"
  sign_in "$work/password"
  step "$t: linus must change his password first" "Change your password at 127.0.0.1" \
    "Sign in to tx.wtf"
  if [ "$(sessions_in "$store")" = 0 ]; then pass "$t: and no session is kept"; else
    fail "$t: a session was kept for an account that must change its password"
  fi
  stop
done

# --- the Admin view ----------------------------------------------------------------------------

# ada is the instance's administrator (txwtf_local.py). Each part of the Admin view as the server
# answers it; then, in FTXUI, what an administrator does there: an account disabled (the server
# refuses its sign-in) and enabled, a group made, a member added and removed, the group deleted,
# and an invite code made and turned off. (tests/run.sh covers both backends against the stub.)
t="txwtf (admin)"
curl -s -m 10 -o "$out/txwtf-openapi.json" "$base/openapi.json"
has_route() { grep -qF "\"$1\"" "$out/txwtf-openapi.json"; }
admin_xdg=$work/xdg-admin
admin_store=$admin_xdg/nicotina/credentials
start ftxui "$admin_xdg" "$base" -- --user ada --start admin
step "$t: the form" "Username: [ada"
sign_in "$work/password"
# (txwtf keeps an account of its own, __system__, beside the four tests/txwtf_local.py makes)
step "$t: --start admin: the accounts, from the server" "Admin: (*) Users" \
  "accounts, the newest first" "@eve  Eve Example" "@linus  Linus" "@grace  Grace Hopper"
if grep -qE '@ada  Ada Lovelace +[0-9-]{10} +admin' \
  "$out/tmux-$(slug "$t: --start admin: the accounts, from the server").txt"; then
  pass "$t: ... ada's row says admin"
else
  fail "$t: ada's row doesn't say admin" \
    "$out/tmux-$(slug "$t: --start admin: the accounts, from the server").txt"
fi
tokens_from "$admin_store"
stop
admin_snap() { # admin_snap NAME START: an 80x60 frame of the view START opens, as ada
  "$ARI" snapshot --width 80 --height 60 --net --net-allow "$base" --credential-store "$admin_store" \
    "$main" --instance "$base" --start "$2" >"$out/txwtf-admin-$1.txt" 2>&1
}
admin_snap groups admin:groups
check "$t: Admin: the server's groups" "$out/txwtf-admin-groups.txt" "(*) Groups" " group" \
  "[ Create ]"
admin_snap site admin:site
check "$t: Admin: the site's settings" "$out/txwtf-admin-site.txt" "(*) Site" "Title: [" \
  "Time zone: [" "New accounts join " "Passwords: "
admin_snap log admin:log
check "$t: Admin: the system log" "$out/txwtf-admin-log.txt" "(*) Log" "events, the newest first"
admin_snap user auser:1
check "$t: Admin: an account, from the server" "$out/txwtf-admin-user.txt" \
  "@ada@127.0.0.1:$port  Ada Lovelace" "Administrator: yes" "Email: ada@example.org" \
  "Your own account: Disable and Remove admin aren't offered."

# eve: found, disabled, refused at sign-in, enabled, signed in.
find_eve() { # from the Admin view's start: Find user, eve, her Open
  for _ in $(seq 8); do keys Tab; done
  type_text eve
  keys Enter
  step "$t: Find user: eve ($1)" "1 account with \"eve\" in the username" "@eve  Eve Example"
  keys Tab; keys Enter
  step "$t: eve's account ($1)" "@eve@127.0.0.1:$port  Eve Example"
}
start ftxui "$admin_xdg" "$base" -- --start admin
step "$t: the Admin view" "Admin: (*) Users"
find_eve "to disable"
check "$t: ... as the server has it" "$out/tmux-$(slug "$t: eve's account (to disable)").txt" \
  "Account: active · Administrator: no · Two-step sign-in: off" "[ Disable ][ Make admin ][ Profile ]"
for _ in $(seq 7); do keys Tab; done
keys Enter # Disable
step "$t: Disable: the server disables her" "@eve is disabled: signed out, and can't sign in." \
  "Account: disabled" "[ Enable ]"
start ftxui "$work/xdg-eve" "$base" -- --user eve
step "$t: the form for eve" "Username: [eve"
sign_in "$work/password"
step "$t: the server refuses a disabled account" \
  "This account is disabled. Ask the site's administrators." "Username: [eve"
start ftxui "$admin_xdg" "$base" -- --start admin
step "$t: the Admin view, to enable her" "Admin: (*) Users"
find_eve "to enable"
for _ in $(seq 7); do keys Tab; done
keys Enter # Enable
step "$t: Enable" "@eve can sign in again." "Account: active"
start ftxui "$work/xdg-eve" "$base" -- --user eve
step "$t: the form for eve again" "Username: [eve"
sign_in "$work/password"
step "$t: enabled: eve signs in" "$bar" "Your feed is empty."
tokens_from "$work/xdg-eve/nicotina/credentials"

# A group: made, eve added and removed, deleted (Delete group asks first).
groups=$(grep -c '\[ Open \]' "$out/txwtf-admin-groups.txt")
start ftxui "$admin_xdg" "$base" -- --start admin:groups
step "$t: the groups, to make one" "(*) Groups" "[ Create ]"
for _ in $(seq $((8 + groups))); do keys Tab; done # the bar, the parts, each group's Open
type_text "nicotina-tests"; keys Tab; type_text "Made by tests/local.sh"; keys Tab; keys Enter
step "$t: Create: the server makes the group" "Created the group nicotina-tests." \
  "nicotina-tests      Made by tests/local.sh"
keys BTab; keys BTab; keys BTab; keys Enter # its Open, the last, before the two fields
step "$t: its Open: no members" "nicotina-tests  ·  0 members" "Made by tests/local.sh"
for _ in $(seq 8); do keys Tab; done # the bar and Permissions: Add member
type_text eve
keys Tab; keys Enter # Add
step "$t: Add member: eve" "Added @eve to nicotina-tests." "nicotina-tests  ·  1 member" \
  "@eve  Eve Example"
keys BTab; keys BTab; keys Enter # her Remove, before the field
step "$t: her Remove" "@eve is out of nicotina-tests." "nicotina-tests  ·  0 members"
for _ in $(seq 8); do keys Tab; done
keys Enter # Permissions: nothing had the focus, so Tab 8 reaches stop 8
step "$t: its permissions: none yet" "nicotina-tests: 0 permissions, what its members may do"
for _ in $(seq 8); do keys Tab; done # the bar and Find permission: Permission
type_text "SocialHashtagRead"; keys Tab; keys Enter # the Grant button
step "$t: Grant: the server grants it" "nicotina-tests grants SocialHashtagRead now." \
  "nicotina-tests: 1 permission" "SocialHashtagRead"
keys BTab; keys BTab; keys Enter # its Revoke, before the field
step "$t: Revoke: the server takes it back" "nicotina-tests no longer grants SocialHashtagRead." \
  "nicotina-tests: 0 permissions"
keys Tab; keys Enter # Back (Revoke went, so nothing had the focus: Tab reaches Back)
step "$t: Back: the group" "nicotina-tests  ·  0 members" "[ Delete group ]"
for _ in $(seq 10); do keys Tab; done
keys Enter # Delete group: past the bar, Permissions, Add member and Add
step "$t: Delete group asks" "Delete nicotina-tests? Its members' accounts stay."
keys Tab; keys Enter # Yes, delete it
step "$t: Yes, delete it: the server deletes it" "Deleted the group nicotina-tests." "(*) Groups"

if has_route /invite/mode; then
  admin_snap invites admin:invites
  check "$t: Admin: sign-up and invite codes" "$out/txwtf-admin-invites.txt" \
    "Sign-up: (*) Open  ( ) Invite only" "You have no codes."
  start ftxui "$admin_xdg" "$base" -- --start admin:invites
  step "$t: the invite codes, to make one" "(*) Invites" "[ New code ]"
  for _ in $(seq 9); do keys Tab; done # the bar, the parts and Sign-up: Uses
  type_text 3; keys Tab; type_text "local.sh"; keys Tab; keys Enter # New code
  step "$t: New code: the server makes one" "New code: " "0 of 3 used  on"
  start ftxui "$admin_xdg" "$base" -- --start admin:invites
  step "$t: the codes again" "(*) Invites" "[ Turn off ]"
  for _ in $(seq 9); do keys Tab; done
  keys Enter # its Turn off, past the bar, the parts and Sign-up
  step "$t: Turn off" "That code is off: it signs no one up now." "0 of 3 used  off"
else
  skip "$t: invite codes (this txwtf has no /invite/mode)"
fi
# The log has the changes. The server logs its background jobs every few seconds, so its first
# page soon holds only those: pick the kind of event (Events: Group Create is the eighth after
# All, Group Delete the ninth).
start ftxui "$admin_xdg" "$base" -- --start admin:log
step "$t: the system log, to find the changes" "(*) Log" "events, the newest first"
for _ in $(seq 8); do keys Tab; done # the bar and the parts: Events
for _ in $(seq 8); do keys Right; done
step "$t: Events: Group Create: the group made here" ": Group Create, the newest first" \
  "Group Create"
keys Right
step "$t: Events: Group Delete: and deleted" ": Group Delete, the newest first" "Group Delete"
stop

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
  "Sign in to 127.0.0.1:$port" "Can't reach 127.0.0.1:$port"

no_secrets_in_output "$work/secrets"
finish
