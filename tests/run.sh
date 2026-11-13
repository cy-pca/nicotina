#!/usr/bin/env bash
# tests/run.sh: nicotina's M0 tests, against a stub TX.WTF instance (tests/stub_txwtf.py).
#
#   tests/run.sh                                   # ari and arigl from PATH
#   ARI=/path/to/ari ARIGL=/path/to/arigl tests/run.sh
#
#  1. bin/nicotina --dry-run: the host, flags and credential store it picks.
#  2. ari check: without the network flags the document refuses to load, and says why.
#  3. ari snapshot, FTXUI and tvision: the sign-in form; a stored session, resumed (the TX.WTF
#     window: its bar, the feed; the profile, laid out as the web app's: the banner and avatar
#     slots, the card, the Posts tab); a stored session the server no longer knows (back to the
#     form, and the host forgets it). Then each view --start opens: a post with its replies, a
#     hashtag's posts, the hashtags, the notifications, search, a new post, another's profile, the
#     viewer; and for ada, the stub's administrator, the Admin view's parts (the accounts, the
#     groups, the invite codes, the site's settings, the system log), an account and a group,
#     none of which someone who isn't an administrator sees or asks the instance for.
#  4. arigl snapshot, if arigl is here: the resumed session as text (--terminal) and in a window
#     (a PNG; checked only for being drawn, since nothing here reads pixels).
#  5. bin/nicotina --terminal in a tmux pane, FTXUI and tvision, typed at the way a person types:
#     sign in, see the profile, the Replies and Balances tabs and an older page of posts, open a
#     post and go Back, like a post and take it back, write a post and a reply, attach a picture
#     and a big file to a post where the host picks and uploads files (the Open file window, then
#     the uploads the stub must get whole), open a hashtag,
#     follow someone and stop, send a direct message, start again still signed in, sign out; a
#     wrong password; the emailed code, wrong and then right; an account that must change its
#     password. As ada, the Admin view: an account found, disabled (its sign-in refused),
#     enabled, its emailed code turned off, made an administrator and not; a group's member
#     added, made its admin, removed; a group made and deleted; sign-up closed and opened, an
#     invite code made and turned off; the site's title changed and back; the log filtered and
#     paged; and the instance refusing an administrator whose rights went, which leaves her
#     signed in.
#
# The direct-message views are in 3 too: the conversations, a plaintext one, and an encrypted
# one locked on a host that keeps no keys. tests/e2ee.sh is the end-to-end encrypted round trip
# with a host that does (libcvc 3.7.14) and TX.WTF's own e2ee.js on the other side.
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
# A host with --e2ee-store (libcvc 3.7.14) gets the key store beside the credentials.
ari_help=$("$ARI" --help 2>&1 || true) # whole: grep -q on a pipe can SIGPIPE ari under pipefail
keys_flag=
grep -q -- '--e2ee-store' <<<"$ari_help" && keys_flag=" '--e2ee-store' '$work/xdg/nicotina/e2ee'"
launch launcher-tvision DISPLAY=:0 XDG_CONFIG_HOME="$work/xdg" -- --backend tvision --fps 30 \
  -- --user ada
check "launcher: --backend tvision, host flags before the document, document args after" \
  "$out/launcher-tvision.txt" "$ARI 'run' '--backend' 'tvision' '--net'" \
  "'$work/xdg/nicotina/credentials'$keys_flag '--fps' '30' '$main' '--instance' 'https://tx.wtf' '--user' 'ada'"
# ari-media (ari with sound and video) is the terminal's ari where it is installed.
mkdir -p "$work/fakebin" && printf '#!/bin/sh\n' >"$work/fakebin/ari-media" &&
  chmod +x "$work/fakebin/ari-media"
launch launcher-ari-media NICOTINA_ARI= PATH="$work/fakebin:/usr/bin:/bin" -- --terminal
check "launcher: a terminal gets ari-media (sound and video) where it is installed" \
  "$out/launcher-ari-media.txt" "$work/fakebin/ari-media 'run' '--net'"
# A host whose help lists --e2ee-store (libcvc 3.7.14) keeps the account's encryption keys beside
# the session; NICOTINA_E2EE=0 leaves them out. (The hosts above have no such flag.)
printf '#!/bin/sh\n[ "$1" = --help ] && echo "  --e2ee-store S         keep end-to-end encryption keys"\nexit 0\n' \
  >"$work/fakebin/ari-e2ee" && chmod +x "$work/fakebin/ari-e2ee"
launch launcher-e2ee NICOTINA_ARI="$work/fakebin/ari-e2ee" -- --terminal
check "launcher: a host with --e2ee-store keeps the encryption keys beside the session" \
  "$out/launcher-e2ee.txt" \
  "'--credential-store' '$work/home/.config/nicotina/credentials' '--e2ee-store' '$work/home/.config/nicotina/e2ee'"
launch launcher-e2ee-off NICOTINA_ARI="$work/fakebin/ari-e2ee" NICOTINA_E2EE=0 -- --terminal
check_not "launcher: ... and NICOTINA_E2EE=0 leaves them out" "$out/launcher-e2ee-off.txt" \
  "--e2ee-store"
if ! grep -q -- '--e2ee-store' <<<"$ari_help"; then
  check_not "launcher: a host without the flag gets none" "$out/launcher-nodisplay.txt" "--e2ee-store"
fi
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
# transfix/libcvc#935): then a card's recording has a player, three Tab stops (Play, the seek
# slider, Mute), and four where the player has a Loop box too (libcvc 3.7.13, #1079; the players'
# snapshot below tells). Its video plays with no controls, so no stops: the viewer has them.
media=
"$ARI" check --net "$main" 2>&1 | grep -q "optional requirement media.player" || media=1
player_stops=0
[ -n "$media" ] && player_stops=3
# Whether this ari draws a post's :emoji: (text.emoji, transfix/libcvc#1052): a standard one's
# shortcode becomes its character; a custom one stays its :name: in a terminal, which can't put
# a picture in a line of text.
emoji=
"$ARI" check --net "$main" 2>&1 | grep -q "optional requirement text.emoji" || emoji=1
# Whether this ari picks and uploads files (file-pick and http-upload, transfix/libcvc#1190): a new
# post then has Attach. ari has no picker of its own, so the Runtime draws an Open file window.
attach=
"$ARI" check --net "$main" 2>&1 | grep -q "optional requirement file-pick" || attach=1
# The picture the tmux cases attach: a small PNG, drawn by the stub's own writer.
attach_file=$work/attach/kitten.png
mkdir -p "$work/attach"
python3 -I -B -c "
import sys; sys.path.insert(0, sys.argv[1]); import stub_txwtf as s
open(sys.argv[2], 'wb').write(s.png(24, 16, lambda x, y: (240, 160 if (x + y) % 2 else 120, 60)))" \
  "$here" "$attach_file"
attach_size=$(wc -c <"$attach_file" | tr -d ' ')
# ... and one over 8 MiB, which goes by the resumable upload, in chunks.
attach_big=$work/attach/engine-log.bin
head -c $((9 * 1024 * 1024 + 4321)) /dev/urandom >"$attach_big"
# check_upload NAME FILENAME FILE: the stub's log has FILENAME uploaded whole: FILE's size and
# sha256.
check_upload() {
  local want
  want="\"upload\": \"$2\", \"size\": $(wc -c <"$3" | tr -d ' '), \"sha256\": \"$(sha256sum "$3" | cut -d' ' -f1)\""
  if grep -qF -- "$want" "$out/stub.log"; then pass "$1"; else
    fail "$1: the stub's log has no [$want]" "$out/stub.log"
  fi
}
# The bar along the window's top, in every view.
bar="[ Back ][ Home ][ Tags ][ Search ][ Alerts ][ Profile ][ Post ][ DMs ]"
# The first card's counts and buttons, and View on its first attachment's row (it has a picture
# and a video), inside the card's frame. (The window's own frame is rounded, or heavy while it
# has the focus, by host: the checks look inside it.)
open_row="│↩5 ⇄3 ♥21 · 310 views              [ Open ][ Reply ][ Like ][ Repost ]"
view_row="│[image] engine-diagram.png · 47 KB · The engine, from the ... [ View ]"

for backend in ftxui tvision; do
  snap "snap-$backend-signin" "$backend" "" --user ada
  check "ari snapshot ($backend): the sign-in form" "$out/snap-$backend-signin.txt" \
    "Sign in to TX.WTF" "Instance: $base" "Username: [ada" "Password: []" "[ Sign in ]"

  store=$work/snap-$backend/credentials
  seed_store "$store" ada
  snap "snap-$backend-feed" "$backend" "$store"
  check "ari snapshot ($backend): a stored session opens the home feed, a card a post" \
    "$out/snap-$backend-feed.txt" " TX.WTF " "$bar 2" \
    "Show: (*) Following  ( ) Everyone  ( ) Friends" "Signed in to 127.0.0.1" \
    " Charles Babbage  @charles@$hostport" " 2026-10-30 22:40" \
    "│The Difference Engine No. 2, working at last. #engines #brass            │" \
    "│#engines  #brass                                                         │"
  check_not "ari snapshot ($backend): ... and no In browser button" "$out/snap-$backend-feed.txt" \
    "In browser"
  if [ -z "$pictures$media" ]; then
    check "ari snapshot ($backend): ... its attachments, a row each" "$out/snap-$backend-feed.txt" \
      "│[image] engine-diagram.png · 47 KB · The engine, from the side           │" \
      "│[video] engine.mp4 · 11 KB                                               │"
  fi
  if [ -z "$pictures" ]; then
    check "ari snapshot ($backend): ... the author's initials, and the next card" \
      "$out/snap-$backend-feed.txt" "│(CB) Charles Babbage  @charles@$hostport" "│     2026-10-30 22:40" \
      "$open_row" "$view_row" \
      "│(GH) Grace Hopper  @grace@$hostport"
  fi
  grep -v '^ari: ' "$out/snap-$backend-feed.txt" >"$work/frame.txt"
  if [ "$(wc -l <"$work/frame.txt")" -le 24 ] && [ "$(wc -L <"$work/frame.txt")" -le 80 ] &&
    grep -qE '^  [╰┗][─┴━┷]{70}' "$work/frame.txt"; then
    pass "ari snapshot ($backend): the feed fits 80x24, its frame whole"
  else
    fail "ari snapshot ($backend): the feed runs past 80x24" "$out/snap-$backend-feed.txt"
  fi
  snap "snap-$backend-resume" "$backend" "$store" --start profile
  check "ari snapshot ($backend): --start profile: the profile, as the web app lays it out" \
    "$out/snap-$backend-resume.txt" " TX.WTF " "$bar" " @ada@$hostport  Ada Lovelace" \
    "Writes notes on the analytical engine. Prefers punched cards t..." \
    "admin · Verified · online" "GB · Joined 2025-03-01 · 42 posts · 1234 views" \
    "Groups: users, analysts" "[ Refresh ][ Sign out ][ Admin ]" \
    "Show: (*) Posts  ( ) Replies  ( ) Balances" \
    "2026-10-30  Finished the notes on Menabrea's paper. Not...  ↩2 ♥5 [ Open ]" \
    "2026-10-28  The Analytical Engine weaves algebraic patt...  ↩4 ♥9 [ Open ]" \
    "2026-10-24  Hello, TX.WTF." "[ Newer ][ Older ]  Page 1" "Signed in to 127.0.0.1"
  if [ -z "$pictures" ]; then
    check "ari snapshot ($backend): ... the banner and avatar placeholders" \
      "$out/snap-$backend-resume.txt" "████████" "╭──────╮ @ada@$hostport  Ada Lovelace" \
      "│  AL  │ Writes notes" "│      │ admin · Verified" "╰──────╯ GB · Joined"
  else
    # The card's picture (card_image_url) is half-blocks behind its text, as the web app dims it
    # behind the card.
    check "ari snapshot ($backend): ... the card's picture behind its text" \
      "$out/snap-$backend-resume.txt" "▀Writes notes" "▀admin · Verified" "▀GB · Joined" \
      "views▀▀▀"
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

# Each view, as --start opens it (a deep link: post:ID, tag:NAME, user:ID, view:ID[:N], tags,
# alerts, search, compose), in a tall terminal so the whole view is in the frame.
store=$work/snap-views/credentials
seed_store "$store" ada
view() { # view NAME START: a 80x60 frame of the view START opens
  "$ARI" snapshot --width 80 --height 60 --net-allow "$base" --credential-store "$store" "$main" \
    --instance "$base" --start "$2" >"$out/snap-view-$1.txt" 2>&1
}
view post post:312
check "ari snapshot: a post: its text, hashtags, counts, reactions, buttons and link" \
  "$out/snap-view-post.txt" "$bar" " Charles Babbage  @charles@$hostport" \
  "The Difference Engine No. 2, working at last. #engines #brass" \
  "Tags: (*) #engines  ( ) #brass  [ Open tag ]" "↩5 ⇄3 ♥21 · 310 views" \
  "Reactions: :thumbsup: 12  :heart: 9" "[ Like ][ Repost ][ Author ]" \
  "Link: $base/app/post/312" "[image] engine-diagram.png · 47 KB · The engine, from the side" \
  "[ View ]"
check "ari snapshot: ... its replies, oldest first, and the reply box" "$out/snap-view-post.txt" \
  "2 replies" "Grace Hopper  @grace@$hostport  2026-10-30 22:50  ↩1" "Splendid. How many digits?" \
  "Alan Turing  @alan@peer.example  2026-10-30 23:10" "A fine machine. #engines" \
  "Reply: [Write a reply (Enter sends it)"
check_not "ari snapshot: ... not someone else's Delete, nor a reply's reply" \
  "$out/snap-view-post.txt" "[ Delete ]" "Thirty-one"
view reply post:315
check "ari snapshot: a reply: the post it replies to, and your own post's Delete" \
  "$out/snap-view-reply.txt" "[ In reply to ]" "Grace Hopper: Splendid. How many digits?" \
  "Thirty-one, and seven orders of differences." "[ Like ][ Repost ][ Author ][ Delete ]" \
  "No replies yet."
view tag tag:engines
check "ari snapshot: a hashtag's posts, newest first, as cards" "$out/snap-view-tag.txt" \
  "#engines  ·  3 posts" "A fine machine. #engines" \
  "The Difference Engine No. 2, working at last. #engines #brass" "Nanoseconds, in wire. #engines" \
  "[ Load more ]"
check_not "ari snapshot: ... no feed choice, no posts without it" "$out/snap-view-tag.txt" \
  "Show: (*) Following" "A ship in port"
view tags tags
check "ari snapshot: the hashtags, the most named first" "$out/snap-view-tags.txt" \
  "2 hashtags, the most named first" "#engines  ·  3 posts" "#brass  ·  2 posts" "[ Open ]"
view alerts alerts
check "ari snapshot: the notifications, the new ones marked" "$out/snap-view-alerts.txt" \
  "3 notifications, 2 new" "● Grace Hopper replied to your post" \
  "● Charles Babbage liked your post" "  Alan Turing followed you" "2026-10-30 22:50  reply"
view alerts-read alerts
check "ari snapshot: ... and once seen, read" "$out/snap-view-alerts-read.txt" "3 notifications"
check_not "ari snapshot: ... none new now" "$out/snap-view-alerts-read.txt" "● " " new"
view search search
check "ari snapshot: search" "$out/snap-view-search.txt" "Find: [" "[ Search ]" \
  "Find posts and people."
view search-hits search:engine
check "ari snapshot: search: posts, people and hashtags, as txwtf groups them" \
  "$out/snap-view-search-hits.txt" "Find: [engine]" "8 found for \"engine\"" \
  "[post] Charles Babbage · @charles@$hostport" "The Difference Engine No. 2, working at last." \
  "[tag] #engines" "  3 posts"
view compose compose
check "ari snapshot: a new post: who sees it, and the text" "$out/snap-view-compose.txt" \
  "Who sees it: (*) Public  ( ) Followers  ( ) Private" "Post: [What's happening? (Enter posts it)"
if [ -n "$attach" ]; then
  check "ari snapshot: ... and Attach, the host picking files" "$out/snap-view-compose.txt" \
    "[ Attach ]"
  check_not "ari snapshot: ... no files yet, so no Post beside it" "$out/snap-view-compose.txt" \
    "[ Attach ][ Post ]" "Text only: this host"
else
  check "ari snapshot: ... text only: this host can't attach files" \
    "$out/snap-view-compose.txt" "Text only: this host can't attach files."
fi
view user user:7
check "ari snapshot: another's profile: Unfollow (ada follows him), Posts and Replies" \
  "$out/snap-view-user.txt" "@charles@$hostport  Charles Babbage" "[ Unfollow ]" \
  "Show: (*) Posts  ( ) Replies" "The Difference Engine No. 2"
check_not "ari snapshot: ... not his balance, nor ada's Sign out" "$out/snap-view-user.txt" \
  "Balances" "[ Sign out ]" "[ Follow ]"
view viewer view:312:1
check "ari snapshot: the viewer: a post's picture and video, one at a time" \
  "$out/snap-view-viewer.txt" "[ Prev ][ Next ]  2 of 2" "[video] engine.mp4 · 11 KB"
view gone post:9999
check "ari snapshot: a post that is gone: the feed instead, saying so" "$out/snap-view-gone.txt" \
  "Show: (*) Following" " Charles Babbage"
check "ari snapshot: ... another's profile has Message beside Unfollow" "$out/snap-view-user.txt" \
  "[ Unfollow ][ Message ]"

# Direct messages (ui/dm.ari): the conversations, a plaintext one, and an encrypted one on a host
# that keeps no keys here (no --e2ee-store: tests/e2ee.sh opens them with one that does).
view dms dms
check "ari snapshot: DMs: the conversations, the latest first" "$out/snap-view-dms.txt" "$bar" \
  "3 conversations" "[ Refresh ]" "@grace@$hostport  Grace Hopper" "  2026-10-31 09:10" \
  "@charles@$hostport  Charles Babbage" "  2026-10-29 12:05  · end-to-end encrypted" "[ Open ]" \
  "Encrypted conversations stay locked here:"
view dm-plain dm:900
check "ari snapshot: a conversation: its messages, oldest first, and a box to write in" \
  "$out/snap-view-dm-plain.txt" "@grace@$hostport  Grace Hopper" \
  "Not encrypted: the server can read these messages." "2026-10-31 08:58  @grace@$hostport" \
  "  Ada, did you see Charles's engine post?" "2026-10-31 09:02  you" \
  "  I did. The carry mechanism is lovely." \
  "  Lunch on Thursday? I'll bring the compiler notes, all three binders of" \
  "  them, and the bugs we found." "Message: [Write a message (Enter sends it)"
view dm-locked dm:901
check "ari snapshot: an encrypted conversation where the host keeps no keys: locked, saying why" \
  "$out/snap-view-dm-locked.txt" "@charles@$hostport  Charles Babbage" \
  "End-to-end encrypted: the server sees ciphertext only." \
  "These messages are end-to-end encrypted, and stay locked here:"
check_not "ari snapshot: ... no box to write in, and no ciphertext" "$out/snap-view-dm-locked.txt" \
  "Message: [" "c3RhbmQtaW4"

# The Admin view, for ada, the stub's administrator: each of its parts, one account, one group.
view admin admin
check "ari snapshot: Admin: the accounts, newest first, a page of six" "$out/snap-view-admin.txt" \
  "$bar" "Admin: (*) Users  ( ) Groups  ( ) Invites  ( ) Site  ( ) Log" "Find user: [" \
  "10 accounts, the newest first" "@ivy  Ivy Lane" \
  "@eve  Eve Example                  2026-04-01               [ Open ]" \
  "@mary  Mary Kenneth Keller of ...  2025-12-01" "[ Prev ][ Next ]  Page 1 of 2"
check_not "ari snapshot: ... not the second page" "$out/snap-view-admin.txt" "@grace" "@ada  Ada" \
  "@charles"
view admin-groups admin:groups
check "ari snapshot: Admin: the groups, and a new one" "$out/snap-view-admin-groups.txt" \
  "(*) Groups" "3 groups" "users               The default user group                [ Open ]" \
  "root                The administrators" "New group: [" "About it: [" "[ Create ]"
view admin-invites admin:invites
check "ari snapshot: Admin: who may sign up, and her invite codes" \
  "$out/snap-view-admin-invites.txt" "(*) Invites" "Sign-up: (*) Open  ( ) Invite only" \
  "Anyone may sign up. Your 2 codes:" \
  "ENGINE-7Q2X  3 of 10 used until 2026-12-31 the lecture  [ Turn off ]" \
  "LOOM-4K9D    1 of 1 used  off              for Charles  [ Turn on ]" "Uses: [" \
  "Note: [" "[ New code ]"
view admin-site admin:site
check "ari snapshot: Admin: the site's settings" "$out/snap-view-admin-site.txt" "(*) Site" \
  "Title: [TX.WTF]" "About: [Austin's crypto club, on the web.]" "Time zone: [UTC]" "[ Save ]" \
  "New accounts join users; the administrators' group is root." \
  "Passwords: 8 characters or more, a digit."
view admin-log admin:log
check "ari snapshot: Admin: the system log, newest first, a page of ten" \
  "$out/snap-view-admin-log.txt" "(*) Log" "Events: " "14 events, the newest first" \
  "2026-10-30 23:10 alan@peer... User Login         Brokered sign-..." \
  "2026-10-30 12:00 -            Stats Job Compl... Stats job comp..." \
  "2026-10-28 08:30 slowpoke     User Create" "[ Prev ][ Next ]  Page 1 of 2"
check_not "ari snapshot: ... not the second page" "$out/snap-view-admin-log.txt" "Retention sweep"
view auser auser:9
check "ari snapshot: an account, as an administrator sees it" "$out/snap-view-auser.txt" \
  "@eve@$hostport  Eve Example" "Account: active · Administrator: no · Two-step sign-in: on" \
  "Email: eve@example.org, verified" "Joined 2026-04-01 · last signed in 2026-10-30 11:59" \
  "Groups: users" "[ Disable ][ Make admin ][ Two-step off ][ Profile ]"
view auser-self auser:1
check "ari snapshot: ... her own: no Disable, no Remove admin" "$out/snap-view-auser-self.txt" \
  "@ada@$hostport  Ada Lovelace" "Administrator: yes" \
  "Groups: users, analysts (its admin), root (its admin)" \
  "Your own account: Disable and Remove admin aren't offered." "[ Profile ]"
check_not "ari snapshot: ... none of those buttons" "$out/snap-view-auser-self.txt" "[ Disable ]" \
  "[ Remove admin ]" "[ Make admin ]"
view agroup agroup:2
check "ari snapshot: a group: its members, Add and Delete group" "$out/snap-view-agroup.txt" \
  "analysts  ·  1 member" "Reads the engine's tables" "[ Permissions ]  what its members may do" \
  "@ada  Ada Lovelace  · group admin           [ Drop admin ][ Remove ]" \
  "Add member: [" "[ Add ][ Delete group ]"
check_not "ari snapshot: ... asking nothing yet" "$out/snap-view-agroup.txt" "Yes, delete it"
view agperm agperm:3
check "ari snapshot: a group's permissions, by name, a page of ten" "$out/snap-view-agperm.txt" \
  "root: 12 permissions, what its members may do" "Find permission: [" \
  "GroupAddPermission                                    [ Revoke ]" "UserListRead" \
  "[ Prev ][ Next ]  Page 1 of 2" "Permission: [" "[ Grant ]"
check_not "ari snapshot: ... not the second page" "$out/snap-view-agperm.txt" "UserWrite"
# An administrator's profile has Admin; it fits 80x24 with the Admin view's first page.
"$ARI" snapshot --width 80 --height 24 --net-allow "$base" --credential-store "$store" "$main" \
  --instance "$base" --start admin >"$out/snap-admin-80x24.txt" 2>&1
grep -v '^ari: ' "$out/snap-admin-80x24.txt" >"$work/frame.txt"
if grep -qF "[ Prev ][ Next ]  Page 1 of 2" "$work/frame.txt" &&
  [ "$(wc -l <"$work/frame.txt")" -le 24 ] && [ "$(wc -L <"$work/frame.txt")" -le 80 ] &&
  grep -qE '^  [╰┗][─┴━┷]{70}' "$work/frame.txt"; then
  pass "ari snapshot: the Admin view's first page fits 80x24, its frame whole"
else
  fail "ari snapshot: the Admin view runs past 80x24" "$out/snap-admin-80x24.txt"
fi
# Not for anyone else: no Admin on grace's profile, and --start admin opens her feed.
seed_store "$work/snap-nonadmin/credentials" grace
"$ARI" snapshot --width 80 --height 60 --net-allow "$base" \
  --credential-store "$work/snap-nonadmin/credentials" "$main" --instance "$base" --start admin \
  >"$out/snap-view-nonadmin.txt" 2>&1
check "ari snapshot: someone who isn't an administrator: --start admin opens the feed" \
  "$out/snap-view-nonadmin.txt" "$bar" "Show: (*) Following"
check_not "ari snapshot: ... and no Admin view" "$out/snap-view-nonadmin.txt" "Admin: (*)" \
  "accounts, the newest first"
"$ARI" snapshot --width 80 --height 60 --net-allow "$base" \
  --credential-store "$work/snap-nonadmin/credentials" "$main" --instance "$base" --start profile \
  >"$out/snap-view-nonadmin-profile.txt" 2>&1
check "ari snapshot: ... her profile: Refresh and Sign out" "$out/snap-view-nonadmin-profile.txt" \
  "@grace@$hostport  Grace Hopper" "[ Refresh ][ Sign out ]"
check_not "ari snapshot: ... and no Admin" "$out/snap-view-nonadmin-profile.txt" "[ Admin ]"
if grep -F '"user": "grace"' "$out/stub.log" | grep -qE '"path": "/(user/list|group/|invite/|logs/)'; then
  fail "the client asked the instance's admin routes for someone who isn't an administrator" \
    "$out/stub.log"
else
  pass "the client never asks the admin routes for someone who isn't an administrator"
fi

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
  "[image] engine-diagram.png · 47 KB · The engine, from the ..." "[video] engine.mp4 · 11 KB" \
  "│⇄ Charles Babbage reposted" " Ada Lovelace  @ada@$hostport" " 2026-10-30 09:15" \
  " Alan Turing  @alan@peer.example" " 2026-10-30 19:30" \
  "│A ship in port is safe, but that's not what ships are built for. Sail" \
  "│is to get permission, and the most dangerous phrase in the language..." \
  "Found a moth in relay 70. First actual case of bug being found." \
  "[image] moth.png · 29 KB · The moth, taped into the log book" \
  "🔒 This post is locked. Pay 5 scrip to unlock." "[file] cobol-notes.pdf · 2 KB" \
  "[image] relay-70.png · 30 KB" "+1 more (Open shows them all)" "[ Load more ]  10 posts" \
  "│↩12 ⇄8 ♥64 · 900 views             [ Open ][ Reply ][ Like ][ Repost ]" \
  "[image] moth.png · 29 KB · The moth, taped into the log book" "[ View ]"
if [ -n "$emoji" ]; then
  check "ari snapshot: ... a post's emoji: a standard one's character, a custom one's :name:" \
    "$out/snap-feed-tall.txt" "Notes on the mill :gear: 💯 at 14:50:47."
else
  check "ari snapshot: ... a post's emoji as their shortcodes (this ari has no text.emoji)" \
    "$out/snap-feed-tall.txt" "Notes on the mill :gear: :100: at 14:50:47."
fi
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
    "╭──────╮ @bob@peer.example  Bob" "│  B   │"
  check_not "ari snapshot: ... and isn't fetched as a picture" "$out/stub.log" \
    '"path": "/uploads/u5/avatar-loop.mp4"' '"path": "/uploads/u8/avatar-loop.webm"'
fi

# Video and audio, where the host has a player: the third card's recording has its controls, the
# first card's video none (the viewer has them), and both were fetched without the session token.
if [ -z "$media" ]; then
  skip "ari snapshot: video and audio players (this ari has no media.player; ari-media has, ARI=ari-media)"
else
  seed_store "$store" ada
  "$ARI" snapshot --width 80 --height 200 --net-allow "$base" --credential-store "$store" "$main" \
    --instance "$base" >"$out/snap-feed-players.txt" 2>&1
  # (ari snapshot doesn't wait for a player whose URL comes from a reply, so not the durations)
  check "ari snapshot: the card's recording has a player" "$out/snap-feed-players.txt" \
    "[ Play ]" "Mute" "[video] engine.mp4 · 11 KB" "[audio] lecture.ogg · 5 KB"
  # A player with a Loop box beside Mute (libcvc 3.7.13) has a fourth Tab stop.
  grep -qF "] Loop" "$out/snap-feed-players.txt" && player_stops=4
  if [ "$(grep -c '\[ Play \]' "$out/snap-feed-players.txt")" -eq 1 ]; then
    pass "ari snapshot: ... and the video has no controls"
  else
    fail "ari snapshot: a player's controls other than the recording's" "$out/snap-feed-players.txt"
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
# (No site answers to name the window, so its host does.)
check "ari snapshot: an instance that doesn't answer" "$out/snap-unreachable.txt" \
  "Sign in to 127.0.0.1:9" "Can't reach 127.0.0.1:9"

# --- 4. arigl snapshot ------------------------------------------------------------------------

if [ -n "$ARIGL" ] && [ -x "$ARIGL" ]; then
  # arigl snapshot does not wait for requests as ari's does; 60 frames at 20 fps give them 3 s.
  store=$work/arigl/credentials
  seed_store "$store" ada
  "$ARIGL" snapshot --terminal --frames 60 --width 80 --height 24 --net --net-allow "$base" \
    --credential-store "$store" "$main" --instance "$base" >"$out/arigl-terminal.txt" 2>&1
  check "arigl snapshot --terminal: the feed" "$out/arigl-terminal.txt" \
    "$bar" "Show: (*) Following" " Charles Babbage  @charles@$hostport" \
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
  codes_made=0 # invite codes the Admin steps have made
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
    # The focus, in the TX.WTF window: the bar's eight buttons are the first eight stops (Back,
    # Home, Tags, Search, Alerts, Profile, Post, DMs) in every view, and each new view starts with
    # the focus on Back: Tab k times reaches stop k + 1.
    step "$t: signed in, the home feed" "Home" "$bar" "Show: (*) Following" \
      " Charles Babbage  @charles@$hostport" " 2026-10-30 22:40" \
      "The Difference Engine No. 2, working at last."
    check_store "$t: the host keeps the session, owner-only (0600 in 0700)" "$store"
    check_not "$t: the password is not on the screen" \
      "$out/tmux-$(slug "$t: signed in, the home feed").txt" "correct horse"
    for _ in $(seq 5); do keys Tab; done
    keys Enter # Profile
    step "$t: Profile: the profile" "@ada@$hostport  Ada Lovelace" "admin · Verified · online" \
      "GB · Joined 2025-03-01 · 42 posts · 1234 views" "Groups: users, analysts" \
      "(*) Posts" "Finished the notes on Menabrea's paper." "Page 1"
    # The tabs: Tab past the bar, Refresh, Sign out and Admin (she is the stub's administrator)
    # to them, then Right picks the next one.
    for _ in $(seq 11); do keys Tab; done
    keys Right
    step "$t: the Replies tab" "(*) Replies" "2026-10-29  Agreed: the engine might compose music" \
      "2026-10-25  Thank you, Mr. Babbage."
    check_not "$t: ... and no posts that aren't replies" \
      "$out/tmux-$(slug "$t: the Replies tab").txt" "Finished the notes"
    keys Right
    step "$t: the Balances tab: SCRIP and its value, and no runway" "(*) Balances" \
      "SCRIP    1234.56789" "Value    \$1234.57"
    check_not "$t: ... no runway" "$out/tmux-$(slug "$t: the Balances tab: SCRIP and its value, and no runway").txt" \
      "Runway" "days"
    keys Right # round to Posts again, then past the five rows' Open (and Newer, off on the
    # first page) to Older
    step "$t: back to Posts" "(*) Posts" "Finished the notes on Menabrea's paper."
    for _ in $(seq 6); do keys Tab; done
    keys Enter
    step "$t: Older: the next page" "Page 2" "2026-10-23  Testing, testing."
    keys BTab; keys Enter
    step "$t: Newer: the first page again" "Page 1" "Finished the notes on Menabrea's paper."

    # The feed: a card's Open shows the whole post; Back; Load more adds the next page.
    start "$backend" "$xdg" "$base"
    step "$t: started again, still signed in: the feed" "$bar" " Charles Babbage"
    # past the bar, Show and the first card's View to its Open
    for _ in $(seq 10); do keys Tab; done
    keys Enter
    # (Its replies are below the fold here: the 80x60 snapshot of post:312 has them.)
    step "$t: Open: the whole post, its hashtags, reactions and attachments" \
      "Reactions: :thumbsup: 12  :heart: 9" " Charles Babbage  @charles@$hostport" \
      " 2026-10-30 22:40" "↩5 ⇄3 ♥21 · 310 views" "Tags: (*) #engines  ( ) #brass" \
      "[image] engine-diagram.png · 47 KB · The engine, from the side" \
      "Link: $base/app/post/312"
    keys Enter # Back: a view just opened has the focus there
    step "$t: Back to the feed" "Show: (*) Following" " Charles Babbage"
    # Back keeps the focus. Load more is stop 54: the bar and Show (9), then ten cards' buttons
    # (Open, Reply, Like, Repost, and View on the four with something to view: 44), and the
    # recording's player more.
    for _ in $(seq $((53 + player_stops))); do keys Tab; done
    keys Enter
    step "$t: Load more: the next page, below the first" "13 posts; no more" \
      "Good morning, TX.WTF."

    # Like: the first card's Like (View, Open, Reply, Like), its count and mark; again, taken back.
    start "$backend" "$xdg" "$base"
    step "$t: the feed, to like a post" "$bar" " Charles Babbage"
    for _ in $(seq 12); do keys Tab; done
    keys Enter
    # (The view scrolls to keep Like in sight, the status line above it out of sight.)
    step "$t: Like: liked, the count one up" "↩5 ⇄3 ♥22 · 310 views · liked"
    keys Enter
    step "$t: Like again: taken back" "↩5 ⇄3 ♥21 · 310 views "
    check_not "$t: ... no mark" "$out/tmux-$(slug "$t: Like again: taken back").txt" "· liked"

    # A hashtag, in a terminal: open the post, pick it in the post's Tags (the arrow keys move a
    # radio's choice there), then Open tag. Back, and Back again.
    keys BTab; keys BTab; keys Enter # Open, two stops before Like
    step "$t: the post again" "Tags: (*) #engines  ( ) #brass  [ Open tag ]"
    for _ in $(seq 8); do keys Tab; done
    keys Right
    step "$t: Tags: #brass picked" "( ) #engines  (*) #brass"
    keys Tab; keys Enter # Open tag
    # (The second, #brass on its own, is below the fold here: the 80x60 snapshots have tags.)
    step "$t: Open tag: the hashtag's posts" "#brass  ·  2 posts" \
      "The Difference Engine No. 2, working at last. #engines #brass"
    check_not "$t: ... and no others" "$out/tmux-$(slug "$t: Open tag: the hashtag's posts").txt" \
      "A ship in port"
    keys Enter # Back
    step "$t: Back: the post" "Reactions: :thumbsup: 12  :heart: 9"
    keys Enter # Back again: it keeps the focus
    step "$t: Back again: the feed" "Show: (*) Following" " Charles Babbage"

    # A new post: Post, type, Enter. It opens, yours; Delete takes it away again, back to the feed.
    for _ in $(seq 6); do keys Tab; done
    keys Enter # Post
    step "$t: Post: the new post's view" "Who sees it: (*) Public" "Post: ["
    type_text "Posted from $backend, by hand."
    keys Enter
    step "$t: posted: the new post, yours" "Posted." "Posted from $backend, by hand." \
      "[ Like ][ Repost ][ Author ][ Delete ]" "No replies yet."
    for _ in $(seq 11); do keys Tab; done
    keys Enter # Delete: past the bar, Like, Repost and Author
    step "$t: Delete: gone, back to the feed" "Deleted." "Show: (*) Following" " Charles Babbage"
    check_not "$t: ... and not in the feed" "$out/tmux-$(slug "$t: Delete: gone, back to the feed").txt" \
      "Posted from $backend"

    # A post with a picture and a big file, where the host picks and uploads files: Post, type,
    # Tab to Attach, Enter: the Open file window (a window of its own on the tvision desktop), the
    # focus in its name field. The picture's path and Enter: it is listed, and the focus is in the
    # text again. Tab past its Remove to Attach for the second, the same way. Enter posts it: the
    # picture uploaded first (POST /social/files), then the big file in the resumable upload's
    # chunks. Delete takes it away.
    if [ -n "$attach" ]; then
      for _ in $(seq 6); do keys Tab; done
      keys Enter # Post
      step "$t: Post again: the new post's view, with Attach" "[ Attach ]" "Who sees it: (*) Public"
      type_text "A picture from $backend."
      keys Tab
      keys Enter # Attach
      step "$t: Attach: the Open file window" "Attach to the post" "Name: [" "Folder: "
      type_text "$attach_file"
      keys Enter
      step "$t: attached: the picture, listed, the text kept" "1 file to attach." \
        "[ Remove ]kitten.png · $attach_size B" "[ Attach ][ Post ]" "A picture from $backend."
      keys Tab; keys Tab; keys Enter # past the picture's Remove: Attach
      step "$t: Attach again: the Open file window" "Attach to the post" "Name: ["
      type_text "$attach_big"
      keys Enter
      step "$t: attached: both listed" "2 files to attach." "[ Remove ]kitten.png" \
        "[ Remove ]engine-log.bin · 9 MB"
      keys Enter # the text has the focus again
      STEP_SECONDS=60 step "$t: posted with both" "Posted." "A picture from $backend." \
        "[image] kitten.png · $attach_size B" "engine-log.bin"
      check_upload "$t: ... the instance got the picture, every byte" kitten.png "$attach_file"
      check_upload "$t: ... and the big file, in chunks, every byte" engine-log.bin "$attach_big"
      if grep -q '"method": "PATCH", "path": "/social/files/resumable/' "$out/stub.log"; then
        pass "$t: ... the big one by the resumable upload"
      else
        fail "$t: ... the big one by the resumable upload: no PATCH in the stub's log" "$out/stub.log"
      fi
      for _ in $(seq 11); do keys Tab; done
      keys Enter # Delete
      step "$t: Delete: the post with the picture gone" "Deleted." "Show: (*) Following"
    else
      skip "$t: a post with a picture (this ari has no file-pick; transfix/libcvc#1190)"
    fi

    # A reply: the second card's Reply opens the post with the reply box focused.
    for _ in $(seq 15); do keys Tab; done
    keys Enter # past the bar, Show, the first card's five, and Open: Reply
    # (waits for the reply box: the feed shows the post's text too, so its text alone could match
    # before the post has opened)
    step "$t: Reply: the post, and the reply box" "Reply: [" "A ship in port is safe"
    type_text "Aye, from $backend."
    keys Enter
    step "$t: replied: the reply, under the post" "Replied." "Aye, from $backend." \
      "Ada Lovelace  @ada@$hostport"

    # Author, then Unfollow and Follow: ada follows grace.
    for _ in $(seq 10); do keys Tab; done
    keys Enter # Author: past the bar, Like and Repost
    step "$t: Author: her profile, followed" "@grace@$hostport  Grace Hopper" "[ Unfollow ]"
    for _ in $(seq 8); do keys Tab; done
    keys Enter
    step "$t: Unfollow" "Stopped following @grace@$hostport." "[ Follow ]"
    # Unfollow is gone, so nothing has the focus: Tab starts at Back.
    for _ in $(seq 9); do keys Tab; done
    keys Enter
    step "$t: Follow again" "Following @grace@$hostport." "[ Unfollow ]"

    # Where the host has a player, the first card's video plays by itself, muted and looping, with
    # no controls. View opens the viewer at the post's picture, and Next goes to the video, which
    # has them there and keeps playing (it loops).
    if [ -n "$media" ]; then
      PANE=100x40 start "$backend" "$xdg" "$base" --media-play always
      step "$t: the feed, with a player: its video has no controls" "$bar" " Charles Babbage"
      check_not "$t: ... none" \
        "$out/tmux-$(slug "$t: the feed, with a player: its video has no controls").txt" "[x] Mute"
      for _ in $(seq 9); do keys Tab; done
      keys Enter # View: past the bar and Show
      step "$t: View: the viewer, at the post's picture" "1 of 2" "[ Prev ][ Next ]"
      for _ in $(seq 9); do keys Tab; done
      keys Enter # Next: past the bar and Prev
      step "$t: Next: the video plays, looping, with its controls" "2 of 2" "[ Pause ]" \
        "[ ] Mute"
    fi
    # --- the Admin view, for ada (the stub's administrator) ---
    # Each backend acts on an account of its own, since nothing turns the emailed code back on:
    # eve in FTXUI, ivy in tvision. A new view starts with the focus on Back (Tab k reaches stop
    # k + 1); where the focused button goes away (Disable becomes Enable), nothing has the focus
    # and Tab k reaches stop k.
    case $backend in
      ftxui) who=eve who_id=9 who_name="Eve Example" ;;
      *) who=ivy who_id=10 who_name="Ivy Lane" ;;
    esac
    start "$backend" "$xdg" "$base"
    step "$t: the feed, to administer" "$bar" " Charles Babbage"
    for _ in $(seq 5); do keys Tab; done
    keys Enter # Profile
    step "$t: her profile has Admin" "[ Refresh ][ Sign out ][ Admin ]"
    for _ in $(seq 10); do keys Tab; done
    keys Enter # past the bar, Refresh and Sign out: Admin
    step "$t: Admin: the accounts, newest first" "Admin: (*) Users" "10 accounts, the newest first" \
      "@ivy  Ivy Lane" "[ Prev ][ Next ]  Page 1 of 2"
    for _ in $(seq 8); do keys Tab; done
    keys Right # the parts, past the bar
    step "$t: Right: the groups" "3 groups" "(*) Groups" "root                The administrators"
    keys Left
    step "$t: Left: the accounts again" "(*) Users" "10 accounts, the newest first"
    keys Tab # Find user
    type_text "${who:0:2}"
    keys Enter
    step "$t: Find user: the usernames with ${who:0:2} in them" \
      "1 account with \"${who:0:2}\" in the username" "@$who  $who_name"
    keys Tab; keys Enter # its Open
    step "$t: Open: $who's account" "@$who@$hostport  $who_name" \
      "Account: active · Administrator: no · Two-step sign-in: on" \
      "[ Disable ][ Make admin ][ Two-step off ][ Profile ]"
    for _ in $(seq 8); do keys Tab; done
    keys Enter # Disable, past the bar
    step "$t: Disable" "@$who is disabled: signed out, and can't sign in." "Account: disabled" \
      "[ Enable ][ Make admin ][ Two-step off ][ Profile ]"
    # A disabled account's sign-in: the instance refuses the password, and emails no code (as
    # txwtf's execute_login).
    start "$backend" "$work/xdg-$who" "$base" -- --user "$who"
    step "$t: the form for $who" "Username: [$who"
    form_focus; keys Tab; type_text "correct horse"; keys Tab; keys Enter
    step "$t: disabled: the instance won't sign $who in" \
      "This account is disabled. Ask the site's administrators." "Sign in to TX.WTF"
    check_not "$t: ... nor ask for a code" \
      "$out/tmux-$(slug "$t: disabled: the instance won't sign $who in").txt" "Two-step verification"
    if [ "$(sessions_in "$work/xdg-$who/nicotina/credentials")" = 0 ]; then
      pass "$t: ... and no session is kept for $who"
    else
      fail "$t: a session was kept for a disabled account"
    fi
    # Back to her account (a deep link): Enable, Two-step off, Make admin and Remove admin.
    start "$backend" "$xdg" "$base" -- --start "auser:$who_id"
    step "$t: --start auser:$who_id: $who's account" "@$who@$hostport  $who_name" "[ Enable ]"
    for _ in $(seq 8); do keys Tab; done
    keys Enter # Enable
    step "$t: Enable" "@$who can sign in again." "Account: active" "[ Disable ]"
    for _ in $(seq 11); do keys Tab; done
    keys Enter # Two-step off: nothing has the focus, so Tab 11 reaches stop 11
    step "$t: Two-step off" "@$who signs in without two-step sign-in now." "Two-step sign-in: off" \
      "[ Disable ][ Make admin ][ Profile ]"
    for _ in $(seq 10); do keys Tab; done
    keys Enter # Make admin
    step "$t: Make admin" "@$who is an administrator now." "Administrator: yes" \
      "[ Disable ][ Remove admin ][ Profile ]"
    for _ in $(seq 10); do keys Tab; done
    keys Enter # Remove admin
    step "$t: Remove admin" "@$who is no longer an administrator." "Administrator: no"
    # Enabled, with the code off: her password alone signs her in, to her (empty) feed.
    start "$backend" "$work/xdg-$who" "$base" -- --user "$who"
    step "$t: the form for $who again" "Username: [$who"
    form_focus; keys Tab; type_text "correct horse"; keys Tab; keys Enter
    step "$t: enabled, the code off: $who signs in with her password" "$bar" \
      "Your feed is empty. Follow people, or Show: Everyone."
    check_not "$t: ... and she has no Admin" \
      "$out/tmux-$(slug "$t: enabled, the code off: $who signs in with her password").txt" \
      "Admin" "Two-step verification"
    # A group: add her, make her its admin and not, remove her.
    start "$backend" "$xdg" "$base" -- --start agroup:2
    step "$t: --start agroup:2: analysts" "analysts  ·  1 member" "[ Add ][ Delete group ]"
    for _ in $(seq 11); do keys Tab; done # the bar, Permissions and ada's two: Add member
    type_text "$who"
    keys Tab; keys Enter # Add
    step "$t: Add member: $who" "Added @$who to analysts." "analysts  ·  2 members" \
      "@$who  $who_name"
    keys BTab; keys BTab; keys BTab; keys Enter # her Make admin: before the field and her Remove
    step "$t: her Make admin" "@$who is an admin of analysts." \
      "@$who  $who_name  · group admin"
    for _ in $(seq 13); do keys Tab; done
    keys Enter # her Remove: the bar, Permissions, ada's two, her Drop admin
    step "$t: her Remove" "@$who is out of analysts." "analysts  ·  1 member"
    # Its permissions: one granted by name, then revoked; a name txwtf doesn't have.
    for _ in $(seq 9); do keys Tab; done
    keys Enter # Permissions (Remove went, so nothing had the focus)
    step "$t: Permissions: what analysts may do" "analysts: 2 permissions, what its members may do" \
      "StatsUserView" "SystemLogReadSelf"
    for _ in $(seq 11); do keys Tab; done # the bar, Find permission, two Revokes: Permission
    type_text "NoSuchThing"; keys Tab; keys Enter # the Grant button
    step "$t: Grant: a name txwtf doesn't have" "No permission is called NoSuchThing."
    keys BTab; for _ in $(seq 11); do keys BSpace; done
    type_text "userlistread"; keys Tab; keys Enter
    step "$t: Grant: UserListRead" "analysts grants UserListRead now." \
      "analysts: 3 permissions" "UserListRead"
    keys BTab; keys BTab; keys Enter # its Revoke, the last row's (sorted by name)
    step "$t: Revoke: UserListRead" "analysts no longer grants UserListRead." \
      "analysts: 2 permissions"
    start "$backend" "$xdg" "$base" -- --start agperm:3
    step "$t: --start agperm:3: root's" "root: 12 permissions" "Page 1 of 2"
    for _ in $(seq 8); do keys Tab; done
    type_text "group"; keys Enter # Find permission
    step "$t: Find permission: group" "root: 7 of 12 permissions with \"group\" in the name" \
      "GroupsRead"
    check_not "$t: ... none other" \
      "$out/tmux-$(slug "$t: Find permission: group").txt" "SiteTitleSet" "Page 1 of 2"
    # A new group, opened, and deleted: Delete group asks first, Keep it keeps it.
    start "$backend" "$xdg" "$base" -- --start admin:groups
    step "$t: --start admin:groups" "(*) Groups" "3 groups" "[ Create ]"
    for _ in $(seq 12); do keys Tab; done # the bar, the parts, three Opens: New group
    type_text "lecturers"; keys Tab; type_text "Give the talks"; keys Tab; keys Enter # Create
    step "$t: Create: a new group" "Created the group lecturers." "4 groups" \
      "lecturers           Give the talks"
    keys BTab; keys BTab; keys BTab; keys Enter # its Open, before New group and About it
    step "$t: its Open: no members" "lecturers  ·  0 members" "Give the talks"
    for _ in $(seq 11); do keys Tab; done
    keys Enter # Delete group: past the bar, Permissions, Add member and Add
    step "$t: Delete group asks first" "Delete lecturers? Its members' accounts stay." \
      "[ Delete group ][ Yes, delete it ][ Keep it ]"
    keys Tab; keys Tab; keys Enter # Keep it
    step "$t: Keep it" "Kept it." "lecturers  ·  0 members"
    check_not "$t: ... and it asks no more" "$out/tmux-$(slug "$t: Keep it").txt" "Yes, delete it"
    for _ in $(seq 12); do keys Tab; done
    keys Enter # Delete group again
    step "$t: Delete group again" "[ Yes, delete it ][ Keep it ]"
    keys Tab; keys Enter # Yes, delete it
    step "$t: Yes, delete it: the groups, without it" "Deleted the group lecturers." "3 groups"
    check_not "$t: ... gone" "$out/tmux-$(slug "$t: Yes, delete it: the groups, without it").txt" \
      "Give the talks"
    # Invites: who may sign up, a new code, and the code turned off.
    start "$backend" "$xdg" "$base" -- --start admin:invites
    step "$t: --start admin:invites" "Sign-up: (*) Open  ( ) Invite only" "[ New code ]"
    for _ in $(seq 9); do keys Tab; done
    keys Right # Sign-up: Invite only, past the bar and the parts
    step "$t: Sign-up: invite only" "Signing up takes an invite code now." \
      "Sign-up: ( ) Open  (*) Invite only"
    keys Left
    step "$t: Sign-up: open again" "Anyone may sign up now." "Sign-up: (*) Open  ( ) Invite only"
    # past each code's button (the stub's two, and one a backend before this made): Uses
    for _ in $(seq $((3 + codes_made))); do keys Tab; done
    type_text 5; keys Tab; type_text "workshop"; keys Tab; keys Enter # New code
    step "$t: New code" "New code: NEW-000" "0 of 5 used  on               workshop"
    codes_made=$((codes_made + 1))
    start "$backend" "$xdg" "$base" -- --start admin:invites
    step "$t: the codes again, the new one first" "Sign-up: (*) Open" "[ Turn off ]"
    for _ in $(seq 10); do keys Tab; done
    keys Enter # the first code's Turn off, past the bar, the parts and Sign-up
    step "$t: Turn off" "That code is off: it signs no one up now." \
      "0 of 5 used  off              workshop"
    # Site: the title saved (the window takes it), and back.
    start "$backend" "$xdg" "$base" -- --start admin:site
    step "$t: --start admin:site" "Title: [TX.WTF]" "Time zone: [UTC]"
    for _ in $(seq 9); do keys Tab; done # Title, past the bar and the parts
    keys End; for _ in $(seq 6); do keys BSpace; done
    type_text "Analytical Engines"
    for _ in $(seq 3); do keys Tab; done
    keys Enter # Save, past About and Time zone
    step "$t: the title saved" "Saved the title." " Analytical Engines " \
      "Title: [Analytical Engines]"
    for _ in $(seq 3); do keys BTab; done
    keys End; for _ in $(seq 18); do keys BSpace; done
    type_text "TX.WTF"
    for _ in $(seq 3); do keys Tab; done
    keys Enter # Save
    step "$t: ... and back" "Saved the title." " TX.WTF " "Title: [TX.WTF]"
    # The log: the changes just made at its top; one kind of event; the next page.
    start "$backend" "$xdg" "$base" -- --start admin:log
    step "$t: --start admin:log: the changes at its top" "(*) Log" \
      "ada          Setting Change     site title cha..." "Page 1 of "
    for _ in $(seq 9); do keys Tab; done
    keys Right # Events, past the bar and the parts: User Login
    step "$t: Events: sign-ins alone" "4 events: User Login, the newest first"
    keys Left
    step "$t: Events: all again" "events, the newest first" "Setting Change"
    keys Tab; keys Enter # Next
    step "$t: Next: an older page" "Page 2 of "
    # An administrator whose rights go while the view is open: the instance refuses (401
    # AccessDenied), and the client says so and stays signed in. bob (his session live in the
    # stub) puts them back.
    start "$backend" "$xdg" "$base" -- --start admin
    step "$t: --start admin" "Admin: (*) Users" "10 accounts"
    sysadmin() { # sysadmin AS USER_ID IS_ADMIN, through the stub's API
      curl -s -o /dev/null -X PUT -H "Authorization: Bearer $(token "$1")" \
        -H 'Content-Type: application/json' -d "{\"user_id\": $2, \"is_admin\": $3}" \
        "$base/group/user/sysadmin"
    }
    sysadmin ada 5 true && sysadmin ada 1 false
    for _ in $(seq 9); do keys Tab; done
    keys Enter # Find user, again
    step "$t: refused: said so, still signed in" "This account may not see the accounts here." \
      "$bar"
    sysadmin bob@peer.example 1 true && sysadmin ada 5 false

    # Everyone: the public feed, with someone ada doesn't follow.
    start "$backend" "$xdg" "$base"
    step "$t: the feed again" "Show: (*) Following" " Charles Babbage"
    for _ in $(seq 8); do keys Tab; done
    keys Right
    # (waits for the post: the choice shows before the public feed has loaded)
    step "$t: Show: Everyone" "Hello from someone you don't follow." "(*) Everyone"

    # Direct messages: DMs (the bar's last stop), grace's conversation (past Refresh, its Open),
    # whose box has the focus; a message, sent and shown below the others.
    start "$backend" "$xdg" "$base"
    step "$t: the feed, for DMs" "$bar" " Charles Babbage"
    for _ in $(seq 7); do keys Tab; done
    keys Enter # DMs
    step "$t: DMs: the conversations" "3 conversations" "@grace@$hostport  Grace Hopper"
    for _ in $(seq 9); do keys Tab; done
    keys Enter # Open: past the bar and Refresh
    step "$t: Open: grace's conversation, its box focused" "Lunch on Thursday?" "Message: ["
    type_text "Thursday works, from $backend."
    keys Enter
    step "$t: sent: the message, below the others" "Sent." "  Thursday works, from $backend."

    start "$backend" "$xdg" "$base"
    step "$t: started again, still signed in" "$bar" " Charles Babbage"
    keys Tab; keys Enter # Home, on the feed: it again
    step "$t: Home loads the feed again" "Updated. Signed in to $hostport." \
      " Charles Babbage"
    for _ in $(seq 5); do keys Tab; done
    keys Enter # Profile
    step "$t: Profile, to sign out" "@ada@$hostport  Ada Lovelace" "[ Sign out ]"
    for _ in $(seq 9); do keys Tab; done
    keys Enter # past the bar and Refresh to Sign out
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
    step "$t: the right code signs in: her feed, empty" "$bar" \
      "Your feed is empty. Follow people, or Show: Everyone."
    for _ in $(seq 5); do keys Tab; done
    keys Enter # Profile
    step "$t: grace's profile" "@grace@$hostport  Grace Hopper" "Nanoseconds, in wire. #engines"
    for _ in $(seq 10); do keys Tab; done
    keys Right; keys Right # the tabs: Balances
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
      step "$t: and then mary's feed" "$bar" "Your feed is empty."
      check_not "$t: no spinner once the requests are back" \
        "$out/tmux-$(slug "$t: and then mary's feed").txt" "Signing in..."
      for _ in $(seq 5); do keys Tab; done
      keys Enter # Profile (it takes the stub 3 s)
      step "$t: mary's profile" "@mary@$hostport" "[ Sign out ]"
      for _ in $(seq 9); do keys Tab; done
      keys Enter # past the bar and Refresh to Sign out
      step "$t: mary signs out" "Signed out."
    fi

    # The whole profile in an 80x24 terminal: the frame's bottom edge and the status row are on
    # the screen (the tvision desktop has a status line below it too).
    PANE=80x24 start "$backend" "$xdg" "$base" -- --user ada
    step "$t: the form for ada at 80x24" "Username: [ada"
    form_focus; keys Tab; type_text "correct horse"; keys Tab; keys Enter
    step "$t: the feed fits an 80x24 terminal" "Signed in to $hostport." "$bar" " Charles Babbage"
    fits_80x24 "$t: ... its frame whole, within 80 columns" \
      "$out/tmux-$(slug "$t: the feed fits an 80x24 terminal").txt"
    for _ in $(seq 5); do keys Tab; done
    keys Enter # Profile
    step "$t: the profile fits an 80x24 terminal" "@ada@$hostport  Ada Lovelace" "Show: (*) Posts" \
      "[ Newer ][ Older ]  Page 1"
    fits_80x24 "$t: ... its frame whole, within 80 columns" \
      "$out/tmux-$(slug "$t: the profile fits an 80x24 terminal").txt"
    for _ in $(seq 9); do keys Tab; done
    keys Enter # past the bar and Refresh to Sign out
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
