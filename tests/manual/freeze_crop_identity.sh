#!/usr/bin/env bash
# Live check: a cropped shot is the frozen frame it came from, pixel for pixel.
#
#   tests/manual/freeze_crop_identity.sh
#
# Needs a running omarchy-shell, Wayland, Hyprland, wtype and (for the file
# comparison) ImageMagick. It opens the picker on your screen for a moment and
# takes one screenshot; the picker is hidden again on the way out.
#
# The frame the picker cropped is deleted by the helper right after the crop, so
# this copies it while the picker sits waiting for a key press — which is where
# it lives for as long as the user would be aiming.

set -uo pipefail

PLUGIN_ID="io.github.analytically.snapmenu"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/snapmenu"
TOLERANCE_PCT="${SNAPMENU_IDENTITY_TOLERANCE:-1}"

die() {
  printf 'freeze_crop_identity: %s\n' "$*" >&2
  exit 1
}

cleanup() { omarchy-shell shell hide "$PLUGIN_ID" >/dev/null 2>&1; }
trap cleanup EXIT

for tool in wtype magick identify omarchy-shell jq hyprctl; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
[[ -n ${WAYLAND_DISPLAY:-} ]] || die "no Wayland session"

state() { omarchy-shell shell call "$PLUGIN_ID" debugState ''; }

# Start from a clean slate so the frame and the shot we find below belong to
# this run: a stale last-shot from an earlier capture would end the wait below
# before the picker had even cropped.
cleanup
rm -f "$STATE_DIR"/freeze/freeze-*.png 2>/dev/null
# A shot from an earlier run would be compared against this run's frame.
rm -f "$STATE_DIR"/last-shot 2>/dev/null
rm -f "$STATE_DIR"/last-shot 2>/dev/null

printf 'opening the picker (whole-monitor selection)\n'
omarchy-shell shell call "$PLUGIN_ID" captureArea '' >/dev/null || die "could not summon the picker"

for _ in $(seq 1 20); do
  [[ $(state | jq -r '.selectorActive') == "true" ]] && break
  sleep 0.3
done
[[ $(state | jq -r '.selectorActive') == "true" ]] || die "the picker did not come up"

FRAME=$(ls -t "$STATE_DIR"/freeze/freeze-*.png 2>/dev/null | head -1 || true)
[[ -n $FRAME && -f $FRAME ]] || die "the picker did not freeze a frame"
KEPT=$(mktemp --suffix=.png)
cp "$FRAME" "$KEPT"
printf 'frozen frame: %s\n' "$FRAME"

# The picker has to hold keyboard focus for Return to reach it at all.
for _ in $(seq 1 20); do
  [[ $(state | jq -r '.hasKeyFocus') == "true" ]] && break
  sleep 0.2
done
[[ $(state | jq -r '.hasKeyFocus') == "true" ]] || die "the picker never took keyboard focus"

# Enter with nothing dragged captures the whole frozen monitor.
wtype -k Return

SHOT=""
for _ in $(seq 1 30); do
  sleep 0.3
  SHOT=$(cat "$STATE_DIR/last-shot" 2>/dev/null || true)
  [[ -n $SHOT && -f $SHOT ]] && break
done
[[ -n $SHOT && -f $SHOT ]] || die "no screenshot was produced"

printf 'shot:          %s\n' "$SHOT"

SHOT_SIZE=$(identify -format '%wx%h' "$SHOT")
FRAME_SIZE=$(identify -format '%wx%h' "$KEPT")
[[ $SHOT_SIZE == "$FRAME_SIZE" ]] ||
  die "the shot is $SHOT_SIZE but the frame is $FRAME_SIZE (whole-monitor capture should match)"

AE=$(magick compare -metric AE "$KEPT" "$SHOT" null: 2>&1 | awk '{print $1}')
PIXELS=$(identify -format '%[fx:w*h]' "$SHOT")
DIFF_PCT=$(awk -v ae="$AE" -v px="$PIXELS" 'BEGIN { printf "%.4f", (ae / px) * 100 }')
printf 'differing:     %s of %s pixels (%s%%)\n' "$AE" "$PIXELS" "$DIFF_PCT"
rm -f "$KEPT"

if awk -v diff="$DIFF_PCT" -v limit="$TOLERANCE_PCT" 'BEGIN { exit !(diff <= limit) }'; then
  printf 'PASS  the crop is the frozen frame (within %s%%)\n' "$TOLERANCE_PCT"
  exit 0
fi

printf 'FAIL  the crop is not the frozen frame (limit %s%%)\n' "$TOLERANCE_PCT" >&2
exit 1
