#!/usr/bin/env bash
# Live check: the bar dropdown opens under the icon, renders the same menu the
# overlay would, and its rows send real commands to the overlay.
#
#   tests/manual/menu_dropdown.sh
#
# Needs a running omarchy-shell, Wayland, Hyprland and jq. It opens the dropdown
# and the action card on your screen, and hides both on the way out.

set -uo pipefail

PLUGIN_ID="io.github.analytically.snapmenu"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/snapmenu"
CASE_DIR=$(mktemp -d)
CASE_MENU="$CASE_DIR/menu.png"
CASE_DESKTOP="$CASE_DIR/desktop.png"
CASE_FRAME="$CASE_DIR/frame.png"
PASS=0
FAIL=0

die() {
  printf 'menu_dropdown: %s\n' "$*" >&2
  exit 1
}

check() { # what actual expected
  if [[ $2 == "$3" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s: expected %s, got %s\n' "$1" "$3" "$2"
  fi
}

cleanup() {
  [[ -n ${FAKE_RECORDING_PID:-} ]] && kill "$FAKE_RECORDING_PID" 2>/dev/null
  omarchy-shell snapmenu.menu close >/dev/null 2>&1
  omarchy-shell shell hide "$PLUGIN_ID" >/dev/null 2>&1
  if [[ -n ${ORIGINAL_DELAY:-} ]]; then
    omarchy-shell shell summon "$PLUGIN_ID" \
      "{\"command\":{\"action\":\"set-delay\",\"value\":$ORIGINAL_DELAY}}" >/dev/null 2>&1
  fi
}
# The suite calls cleanup() between sections as well, so the scratch directory is
# removed by the exit trap only.
trap 'cleanup; rm -rf "$CASE_DIR"' EXIT

command -v omarchy-shell >/dev/null 2>&1 || die "omarchy-shell is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
[[ -n ${WAYLAND_DISPLAY:-} ]] || die "no Wayland session"

state() { omarchy-shell shell call "$PLUGIN_ID" debugState ''; }

cleanup
sleep 0.5

ORIGINAL_DELAY=$(state | jq -r '.delay')

printf 'dropdown lifecycle\n'
check "starts closed" "$(omarchy-shell snapmenu.menu isOpen)" "false"
# The bar widget registers its IPC target as it loads, which can lag a shell
# restart by a moment: toggle until it takes, the way a second click would.
OPENED=false
for _ in $(seq 1 25); do
  omarchy-shell snapmenu.menu toggle >/dev/null 2>&1
  sleep 0.25
  if [[ $(omarchy-shell snapmenu.menu isOpen) == "true" ]]; then OPENED=true; break; fi
done
check "opens on toggle" "$OPENED" "true"

ROWS=$(omarchy-shell snapmenu.menu rows)
check "rows parse" "$(jq -r 'length > 5' <<<"$ROWS")" "true"
# Assert the capture modes rather than ids, so renaming a row does not break the
# test: every way of picking pixels has to be reachable from the menu. Previous
# area is the one that comes and goes with state — it is offered only once a
# region has been remembered — so it is checked separately, below.
check "every always-available capture mode has a row" \
  "$(jq -r '[.[] | .payload.mode | select(. != null and . != "previous")] | sort | join(",")' <<<"$ROWS")" \
  "fullscreen,region,smart,window"
# Whether it is offered at all depends on state the model tests own; what matters
# live is that it is never offered dimmed, which is the behaviour that replaced the
# "No region recorded yet" line.
check "a previous-area row is never dimmed" \
  "$(jq -r '[.[] | select(.payload.mode == "previous") | select(.enabled == false)] | length' <<<"$ROWS")" "0"
check "every selectable row carries a command" \
  "$(jq -r '[.[] | select(.kind != "separator") | select(.payload == null)] | length' <<<"$ROWS")" "0"

omarchy-shell snapmenu.menu close >/dev/null
sleep 0.4
check "closes on close" "$(omarchy-shell snapmenu.menu isOpen)" "false"

printf 'the timer row writes the setting it shows\n'
TIMER_ROW=$(jq -r 'to_entries | map(select(.value.id == "timer"))[0].key' <<<"$ROWS")
[[ $TIMER_ROW =~ ^[0-9]+$ ]] || die "could not find the timer row"
omarchy-shell snapmenu.menu activate "$TIMER_ROW" >/dev/null
sleep 1.2
check "delay followed the row" "$(state | jq -r '.delay')" \
  "$(jq -r --argjson i "$TIMER_ROW" '.[$i].payload.value' <<<"$ROWS")"

printf 'a capture row captures, and the card stays up\n'
# No self-timer here: the timer row above already proved it writes the setting
# (and left the delay at its next step, which would be a ten second wait).
omarchy-shell shell summon "$PLUGIN_ID" '{"command":{"action":"set-delay","value":0}}' >/dev/null
sleep 0.4
FULLSCREEN_ROW=$(jq -r 'to_entries | map(select(.value.id == "fullscreen"))[0].key' <<<"$ROWS")
rm -f "$STATE_DIR/last-shot" 2>/dev/null
omarchy-shell snapmenu.menu activate "$FULLSCREEN_ROW" >/dev/null

SHOT=""
for _ in $(seq 1 30); do
  sleep 0.3
  SHOT=$(cat "$STATE_DIR/last-shot" 2>/dev/null || true)
  [[ -n $SHOT && -f $SHOT ]] && break
done
[[ -n $SHOT && -f $SHOT ]] || die "no screenshot came out of the dropdown"
printf '  shot:  %s\n' "$SHOT"

check "the action card is up" "$(state | jq -r '.stage')" "result"
check "and opened" "$(state | jq -r '.opened')" "true"

# Keys only reach the card once the layer surface has keyboard focus, which the
# compositor grants a moment after it maps. Waiting for it here is also the
# assertion that it happens at all.
FOCUSED=false
for _ in $(seq 1 25); do
  if [[ $(state | jq -r '.cardFocus') == "true" ]]; then FOCUSED=true; break; fi
  sleep 0.2
done
check "the card took keyboard focus" "$FOCUSED" "true"

# Dismissal is part of the contract, so assert it instead of racing a human who
# saw the card appear: Esc steps back to the menu, Esc again closes.
if command -v wtype >/dev/null 2>&1; then
  printf 'copy from the card hands off\n'
  wtype -k c
  for _ in $(seq 1 15); do
    [[ $(state | jq -r '.opened') == "false" ]] && break
    sleep 0.2
  done
  check "C closes the card" "$(state | jq -r '.opened')" "false"
  # One copy, two representations: the image for apps and agents, the path for
  # shells. wl-copy alone cannot offer both.
  check "C leaves the image on the clipboard" \
    "$(wl-paste --list-types 2>/dev/null | grep -cx 'image/png')" "1"
  # Compare against the file the card is showing: which shot that is depends on
  # what preceded the run, and pairing the clipboard with a stale last-shot
  # tested nothing.
  CARD_FILE=$(state | jq -r '.currentFile')
  check "and the path as text too" \
    "$(wl-paste --type text/plain 2>/dev/null)" "$CARD_FILE"
  # The file representations point at a snapshot, so a pasted file cannot
  # dangle when the original is edited, renamed or deleted.
  check "and the file types, for pasting a file" \
    "$(wl-paste --list-types 2>/dev/null | grep -cx 'text/uri-list')" "1"
  SNAPSHOT=$(wl-paste --type text/uri-list 2>/dev/null | python3 -c "
import sys, urllib.parse
print(urllib.parse.unquote(sys.stdin.read().strip()[len('file://'):]))
")
  check "the snapshot exists" "$([[ -f $SNAPSHOT ]] && echo yes)" "yes"
  check "and holds this shot" "$(basename "$SNAPSHOT")" "$(basename "$CARD_FILE")"
  check "and is a PNG" "$(head -c 4 "$SNAPSHOT" | xxd -p)" "89504e47"

  # The image is invisible to a shell, so the same copy carries the path as text
  # too — the checks above read it back. There is no path-only shortcut any more.

  # Reopen for the dismissal checks below.
  omarchy-shell shell summon "$PLUGIN_ID" '{"stage":"result"}' >/dev/null
  for _ in $(seq 1 20); do
    [[ $(state | jq -r '.cardFocus') == "true" ]] && break
    sleep 0.2
  done

  printf 'dismissal\n'
  # The card is where a shot is finished with, so Escape dismisses it outright: there
  # is nothing left to choose from. The menu, history, settings and about are steps on
  # the way somewhere else, and Escape steps back through those.
  # A layer surface can be on screen, and focused as far as QML knows, before the
  # compositor has handed it the keyboard: the first Escape is sometimes swallowed. The
  # test presses until it lands rather than depending on one keystroke.
  for _ in $(seq 1 4); do
    wtype -k Escape
    for _ in $(seq 1 8); do
      sleep 0.2
      [[ $(state | jq -r '.opened') == "false" ]] && break 2
    done
  done
  check "Esc on the card closes it" "$(state | jq -r '.opened')" "false"
  check "and leaves nothing of ours up" \
    "$(state | jq -r '(.opened == false) and (.selectorActive == false)')" "true"
fi

printf 'walking the history from the card\n'
  omarchy-shell shell call "$PLUGIN_ID" captureAreaAt '300,200 200x150' >/dev/null
  for _ in $(seq 1 25); do
    [[ $(state | jq -r '.stage') == "result" ]] && break
    sleep 0.3
  done
  CURRENT=$(state | jq -r '.currentFile')
  omarchy-shell shell call "$PLUGIN_ID" stepShot older >/dev/null
  sleep 0.5
  STEPPED=$(state | jq -r '.currentFile')
  check "the older button steps back through the history" \
    "$([ "$STEPPED" != "$CURRENT" ] && echo yes)" "yes"
  RET=$(omarchy-shell shell call "$PLUGIN_ID" stepShot newer 2>/dev/null)
  sleep 0.5
  FORWARD=$(state | jq -r '.currentFile')
  # Either is correct: it moved, or it reported there is nothing newer to move to. That
  # happens whenever the card's subject has advanced past the step — another capture
  # landing in the shared export folder does exactly that — and asserting the move alone
  # made this check fail for a reason that is not a defect.
  check "the newer button moves it, or says there is nowhere newer" \
    "$([ "$FORWARD" != "$STEPPED" ] || [ "$RET" = "none" ] && echo ok)" "ok"

printf 'a capture started from the menu does not freeze the menu into the frame\n'
  # The popout is a full-screen layer of Omarchy's own (omarchy-keyboard-panel),
  # not this plugin's namespace, so the no-anim rule the helper sets for its own
  # surfaces does not cover it and waiting for its layer to disappear does not wait
  # for its fade. Freezing too early bakes that fading menu into the frozen frame.
  #
  # Photograph the screen twice — once with the menu up, once with it gone — then
  # ask which of the two the frozen frame resembles. Relative, so no thresholds,
  # and whole-screen, because the popout's layer covers the whole screen.
  MENU_ALIAS="${PLUGIN_ID##*.}"
  omarchy-shell shell hide "$PLUGIN_ID" >/dev/null 2>&1
  omarchy-shell $MENU_ALIAS.menu close >/dev/null 2>&1
  omarchy-shell shell call "$PLUGIN_ID" cancelCapture '' >/dev/null 2>&1
  sleep 1.2
  rm -f "$STATE_DIR"/freeze/freeze-*.png 2>/dev/null
  for _ in $(seq 1 6); do
    omarchy-shell $MENU_ALIAS.menu open >/dev/null 2>&1
    sleep 1.5
    [[ $(omarchy-shell $MENU_ALIAS.menu isOpen 2>/dev/null) == "true" ]] && break
  done
  check "the menu is open to start a capture from" \
    "$(omarchy-shell $MENU_ALIAS.menu isOpen 2>/dev/null)" "true"
  grim "$CASE_MENU" 2>/dev/null || true

  # Which row starts a region capture is the menu's business, not the test's.
  CAPTURE_ROW=$(omarchy-shell $MENU_ALIAS.menu rows 2>/dev/null \
    | jq -r '[to_entries[] | select(.value.id == "region-or-window")][0].key // ""')
  check "no picker is left over from earlier checks" "$(state | jq -r '.selectorActive')" "false"
  omarchy-shell $MENU_ALIAS.menu activate "$CAPTURE_ROW" >/dev/null 2>&1
  for _ in $(seq 1 40); do
    sleep 0.15
    [[ $(state | jq -r '.selectorActive') == "true" ]] && break
  done
  check "the capture opened the picker" "$(state | jq -r '.selectorActive')" "true"

  # The frame is written by grim as the picker comes up and is deleted once a
  # selection has been cropped, so it is copied here, while the picker waits to be
  # dragged — and only once it is a complete PNG, since grim writes it in place.
  # The plugin must say which rectangle it is waiting on, because the popout is a
  # full-screen layer and probing the middle of the screen misses a menu fading out
  # in the corner. Without it there is nothing that can catch the ghost.
  SETTLE=$(state | jq -r '.settleArea // ""')
  check "the capture declares the rectangle it will wait on" \
    "$([[ -n $SETTLE ]] && echo yes)" "yes"

  # The frame is only complete once the picker is fully up — grim writes it in place
  # and a copy taken mid-write is a truncated PNG that compares against anything —
  # so wait for the picker, then for the file size to stop changing. The path comes
  # from the plugin, which started the helper and knows where it wrote.
  FRAME=""
  for _ in $(seq 1 40); do
    sleep 0.15
    [[ $(state | jq -r '.selectorActive') == "true" ]] && break
  done
  # Several attempts: a single check after one settle was enough when the machine was
  # idle and skipped the copy entirely when it was not.
  for _ in $(seq 1 6); do
    CANDIDATE=$(state | jq -r '.freezePath // ""')
    if [[ -n $CANDIDATE && -s $CANDIDATE ]]; then
      FIRST=$(stat -c %s "$CANDIDATE")
      sleep 0.3
      if [[ $(stat -c %s "$CANDIDATE") == "$FIRST" ]] && magick identify "$CANDIDATE" >/dev/null 2>&1; then
        FRAME="$CANDIDATE"
        cp "$CANDIDATE" "$CASE_FRAME"
        break
      fi
    fi
    sleep 0.3
  done
  printf '        frame reported: %s\n' "${FRAME:-none}"
  printf '        state dir listing: %s\n' "$(ls -t "$STATE_DIR"/freeze/ 2>/dev/null | head -3 | tr '\n' ' ')"
  omarchy-shell shell call "$PLUGIN_ID" cancelCapture '' >/dev/null 2>&1
  omarchy-shell $MENU_ALIAS.menu close >/dev/null 2>&1
  sleep 1.2
  grim "$CASE_DESKTOP" 2>/dev/null || true

  check "a frozen frame was written" "$([[ -s $CASE_FRAME ]] && echo yes)" "yes"
  if [[ -s $CASE_FRAME ]]; then
    # RMSE as a fraction: "4232.36 (0.0645817)" -> 0.0645817
    rmse() { magick compare -metric RMSE "$1" "$2" null: 2>&1 | sed 's/.*(\([0-9.]*\))/\1/'; }
    # Compared where the menu actually was: a fading menu is only a ghost there, so
    # a whole-screen average can hide it entirely.
    if [[ -n $SETTLE ]]; then
      # "X,Y WxH" (grim) -> "WxH+X+Y" (magick)
      CROP=$(python3 -c "
origin, _, size = '\''$SETTLE'\''.partition(' ')
x, _, y = origin.partition(',')
print(size + '+' + x + '+' + y)" 2>/dev/null || echo "")
      if [[ -n $CROP ]]; then
        for shot in CASE_FRAME CASE_MENU CASE_DESKTOP; do
          magick "${!shot}" -crop "$CROP" +repage "$CASE_DIR/crop-$shot.png" 2>/dev/null || true
        done
        TO_MENU=$(rmse "$CASE_DIR/crop-CASE_FRAME.png" "$CASE_DIR/crop-CASE_MENU.png")
        TO_DESKTOP=$(rmse "$CASE_DIR/crop-CASE_FRAME.png" "$CASE_DIR/crop-CASE_DESKTOP.png")
      fi
    fi
    : "${TO_MENU:=$(rmse "$CASE_FRAME" "$CASE_MENU")}"
    : "${TO_DESKTOP:=$(rmse "$CASE_FRAME" "$CASE_DESKTOP")}"
    printf '        frame vs menu %s, vs desktop %s\n' "$TO_MENU" "$TO_DESKTOP"
    # The screen behind the menu is a live terminal, so comparing the frame against
    # the desktop is noise. Compare it against the menu instead: a frame that is not
    # the menu has to differ from it by a good fraction of how much the menu differs
    # from the desktop, and a ghost of any visible strength does not.
    MENU_WEIGHT=$(rmse "$CASE_MENU" "$CASE_DESKTOP")
    printf '        frame vs menu %s, menu vs desktop %s\n' "$TO_MENU" "$MENU_WEIGHT"
    check "the frozen frame is not the menu" \
      "$(python3 -c "
frame, menu, weight = float('$TO_MENU' or 0), float('$TO_MENU' or 0), float('$MENU_WEIGHT' or 0)
print('yes' if weight <= 0 or frame >= 0.35 * weight else 'no')" 2>/dev/null || echo unparsed)" "yes"
  fi

printf 'Esc on the card closes it rather than stepping back\n'
  # The card is the end of the road for the shot: Esc dismisses it. It used to drop
  # back to the menu, which meant the pane stayed on screen after "closing" it.
  omarchy-shell shell hide "$PLUGIN_ID" >/dev/null 2>&1
  sleep 0.8
  omarchy-shell shell call "$PLUGIN_ID" captureAreaAt '300,200 250x180' >/dev/null 2>&1
  for _ in $(seq 1 30); do
    sleep 0.3
    [[ $(state | jq -r '.stage') == "result" ]] && break
  done
  check "the card is up" "$(state | jq -r '.stage')" "result"
  for _ in $(seq 1 20); do
    sleep 0.2
    [[ $(state | jq -r '.cardFocus') == "true" ]] && break
  done
  wtype -k Escape
  sleep 0.8
  check "Esc closes the card" "$(state | jq -r '.opened')" "false"
  # Nothing of ours left on screen: no card, and no picker either.
  check "and nothing else of ours is up"     "$(state | jq -r '(.opened == false) and (.selectorActive == false)')" "true"

printf 'capture previous area repeats the last region\n'
  # The one capture path with no freeze and no picker: it shoots the remembered
  # rectangle straight away, so it depends on the helper waiting for our own layer.
  printf '120,140 360x260\n' >"$STATE_DIR/last-region"
  omarchy-shell shell hide "$PLUGIN_ID" >/dev/null 2>&1
  sleep 0.8
  before=$(state | jq -r '.currentFile // ""')
  omarchy-shell shell call "$PLUGIN_ID" capturePrevious '' >/dev/null 2>&1
  for _ in $(seq 1 30); do
    sleep 0.3
    now=$(state | jq -r '.currentFile // ""')
    [[ -n $now && $now != "null" && $now != "$before" ]] && break
  done
  check "previous area produced a new shot" "$([[ -n $now && $now != "null" && $now != "$before" ]] && echo yes)" "yes"
  check "and left the remembered region alone" "$(cat "$STATE_DIR/last-region")" "120,140 360x260"

printf 'deleting a shot from the card\n'
  SCRATCH="$CASE_DIR/scratch-shot.png"
  magick -size 40x30 xc:blue "$SCRATCH" 2>/dev/null || true
  if [[ -f $SCRATCH ]]; then
    omarchy-shell shell summon "$PLUGIN_ID" "{\"path\":\"$SCRATCH\"}" >/dev/null 2>&1
    for _ in $(seq 1 20); do
      sleep 0.2
      [[ $(state | jq -r '.stage') == "result" ]] && break
    done
    check "the card opens a file by path" "$(state | jq -r '.stage')" "result"
    wtype -k x
    for _ in $(seq 1 15); do
      sleep 0.2
      [[ ! -f $SCRATCH ]] && break
    done
    check "X removes it" "$([[ -f $SCRATCH ]] && echo here || echo gone)" "gone"
    # A shot the plugin is throwing away must not travel through the Trash.
    check "and it went, not to the Trash" \
      "$(find ~/.local/share/Trash/files -maxdepth 1 -name 'scratch-shot*' 2>/dev/null | wc -l)" "0"
  fi

printf 'the bar icon reflects the state\n'
icon() { omarchy-shell snapmenu.menu icon; }

# Start from a known state: another run may have left a self-timer armed.
omarchy-shell shell summon "$PLUGIN_ID" '{"command":{"action":"set-delay","value":0}}' >/dev/null
for _ in $(seq 1 20); do
  [[ $(icon | jq -r '.tone') == "idle" ]] && break
  sleep 0.3
done

check "idle icon is the camera" "$(icon | jq -r '.tone')" "idle"
check "with the menu tooltip" \
  "$(icon | jq -r '.tooltip | test("screenshot menu")')" "true"

# Arm the timer the way the menu does, and the glyph should follow.
omarchy-shell shell summon "$PLUGIN_ID" '{"command":{"action":"set-delay","value":5}}' >/dev/null
for _ in $(seq 1 20); do
  TONE=$(icon | jq -r '.tone')
  [[ $TONE == "armed" ]] && break
  sleep 0.3
done
check "an armed self-timer shows in the icon" "$TONE" "armed"
check "and the tooltip says how long" \
  "$(icon | jq -r '.tooltip | test("5 s")')" "true"

# A recording is detected from the outside, like the screen-recording indicator
# does it: a process that looks like gpu-screen-recorder.
bash -c 'exec -a gpu-screen-recorder sleep 25' &
FAKE_RECORDING_PID=$!
for _ in $(seq 1 25); do
  TONE=$(icon | jq -r '.tone')
  [[ $TONE == "recording" ]] && break
  sleep 0.4
done
check "a running recording outranks the timer" "$TONE" "recording"
kill "$FAKE_RECORDING_PID" 2>/dev/null
FAKE_RECORDING_PID=""
for _ in $(seq 1 25); do
  TONE=$(icon | jq -r '.tone')
  [[ $TONE == "armed" ]] && break
  sleep 0.4
done
check "and gives the icon back when it ends" "$TONE" "armed"

printf '\n  menu dropdown: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
