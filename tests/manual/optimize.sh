#!/usr/bin/env bash
# Live check: re-compressing a saved shot happens behind the card, never in front of it.
#
#   tests/manual/optimize.sh
#
# A capture is written at the PNG level grim writes fast, so the card appears at once, and
# the file is re-compressed afterwards at a slower level. This asserts the order the user
# would feel if it were wrong: the card is up before the compressor is asked to do
# anything, the pass runs at idle priority, and the file it leaves is smaller with the same
# pixels in it.
#
# Needs a running omarchy-shell, Wayland and jq. It takes a few full-screen shots into a
# temporary folder and puts your settings back on the way out.

set -uo pipefail

PLUGIN_ID="io.github.analytically.snapmenu"
WORK=$(mktemp -d)
PASS=0
FAIL=0

die() {
  printf 'optimize: %s\n' "$*" >&2
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

note() { printf '  note  %s\n' "$1"; }

state() { omarchy-shell shell call "$PLUGIN_ID" debugState ''; }

setting() { # key
  jq -r --arg id "$PLUGIN_ID" --arg key "$1" \
    '[.bar.layout[]?[]? | select(.id == $id)] | first | .[$key] // empty' \
    "$HOME/.config/omarchy/shell.json" 2>/dev/null
}

set_setting() { # key json_value
  omarchy-shell shell summon "$PLUGIN_ID" \
    "{\"command\":{\"action\":\"set-setting\",\"key\":\"$1\",\"value\":$2}}" >/dev/null 2>&1
}

restore() {
  omarchy-shell shell hide "$PLUGIN_ID" >/dev/null 2>&1
  set_setting optimizeShots "${OPT_WAS:-5}"
  set_setting saveToDisk "${SAVE_WAS:-true}"
  set_setting exportDir "\"${DIR_WAS:-}\""
  rm -rf "$WORK"
}
trap restore EXIT

for tool in omarchy-shell jq identify; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
[[ -n ${WAYLAND_DISPLAY:-} ]] || die "no Wayland session"

OPT_WAS=$(setting optimizeShots)
OPT_WAS=${OPT_WAS:-5}
SAVE_WAS=$(setting saveToDisk)
SAVE_WAS=${SAVE_WAS:-true}
DIR_WAS=$(setting exportDir)
mkdir -p "$WORK/shots"

# The shots land in a folder of our own: this is about the file, and the user's Pictures
# folder is not the place to leave a handful of full-screen tests behind.
set_setting saveToDisk true
set_setting exportDir "\"$WORK/shots\""
sleep 1.5

capture() { # out: "STAGE MS" — milliseconds from the call to the card being up
  local before after stage
  before=$(date +%s%N)
  omarchy-shell shell call "$PLUGIN_ID" captureScreen '' >/dev/null 2>&1
  stage=""
  for _ in $(seq 1 60); do
    sleep 0.2
    stage=$(state | jq -r '.stage')
    [[ $stage == "result" ]] && break
  done
  after=$(date +%s%N)
  printf '%s %s' "$stage" "$(( (after - before) / 1000000 ))"
}

# The trace is a rolling list of "|+Nms name" entries: the plugin's own view of the order
# things happened in, which is what the latency promise is about.
trace_entries() {
  state | jq -r '.traceLog' | tr '|' '\n' | grep -v '^$'
}

trace_names() { trace_entries | sed 's/^+[0-9]*ms //'; }

# Milliseconds the plugin itself spent between finishing the capture and putting the card
# up. An inline re-compress at this level costs about 1.5 s for a full screen, so it would
# be unmistakable here — this is the check to watch if the gate in front of the pass moves.
card_delta_ms() {
  trace_entries | awk '/^\+[0-9]+ms stage:result$/{d=$1} END{gsub(/[^0-9]/, "", d); print (d == "" ? 9999 : d)}'
}

size_of() { stat -c '%s' "$1" 2>/dev/null || echo 0; }

# What the capture would have written for this same image at level 1 — the baseline the pass
# has to beat. Re-encoding the file that is there at level 1 gives exactly that, on the
# machine that is being tested, for whatever was on screen.
level1_reference() { # file out_path
  magick "$1" -define png:compression-level=1 "$2" 2>/dev/null || cp "$1" "$2" 2>/dev/null
  size_of "$2"
}

wait_for_queue_to_drain() { # timeout_tenths
  for _ in $(seq 1 "$1"); do
    if [[ $(state | jq -r '.optimizing') == "false" && $(state | jq -r '.optimizeQueued') == "0" ]]; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

wait_for_shot_to_shrink() { # file smaller_than timeout_tenths
  local file="$1" limit="$2" tries="$3" size
  for _ in $(seq 1 "$tries"); do
    size=$(size_of "$file")
    ((size > 0 && size < limit)) && { printf '%s' "$size"; return 0; }
    sleep 0.25
  done
  printf '%s' "$(size_of "$file")"
  return 1
}

printf 'the card is up before the compressor is asked for anything\n'
set_setting optimizeShots 9
sleep 1.2
read -r STAGE MS < <(capture)
check "the card is up" "$STAGE" "result"
note "capture call to card on screen: ${MS} ms (most of it is grim reading 2880x1800)"
SHOT=$(state | jq -r '.currentFile')
BEFORE=$(size_of "$SHOT")
DIMS=$(identify -format '%m %wx%h' "$SHOT" 2>/dev/null || echo unknown)
note "as written: $((BEFORE / 1024)) KB, $DIMS, level 1"

DELTA=$(card_delta_ms)
note "the plugin's own time from shutter to card: ${DELTA} ms"
check "and it did not wait for a re-compress" "$((DELTA < 250))" "1"

check "the card is in the trace before any pass starts" \
  "$(trace_names | awk '/^stage:result/{r=NR} /optimize:start/{o=(o==0?NR:o)} END{print (r>0 && o>0 && o>r) ? "card-first" : "wrong-order"}')" \
  "card-first"

printf 'the pass runs at idle priority, so it cannot hold anything up\n'
NICENESS=""
for _ in $(seq 1 40); do
  PID=$(pgrep -f "snapmenu-capture.sh --optimize" 2>/dev/null | head -1)
  if [[ -n ${PID:-} ]]; then
    NICENESS=$(ps -o ni= -p "$PID" 2>/dev/null | tr -d ' ')
    [[ -n $NICENESS ]] && break
  fi
  sleep 0.1
done
if [[ -n $NICENESS ]]; then
  check "a running pass is niced to 19" "$NICENESS" "19"
  check "and it is one pass, not a pile of them" \
    "$(pgrep -fc "snapmenu-capture.sh --optimize" 2>/dev/null)" "1"
else
  note "the pass finished too fast to sample its priority"
fi

printf 'and the file it leaves is smaller, with the same pixels\n'
AFTER=$(wait_for_shot_to_shrink "$SHOT" "$BEFORE" 80) || true
REF=$(level1_reference "$SHOT" "$WORK/level1.png")
check "the shot got smaller" "$((AFTER < BEFORE && AFTER > 0))" "1"
check "and smaller than a level-1 copy of itself" "$((AFTER < REF))" "1"
note "$((BEFORE / 1024)) KB as captured -> $((AFTER / 1024)) KB re-compressed at 9"
note "the same encoder is worth $((REF / 1024)) KB on this image at level 1, so the pass beat it"
check "with the same pixels in it" "$(identify -format '%m %wx%h' "$SHOT" 2>/dev/null)" "$DIMS"
check "under the name the card and the clipboard point at" \
  "$(basename "$SHOT")" "$(basename "$(state | jq -r '.currentFile')")"
check "and nothing was left beside it" "$(ls -A "$WORK/shots" | wc -l)" "1"
check "no pass is still running" "$(state | jq -r '.optimizing')" "false"

printf 'two shots in a row are both dealt with\n'
read -r STAGE _ < <(capture)
FIRST=$(state | jq -r '.currentFile')
read -r STAGE _ < <(capture)
SECOND=$(state | jq -r '.currentFile')
check "both shots are queued or running" \
  "$( [[ $(state | jq -r '.optimizing') == "true" || $(state | jq -r '.optimizeQueued') -gt 0 ]] && echo busy || echo idle )" \
  "busy"
wait_for_queue_to_drain 80 || note "the queue did not drain in twenty seconds"
check "neither pass is still running" "$(state | jq -r '.optimizing')" "false"
check "and nothing is left in the queue" "$(state | jq -r '.optimizeQueued')" "0"
# Both files, each against a level-1 copy of itself: a size the pass must have beaten.
FIRST_AFTER=$(wait_for_shot_to_shrink "$FIRST" "$(level1_reference "$FIRST" "$WORK/ref-1.png")" 40) || true
SECOND_AFTER=$(wait_for_shot_to_shrink "$SECOND" "$(level1_reference "$SECOND" "$WORK/ref-2.png")" 40) || true
check "the first shot was re-compressed" "$((FIRST_AFTER < $(level1_reference "$FIRST" "$WORK/ref-1b.png")))" "1"
check "and so was the second" "$((SECOND_AFTER < $(level1_reference "$SECOND" "$WORK/ref-2b.png")))" "1"

printf 'turning it off leaves the file exactly as the capture wrote it\n'
set_setting optimizeShots 0
sleep 1.2
STARTS_BEFORE=$(trace_names | grep -c 'optimize:start')
read -r STAGE _ < <(capture)
OFF_SHOT=$(state | jq -r '.currentFile')
OFF_SIZE=$(size_of "$OFF_SHOT")
sleep 3
check "nothing re-compressed it" "$(size_of "$OFF_SHOT")" "$OFF_SIZE"
check "and no pass was started for it" \
  "$(( $(trace_names | grep -c 'optimize:start') <= STARTS_BEFORE ))" "1"
check "the row says so" \
  "$(omarchy-shell shell call "$PLUGIN_ID" debugState '' | jq -r '.optimizeLevel')" "0"

printf '\n  optimize: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
