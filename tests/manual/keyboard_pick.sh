#!/usr/bin/env bash
# Live check: the keyboard path picks a whole window and captures exactly its
# pixels — the All-In-One behaviour that no headless runner can reach, because
# it needs a compositor, a mapped layer surface and real keyboard focus.
#
#   tests/manual/keyboard_pick.sh
#
# Needs a running omarchy-shell, Wayland, Hyprland, wtype and jq. The picker is
# on screen for a couple of seconds and ends with one screenshot.

set -uo pipefail

PLUGIN_ID="io.github.analytically.snapmenu"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/snapmenu"

die() {
  printf 'keyboard_pick: %s\n' "$*" >&2
  exit 1
}

for tool in wtype omarchy-shell jq hyprctl identify; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
[[ -n ${WAYLAND_DISPLAY:-} ]] || die "no Wayland session"

state() { omarchy-shell shell call "$PLUGIN_ID" debugState ''; }

# Never leave the picker on screen: a stray one poisons the next run (and the
# user's screen).
cleanup() { omarchy-shell shell hide "$PLUGIN_ID" >/dev/null 2>&1; }
trap cleanup EXIT

wait_for_picker() { # timeout_tenths
  local tries=$1
  for _ in $(seq 1 "$tries"); do
    if [[ $(state | jq -r '.selectorActive') == "true" ]]; then return 0; fi
    sleep 0.3
  done
  return 1
}

# The focused monitor's scale: grim writes logical geometry times this.
SCALE=$(hyprctl monitors -j | jq -r '.[] | select(.focused == true) | .scale')
[[ -n $SCALE ]] || die "could not read the monitor scale"

WINDOWS=$(hyprctl clients -j | jq -c '[.[] | select(.hidden != true) | {title, w: .size[0], h: .size[1]}]')
[[ $(jq 'length' <<<"$WINDOWS") -gt 0 ]] || die "no windows to pick from"

printf 'scale %s, %s window(s) on the workspace\n' "$SCALE" "$(jq 'length' <<<"$WINDOWS")"

omarchy-shell shell call "$PLUGIN_ID" captureArea '' >/dev/null || die "could not summon the picker"
wait_for_picker 20 || die "the picker did not come up (selectorActive never became true)"

# The layer surface needs keyboard focus before wtype's key reaches it.
for _ in $(seq 1 20); do
  [[ $(state | jq -r '.hasKeyFocus') == "true" ]] && break
  sleep 0.2
done
[[ $(state | jq -r '.hasKeyFocus') == "true" ]] || die "the picker never took keyboard focus"

# Tab selects the next window in reading order; the picker reports which one. The
# first key after a layer surface maps can still be swallowed before the compositor
# grants it the keyboard, so this keeps pressing: whoever it lands on is what the
# test then captures, so extra presses cost nothing.
PICKED=""
for _ in $(seq 1 5); do
  wtype -k Tab
  for _ in $(seq 1 6); do
    sleep 0.3
    PICKED=$(state | jq -c '.keyboardRect')
    [[ $PICKED != "null" ]] && break 2
  done
done
[[ $PICKED != "null" ]] || die "Tab did not select a window (keyboardRect is null)"

PICK_W=$(jq -r '.width' <<<"$PICKED")
PICK_H=$(jq -r '.height' <<<"$PICKED")
PICK_LABEL=$(jq -r '.label' <<<"$PICKED")
printf 'Tab picked: %s (%sx%s)\n' "$PICK_LABEL" "$PICK_W" "$PICK_H"

wtype -k Return
sleep 3

STAGE=$(state | jq -r '.stage')
[[ $STAGE == "result" ]] || die "expected the action card after the capture, got stage=$STAGE"

SHOT=$(cat "$STATE_DIR/last-shot" 2>/dev/null || true)
[[ -n $SHOT && -f $SHOT ]] || die "no screenshot was produced"

EXPECT_W=$(awk -v w="$PICK_W" -v s="$SCALE" 'BEGIN { printf "%.0f", w * s }')
EXPECT_H=$(awk -v h="$PICK_H" -v s="$SCALE" 'BEGIN { printf "%.0f", h * s }')
GOT=$(identify -format '%wx%h' "$SHOT")

printf 'captured: %s (expected %sx%s)\n' "$GOT" "$EXPECT_W" "$EXPECT_H"

if [[ $GOT == "${EXPECT_W}x${EXPECT_H}" ]]; then
  printf 'PASS  %s captured exactly its own pixels\n' "$PICK_LABEL"
  exit 0
fi

printf 'FAIL  %s is %sx%s but the shot is %s\n' "$PICK_LABEL" "$PICK_W" "$PICK_H" "$GOT" >&2
exit 1
