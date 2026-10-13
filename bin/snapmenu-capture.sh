#!/bin/bash
# snapmenu-capture.sh — take one screenshot and report it as a single JSON line.
#
#   snapmenu-capture.sh --freeze [--tmp]            freeze one monitor to a PNG
#   snapmenu-capture.sh --crop "X,Y WxH"            crop the on-screen frozen frame
#   snapmenu-capture.sh --rects                     window/monitor rects for snapping
#   snapmenu-capture.sh --mode fullscreen|previous  direct captures
#   snapmenu-capture.sh --from-clipboard            clipboard image -> file
#   snapmenu-capture.sh --delete <path>             trash (or remove) a shot
#
# Always exits 0: the caller is a long-lived shell process that has to tell a
# cancelled pick apart from a failure, and "no output" cannot say which. The
# JSON line does:
#   {"ok":true,"path":"/…/screenshot.png","width":1600,"height":900,"mode":"region","temporary":false}
#   {"ok":false,"reason":"no-previous"}
#
# Region selection is NOT done here. The shell overlay displays the frozen frame
# returned by --freeze, drags its own selection, and calls --crop while that
# frame is still on screen; grim then captures the composited output, which is
# the frozen frame pixel for pixel. That keeps the picker out of slurp and
# hyprpicker entirely — no freeze process to leak, no input grab to lose — and
# needs no image tool: grim is the only cropper.

set -o pipefail

OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"

# Tools are absolute by default so an inherited PATH cannot stand in for them.
# The SNAPMENU_* overrides exist for tests (see tests/capture.test.sh), which
# point them at stubs; nothing in normal use sets them.
GRIM="${SNAPMENU_GRIM:-/usr/bin/grim}"
# PNG compression level for the freeze frame. Measured on a 2880x1800 display, grim
# spends 0.22s at the default level (6), 0.12s at level 1 and 0.06s at level 0 — and a
# less-compressed PNG also decodes faster, which is the other end of the same wait.
# Level 1 is the balance: 60ms slower than none, for 1.4MB instead of 15MB written and
# read on every capture. Pixels are identical at any level.
PNG_LEVEL="${SNAPMENU_PNG_LEVEL:-1}"
HYPRCTL="${SNAPMENU_HYPRCTL:-/usr/bin/hyprctl}"
WL_PASTE="${SNAPMENU_WL_PASTE:-/usr/bin/wl-paste}"
MAGICK="${SNAPMENU_MAGICK:-/usr/bin/magick}"
VIPS="${SNAPMENU_VIPS:-/usr/bin/vips}"
CONVERT="${SNAPMENU_CONVERT:-/usr/bin/convert}"
FFMPEG="${SNAPMENU_FFMPEG:-/usr/bin/ffmpeg}"
GIO="${SNAPMENU_GIO:-/usr/bin/gio}"
RM="${SNAPMENU_RM:-/usr/bin/rm}"

# Scratch space (freeze frames, last region, last shot). Overridable so a test
# never touches the real one.
STATE_DIR="${SNAPMENU_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/snapmenu}"
FREEZE_DIR="$STATE_DIR/freeze"
LAST_REGION="$STATE_DIR/last-region"
LAST_SHOT="$STATE_DIR/last-shot"

MODE=""
CROP=""
DELETE=""
FREEZE_FILE=""
OUT_DIR=""
FROM_CLIPBOARD=0
TEMP=0
WANT_FREEZE=0
WANT_RECTS=0
WANT_NO_ANIM=0
WANT_NO_SETTLE=0
PERMANENT=0
SETTLE_AREA=""
MONITOR_ORIGIN="0,0"
WANT_CURSOR=0
SCALE=""

while (($# > 0)); do
  case "$1" in
  --mode)
    MODE="${2:-}"
    shift 2
    ;;
  --crop)
    CROP="${2:-}"
    shift 2
    ;;
  --freeze-file)
    FREEZE_FILE="${2:-}"
    shift 2
    ;;
  --delete)
    DELETE="${2:-}"
    shift 2
    ;;
  --dir)
    OUT_DIR="${2:-}"
    shift 2
    ;;
  --scale)
    SCALE="${2:-}"
    shift 2
    ;;
  --from-clipboard)
    FROM_CLIPBOARD=1
    shift
    ;;
  --temp | --tmp)
    TEMP=1
    shift
    ;;
  --freeze)
    WANT_FREEZE=1
    shift
    ;;
  --rects)
    WANT_RECTS=1
    shift
    ;;
  --no-anim)
    WANT_NO_ANIM=1
    shift
    ;;
  --origin)
    # The frozen monitor's own top-left, in global coordinates. A selection is global,
    # but the frame file it is cropped from starts at the monitor, so the file crop
    # subtracts this. The grim read-back below still wants the global rectangle.
    # Kept as text: the geometry helpers are defined below this loop, so parsing it
    # here silently produced an empty value and a wrong cut.
    MONITOR_ORIGIN="${2:-0,0}"
    shift 2
    ;;
  --settle-area)
    # "X,Y WxH": the rectangle to watch for movement before freezing, for a caller
    # whose fading surface is not in the middle of the screen.
    SETTLE_AREA="${2:-}"
    shift 2
    ;;
  --permanently)
    # Skip the trash: the caller has asked for the file not to be recoverable.
    PERMANENT=1
    shift
    ;;
  --no-settle)
    # The caller has already turned the layer fade off, so nothing of ours can
    # still be drawn on screen and the probe below would be pure waiting.
    WANT_NO_SETTLE=1
    shift
    ;;
  --cursor)
    WANT_CURSOR=1
    shift
    ;;

  -h | --help)
    sed -n '2,16p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    shift
    ;;
  esac
done

emit_ok() { # path width height mode temporary source
  jq -cn --arg p "$1" --argjson w "${2:-0}" --argjson h "${3:-0}" --arg m "$4" \
    --argjson t "${5:-0}" --arg s "${6:-}" \
    '{ok:true,path:$p,width:$w,height:$h,mode:$m,temporary:($t==1),source:$s}'
}

# The size of the file that was actually written, not the one that was asked for: a
# cropper can clip, a scale can round, and the grim fallback reads the screen. The
# PNG header carries the truth in its IHDR, at bytes 16..24, big-endian.
png_size() { # file -> "W H", nothing when it is not a PNG
  local bytes width height
  bytes=$(od -An -tu1 -j16 -N8 -- "$1" 2>/dev/null) || return 0
  # shellcheck disable=SC2086
  set -- $bytes
  [[ $# -eq 8 ]] || return 0
  width=$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))
  height=$(( $5 * 16777216 + $6 * 65536 + $7 * 256 + $8 ))
  ((width > 0 && height > 0)) || return 0
  printf '%s %s' "$width" "$height"
}

reported_size() { # file fallback_width fallback_height
  local size
  size=$(png_size "$1")
  if [[ -n $size ]]; then printf '%s' "$size"; else printf '%s %s' "$2" "$3"; fi
}

# Discarded shots live in their own directory, and nothing prunes it today.
prune_tmp() {
  local dir
  dir=$(temp_dir)
  [[ -d $dir ]] || return 0
  ls -t "$dir"/*.png 2>/dev/null | tail -n +6 | while read -r old; do
    rm -f -- "$old" 2>/dev/null
  done
  return 0
}

emit_fail() { jq -cn --arg r "$1" '{ok:false,reason:$r}'; }

# Only the paths that actually read pixels need grim; --delete, --rects and
# --from-clipboard must work on a box where it is missing.
require_grim() {
  [[ -x $GRIM ]] || {
    emit_fail grim-missing
    exit 0
  }
}

temp_dir() { printf '%s/tmp' "$STATE_DIR"; }

default_dir() {
  if [[ -n ${SNAPMENU_DIR:-} ]]; then
    printf '%s' "$SNAPMENU_DIR"
    return
  fi
  if [[ -n ${OMARCHY_SCREENSHOT_DIR:-} ]]; then
    printf '%s' "$OMARCHY_SCREENSHOT_DIR"
    return
  fi

  local pictures=""
  if [[ -f $HOME/.config/user-dirs.dirs ]]; then
    pictures=$(sed -n 's/^XDG_PICTURES_DIR="\(.*\)"$/\1/p' "$HOME/.config/user-dirs.dirs" | head -n1)
    pictures="${pictures/\$HOME/$HOME}"
  fi
  [[ -n $pictures ]] || pictures="$HOME/Pictures"
  printf '%s' "$pictures"
}

target_dir() {
  if ((TEMP)); then
    temp_dir
  elif [[ -n $OUT_DIR ]]; then
    printf '%s' "$OUT_DIR"
  else
    default_dir
  fi
}

unique_path() { # dir base ext
  local dir="$1" base="$2" ext="$3" candidate counter=1
  candidate="$dir/$base.$ext"
  while [[ -e $candidate ]]; do
    candidate="$dir/$base-$counter.$ext"
    counter=$((counter + 1))
  done
  printf '%s' "$candidate"
}

stamp() { date +'%Y-%m-%d_%H-%M-%S'; }

remember_shot() { # path
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s\n' "$1" >"$LAST_SHOT" 2>/dev/null
}

# "X,Y WxH" -> "W H" (0 0 when the geometry is not parseable)
geom_size() {
  local geometry="$1" size w h
  size="${geometry##* }"
  w="${size%%x*}"
  h="${size##*x}"
  [[ $w =~ ^[0-9]+$ && $h =~ ^[0-9]+$ ]] || {
    w=0
    h=0
  }
  printf '%s %s' "$w" "$h"
}

# "X,Y WxH" -> "X Y"
geom_origin() {
  local geometry="$1" origin
  origin="${geometry%% *}"
  printf '%s %s' "${origin%%,*}" "${origin#*,}"
}

scale_px() { # logical_pixels
  # %.0f, not "+ 0.5 then truncate": a monitor left of the origin has negative
  # coordinates, and adding half a pixel before a truncating conversion rounds
  # those the wrong way (-3799.5 -> -3799 instead of -3800).
  awk -v value="$1" -v scale="$(output_scale)" 'BEGIN { printf "%.0f", value * scale }'
}

# Hyprland reports monitor/global geometry in logical layout coordinates, while
# the physical pixel size comes from width/height and the output scale. Selections
# and grim both take logical geometry, but grim writes physical pixels, so the
# captured file's dimensions are the logical ones times the output scale.
JQ_MONITORS='
  def logical_w: (.width / .scale | floor);
  def logical_h: (.height / .scale | floor);
  def as_rect($kind):
    {kind: $kind, name: (.name // ""), label: ("Screen " + (.name // "")), x: .x, y: .y,
     width: logical_w, height: logical_h, scale: .scale, pixelWidth: .width, pixelHeight: .height};
'

focused_monitor_json() {
  "$HYPRCTL" monitors -j 2>/dev/null | jq -c "$JQ_MONITORS"' .[] | select(.focused == true) | as_rect("monitor")'
}

output_scale() {
  if [[ -n $SCALE ]]; then
    printf '%s' "$SCALE"
    return
  fi
  local value
  value=$("$HYPRCTL" monitors -j 2>/dev/null | jq -r '.[] | select(.focused == true) | .scale' 2>/dev/null)
  [[ -n $value ]] || value=1
  printf '%s' "$value"
}

# Logical geometry -> the pixel size grim actually writes.
physical_size() { # logical_width logical_height
  local width height
  width=$(scale_px "$1")
  height=$(scale_px "$2")
  printf '%s %s' "$width" "$height"
}

# Cropping the freeze file needs no image on screen, and on a fractionally
# scaled display it is the only bit-exact option: the composited route goes
# through logical pixels, so the frame is downscaled and scaled back. Neither
# ImageMagick nor ffmpeg is an Omarchy guarantee, hence the grim fallback.
crop_freeze_file() { # freeze_file out_file "X,Y WxH" width height
  local source="$1" out="$2" geometry="$3" width="$4" height="$5"
  [[ -n $source && -s $source ]] || return 1

  local origin origin_x origin_y pixel_width pixel_height pixel_x pixel_y
  read -r origin_x origin_y <<<"$(geom_origin "$geometry")"
  read -r pixel_width pixel_height <<<"$(physical_size "$width" "$height")"
  pixel_x=$(scale_px "${origin_x:-0}")
  pixel_y=$(scale_px "${origin_y:-0}")

  # libvips first: it writes the identical pixels in about half the time ImageMagick
  # takes (70ms against 130ms for a 1280x960 crop of a 2880x1800 frame), so a
  # drag-to-card round trip is that much shorter. The rest are the fallbacks.
  if [[ -x $VIPS ]]; then
    "$VIPS" crop "$source" "$out" "$pixel_x" "$pixel_y" "$pixel_width" "$pixel_height" 2>/dev/null
  elif [[ -x $MAGICK ]]; then
    "$MAGICK" "$source" -crop "${pixel_width}x${pixel_height}+${pixel_x}+${pixel_y}" \
      +repage "$out" 2>/dev/null
  elif [[ -x $CONVERT ]]; then
    "$CONVERT" "$source" -crop "${pixel_width}x${pixel_height}+${pixel_x}+${pixel_y}" \
      +repage "$out" 2>/dev/null
  elif [[ -x $FFMPEG ]]; then
    "$FFMPEG" -v error -y -i "$source" -vf "crop=${pixel_width}:${pixel_height}:${pixel_x}:${pixel_y}" \
      "$out" 2>/dev/null
  else
    return 1
  fi

  [[ -s $out ]]
}

# The freeze frame must not contain the shell's own card, so wait for the layer
# to be withdrawn instead of guessing at a sleep. Measured cost is one frame.
wait_for_layer_gone() { # namespace [timeout_ms]
  local namespace="${1:-snapmenu}" timeout_ms="${2:-800}" waited=0
  [[ -x $HYPRCTL ]] || return 0
  # Plain `hyprctl layers` and a grep, not `-j` piped into jq: this runs in the
  # latency-critical path between the click and the freeze, and a second fork
  # per attempt is pure overhead. A layer line reads
  #   Layer <id>: xywh: …, namespace: snapmenu, pid: 1234
  # so the namespace is followed by a comma, not the end of the line.
  while ((waited < timeout_ms)); do
    if ! "$HYPRCTL" layers 2>/dev/null | grep -qE "namespace: ${namespace}(,|\$)"; then
      return 0
    fi
    sleep 0.02
    waited=$((waited + 20))
  done
  return 0
}

freeze_to_file() { # path [output]
  local path="$1" output="${2:-}"
  mkdir -p "$(dirname -- "$path")" 2>/dev/null || return 1
  if [[ -n $output ]]; then
    "$GRIM" -l "$PNG_LEVEL" -o "$output" "$path" 2>/dev/null || return 1
  else
    "$GRIM" -l "$PNG_LEVEL" "$path" 2>/dev/null || return 1
  fi
  [[ -s $path ]]
}

# True when a cropper is installed, in which case the crop is cut from the frame
# file and nothing on screen can end up in it — the picker uses this to skip
# waiting for its own chrome to disappear before the crop.
have_cropper() {
  [[ -x $VIPS || -x $MAGICK || -x $CONVERT || -x $FFMPEG ]]
}

# ------------------------------------------------------------------ cursor

# Software-composited cursors are drawn into the scene, so wlr-screencopy — and
# therefore grim — bakes the pointer into the frame; hardware cursors are not
# part of the scene at all. Omarchy's own capture forces hardware cursors so the
# pointer stays out, which is also the default here; --cursor asks for the
# opposite, and a crop always forces them back off so that a frame read back off
# the screen cannot gain a second pointer at the release position.
ORIGINAL_CURSORS=""
CURSORS_CHANGED=0

apply_cursors() { # 1 = software (pointer in the frame), 0 = hardware (pointer out)
  local wanted="$1"
  [[ -x $HYPRCTL ]] || return 0
  if ((CURSORS_CHANGED == 0)); then
    ORIGINAL_CURSORS=$("$HYPRCTL" getoption cursor:no_hardware_cursors -j 2>/dev/null | jq '.int // empty' 2>/dev/null)
    [[ -n $ORIGINAL_CURSORS ]] || return 0
    CURSORS_CHANGED=1
  fi
  "$HYPRCTL" eval "hl.config({ cursor = { no_hardware_cursors = $wanted } })" >/dev/null 2>&1 ||
    "$HYPRCTL" keyword cursor:no_hardware_cursors "$wanted" >/dev/null 2>&1
}

cursors_for_capture() {
  if ((WANT_CURSOR)); then
    apply_cursors 1
  else
    apply_cursors 0
  fi
}

cursors_for_crop() { apply_cursors 0; }

restore_cursors() {
  ((CURSORS_CHANGED)) || return 0
  "$HYPRCTL" eval "hl.config({ cursor = { no_hardware_cursors = $ORIGINAL_CURSORS } })" >/dev/null 2>&1 ||
    "$HYPRCTL" keyword cursor:no_hardware_cursors "$ORIGINAL_CURSORS" >/dev/null 2>&1
  CURSORS_CHANGED=0
}
trap restore_cursors EXIT

# --------------------------------------------------------------- animations

# Omarchy animates layer surfaces out (layerrule layersOut, a ~200ms fade), so
# the compositor keeps drawing our own card for a moment *after* hyprctl reports
# its layer gone. A frame taken in that window has a ghost of the card in it,
# which is what the picker used to show. Turning the fade off for our namespace
# removes the window entirely; the settle probe below covers the case where the
# rule could not be applied (another compositor, or a Hyprland restart).
if ((WANT_NO_ANIM)); then
  applied=false
  if [[ -x $HYPRCTL ]]; then
    # Hyprland 0.56 and later read their config as Lua, where the legacy
    # `keyword layerrule …` form is refused; the Lua call is the supported way
    # to add a rule at runtime.
    if [[ $("$HYPRCTL" eval 'hl.layer_rule({ name = "snapmenu", no_anim = true })' 2>&1) == "ok" ]]; then
      applied=true
    elif "$HYPRCTL" keyword layerrule "noanim,snapmenu" >/dev/null 2>&1; then
      applied=true
    fi
  fi
  jq -cn --argjson a "$applied" '{ok:true,noAnim:($a==true)}'
  exit 0
fi

# Two identical probes of the middle of the screen mean whatever was moving
# there has stopped — the card's fade, in practice. Capped, because something
# else on screen (video, an animation) may never settle.
# Two identical probes of one rectangle mean whatever was moving inside it has
# stopped. Probing the middle of the screen is not enough for everything that
# fades: a bar popout is anchored to its icon, so its fade happens in a corner and
# the middle never changes. Callers that know where their surface was pass it here.
settle_area() { # "X,Y WxH"
  local geometry="$1" prev="" now="" waited=0
  [[ -n $geometry ]] || return 0
  while ((waited < 400)); do
    now=$("$GRIM" -g "$geometry" - 2>/dev/null | md5sum | cut -d' ' -f1)
    if [[ -n $prev && $now == "$prev" ]]; then
      return 0
    fi
    prev="$now"
    sleep 0.04
    waited=$((waited + 40))
  done
  return 0
}

settle_after_unmap() { # monitor x y width height
  local geometry
  geometry=$(awk -v x="$2" -v y="$3" -v w="$4" -v h="$5" \
    'BEGIN { printf "%d,%d 96x96", x + w / 2 - 48, y + h / 2 - 48 }')
  settle_area "$geometry"
}

# ------------------------------------------------------------------- rects

if ((WANT_RECTS)); then
  monitor=$(focused_monitor_json)
  if [[ -z $monitor ]]; then
    jq -cn '{ok:true,rects:[]}'
    exit 0
  fi
  workspace=$("$HYPRCTL" monitors -j 2>/dev/null | jq -r '.[] | select(.focused == true) | .activeWorkspace.id')
  windows=$("$HYPRCTL" clients -j 2>/dev/null | jq -c --argjson ws "${workspace:-0}" \
    '[.[] | select(.hidden != true and .workspace.id == $ws) | {kind: "window", label: (if (.title // "") != "" then .title else (.class // "") end), x: .at[0], y: .at[1], width: .size[0], height: .size[1]}] | unique')
  jq -cn --argjson monitor "$monitor" --argjson windows "${windows:-[]}" \
    '{ok:true,monitor:$monitor,rects:([$monitor] + $windows)}'
  exit 0
fi

# ------------------------------------------------------------------ freeze

if ((WANT_FREEZE)); then
  require_grim
  wait_for_layer_gone snapmenu

  monitor=$(focused_monitor_json)
  output=$(jq -r '.name // ""' <<<"$monitor" 2>/dev/null)
  if [[ -z $monitor || -z $output ]]; then
    # Without an output grim would write every monitor into one frame and the
    # overlay would then treat it as the focused one, cropping the wrong pixels.
    emit_fail no-monitor
    exit 0
  fi
  # Two identical probes and a 40ms sleep between them: on the idle path that is
  # ~130ms of waiting for a fade that cannot happen when the caller has already
  # disabled it, which is why --no-settle exists.
  if ((WANT_NO_SETTLE == 0)); then
    if [[ -n $SETTLE_AREA ]]; then
      settle_area "$SETTLE_AREA"
    else
    settle_after_unmap "$monitor" \
      "$(jq -r '.x // 0' <<<"$monitor")" "$(jq -r '.y // 0' <<<"$monitor")" \
      "$(jq -r '.width // 0' <<<"$monitor")" "$(jq -r '.height // 0' <<<"$monitor")"
    fi
  fi

  cursors_for_capture

  # A freeze frame is scratch space for one selection; keep only the newest.
  rm -f "$FREEZE_DIR"/freeze-*.png 2>/dev/null
  file="$FREEZE_DIR/freeze-$(stamp).png"
  if ! freeze_to_file "$file" "$output"; then
    emit_fail freeze-failed
    exit 0
  fi


  cropper=false
  have_cropper && cropper=true

  jq -cn --arg p "$file" --argjson m "$monitor" --argjson t "$TEMP" --argjson c "$cropper" \
    '{ok:true,mode:"freeze",path:$p,temporary:($t==1),x:$m.x,y:$m.y,width:$m.width,height:$m.height,
      cropper:$c,monitor:$m}'
  exit 0
fi

# ------------------------------------------------------------------ delete

# `gio trash` first: a screenshot deleted by mistake should be recoverable from
# the file manager's trash, and it still leaves the export folder either way, so
# the capture history (which is that folder) drops it immediately. --permanently
# skips that and unlinks the file; both report the same mode once the folder no
# longer has it.
if [[ -n $DELETE ]]; then
  if [[ ! -e $DELETE ]]; then
    jq -cn --arg p "$DELETE" '{ok:true,path:$p,mode:"missing"}'
    exit 0
  fi

  if ((PERMANENT == 0)) && [[ -x $GIO ]] && "$GIO" trash -- "$DELETE" 2>/dev/null; then
    jq -cn --arg p "$DELETE" '{ok:true,path:$p,mode:"trash"}'
    exit 0
  fi

  if "$RM" -- "$DELETE" 2>/dev/null; then
    jq -cn --arg p "$DELETE" '{ok:true,path:$p,mode:"delete"}'
    exit 0
  fi

  emit_fail delete-failed
  exit 0
fi

# -------------------------------------------------------------------- crop

if [[ -n $CROP ]]; then
  read -r width height <<<"$(geom_size "$CROP")"
  if ((width <= 0 || height <= 0)); then
    emit_fail cancelled
    exit 0
  fi

  dir=$(target_dir)
  mkdir -p "$dir" 2>/dev/null || {
    emit_fail write-failed
    exit 0
  }
  file=$(unique_path "$dir" "screenshot-$(stamp)" "png")

  # grim captures the composited output: the overlay is showing the frozen frame
  # and nothing of its own chrome is inside the selection, so this is a crop of
  # the freeze, at the display's native pixels. Cropping the frame file directly
  # gives the same answer bit for bit when a cropper is installed.
  # The frame file's (0,0) is the frozen monitor's top-left corner, so a crop of the
  # file is in monitor-local coordinates while the selection is global. Without this
  # the cut is shifted by origin x scale on any monitor that is not at (0,0).
  FILE_CROP="$CROP"
  read -r origin_x origin_y <<<"$(geom_origin "$MONITOR_ORIGIN")"
  origin_x="${origin_x:-0}"
  origin_y="${origin_y:-0}"
  if ((origin_x != 0 || origin_y != 0)); then
    read -r sel_x sel_y <<<"$(geom_origin "$CROP")"
    FILE_CROP="$((sel_x - origin_x)),$((sel_y - origin_y)) ${width}x${height}"
  fi
  crop_source="file"
  if ! crop_freeze_file "$FREEZE_FILE" "$file" "$FILE_CROP" "$width" "$height"; then
    # No cropper installed: read the pixels back off the composited frozen frame,
    # with the pointer forced out so it cannot be drawn in a second time.
    require_grim
    cursors_for_crop
    # Read off the composited screen: slower, and only exact because the picker hides
    # its chrome first. The caller is told, so it can say so if it matters.
    crop_source="screen"
    if ! "$GRIM" -g "$CROP" "$file" 2>/dev/null || [[ ! -s $file ]]; then
      rm -f "$file"
      emit_fail grim-failed
      exit 0
    fi
  fi

  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s\n' "$CROP" >"$LAST_REGION" 2>/dev/null
  # SNAPMENU_KEEP_FREEZE is a debugging hook: it keeps the frame the crop came from
  # so the two can be compared by hand. The live identity suite copies the frame
  # itself while the picker waits, and does not need it.
  if [[ -n $FREEZE_FILE && -z ${SNAPMENU_KEEP_FREEZE:-} ]]; then
    rm -f "$FREEZE_FILE" 2>/dev/null
  fi
  remember_shot "$file"

  read -r physical_width physical_height <<<"$(physical_size "$width" "$height")"
  read -r reported_width reported_height \
    <<<"$(reported_size "$file" "$physical_width" "$physical_height")"
  emit_ok "$file" "$reported_width" "$reported_height" "${MODE:-region}" "$TEMP" "$crop_source"
  exit 0
fi

# ------------------------------------------------------------------ others

if ((FROM_CLIPBOARD)); then
  [[ -x $WL_PASTE ]] || {
    emit_fail no-image
    exit 0
  }

  types=$("$WL_PASTE" --list-types 2>/dev/null || true)
  mime=""
  for candidate in image/png image/jpeg image/webp image/gif image/bmp image/tiff; do
    if grep -qx "$candidate" <<<"$types"; then
      mime="$candidate"
      break
    fi
  done

  if [[ -z $mime ]]; then
    emit_fail no-image
    exit 0
  fi

  ext="${mime#image/}"
  [[ $ext == jpeg ]] && ext=jpg

  dir=$(target_dir)
  mkdir -p "$dir" 2>/dev/null || {
    emit_fail write-failed
    exit 0
  }
  file=$(unique_path "$dir" "clipboard-$(stamp)" "$ext")

  if ! "$WL_PASTE" --type "$mime" >"$file" 2>/dev/null || [[ ! -s $file ]]; then
    rm -f "$file"
    emit_fail clipboard-failed
    exit 0
  fi

  remember_shot "$file"
  emit_ok "$file" 0 0 "clipboard" "$TEMP"
  exit 0
fi

# fullscreen and previous go straight through grim: no overlay, no freeze.
geometry=""
case "$MODE" in
fullscreen | previous)
  monitor=$(focused_monitor_json)
  if [[ -z $monitor ]]; then
    emit_fail no-monitor
    exit 0
  fi

  if [[ $MODE == previous ]]; then
    geometry=$(cat "$LAST_REGION" 2>/dev/null || true)
    if [[ -z $geometry ]]; then
      emit_fail no-previous
      exit 0
    fi
  else
    geometry=$(jq -r '"\(.x),\(.y) \(.width)x\(.height)"' <<<"$monitor")
  fi
  ;;
"")
  emit_fail "no-request"
  exit 0
  ;;
*)
  emit_fail "unknown-mode:$MODE"
  exit 0
  ;;
esac

read -r width height <<<"$(geom_size "$geometry")"
require_grim
prune_tmp

# Our own surfaces are on screen when this runs: the menu this was chosen from is
# still unmapping, and shooting now bakes it into the picture. The freeze path waits
# for the layer before it captures; this path has to as well, or the grace period the
# overlay used to sleep through is all that stood between the menu and the shot.
wait_for_layer_gone snapmenu
if [[ -n $SETTLE_AREA ]]; then
  # A capture started from the bar dropdown: that popout is Omarchy's own full-screen
  # layer, which fades out, so watching our namespace is not enough.
  settle_area "$SETTLE_AREA"
fi

cursors_for_capture
dir=$(target_dir)
mkdir -p "$dir" 2>/dev/null || {
  emit_fail write-failed
  exit 0
}
file=$(unique_path "$dir" "screenshot-$(stamp)" "png")

if ! "$GRIM" -g "$geometry" "$file" 2>/dev/null || [[ ! -s $file ]]; then
  rm -f "$file"
  emit_fail grim-failed
  exit 0
fi

remember_shot "$file"
read -r physical_width physical_height <<<"$(physical_size "$width" "$height")"
read -r reported_width reported_height \
  <<<"$(reported_size "$file" "$physical_width" "$physical_height")"
emit_ok "$file" "$reported_width" "$reported_height" "$MODE" "$TEMP" "screen"
exit 0
