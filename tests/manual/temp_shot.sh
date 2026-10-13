#!/usr/bin/env bash
# Live check: a shot taken with Save off belongs to the card, and the card is what
# decides when it goes.
#
#   tests/manual/temp_shot.sh
#
# Save off writes a temporary file instead of one in your Pictures folder. Copy,
# Annotate, Share and Reveal all work on that file, so it has to exist while the card
# is up: it used to be deleted the moment the capture finished, which also threw the
# card itself back to the menu, so a Save-off capture never showed a card at all.
#
# Needs a running omarchy-shell, Wayland and jq. It opens the picker and the card on
# your screen, and puts your Save and Copy settings back on the way out.

set -uo pipefail

PLUGIN_ID="io.github.analytically.snapmenu"
SHELL_CONFIG="$HOME/.config/omarchy/shell.json"
PASS=0
FAIL=0

die() {
  printf 'temp_shot: %s\n' "$*" >&2
  exit 1
}

check() { # what actual expected
  if [[ $2 == "$3" ]]; then
    printf '  ok    %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s: expected %s, got %s\n' "$1" "$3" "$2" >&2
    FAIL=$((FAIL + 1))
  fi
}

state() { omarchy-shell shell call "$PLUGIN_ID" debugState ''; }

setting() { # key — what this plugin's bar entry says, or empty for "not set"
  jq -r --arg id "$PLUGIN_ID" --arg key "$1" \
    '[.bar.layout[]?[]? | select(.id == $id)] | first | .[$key] // empty' \
    "$SHELL_CONFIG" 2>/dev/null
}

set_setting() { # key json_value
  omarchy-shell shell summon "$PLUGIN_ID" \
    "{\"command\":{\"action\":\"set-setting\",\"key\":\"$1\",\"value\":$2}}" >/dev/null 2>&1
}

# The settings under test are the user's, so they go back whatever happens.
restore() {
  omarchy-shell shell hide "$PLUGIN_ID" >/dev/null 2>&1
  set_setting saveToDisk "${SAVE_WAS:-true}"
  set_setting copyToClipboard "${COPY_WAS:-false}"
}
trap restore EXIT

for tool in omarchy-shell jq; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
[[ -n ${WAYLAND_DISPLAY:-} ]] || die "no Wayland session"

SAVE_WAS=$(setting saveToDisk)
SAVE_WAS=${SAVE_WAS:-true}
COPY_WAS=$(setting copyToClipboard)
COPY_WAS=${COPY_WAS:-false}

GEOMETRY='120,120 420x260'

capture_and_wait() { # out_var_file
  omarchy-shell shell call "$PLUGIN_ID" captureAreaAt "$GEOMETRY" >/dev/null 2>&1
  local stage=""
  for _ in $(seq 1 25); do
    sleep 0.4
    stage=$(state | jq -r '.stage')
    [[ $stage == "result" ]] && break
  done
  printf '%s' "$stage"
}

wait_for_card_focus() {
  for _ in $(seq 1 25); do
    [[ $(state | jq -r '.cardFocus') == "true" ]] && return 0
    sleep 0.2
  done
  return 1
}

printf 'Save off (was %s), Copy off (was %s)\n' "$SAVE_WAS" "$COPY_WAS"
set_setting saveToDisk false
set_setting copyToClipboard false
sleep 1.5

printf 'the card holds the shot while it is up\n'
STAGE=$(capture_and_wait)
check "the capture reached the card, not the menu" "$STAGE" "result"
FILE=$(state | jq -r '.currentFile')
check "the card is showing a shot" \
  "$([[ -n $FILE && $FILE != null ]] && echo yes || echo no)" "yes"
check "and the temporary file is still there" "$([[ -f $FILE ]] && echo yes || echo no)" "yes"
check "and it is the temporary folder, not Pictures" \
  "$(dirname "$FILE")" "${XDG_STATE_HOME:-$HOME/.local/state}/snapmenu/tmp"

printf 'and gives it up when the card closes\n'
if command -v wtype >/dev/null 2>&1 && wait_for_card_focus; then
  wtype -k Escape
else
  omarchy-shell shell hide "$PLUGIN_ID" >/dev/null 2>&1
fi
for _ in $(seq 1 20); do
  [[ ! -f $FILE ]] && break
  sleep 0.3
done
check "the shot is gone once the card closes" \
  "$([[ -f $FILE ]] && echo yes || echo no)" "no"

printf 'unless the card copies it, which is what it was for\n'
if command -v wtype >/dev/null 2>&1; then
  STAGE=$(capture_and_wait)
  check "a second Save-off capture reached the card" "$STAGE" "result"
  FILE=$(state | jq -r '.currentFile')
  wait_for_card_focus || true
  wtype -k c
  for _ in $(seq 1 20); do
    [[ ! -f $FILE ]] && break
    sleep 0.3
  done
  check "the copy took the shot with it" \
    "$([[ -f $FILE ]] && echo yes || echo no)" "no"
  check "and the image is on the clipboard" \
    "$(command -v wl-paste >/dev/null 2>&1 && wl-paste --list-types 2>/dev/null | grep -cx 'image/png')" "1"
  omarchy-shell shell hide "$PLUGIN_ID" >/dev/null 2>&1
else
  printf '  skip  wtype is not installed, so the card cannot be driven by key\n'
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
