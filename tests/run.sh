#!/usr/bin/env bash
# tests/run.sh: nicotina's M0 tests, against a stub TX.WTF instance (tests/stub_txwtf.py).
#
#   tests/run.sh                                   # ari and arigl from PATH
#   ARI=/path/to/ari ARIGL=/path/to/arigl tests/run.sh
#
#  1. bin/nicotina --dry-run: the host, flags and credential store it picks.
#  2. ari check: without the network flags the document refuses to load, and says why.
#  3. ari snapshot, FTXUI and tvision: the sign-in form; a stored session, resumed (the profile,
#     laid out as the web app's: the banner and avatar slots, the card, the Posts tab); a stored
#     session the server no longer knows (back to the form, and the host forgets it).
#  4. arigl snapshot, if arigl is here: the resumed session as text (--terminal) and in a window
#     (a PNG; checked only for being drawn, since nothing here reads pixels).
#  5. bin/nicotina --terminal in a tmux pane, FTXUI and tvision, typed at the way a person types:
#     sign in, see the profile, the Replies and Balances tabs and an older page of posts, start
#     again still signed in, sign out; a wrong password; the emailed code, wrong and then right;
#     an account that must change its password.
#
# `ari snapshot` lays a frame out with FTXUI whatever --backend says, so 5 is what checks the
# tvision desktop itself. 5 needs tmux; without it those cases are skipped.
#
# Every output (frames, panes, the hosts' stderr, the stub's log) is kept in $NICOTINA_TEST_OUT
# (a fresh temp dir by default) and searched for the stub's session tokens at the end: none may
# appear anywhere. Exits non-zero if any check failed.
set -uo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
stub_pid=
stop_stub() { [ -z "$stub_pid" ] || kill "$stub_pid" 2>/dev/null; }
on_exit stop_stub

# --- the stub ---------------------------------------------------------------------------------

python3 -I -B -c "
import sys; sys.path.insert(0, sys.argv[1]); import stub_txwtf as s
for name, token in list(s.TOKENS.items()) + [('stale', s.STALE_TOKEN)]: print(name, token)" \
  "$here" >"$work/token-names"
awk '{ print $2 }' "$work/token-names" >"$work/tokens" # for the scan at the end
token() { awk -v n="$1" '$1 == n { print $2 }' "$work/token-names"; } # never echoed

python3 -I -B "$here/stub_txwtf.py" --port 0 --port-file "$work/port" --log "$out/stub.log" \
  --signed-in ada --signed-in grace --signed-in mary --signed-in bob@peer.example \
  --signed-in slowpoke \
  2>"$out/stub.stderr" &
stub_pid=$!
for _ in $(seq 100); do [ -s "$work/port" ] && break; sleep 0.05; done
[ -s "$work/port" ] || { echo "tests: the stub did not start" >&2; cat "$out/stub.stderr" >&2; exit 2; }
base="http://127.0.0.1:$(cat "$work/port")"
hostport=${base#http://} # the instance as a handle names it
echo "stub TX.WTF at $base; outputs in $out"

# A credential store holding one session, as the host writes one: owner-only.
seed_store() { # seed_store PATH TOKEN-NAME [ORIGIN]
  mkdir -p "$(dirname "$1")" && chmod 700 "$(dirname "$1")"
  (umask 077 && printf 'txwtf %s %s\n' "${3:-$base}" "$(token "$2")" >"$1")
}

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
# ari-media (ari with sound and video) is the terminal's ari where it is installed.
mkdir -p "$work/fakebin" && printf '#!/bin/sh\n' >"$work/fakebin/ari-media" &&
  chmod +x "$work/fakebin/ari-media"
launch launcher-ari-media NICOTINA_ARI= PATH="$work/fakebin:/usr/bin:/bin" -- --terminal
check "launcher: a terminal gets ari-media (sound and video) where it is installed" \
  "$out/launcher-ari-media.txt" "$work/fakebin/ari-media 'run' '--net'"
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

# Whether this ari shows pictures from a URL (image.url, transfix/libcvc#931): where it does,
# the avatar and the banner are pictures, not the placeholders.
pictures=
"$ARI" check --net "$main" 2>&1 | grep -q "optional requirement image.url" || pictures=1
# Whether this ari plays video and audio (media.player: ari-media and arigl with
# transfix/libcvc#935): then a card's video and recording have players, three Tab stops each
# (Play, the seek slider, Mute).
media=
"$ARI" check --net "$main" 2>&1 | grep -q "optional requirement media.player" || media=1
player_stops=0
[ -n "$media" ] && player_stops=3

for backend in ftxui tvision; do
  snap "snap-$backend-signin" "$backend" "" --user ada
  check "ari snapshot ($backend): the sign-in form" "$out/snap-$backend-signin.txt" \
    "Sign in to TX.WTF" "Instance: $base" "Username: [ada" "Password: []" "[ Sign in ]"

  store=$work/snap-$backend/credentials
  seed_store "$store" ada
  snap "snap-$backend-feed" "$backend" "$store"
  check "ari snapshot ($backend): a stored session opens the home feed, a card a post" \
    "$out/snap-$backend-feed.txt" "╭ Home ─" "│@ada@$hostport " "[ Profile ][ Refresh ][ Sign out ]" \
    "Show: (*) Following  ( ) Everyone" "Signed in to 127.0.0.1" \
    " Charles Babbage  @charles@$hostport" " 2026-10-30 22:40" \
    "││The Difference Engine No. 2, working at last.                          │"
  if [ -z "$pictures$media" ]; then
    check "ari snapshot ($backend): ... its attachments, a row each" "$out/snap-$backend-feed.txt" \
      "││[image] engine-diagram.png · 47 KB · The engine, from the side         │" \
      "││[video] engine.mp4 · 11 KB                                             │"
  fi
  if [ -z "$pictures" ]; then
    check "ari snapshot ($backend): ... the author's initials, and the next card" \
      "$out/snap-$backend-feed.txt" "││(CB) Charles Babbage  @charles@$hostport" "││     2026-10-30 22:40" \
      "││↩5 ⇄3 ♥21 · 310 views                                         [ Open ] │" \
      "││(GH) Grace Hopper  @grace@$hostport"
  fi
  grep -v '^ari: ' "$out/snap-$backend-feed.txt" >"$work/frame.txt"
  if [ "$(wc -l <"$work/frame.txt")" -le 24 ] && [ "$(wc -L <"$work/frame.txt")" -le 80 ] &&
    grep -qE '^  ╰[─┴]{70}' "$work/frame.txt"; then
    pass "ari snapshot ($backend): the feed fits 80x24, its frame whole"
  else
    fail "ari snapshot ($backend): the feed runs past 80x24" "$out/snap-$backend-feed.txt"
  fi
  snap "snap-$backend-resume" "$backend" "$store" --start profile
  check "ari snapshot ($backend): --start profile: the profile, as the web app lays it out" \
    "$out/snap-$backend-resume.txt" "╭ Profile ─" " @ada@$hostport  Ada Lovelace" \
    " Writes notes on the analytical engine. Prefers punched cards t..." \
    " admin · Verified · online" " GB · Joined 2025-03-01 · 42 posts · 1234 views" \
    "│Groups: users, analysts" "[ Feed ][ Refresh ][ Sign out ]│" \
    "Show: (*) Posts  ( ) Replies  ( ) Balances" \
    "2026-10-30  Finished the notes on Menabrea's paper. Note G is th...  ↩2 ♥5" \
    "2026-10-28  The Analytical Engine weaves algebraic patterns just...  ↩4 ♥9" \
    "2026-10-24  Hello, TX.WTF." "[ Newer ][ Older ]  Page 1" "Signed in to 127.0.0.1"
  if [ -z "$pictures" ]; then
    check "ari snapshot ($backend): ... the banner and avatar placeholders" \
      "$out/snap-$backend-resume.txt" "│████████" "│╭──────╮ @ada@$hostport  Ada Lovelace" \
      "││  AL  │ Writes notes" "││      │ admin · Verified" "│╰──────╯ GB · Joined"
  fi
  # The owner found the SCRIP runway (days left at the current burn) confusing: it is gone.
  check_not "ari snapshot ($backend): ... no Runway, no replies on the Posts tab" \
    "$out/snap-$backend-resume.txt" "Runway" "Thank you, Mr. Babbage." "Testing, testing."
  # The frame alone: a host's warnings (an older ari's about the spinner) go to the same file.
  grep -v '^ari: ' "$out/snap-$backend-resume.txt" >"$work/frame.txt"
  if [ "$(wc -l <"$work/frame.txt")" -le 24 ] && [ "$(wc -L <"$work/frame.txt")" -le 80 ]; then
    pass "ari snapshot ($backend): the profile fits 80x24"
  else
    fail "ari snapshot ($backend): the profile runs past 80x24" "$out/snap-$backend-resume.txt"
  fi

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

# The card's first row: the full handle, @user@instance, then the display name cut to fit the
# 65 columns beside the avatar.
store=$work/snap-handles/credentials
seed_store "$store" mary
snap snap-handle-long ftxui "$store" --start profile
long_name="Mary Kenneth Keller of the University of Wisconsin-Madison"
handle="@mary@$hostport"
room=$((65 - ${#handle} - 2))
check "ari snapshot: a long display name is cut to fit beside the full handle" \
  "$out/snap-handle-long.txt" "$handle  ${long_name:0:room-3}..."
check_not "ari snapshot: ... and not drawn whole" "$out/snap-handle-long.txt" "$long_name"
# A brokered account keeps its home instance: txwtf names it bob@peer.example.
seed_store "$store" bob@peer.example
snap snap-handle-brokered ftxui "$store" --start profile
check "ari snapshot: a brokered account shows its home instance, not this one" \
  "$out/snap-handle-brokered.txt" "@bob@peer.example  Bob"
check_not "ari snapshot: ... with nothing added, and no placeholder email" \
  "$out/snap-handle-brokered.txt" "@bob@peer.example@" "fedauth-"
# The instance below a path: the handle and messages name the host alone.
seed_store "$store" ada
"$ARI" snapshot --width 80 --height 24 --net-allow "$base" --credential-store "$store" "$main" \
  --instance "$base/txwtf/" --start profile >"$out/snap-handle-path.txt" 2>&1
check "ari snapshot: an instance URL with a path: the handle names the host" \
  "$out/snap-handle-path.txt" "@ada@$hostport  Ada Lovelace" "Signed in to $hostport."
# A default port is not part of the host: https://example.invalid:443 is example.invalid.
seed_store "$store" ada https://example.invalid
"$ARI" snapshot --width 80 --height 24 --net-allow https://example.invalid \
  --credential-store "$store" "$main" --instance https://example.invalid:443/ \
  >"$out/snap-handle-port.txt" 2>&1
check "ari snapshot: a default port is left out of the host" "$out/snap-handle-port.txt" \
  "Can't reach example.invalid: "

# The whole first page of the feed, in a tall terminal: every kind of card.
seed_store "$store" ada
"$ARI" snapshot --width 80 --height 200 --net-allow "$base" --credential-store "$store" "$main" \
  --instance "$base" >"$out/snap-feed-tall.txt" 2>&1
check "ari snapshot: the feed's first page: attachments, a repost, a paid post, rich text" \
  "$out/snap-feed-tall.txt" "[audio] lecture.ogg · 5 KB · Lecture, part one" \
  "[image] engine-diagram.png · 47 KB · The engine, from the side" "[video] engine.mp4 · 11 KB" \
  "│⇄ Charles Babbage reposted" " Ada Lovelace  @ada@$hostport" " 2026-10-30 09:15" \
  " Alan Turing  @alan@peer.example" " 2026-10-30 19:30" \
  "│A ship in port is safe, but that's not what ships are built for. Sail" \
  "│is to get permission, and the most dangerous phrase in the language..." \
  "Found a moth in relay 70. First actual case of bug being found." \
  "[image] moth.png · 29 KB · The moth, taped into the log book" \
  "🔒 This post is locked. Pay 5 scrip to unlock." "[file] cobol-notes.pdf · 2 KB" \
  "[image] relay-70.png · 30 KB" "+1 more (Open shows them all)" "[ Load more ]  10 posts"
check_not "ari snapshot: ... not the next page, nor someone ada doesn't follow, nor HTML" \
  "$out/snap-feed-tall.txt" "Good morning, TX.WTF." "Hello from someone you don't follow." \
  "<p>" "<em>" "log-book.png"
seed_store "$store" grace
snap snap-feed-empty ftxui "$store"
check "ari snapshot: following no one: the feed says so" "$out/snap-feed-empty.txt" \
  "Your feed is empty. Follow people, or Show: Everyone."

# Pictures, where the host shows them from a URL (image.url, transfix/libcvc#931): the profile's
# avatar and banner and the cards' avatars and pictures are drawn (half-blocks in a snapshot)
# where the placeholders were, and fetched without the session token (txwtf's /uploads needs
# none, and the document never asks the host to send one there).
if [ -z "$pictures" ]; then
  skip "ari snapshot: pictures by URL (this ari has no image.url; transfix/libcvc#931)"
else
  seed_store "$store" ada
  snap snap-pictures-profile ftxui "$store" --start profile
  check_not "ari snapshot: the profile's avatar and banner are pictures, not placeholders" \
    "$out/snap-pictures-profile.txt" "╭──────╮" "│  AL  │" "████████"
  check "ari snapshot: ... drawn in half-blocks" "$out/snap-pictures-profile.txt" "▀" \
    "@ada@$hostport  Ada Lovelace"
  "$ARI" snapshot --width 80 --height 200 --net-allow "$base" --credential-store "$store" "$main" \
    --instance "$base" >"$out/snap-pictures-feed.txt" 2>&1
  check_not "ari snapshot: the cards' avatars are pictures, not initials" \
    "$out/snap-pictures-feed.txt" "(CB) Charles" "(GH) Grace"
  check "ari snapshot: ... but a video avatar keeps its initials" "$out/snap-pictures-feed.txt" \
    "(AT) Alan Turing"
  check "ari snapshot: ... and the cards' text is all there" "$out/snap-pictures-feed.txt" \
    "Charles Babbage  @charles@$hostport" "[image] moth.png · 29 KB" "▀"
  for pic in /uploads/u1/avatar-3f9c.png /uploads/u1/header-77a1.png \
    /uploads/u7/avatar-c4b1.png /static/img/atxcf_logo_small.jpg /uploads/media/moth.png; do
    if grep -F "\"path\": \"$pic\"" "$out/stub.log" | grep -qF '"authorization": "none"' &&
      ! grep -F "\"path\": \"$pic\"" "$out/stub.log" | grep -qvF '"authorization": "none"'; then
      pass "the picture $pic was fetched, without the session token"
    else
      fail "the picture $pic was not fetched, or was sent a token" "$out/stub.log"
    fi
  done
  # A video avatar keeps the placeholder (no video widget yet), and isn't fetched as a picture.
  seed_store "$store" bob@peer.example
  snap snap-pictures-video-avatar ftxui "$store" --start profile
  check "ari snapshot: a video avatar keeps its placeholder" "$out/snap-pictures-video-avatar.txt" \
    "│╭──────╮ @bob@peer.example  Bob" "││  B   │"
  check_not "ari snapshot: ... and isn't fetched as a picture" "$out/stub.log" \
    '"path": "/uploads/u5/avatar-loop.mp4"' '"path": "/uploads/u8/avatar-loop.webm"'
fi

# Video and audio, where the host has a player: the first card's video and the third card's
# recording have their controls, and the recordings were fetched without the session token. (In
# tmux, below, Play runs the video to its end: its 2 s.)
if [ -z "$media" ]; then
  skip "ari snapshot: video and audio players (this ari has no media.player; ari-media, transfix/libcvc#935)"
else
  seed_store "$store" ada
  "$ARI" snapshot --width 80 --height 200 --net-allow "$base" --credential-store "$store" "$main" \
    --instance "$base" >"$out/snap-feed-players.txt" 2>&1
  # (ari snapshot doesn't wait for a player whose URL comes from a reply, so not the durations)
  check "ari snapshot: the cards' video and recording have players" "$out/snap-feed-players.txt" \
    "[ Play ]" "Mute" "[video] engine.mp4 · 11 KB" "[audio] lecture.ogg · 5 KB"
  if [ "$(grep -c '\[ Play \]' "$out/snap-feed-players.txt")" -ge 2 ]; then
    pass "ari snapshot: ... one each"
  else
    fail "ari snapshot: fewer than two players" "$out/snap-feed-players.txt"
  fi
  for rec in /uploads/media/engine.mp4 /uploads/media/lecture.ogg; do
    if grep -F "\"path\": \"$rec\"" "$out/stub.log" | grep -qF '"authorization": "none"' &&
      ! grep -F "\"path\": \"$rec\"" "$out/stub.log" | grep -qvF '"authorization": "none"'; then
      pass "the recording $rec was fetched, without the session token"
    else
      fail "the recording $rec was not fetched, or was sent a token" "$out/stub.log"
    fi
  done
fi

# The spinner, while a request is out: slowpoke's profile takes the stub 12 s, longer than
# `ari snapshot` waits for requests (10 s), so the frame shows the start-up line still turning.
if "$ARI" check --net "$main" 2>&1 | grep -q "optional requirement spinner"; then
  skip "ari snapshot: the spinner (this ari has no spinner widget; transfix/libcvc#915)"
  have_spinner=
else
  have_spinner=1
  seed_store "$store" slowpoke
  snap snap-spinner ftxui "$store"
  if [ -n "$(spinner_glyph "$out/snap-spinner.txt" "Connecting to $hostport ...")" ]; then
    pass "ari snapshot: a spinner turns beside 'Connecting to ...' while the request is out"
  else
    fail "ari snapshot: no spinner beside 'Connecting to ...'" "$out/snap-spinner.txt"
  fi
fi

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
  check "arigl snapshot --terminal: the feed" "$out/arigl-terminal.txt" \
    "@ada@$hostport" "Show: (*) Following" " Charles Babbage  @charles@$hostport" \
    "The Difference Engine No. 2, working at last."
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

# fits_80x24 NAME FILE: an 80x24 pane shows the window's bottom edge, nothing wider than 80.
fits_80x24() {
  if grep -qE '[╰┗][─┴━┷]{20}|└─═{20}' "$2" && [ "$(wc -L <"$2")" -le 80 ]; then pass "$1"; else
    fail "$1: the window's frame is cut off at 80x24" "$2"
  fi
}

masked=
if masks_passwords; then masked=1; else
  skip "the password masked as it is typed (this ari has no password fields; transfix/libcvc#906)"
fi
if ! command -v tmux >/dev/null; then
  skip "bin/nicotina in tmux: no tmux"
else
  for backend in ftxui tvision; do
    xdg=$work/xdg-$backend
    store=$xdg/nicotina/credentials
    t="nicotina --terminal --backend $backend"

    start "$backend" "$xdg" "$base"
    step "$t: the sign-in form" "Sign in to TX.WTF" "Instance: $base"
    form_focus; type_text ada; keys Tab; type_text "correct horse"
    if [ -n "$masked" ]; then # a bullet per character, never the text
      step "$t: the password is masked as it is typed" "Password: [•••••••••••••"
      check_not "$t: ... and not shown" "$out/tmux-$(slug "$t: the password is masked as it is typed").txt" \
        "correct horse"
    fi
    keys Tab; keys Enter
    step "$t: signed in, the home feed" "Home" "@ada@$hostport" "Show: (*) Following" \
      " Charles Babbage  @charles@$hostport" " 2026-10-30 22:40" \
      "The Difference Engine No. 2, working at last."
    check_store "$t: the host keeps the session, owner-only (0600 in 0700)" "$store"
    check_not "$t: the password is not on the screen" \
      "$out/tmux-$(slug "$t: signed in, the home feed").txt" "correct horse"
    keys Tab; keys Enter # Profile
    step "$t: Profile: the profile" "@ada@$hostport  Ada Lovelace" "admin · Verified · online" \
      "GB · Joined 2025-03-01 · 42 posts · 1234 views" "Groups: users, analysts" \
      "(*) Posts" "Finished the notes on Menabrea's paper." "Page 1"
    # The tabs: Tab past Feed, Refresh and Sign out to them, then Right picks the next one.
    keys Tab; keys Tab; keys Tab; keys Tab; keys Right
    step "$t: the Replies tab" "(*) Replies" "2026-10-29  Agreed: the engine might compose music" \
      "2026-10-25  Thank you, Mr. Babbage."
    check_not "$t: ... and no posts that aren't replies" \
      "$out/tmux-$(slug "$t: the Replies tab").txt" "Finished the notes"
    keys Right
    step "$t: the Balances tab: SCRIP and its value, and no runway" "(*) Balances" \
      "SCRIP    1234.56789" "Value    \$1234.57"
    check_not "$t: ... no runway" "$out/tmux-$(slug "$t: the Balances tab: SCRIP and its value, and no runway").txt" \
      "Runway" "days"
    keys Right # round to Posts again, then Older (Newer is off on the first page)
    step "$t: back to Posts" "(*) Posts" "Finished the notes on Menabrea's paper."
    keys Tab; keys Enter
    step "$t: Older: the next page" "Page 2" "2026-10-23  Testing, testing."
    keys BTab; keys Enter
    step "$t: Newer: the first page again" "Page 1" "Finished the notes on Menabrea's paper."

    # The feed: a card's Open shows the whole post; Back; Load more adds the next page.
    start "$backend" "$xdg" "$base"
    step "$t: started again, still signed in: the feed" "@ada@$hostport" " Charles Babbage"
    # past Profile, Refresh, Sign out, Show (and, with a player, the first card's video)
    for _ in $(seq $((5 + player_stops))); do keys Tab; done
    keys Enter
    step "$t: Open: the whole post, its attachments' URLs and its reactions" "[ Back ]" \
      " Charles Babbage  @charles@$hostport" " 2026-10-30 22:40" \
      "↩5 ⇄3 ♥21 · 310 views" "Reactions: :thumbsup: 12  :heart: 9" \
      "[image] engine-diagram.png · 47 KB · The engine, from the side" \
      "  $base/uploads/media/engine-diagram.png" "$base/app/post/312"
    keys Enter # Back has the focus
    step "$t: Back to the feed" "Show: (*) Following" " Charles Babbage"
    # The feed comes back with nothing focused: Load more is the 15th stop (Profile, Refresh,
    # Sign out, Show, then ten cards' Open), and 6 more with players (a video and a recording).
    for _ in $(seq $((15 + 2 * player_stops))); do keys Tab; done
    keys Enter
    step "$t: Load more: the next page, below the first" "13 posts; no more" \
      "Good morning, TX.WTF."
    # Play the first card's video, where the host has a player: it runs to its end.
    if [ -n "$media" ]; then
      PANE=100x40 start "$backend" "$xdg" "$base" --media-play always
      step "$t: the feed, with a player" "0:00 / 0:02" "[ Play ]"
      for _ in $(seq 5); do keys Tab; done
      keys Enter # Play
      step "$t: Play: the video plays to its end" "0:02 / 0:02"
    fi
    # Everyone: the public feed, with someone ada doesn't follow.
    start "$backend" "$xdg" "$base"
    step "$t: the feed again" "Show: (*) Following" " Charles Babbage"
    keys Tab; keys Tab; keys Tab; keys Tab; keys Right
    step "$t: Show: Everyone" "(*) Everyone" "Hello from someone you don't follow."

    start "$backend" "$xdg" "$base"
    step "$t: started again, still signed in" "@ada@$hostport" " Charles Babbage"
    keys Tab; keys Tab; keys Enter # Refresh
    step "$t: Refresh loads the feed again" "Updated. Signed in to $hostport." \
      " Charles Babbage"
    keys Tab; keys Enter # Sign out
    step "$t: signed out" "Signed out." "Sign in to TX.WTF" "Username: [ada"
    if [ "$(sessions_in "$store")" = 0 ]; then pass "$t: sign-out drops the session"; else
      fail "$t: the session is still in the store after signing out"
    fi

    form_focus; keys Tab; type_text "not the password"; keys Tab; keys Enter
    step "$t: a wrong password" "Wrong username or password." "Sign in to TX.WTF"

    start "$backend" "$xdg" "$base" -- --user grace
    step "$t: --user fills in the form" "Username: [grace"
    form_focus; keys Tab; type_text "correct horse"; keys Tab; keys Enter
    step "$t: the emailed code is asked for" "Two-step verification" "Signing in as grace" \
      "We emailed you a code. It expires in 5 minutes."
    form_focus; type_text 000000; keys Tab; keys Enter
    step "$t: a wrong code" "That code didn't work. Try again, or go Back." "Code: []"
    keys BTab; type_text 123456; keys Tab; keys Enter
    step "$t: the right code signs in: her feed, empty" "@grace@$hostport" \
      "Your feed is empty. Follow people, or Show: Everyone."
    keys Tab; keys Enter # Profile
    step "$t: grace's profile" "@grace@$hostport  Grace Hopper" "No posts yet."
    keys Tab; keys Tab; keys Tab; keys Tab; keys Right; keys Right # the tabs: Balances
    step "$t: grace's balance" "(*) Balances" "SCRIP    25" "Value    \$25.00"
    keys BTab; keys Enter # back from the tabs to Sign out
    step "$t: grace signs out" "Signed out."

    # mary's profile takes the stub 3 s: the spinner turns beside "Signing in..." meanwhile,
    # by the host's clock, while the client waits on the request.
    if [ -n "$have_spinner" ]; then
      start "$backend" "$xdg" "$base" -- --user mary
      step "$t: the form for mary" "Username: [mary"
      form_focus; keys Tab; type_text "correct horse"; keys Tab; keys Enter
      if wait_for "$t: the spinner" "Signing in..." 5; then
        g1=$(spinner_glyph "$out/tmux-$(slug "$t: the spinner").txt" "Signing in...")
        sleep 0.5
        pane >"$out/tmux-$(slug "$t: the spinner, later").txt"
        g2=$(spinner_glyph "$out/tmux-$(slug "$t: the spinner, later").txt" "Signing in...")
        if [ -n "$g1" ] && [ -n "$g2" ] && [ "$g1" != "$g2" ]; then
          pass "$t: a spinner turns beside 'Signing in...' while the request is out ($g1 then $g2)"
        else
          fail "$t: no turning spinner beside 'Signing in...' ('$g1' then '$g2')" \
            "$out/tmux-$(slug "$t: the spinner, later").txt"
        fi
      else
        fail "$t: no 'Signing in...' while mary's profile loads" \
          "$out/tmux-$(slug "$t: the spinner").txt"
      fi
      step "$t: and then mary's feed" "@mary@$hostport" "Your feed is empty."
      check_not "$t: no spinner once the requests are back" \
        "$out/tmux-$(slug "$t: and then mary's feed").txt" "Signing in..."
      keys Tab; keys Tab; keys Tab; keys Enter # past Profile and Refresh to Sign out
      step "$t: mary signs out" "Signed out."
    fi

    # The whole profile in an 80x24 terminal: the frame's bottom edge and the status row are on
    # the screen (the tvision desktop has a status line below it too).
    PANE=80x24 start "$backend" "$xdg" "$base" -- --user ada
    step "$t: the form for ada at 80x24" "Username: [ada"
    form_focus; keys Tab; type_text "correct horse"; keys Tab; keys Enter
    step "$t: the feed fits an 80x24 terminal" "Signed in to $hostport." \
      "@ada@$hostport" "[ Profile ][ Refresh ][ Sign out ]" " Charles Babbage"
    fits_80x24 "$t: ... its frame whole, within 80 columns" \
      "$out/tmux-$(slug "$t: the feed fits an 80x24 terminal").txt"
    keys Tab; keys Enter # Profile
    step "$t: the profile fits an 80x24 terminal" "@ada@$hostport  Ada Lovelace" "Show: (*) Posts" \
      "[ Newer ][ Older ]  Page 1"
    fits_80x24 "$t: ... its frame whole, within 80 columns" \
      "$out/tmux-$(slug "$t: the profile fits an 80x24 terminal").txt"
    keys Tab; keys Tab; keys Tab; keys Enter # past Feed and Refresh to Sign out
    step "$t: ada signs out at 80x24" "Signed out."

    start "$backend" "$xdg" "$base" -- --user linus
    step "$t: the form for linus" "Username: [linus"
    form_focus; keys Tab; type_text "correct horse"; keys Tab; keys Enter
    step "$t: a password that must change first" "Change your password at 127.0.0.1" \
      "Sign in to TX.WTF"
    if [ "$(sessions_in "$store")" = 0 ]; then pass "$t: and no session is kept"; else
      fail "$t: a session was kept for an account that must change its password"
    fi
    stop
  done
fi

# --- the tokens -------------------------------------------------------------------------------

no_secrets_in_output "$work/tokens"
check "the stub refused the expired token and took the valid ones" "$out/stub.log" \
  '"authorization": "rejected"' '"authorization": "valid"'
finish
