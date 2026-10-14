#!/usr/bin/env bash
# Hermetic tests for bin/snapmenu-capture.sh.
#
# Nothing here touches the real screen, the real state directory or the real
# tools: every external command is a stub in a temp directory, wired up through
# the SNAPMENU_* overrides, and every assertion is made against the one JSON
# line the helper promises its caller.
#
#   bash tests/capture.test.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/snapmenu-capture.sh"
PASS=0
FAIL=0
CASE=""
CALLS=""
FIXTURES=""
ROOT=""

# ------------------------------------------------------------------ reporting

pass() { PASS=$((PASS + 1)); }
fail() {
  FAIL=$((FAIL + 1))
  printf '    x %s\n' "$1"
}

assert_eq() { # what actual expected
  if [[ $2 == "$3" ]]; then pass; else fail "$1: expected '$3', got '$2'"; fi
}

assert_contains() { # what haystack needle
  if [[ $2 == *"$3"* ]]; then pass; else fail "$1: '$3' not found in '$2'"; fi
}

assert_file_exists() {
  if [[ -e $2 ]]; then pass; else fail "$1: $2 does not exist"; fi
}

assert_file_missing() {
  if [[ ! -e $2 ]]; then pass; else fail "$1: $2 still exists"; fi
}

jq_str() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }

# --------------------------------------------------------------------- stubs

new_case() { # name
  ROOT=$(mktemp -d)
  CASE="$ROOT/case"
  CALLS="$ROOT/calls"
  FIXTURES="$ROOT/fixtures"
  mkdir -p "$CASE/bin" "$CALLS" "$FIXTURES" "$CASE/state" "$CASE/out"
  printf 'case: %s\n' "$1"
}

# Records every invocation as one line of "$@" in $CALLS/<tool>.log
stub_recorder() { # tool extra-body
  local tool="$1" extra="${2:-}"
  cat >"$CASE/bin/$tool" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS/$tool.log"
$extra
EOF
  chmod +x "$CASE/bin/$tool"
}

write_monitor_fixture() { # scale
  cat >"$FIXTURES/monitors.json" <<EOF
[{"name":"eDP-1","x":0,"y":0,"width":2880,"height":1800,"scale":$1,"focused":true,
  "activeWorkspace":{"id":1}}]
EOF
}

write_client_fixture() {
  cat >"$FIXTURES/clients.json" <<'EOF'
[{"title":"Editor","class":"com.mitchellh.ghostty","hidden":false,"workspace":{"id":1},
  "at":[12,38],"size":[881,531]},
 {"title":"Browser","class":"chromium","hidden":false,"workspace":{"id":1},
  "at":[907,38],"size":[881,1075]},
 {"title":"Hidden","class":"x","hidden":true,"workspace":{"id":1},"at":[0,0],"size":[10,10]},
 {"title":"Other workspace","class":"y","hidden":false,"workspace":{"id":9},
  "at":[0,0],"size":[10,10]}]
EOF
}

# grim: records argv, writes the output file (last argument)
stub_grim() {
  stub_recorder grim 'out="${!#}"
# "-" means stdout, which is how the settle probe reads a frame: writing it to a file
# named - is how a stray "-" ended up committed in the repository root once.
if [[ $out == "-" ]]; then printf "PNG"; exit 0; fi
mkdir -p "$(dirname "$out")"; printf "PNG" >"$out"'
}

# magick/convert: records argv, writes the output file (last argument)
stub_magick() { # tool
  stub_recorder "$1" 'out="${!#}"
if [[ $out == "-" ]]; then printf "CROPPED"; exit 0; fi
mkdir -p "$(dirname "$out")"; printf "CROPPED" >"$out"'
}

# magick for the optimize pass: records argv, then runs whatever the case asks for — a
# smaller file, a bigger one, or deleting the input first (a shot deleted mid-pass).
stub_magick_optimize() { # body
  stub_recorder magick "out=\"\${!#}\"
$1"
}

# vips crop <in> <out> <left> <top> <width> <height>: the output is the third
# argument, so it needs a stub of its own rather than stub_recorder.
stub_vips() {
  cat >"$CASE/bin/vips" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS/vips.log"
out="\$3"
mkdir -p "\$(dirname "\$out")"
printf "CROPPED" >"\$out"
EOF
  chmod +x "$CASE/bin/vips"
}

# hyprctl: answers monitors/clients/layers/getoption from fixtures and files
stub_hyprctl() { # layers_calls_before_gone (0 = never seen)
  cat >"$CASE/bin/hyprctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS/hyprctl.log"
case "\${1:-}" in
  monitors) cat "$FIXTURES/monitors.json" ;;
  clients) cat "$FIXTURES/clients.json" ;;
  getoption) printf '{"int":1}\n' ;;
  layers)
    count_file="$CALLS/layers.count"
    count=0
    [[ -f \$count_file ]] && count=\$(cat \$count_file)
    count=\$((count + 1))
    printf '%s' "\$count" >\$count_file
    # The real output is text, with the namespace followed by ", pid:", so the
    # stub has to keep that shape or it would not exercise the caller's match.
    printf 'Monitor eDP-1:\n'
    printf '\tLayer level 2 (top):\n'
    printf '\t\tLayer 1: xywh: 0 0 1800 26, a: 1, namespace: omarchy-bar, pid: 1\n'
    if (( count <= ${1:-0} )); then
      printf '\tLayer level 3 (overlay):\n'
      printf '\t\tLayer 2: xywh: 0 0 1800 1125, a: 1, namespace: snapmenu, pid: 1\n'
    fi
    ;;
  *) printf '{}\n' ;;
esac
EOF
  chmod +x "$CASE/bin/hyprctl"
}

# wl-paste: types on --list-types (one per line, like the real tool), payload on --type
stub_wl_paste() { # types payload_file
  cat >"$CASE/bin/wl-paste" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS/wl-paste.log"
if [[ \${1:-} == --list-types ]]; then
  for type in $1; do printf '%s\n' "\$type"; done
  exit 0
fi
cat "$2"
EOF
  chmod +x "$CASE/bin/wl-paste"
}

stub_gio() { # exit_code
  cat >"$CASE/bin/gio" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS/gio.log"
exit $1
EOF
  chmod +x "$CASE/bin/gio"
}

stub_rm() { # exit_code
  cat >"$CASE/bin/rm" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS/rm.log"
exit $1
EOF
  chmod +x "$CASE/bin/rm"
}

# The helper runs with every tool override pointing at $CASE/bin and the state
# directory inside the case, so it cannot touch anything real.
run_capture() {
  env \
    SNAPMENU_GRIM="$CASE/bin/grim" \
    SNAPMENU_HYPRCTL="$CASE/bin/hyprctl" \
    SNAPMENU_WL_PASTE="$CASE/bin/wl-paste" \
    SNAPMENU_MAGICK="$CASE/bin/magick" \
    SNAPMENU_VIPS="$CASE/bin/vips" \
    SNAPMENU_CONVERT="$CASE/bin/convert" \
    SNAPMENU_FFMPEG="$CASE/bin/ffmpeg" \
    SNAPMENU_GIO="$CASE/bin/gio" \
    SNAPMENU_RM="$CASE/bin/rm" \
    SNAPMENU_STATE_DIR="$CASE/state" \
    bash "$SCRIPT" "$@"
}

# ---------------------------------------------------------------------- cases

case_freeze_reports_the_focused_monitor() {
  new_case "--freeze reports the focused monitor in logical coordinates"
  write_monitor_fixture 1.6
  stub_grim
  stub_hyprctl 0

  local json
  json=$(run_capture --freeze)

  assert_eq "ok" "$(jq_str "$json" '.ok')" "true"
  assert_eq "mode" "$(jq_str "$json" '.mode')" "freeze"
  assert_eq "logical width" "$(jq_str "$json" '.width')" "1800"
  assert_eq "logical height" "$(jq_str "$json" '.height')" "1125"
  assert_eq "scale" "$(jq_str "$json" '.monitor.scale')" "1.6"
  assert_eq "monitor name" "$(jq_str "$json" '.monitor.name')" "eDP-1"
  assert_contains "frame written under the state dir" \
    "$(jq_str "$json" '.path')" "$CASE/state/freeze/freeze-"
  assert_file_exists "frame file exists" "$(jq_str "$json" '.path')"
  assert_contains "pointer kept out of the frame" "$(cat "$CALLS/hyprctl.log")" "no_hardware_cursors = 0"
  # Only the monitor the picker is about: capturing every output makes the
  # freeze scale with the number of displays.
  assert_contains "freeze limits grim to the focused output" \
    "$(cat "$CALLS/grim.log")" "-o eDP-1"
}

case_cursor_is_left_out_by_default() {
  new_case "the pointer is kept out of the frame unless asked for"
  write_monitor_fixture 1
  stub_grim
  stub_hyprctl 0

  run_capture --mode fullscreen --dir "$CASE/out" >/dev/null
  # Hardware cursors are the ones wlr-screencopy does not composite in, so this
  # is what keeps the pointer out of the shot.
  assert_contains "hardware cursors forced on" "$(cat "$CALLS/hyprctl.log")" "no_hardware_cursors = 0"

  new_case "--cursor puts the pointer in the frame"
  write_monitor_fixture 1
  stub_grim
  stub_hyprctl 0
  run_capture --mode fullscreen --dir "$CASE/out" --cursor >/dev/null
  # Software cursors are drawn into the scene, which is how the pointer ends up
  # in the captured frame.
  assert_contains "software cursors asked for" "$(cat "$CALLS/hyprctl.log")" "no_hardware_cursors = 1"
}

case_no_anim_turns_off_the_layer_fade() {
  new_case "--no-anim stops our surfaces fading out"
  stub_hyprctl 0
  stub_grim

  local json
  json=$(run_capture --no-anim)
  assert_eq "ok" "$(jq_str "$json" '.ok')" "true"
  assert_eq "rule applied" "$(jq_str "$json" '.noAnim')" "true"
  # The card is drawn by a layer surface, and Omarchy fades layers out: without
  # this rule the compositor can still be drawing the card when the frame is
  # taken, which is the ghost the picker used to show.
  assert_contains "lua api used" "$(cat "$CALLS/hyprctl.log")" "hl.layer_rule"
  assert_contains "our namespace named" "$(cat "$CALLS/hyprctl.log")" "snapmenu"
  assert_contains "animation off" "$(cat "$CALLS/hyprctl.log")" "no_anim"
}

case_no_anim_falls_back_to_the_keyword() {
  new_case "--no-anim falls back to the legacy layerrule keyword"
  cat >"$CASE/bin/hyprctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS/hyprctl.log"
if [[ \${1:-} == eval ]]; then printf 'not a lua config\n'; exit 1; fi
exit 0
EOF
  chmod +x "$CASE/bin/hyprctl"

  local json
  json=$(run_capture --no-anim)
  assert_contains "eval tried first" "$(cat "$CALLS/hyprctl.log")" "hl.layer_rule"
  assert_contains "keyword used as the fallback" "$(cat "$CALLS/hyprctl.log")" "keyword layerrule"
}

case_freeze_settles_before_capturing() {
  new_case "--freeze probes the screen until it stops changing"
  write_monitor_fixture 1
  stub_grim
  stub_hyprctl 0

  run_capture --freeze >/dev/null
  # At least two probe captures of the middle of the screen, then the frame.
  local probes
  probes=$(grep -c -- '-g .* 96x96 -$' "$CALLS/grim.log")
  if ((probes >= 2)); then pass; else fail "expected 2+ settle probes, saw $probes"; fi
  assert_contains "and then the frame itself" "$(cat "$CALLS/grim.log")" "freeze/"
  # The freeze asks for a cheaply compressed PNG: the default level costs ~100ms per
  # capture, and level 1 keeps the file at 1.4MB rather than the 15MB of level 0.
  assert_contains "at the cheap compression level" "$(cat "$CALLS/grim.log")" "-l 1"
  assert_contains "with the level configurable" \
    "$(grep -c 'SNAPMENU_PNG_LEVEL' "$SCRIPT" || true)" "1"
}

case_freeze_settles_on_the_rectangle_it_is_given() {
  new_case "--freeze probes the rectangle the caller names, not the middle"
  write_monitor_fixture 1
  stub_grim
  stub_hyprctl 0

  run_capture --freeze --settle-area "1700,40 600x790" >/dev/null
  # The middle never changes when the fading thing is a bar popout in a corner, so
  # a caller that knows where its surface was says so and the probe looks there.
  assert_contains "probed the named rectangle" "$(cat "$CALLS/grim.log")" "-g 1700,40 600x790"
  local middle
  middle=$(grep -c -- '-g [0-9]*,514 96x96 -$' "$CALLS/grim.log" || true)
  assert_eq "and not the middle of the screen" "${middle:-0}" "0"
}

case_freeze_reports_whether_cropping_is_exact() {
  new_case "--freeze says whether a cropper is installed"
  write_monitor_fixture 1
  stub_grim
  stub_hyprctl 0
  stub_magick magick

  local json
  json=$(run_capture --freeze)
  assert_eq "cropper available" "$(jq_str "$json" '.cropper')" "true"

  new_case "--freeze without a cropper"
  write_monitor_fixture 1
  stub_grim
  stub_hyprctl 0
  : >"$CASE/bin/convert"
  : >"$CASE/bin/ffmpeg"
  rm -f "$CASE/bin/magick" "$CASE/bin/vips"
  json=$(run_capture --freeze)
  assert_eq "no cropper" "$(jq_str "$json" '.cropper')" "false"
}

case_freeze_waits_for_the_overlay_to_unmap() {
  new_case "--freeze waits until the shell's own layer is gone"
  write_monitor_fixture 1
  stub_grim
  stub_hyprctl 3 # snapmenu layer present for the first three queries

  run_capture --freeze >/dev/null
  local queries
  queries=$(wc -l <"$CALLS/hyprctl.log")
  if ((queries >= 4)); then pass; else fail "expected at least 4 hyprctl calls, got $queries"; fi
  assert_file_exists "grim still ran" "$CALLS/grim.log"
}

case_freeze_keeps_only_the_newest_frame() {
  new_case "--freeze clears older frames"
  write_monitor_fixture 1
  stub_grim
  stub_hyprctl 0
  mkdir -p "$CASE/state/freeze"
  : >"$CASE/state/freeze/freeze-2020-01-01_00-00-00.png"
  : >"$CASE/state/freeze/freeze-2020-01-02_00-00-00.png"

  run_capture --freeze >/dev/null
  assert_file_missing "old frame 1 removed" "$CASE/state/freeze/freeze-2020-01-01_00-00-00.png"
  assert_file_missing "old frame 2 removed" "$CASE/state/freeze/freeze-2020-01-02_00-00-00.png"
  local count
  count=$(find "$CASE/state/freeze" -name 'freeze-*.png' | wc -l)
  assert_eq "one frame left" "$count" "1"
}

case_crop_converts_logical_geometry_to_pixels() {
  new_case "--crop hands the cropper physical pixels"
  printf 'PNG' >"$CASE/state/freeze.png"
  stub_magick magick
  stub_grim

  local json
  json=$(run_capture --crop "100,100 300x200" --freeze-file "$CASE/state/freeze.png" \
    --scale 1.6 --dir "$CASE/out" --mode region)

  assert_eq "ok" "$(jq_str "$json" '.ok')" "true"
  assert_eq "reported width" "$(jq_str "$json" '.width')" "480"
  assert_eq "reported height" "$(jq_str "$json" '.height')" "320"
  assert_eq "mode" "$(jq_str "$json" '.mode')" "region"
  assert_contains "crop geometry" "$(cat "$CALLS/magick.log")" "-crop 480x320+160+160"
  assert_file_missing "grim not needed when a cropper exists" "$CALLS/grim.log"
  assert_eq "last region remembered" "$(cat "$CASE/state/last-region")" "100,100 300x200"
  assert_eq "last shot remembered" "$(cat "$CASE/state/last-shot")" "$(jq_str "$json" '.path')"
}

case_freeze_skips_the_settle_probe_when_asked() {
  new_case "--freeze skips the settle probe when the caller turned the fade off"
  write_monitor_fixture 1
  stub_grim
  stub_hyprctl 0

  run_capture --freeze --no-settle >/dev/null
  # One grim call for the frame; the probe would have added two more.
  assert_eq "no probing screenshots" "$(grep -c . "$CALLS/grim.log" 2>/dev/null || echo 0)" "1"

  new_case "--freeze still probes when the fade rule may not be in place"
  write_monitor_fixture 1
  stub_grim
  stub_hyprctl 0
  run_capture --freeze >/dev/null
  assert_eq "probes the screen" "$(grep -c . "$CALLS/grim.log" 2>/dev/null || echo 0)" "3"
}

case_direct_captures_wait_for_the_menu_to_go() {
  new_case "--mode previous waits for the menu before it shoots"
  write_monitor_fixture 1
  printf '100,100 300x200\n' >"$CASE/state/last-region"
  stub_grim
  stub_hyprctl 3 # the snapmenu layer is present for the first three queries

  run_capture --mode previous >/dev/null

  # The menu the row was chosen from is still unmapping: without the wait, grim
  # photographs it and the menu ends up in the picture.
  local queries
  queries=$(wc -l <"$CALLS/hyprctl.log")
  if ((queries >= 4)); then pass; else fail "expected the layer to be waited on, saw $queries hyprctl calls"; fi
  assert_file_exists "grim still ran" "$CALLS/grim.log"

  new_case "--mode previous probes the popout's rectangle when it is given one"
  write_monitor_fixture 1
  printf '100,100 300x200
' >"$CASE/state/last-region"   # previous needs one to repeat
  stub_grim
  stub_hyprctl 0

  run_capture --mode previous --settle-area "1042,31 370x484" >/dev/null

  # A capture started from the bar dropdown has Omarchy's own full-screen layer
  # fading behind it, which watching our own namespace does not cover.
  local probes
  probes=$(grep -c -- '-g 1042,31 370x484 -$' "$CALLS/grim.log")
  if ((probes >= 2)); then pass; else fail "expected the popout rectangle to be probed, saw $probes"; fi
}

case_state_and_shots_are_owner_only() {
  new_case "state dirs and captures are readable by the owner only"
  write_monitor_fixture 1
  stub_grim
  stub_hyprctl 0

  # A tree left behind by an older, looser run must be corrected on the way in.
  mkdir -p "$CASE/state/freeze" "$CASE/state/tmp"
  chmod 755 "$CASE/state" "$CASE/state/freeze" "$CASE/state/tmp"

  local json frame shot
  json=$(run_capture --freeze)
  frame=$(jq_str "$json" '.path')
  assert_eq "state dir corrected to 700" "$(stat -c '%a' "$CASE/state")" "700"
  assert_eq "freeze dir corrected to 700" "$(stat -c '%a' "$CASE/state/freeze")" "700"
  assert_eq "frame file is 600" "$(stat -c '%a' "$frame")" "600"

  json=$(run_capture --crop "100,100 300x200" --freeze-file "$frame" \
    --dir "$CASE/out" --mode region)
  shot=$(jq_str "$json" '.path')
  assert_eq "shot file is 600" "$(stat -c '%a' "$shot")" "600"
  assert_eq "last-region is 600" "$(stat -c '%a' "$CASE/state/last-region")" "600"
  assert_eq "last-shot is 600" "$(stat -c '%a' "$CASE/state/last-shot")" "600"
}

case_freeze_reports_no_monitor() {
  new_case "--freeze with no focused monitor is a failure, not a 0x0 screen"
  printf '[]' >"$FIXTURES/monitors.json"   # hyprctl answered, with nothing focused
  stub_grim
  stub_hyprctl 0

  local json
  json=$(run_capture --freeze)

  # Without an output grim writes every monitor into one frame, and the overlay
  # would treat it as the focused one and crop the wrong pixels.
  assert_eq "ok" "$(jq_str "$json" '.ok')" "false"
  assert_eq "reason" "$(jq_str "$json" '.reason')" "no-monitor"
  assert_file_missing "nothing was frozen" "$CALLS/grim.log"
}

case_output_dir_can_be_overridden() {
  new_case "--dir is used when given, SNAPMENU_DIR when not"
  write_monitor_fixture 1
  stub_grim
  stub_hyprctl 0

  local json
  json=$(SNAPMENU_DIR="$CASE/override" run_capture --mode fullscreen)

  assert_eq "ok" "$(jq_str "$json" '.ok')" "true"
  assert_contains "the shot landed in the override" "$(jq_str "$json" '.path')" "$CASE/override/"
}

case_temp_shots_do_not_pile_up() {
  new_case "temp shots do not pile up in the state directory"
  write_monitor_fixture 1
  stub_grim
  stub_hyprctl 0

  # Eight discarded shots, one after another. The freeze dir is pruned; the temp dir
  # a temp shot lands in never was, so the state directory grew without bound.
  for _ in $(seq 1 8); do
    run_capture --mode fullscreen --temp >/dev/null
    sleep 0.05
  done
  # Pruning runs before the write, so the steady state is the cap plus the new shot.
  local left
  left=$(find "$CASE/state/tmp" -name '*.png' 2>/dev/null | wc -l)
  if ((left <= 6)); then pass; else fail "expected the temp dir to be pruned, saw $left files"; fi

  # And it plateaus: more discarded shots must not keep growing it.
  for _ in $(seq 1 4); do
    run_capture --mode fullscreen --temp >/dev/null
    sleep 0.05
  done
  left=$(find "$CASE/state/tmp" -name '*.png' 2>/dev/null | wc -l)
  if ((left <= 6)); then pass; else fail "the temp dir keeps growing: $left files"; fi
}

case_reported_size_is_the_file_size() {
  new_case "the reported size is the file's, not the one that was asked for"
  write_monitor_fixture 1
  # A real 7x3 PNG, so the size can be read back from the header rather than assumed.
  cat >"$CASE/bin/grim" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\$CALLS/grim.log"
out="\${!#}"
mkdir -p "\$(dirname "\$out")"
printf '%s' '$(printf '%s' "iVBORw0KGgoAAAANSUhEUgAAAAcAAAADAQMAAABlDYeGAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAADUExURQAA/4p40lcAAAAHdElNRQfqCg0LOAYxeKQXAAAAJXRFWHRkYXRlOmNyZWF0ZQAyMDI2LTEwLTEzVDExOjU2OjA2")' | base64 -d >"\$out"
EOF
  chmod +x "$CASE/bin/grim"
  stub_hyprctl 0

  local json
  json=$(run_capture --mode fullscreen)

  assert_eq "ok" "$(jq_str "$json" '.ok')" "true"
  assert_eq "width is the file's" "$(jq_str "$json" '.width')" "7"
  assert_eq "height is the file's" "$(jq_str "$json" '.height')" "3"
}

case_crop_says_where_it_came_from() {
  new_case "a crop says whether it came from the frame file or the screen"
  printf 'PNG' >"$CASE/state/freeze.png"
  stub_magick magick

  local json
  json=$(run_capture --crop "10,20 30x40" --freeze-file "$CASE/state/freeze.png" \
    --dir "$CASE/out" --mode region)
  assert_eq "from the frame file" "$(jq_str "$json" '.source')" "file"

  new_case "and says so when the cropper could not do it"
  printf 'PNG' >"$CASE/state/freeze.png"
  stub_grim
  stub_hyprctl 0
  rm -f "$CASE/bin/magick" "$CASE/bin/convert" "$CASE/bin/ffmpeg"

  json=$(run_capture --crop "10,20 30x40" --freeze-file "$CASE/state/freeze.png" \
    --dir "$CASE/out" --mode region)
  # Read off the composited screen instead: slower, and only exact because the
  # picker hides its chrome first. The caller cannot tell unless it is told.
  assert_eq "from the screen" "$(jq_str "$json" '.source')" "screen"
}

case_no_stray_output_files() {
  new_case "a run leaves no file named - in the working directory"
  write_monitor_fixture 1
  stub_grim
  stub_hyprctl 0

  # The settle probe asks grim for stdout, and the stub used to treat that as a path.
  # The suite runs from the repository, so that file landed in it and was committed.
  run_capture --freeze >/dev/null

  assert_file_missing "no file named - was created" "./-"
}

case_crop_prefers_libvips() {
  new_case "--crop prefers libvips, which writes the same pixels in half the time"
  printf 'PNG' >"$CASE/state/freeze.png"
  stub_vips
  stub_magick magick
  stub_grim

  local json
  json=$(run_capture --crop "100,100 300x200" --freeze-file "$CASE/state/freeze.png" \
    --scale 1.6 --dir "$CASE/out" --mode region)

  assert_eq "ok" "$(jq_str "$json" '.ok')" "true"
  assert_eq "the pixels are the cropper's, not grim's" "$(cat "$(jq_str "$json" '.path')")" "CROPPED"
  # vips takes the rectangle as four numbers instead of one -crop argument.
  assert_contains "vips got the physical rectangle" "$(cat "$CALLS/vips.log")" \
    "crop $CASE/state/freeze.png $(jq_str "$json" '.path') 160 160 480 320"
  assert_file_missing "ImageMagick is not needed when libvips is there" "$CALLS/magick.log"
  assert_file_missing "and neither is grim" "$CALLS/grim.log"
}

case_crop_handles_negative_origins_and_scale_two() {
  new_case "--crop cuts the frame file in the monitor's own coordinates"
  printf 'PNG' >"$CASE/state/freeze.png"
  stub_magick magick

  # A monitor at -1920 with the selection at -1900: the file starts at the monitor,
  # so the cut belongs at (40, 80) after scaling, not at the global (-3800, 80).
  run_capture --crop "-1900,40 400x300" --origin "-1920,0" \
    --freeze-file "$CASE/state/freeze.png" \
    --scale 2 --dir "$CASE/out" >/dev/null

  assert_contains "the cut is monitor-local and scaled" "$(cat "$CALLS/magick.log")" \
    "-crop 800x600+40+80"

  new_case "and the grim read-back still uses the global rectangle"
  printf 'PNG' >"$CASE/state/freeze.png"
  stub_grim
  rm -f "$CASE/bin/magick" "$CASE/bin/convert" "$CASE/bin/ffmpeg"

  run_capture --crop "-1900,40 400x300" --origin "-1920,0" \
    --freeze-file "$CASE/state/freeze.png" \
    --scale 2 --dir "$CASE/out" >/dev/null

  # grim reads the composited screen, which is global.
  assert_contains "grim was given the global rectangle" "$(cat "$CALLS/grim.log")" \
    "-g -1900,40 400x300"
}

case_crop_falls_back_to_grim() {
  new_case "--crop falls back to grim on the composited frozen frame"
  printf 'PNG' >"$CASE/state/freeze.png"
  stub_grim
  stub_hyprctl 0
  stub_magick magick
  # No cropper available, and it must not be used even if present.
  rm -f "$CASE/bin/magick" "$CASE/bin/convert" "$CASE/bin/ffmpeg"

  local json
  json=$(run_capture --crop "10,20 30x40" --freeze-file "$CASE/state/freeze.png" \
    --scale 1 --dir "$CASE/out")
  assert_eq "ok" "$(jq_str "$json" '.ok')" "true"
  assert_contains "grim got the logical geometry" "$(cat "$CALLS/grim.log")" "-g 10,20 30x40"
  assert_contains "pointer forced out of the read-back" "$(cat "$CALLS/hyprctl.log")" "no_hardware_cursors = 0"
}

case_crop_rejects_a_degenerate_selection() {
  new_case "--crop reports a degenerate selection as cancelled"
  local json
  json=$(run_capture --crop "10,10 0x0" --dir "$CASE/out")
  assert_eq "ok" "$(jq_str "$json" '.ok')" "false"
  assert_eq "reason" "$(jq_str "$json" '.reason')" "cancelled"
}

case_crop_reports_an_unwritable_target() {
  new_case "--crop reports a directory it cannot create"
  printf 'PNG' >"$CASE/state/freeze.png"
  stub_magick magick
  printf 'not a directory' >"$CASE/blocked"

  local json
  json=$(run_capture --crop "1,1 10x10" --dir "$CASE/blocked/nested")
  assert_eq "reason" "$(jq_str "$json" '.reason')" "write-failed"
}

case_rects_lists_windows_with_labels() {
  new_case "--rects lists the monitor and its workspace's windows"
  write_monitor_fixture 1.6
  write_client_fixture
  stub_hyprctl 0

  local json
  json=$(run_capture --rects)
  assert_eq "ok" "$(jq_str "$json" '.ok')" "true"
  assert_eq "rect count" "$(jq_str "$json" '.rects | length')" "3"
  assert_eq "monitor first" "$(jq_str "$json" '.rects[0].kind')" "monitor"
  assert_eq "monitor logical width" "$(jq_str "$json" '.rects[0].width')" "1800"
  assert_eq "monitor label" "$(jq_str "$json" '.rects[0].label')" "Screen eDP-1"
  assert_eq "window label is its title" "$(jq_str "$json" '.rects[1].label')" "Editor"
  assert_eq "window geometry" "$(jq_str "$json" '.rects[1] | "\(.x),\(.y) \(.width)x\(.height)"')" \
    "12,38 881x531"
  assert_eq "hidden and other-workspace windows are excluded" \
    "$(jq_str "$json" '[.rects[] | select(.label == "Hidden" or .label == "Other workspace")] | length')" "0"
}

case_fullscreen_captures_the_focused_monitor() {
  new_case "--mode fullscreen captures the focused monitor"
  write_monitor_fixture 1.6
  stub_grim
  stub_hyprctl 0

  local json
  json=$(run_capture --mode fullscreen --dir "$CASE/out")
  assert_eq "ok" "$(jq_str "$json" '.ok')" "true"
  assert_eq "pixel width" "$(jq_str "$json" '.width')" "2880"
  assert_eq "pixel height" "$(jq_str "$json" '.height')" "1800"
  assert_contains "grim geometry is logical" "$(cat "$CALLS/grim.log")" "-g 0,0 1800x1125"
}

case_previous_needs_a_region_first() {
  new_case "--mode previous before any area capture"
  write_monitor_fixture 1
  stub_grim
  stub_hyprctl 0

  local json
  json=$(run_capture --mode previous --dir "$CASE/out")
  assert_eq "ok" "$(jq_str "$json" '.ok')" "false"
  assert_eq "reason" "$(jq_str "$json" '.reason')" "no-previous"

  printf '5,6 70x80\n' >"$CASE/state/last-region"
  json=$(run_capture --mode previous --dir "$CASE/out")
  assert_eq "ok after a region exists" "$(jq_str "$json" '.ok')" "true"
  assert_eq "reused width" "$(jq_str "$json" '.width')" "70"
  assert_contains "reused geometry" "$(cat "$CALLS/grim.log")" "-g 5,6 70x80"
}

case_clipboard_imports_an_image() {
  new_case "--from-clipboard writes the clipboard image out"
  printf 'IMAGEDATA' >"$FIXTURES/payload"
  stub_wl_paste "image/png image/jpeg" "$FIXTURES/payload"

  local json
  json=$(run_capture --from-clipboard --dir "$CASE/out")
  assert_eq "ok" "$(jq_str "$json" '.ok')" "true"
  assert_eq "mode" "$(jq_str "$json" '.mode')" "clipboard"
  assert_contains "png extension" "$(jq_str "$json" '.path')" "clipboard-"
  assert_contains "extension from mime" "$(jq_str "$json" '.path')" ".png"
  assert_eq "payload copied" "$(cat "$(jq_str "$json" '.path')")" "IMAGEDATA"
}

case_clipboard_prefers_png_and_reports_empty() {
  new_case "--from-clipboard without an image"
  stub_wl_paste "text/plain UTF8_STRING" "$FIXTURES/payload"
  local json
  json=$(run_capture --from-clipboard --dir "$CASE/out")
  assert_eq "reason" "$(jq_str "$json" '.reason')" "no-image"

  new_case "--from-clipboard with an empty payload"
  : >"$FIXTURES/empty"
  stub_wl_paste "image/png" "$FIXTURES/empty"
  json=$(run_capture --from-clipboard --dir "$CASE/out")
  assert_eq "reason" "$(jq_str "$json" '.reason')" "clipboard-failed"
}

case_delete_prefers_the_trash() {
  new_case "--delete trashes when it can, removes when it cannot"
  : >"$CASE/out/keep.png"
  stub_gio 0
  stub_rm 0
  local json
  json=$(run_capture --delete "$CASE/out/keep.png")
  assert_eq "ok" "$(jq_str "$json" '.ok')" "true"
  assert_eq "mode" "$(jq_str "$json" '.mode')" "trash"
  assert_file_missing "rm not used" "$CALLS/rm.log"

  new_case "--delete falls back to rm"
  : >"$CASE/out/keep.png"
  stub_gio 1
  stub_rm 0
  json=$(run_capture --delete "$CASE/out/keep.png")
  assert_eq "mode" "$(jq_str "$json" '.mode')" "delete"
  assert_file_exists "rm was used" "$CALLS/rm.log"

  new_case "--delete on a file that is already gone"
  stub_gio 0
  stub_rm 0
  json=$(run_capture --delete "$CASE/out/never-existed.png")
  assert_eq "ok" "$(jq_str "$json" '.ok')" "true"
  assert_eq "mode" "$(jq_str "$json" '.mode')" "missing"

  new_case "--delete when nothing can remove it"
  : >"$CASE/out/stuck.png"
  stub_gio 1
  stub_rm 1
  json=$(run_capture --delete "$CASE/out/stuck.png")
  assert_eq "ok" "$(jq_str "$json" '.ok')" "false"
  assert_eq "reason" "$(jq_str "$json" '.reason')" "delete-failed"
}

case_delete_can_skip_the_trash() {
  new_case "--permanently skips the trash"
  : >"$CASE/out/shot.png"
  stub_gio 0
  stub_rm 0

  local json
  json=$(run_capture --delete "$CASE/out/shot.png" --permanently)

  assert_eq "ok" "$(jq_str "$json" '.ok')" "true"
  assert_eq "mode" "$(jq_str "$json" '.mode')" "delete"
  # The fakes log rather than delete, so the log is the evidence: rm ran and the
  # trash was never asked, because that is the whole point of the flag.
  assert_file_missing "trash was not asked" "$CALLS/gio.log"
  assert_contains "rm did it" "$(cat "$CALLS/rm.log" 2>/dev/null)" "shot.png"
}

case_missing_tools_are_reported() {
  new_case "a missing grim is reported, not crashed on"
  write_monitor_fixture 1
  stub_hyprctl 0
  SNAPMENU_GRIM="$CASE/bin/absent" run_capture --mode fullscreen --dir "$CASE/out" >/dev/null
  local json
  json=$(SNAPMENU_GRIM="$CASE/bin/absent" run_capture --mode fullscreen --dir "$CASE/out")
  assert_eq "reason" "$(jq_str "$json" '.reason')" "grim-missing"
}

case_optimize_shrinks_the_shot_in_place() {
  new_case "--optimize re-compresses the shot the capture already wrote"
  printf 'a big fat png payload' >"$CASE/out/shot.png"
  stub_magick_optimize 'printf small >"$out"'

  local json
  json=$(run_capture --optimize "$CASE/out/shot.png" --level 5)

  assert_eq "ok" "$(jq_str "$json" '.ok')" "true"
  assert_eq "it saved something" "$(jq_str "$json" '.saved')" "true"
  assert_eq "the path is the one it was given" "$(jq_str "$json" '.path')" "$CASE/out/shot.png"
  assert_eq "before" "$(jq_str "$json" '.before')" "21"
  assert_eq "after" "$(jq_str "$json" '.after')" "5"
  assert_eq "the shot is now the smaller file" "$(cat "$CASE/out/shot.png")" "small"
  assert_contains "at the level it was given" "$(cat "$CALLS/magick.log")" \
    "png:compression-level=5"
  # The new file arrives by rename, and the name it is written under first is
  # dot-prefixed: the capture history is a listing of this folder, and a leftover
  # ".shot.png.opt.png" would turn up in it as a shot.
  assert_eq "and nothing else is left in the folder" "$(ls -A "$CASE/out" | wc -l)" "1"
}

case_optimize_keeps_the_shot_when_there_is_nothing_to_gain() {
  new_case "--optimize leaves a shot alone when the re-encode is no smaller"
  printf 'small' >"$CASE/out/shot.png"
  stub_magick_optimize 'printf "a much bigger payload" >"$out"'

  local json
  json=$(run_capture --optimize "$CASE/out/shot.png")

  assert_eq "ok" "$(jq_str "$json" '.ok')" "true"
  assert_eq "nothing to report" "$(jq_str "$json" '.saved')" "false"
  # Rewriting a file with a copy of itself would move its timestamp, and the history is
  # ordered by that.
  assert_eq "the shot is the one that was there" "$(cat "$CASE/out/shot.png")" "small"
  assert_eq "and the pass cleaned up after itself" "$(ls -A "$CASE/out" | wc -l)" "1"
}

case_optimize_does_not_rename_a_deleted_shot_back() {
  new_case "--optimize does not bring back a shot deleted while it ran"
  printf 'a big fat png payload' >"$CASE/out/shot.png"
  # Deleting a shot takes a moment, and the pass takes longer than that. The replacement
  # is smaller, so only the deleted file can stop it being renamed into place.
  stub_magick_optimize 'rm -f -- "$1"; printf tiny >"$out"'

  local json
  json=$(run_capture --optimize "$CASE/out/shot.png")

  assert_eq "not ok" "$(jq_str "$json" '.ok')" "false"
  assert_eq "and it says the shot went" "$(jq_str "$json" '.reason')" "gone"
  assert_file_missing "the shot is still deleted" "$CASE/out/shot.png"
  assert_eq "and the smaller copy goes with it" "$(ls -A "$CASE/out" | wc -l)" "0"
}

case_optimize_without_imagemagick() {
  new_case "--optimize is a no-op without ImageMagick, not a failure"
  printf 'shot' >"$CASE/out/shot.png"

  local json
  json=$(run_capture --optimize "$CASE/out/shot.png")

  # run_capture points SNAPMENU_MAGICK at the case's own stub directory, and this case
  # deliberately does not put one there.
  assert_eq "ok" "$(jq_str "$json" '.ok')" "true"
  assert_eq "nothing was saved" "$(jq_str "$json" '.saved')" "false"
  assert_eq "and the shot is untouched" "$(cat "$CASE/out/shot.png")" "shot"
}

case_optimize_reports_a_file_that_is_not_there() {
  new_case "--optimize on a shot that is not on disk"
  local json
  json=$(run_capture --optimize "$CASE/out/nothing.png")
  assert_eq "not ok" "$(jq_str "$json" '.ok')" "false"
  assert_eq "and it says why" "$(jq_str "$json" '.reason')" "no-file"
}

case_unknown_requests_are_refused() {
  new_case "an unknown request is refused"
  local json
  json=$(run_capture)
  assert_eq "reason" "$(jq_str "$json" '.reason')" "no-request"

  json=$(run_capture --mode sideways)
  assert_eq "reason" "$(jq_str "$json" '.reason')" "unknown-mode:sideways"
}

# ----------------------------------------------------------------------- main

if [[ ! -f $SCRIPT ]]; then
  printf 'cannot find %s\n' "$SCRIPT" >&2
  exit 1
fi

case_freeze_reports_the_focused_monitor
case_freeze_reports_whether_cropping_is_exact
case_freeze_waits_for_the_overlay_to_unmap
case_freeze_settles_before_capturing
case_freeze_settles_on_the_rectangle_it_is_given
case_no_anim_turns_off_the_layer_fade
case_no_anim_falls_back_to_the_keyword
case_cursor_is_left_out_by_default
case_freeze_keeps_only_the_newest_frame
case_freeze_skips_the_settle_probe_when_asked
case_freeze_reports_no_monitor
case_state_and_shots_are_owner_only
case_no_stray_output_files
case_output_dir_can_be_overridden
case_temp_shots_do_not_pile_up
case_reported_size_is_the_file_size
case_crop_says_where_it_came_from
case_direct_captures_wait_for_the_menu_to_go
case_crop_prefers_libvips
case_crop_converts_logical_geometry_to_pixels
case_crop_handles_negative_origins_and_scale_two
case_crop_falls_back_to_grim
case_crop_rejects_a_degenerate_selection
case_crop_reports_an_unwritable_target
case_rects_lists_windows_with_labels
case_fullscreen_captures_the_focused_monitor
case_previous_needs_a_region_first
case_clipboard_imports_an_image
case_clipboard_prefers_png_and_reports_empty
case_delete_prefers_the_trash
case_delete_can_skip_the_trash
case_missing_tools_are_reported
case_optimize_shrinks_the_shot_in_place
case_optimize_keeps_the_shot_when_there_is_nothing_to_gain
case_optimize_does_not_rename_a_deleted_shot_back
case_optimize_without_imagemagick
case_optimize_reports_a_file_that_is_not_there
case_unknown_requests_are_refused

printf '\n  capture helper: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
