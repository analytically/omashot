.pragma library

// Pure logic for snapmenu: the menu/history/settings row lists, capture-helper
// output parsing, shell.json settings lookup, and small formatting helpers.
// Nothing here touches QML so it can be unit tested with plain node
// (tests/model.test.mjs).

var PLUGIN_ID = "io.github.analytically.snapmenu"
var VERSION = "0.1.0"

// Every glyph below is verified present in JetBrainsMono Nerd Font, and the
// ones Omarchy already uses for capture (0xF030, 0xF03D, 0xF0D11, 0xEA74,
// 0xE615) are the exact codepoints from Omarchy's own menu definition, so the
// plugin renders the same icons as the rest of the desktop.
//
// They are written as numbers on purpose: \uXXXX takes exactly four hex digits,
// and most of the Nerd Font private-use area lives above U+FFFF, where a bare
// \uF0101 would silently parse as \uF010 followed by "1".
var ICON_CODEPOINTS = {
  regionOrWindow: 0xF0101, // md-camera_enhance
  area: 0xF019F, // md-crop_free
  previous: 0xF0450, // md-refresh: a circle with an arrow back to it
  fullscreen: 0xF0379, // md-monitor (the bar icon carries the camera badge now)
  window: 0xF05B2, // md-window_restore
  timer: 0xF051B, // md-timer_outline
  record: 0xF03D, // fa-video_camera (Omarchy's screenrecord glyph)
  open: 0xF115, // fa-folder_open_o
  author: 0xF0004, // md-account, for the author row
  github: 0xF02A4, // md-github, for the link out
  clipboard: 0xF07F, // fa-clipboard_alt
  history: 0xF02DA, // md-history
  settings: 0xE615, // seti-config (Omarchy's setup glyph)
  about: 0xEA74, // cod-info (Omarchy's about glyph)
  copy: 0xF018F, // md-content_copy
  annotate: 0xF03EB, // md-pencil
  share: 0xF50E, // oct-share
  reveal: 0xF115, // fa-folder_open_o
  remove: 0xF0A79, // md-trash_can
  image: 0xF02E9, // md-image
  download: 0xF019, // fa-download
  eye: 0xF0208, // md-eye
  back: 0xF054C, // md-undo
  toggleOn: 0xF0132, // md-checkbox_marked
  toggleOff: 0xF0131, // md-checkbox_blank_outline
  // The bar icon is the screenshot glyph itself — a monitor with a camera badge
  // (md-monitor_screenshot) — rather than a generic camera: it says what the
  // plugin does at a glance. The states carry their own shapes: a camera with a
  // timer badge for an armed self-timer, and Omarchy's own record dot (U+F0EC2,
  // from its screen-recording indicator) for a recording in progress.
  camera: 0xF0E51, // md-monitor_screenshot
  cursor: 0xF245, // fa-mouse_pointer
  close: 0xF0156, // md-close
  chevronLeft: 0xF0141, // md-chevron_left
  chevronRight: 0xF0142, // md-chevron_right
  glaze: 0xF04A2, // md-contrast_circle, standing in for a tint
  trash: 0xF0A79, // md_delete_sweep, for where a deleted shot goes
  alert: 0xF05D6, // md-alert_circle_outline
  cameraTimer: 0xF0109, // md-camera_timer
  recordDot: 0xF0EC2 // md-record_circle
}

function glyphForCodePoint(codepoint) {
  var value = Number(codepoint)
  if (!isFinite(value) || value < 0) return ""
  if (value <= 0xFFFF) return String.fromCharCode(value)
  var offset = value - 0x10000
  return String.fromCharCode(0xD800 + (offset >> 10), 0xDC00 + (offset & 0x3FF))
}

var ICON = {}
for (var iconName in ICON_CODEPOINTS) ICON[iconName] = glyphForCodePoint(ICON_CODEPOINTS[iconName])

var DEFAULT_SETTINGS = {
  // Off by default: the clipboard belongs to whoever is using the machine, so taking a
  // shot must not replace what is already on it. Copying is a press on the card, and
  // copying every capture on its way past is something to opt into.
  copyToClipboard: false,
  saveToDisk: true,
  showResult: true,
  openAnnotate: false,
  showCursor: false,
  // Deleting is a deliberate press and the card names the file, so no second
  // question by default.
  confirmDelete: false,
  exportDir: "",
  // Off by default: a self-timer that is always on puts a wait in front of every
  // capture. The ring offers 3, 5, 10 and 15 seconds, and the bar icon shows
  // when one is armed.
  delay: 0,
  glaze: 0.1,
  dim: 0,
  deleteMode: "trash",
  cardWidth: 500
}

var DELAY_CHOICES = [0, 3, 5, 10, 15]

// How much white is washed over the selection while aiming. It is the only
// visual the user tunes by eye, so it steps through named levels rather than
// being a free number: 0.05 was invisible, 0.16 was raised as too much, and the
// default sits between them.
var GLAZE_CHOICES = [
  { value: 0, label: "Off" },
  { value: 0.06, label: "Subtle" },
  { value: 0.1, label: "Light" },
  { value: 0.14, label: "Medium" },
  { value: 0.2, label: "Strong" }
]

// How dark the rest of the screen goes while a selection is being made. Off by
// default: the glaze on the selection and the hairline around it say what is
// chosen, and the screen behind stays readable.
var DIM_CHOICES = [
  { value: 0, label: "Off" },
  { value: 0.25, label: "Light" },
  { value: 0.4, label: "Medium" },
  { value: 0.55, label: "Strong" }
]

// How wide the action card is. The preview fills the card's width, so this is the
// size of the screenshot you are looking at; the rows get the room with it. Widths
// are logical, the same units the rest of the theme uses.
var CARD_WIDTHS = [
  { value: 360, label: "Compact" },
  { value: 500, label: "Normal" },
  { value: 620, label: "Wide" },
  { value: 760, label: "Extra wide" }
]

function normalizeCardWidth(value) { return normalizeLevel(CARD_WIDTHS, value, 500) }
function prevCardWidth(value) { return nextLevel(CARD_WIDTHS.slice().reverse(), value, 500) }

// Dragging an edge of the card resizes it the way a centred window would: both
// sides move out together, so the width is twice the distance from the middle to
// the pointer. Raw pixels; the caller snaps them to an offered width.
function dragCardWidth(edge, pointerX, centreX, bounds) {
  var x = Number(pointerX), c = Number(centreX)
  if (!isFinite(x) || !isFinite(c)) return 0
  var half = String(edge || "right") === "left" ? c - x : x - c
  var width = Math.round(2 * half)
  var limit = Number(bounds) > 0 ? Number(bounds) : width
  return Math.max(0, Math.min(limit, width))
}
function cardWidthLabel(value) { return levelLabel(CARD_WIDTHS, value, 500) }
function nextCardWidth(value) { return nextLevel(CARD_WIDTHS, value, 500) }

// Where a deleted screenshot goes. Trash by default: deleting a shot is a
// keystroke away and the file manager can still get it back.
var DELETE_MODES = [
  { value: "trash", label: "Trash" },
  { value: "permanently", label: "Permanently" }
]

// Both are "pick one of a few named steps", so they share one implementation.
function normalizeLevel(choices, value, fallback) {
  var number = Number(value)
  if (!isFinite(number)) return fallback
  var best = choices[0]
  for (var i = 1; i < choices.length; i++) {
    if (Math.abs(choices[i].value - number) < Math.abs(best.value - number)) best = choices[i]
  }
  return best.value
}

function levelLabel(choices, value, fallback) {
  var snapped = normalizeLevel(choices, value, fallback)
  for (var i = 0; i < choices.length; i++) {
    if (choices[i].value === snapped) return choices[i].label
  }
  return choices[0].label
}

function nextLevel(choices, value, fallback) {
  var snapped = normalizeLevel(choices, value, fallback)
  for (var i = 0; i < choices.length; i++) {
    if (choices[i].value === snapped) return choices[(i + 1) % choices.length].value
  }
  return choices[0].value
}

// --------------------------------------------------------------- formatting

function localPathFromUrl(url) {
  var text = String(url || "")
  if (text.indexOf("file://") === 0) text = text.slice(7)
  try {
    text = decodeURIComponent(text)
  } catch (e) { /* leave the raw path if it is not percent-encoded */ }
  if (text.length > 1 && text.charAt(text.length - 1) === "/") text = text.slice(0, -1)
  return text
}

function basename(path) {
  var text = String(path || "")
  var slash = text.lastIndexOf("/")
  return slash >= 0 ? text.slice(slash + 1) : text
}

function dirname(path) {
  var text = String(path || "")
  var slash = text.lastIndexOf("/")
  return slash > 0 ? text.slice(0, slash) : "/"
}

function formatBytes(bytes) {
  var value = Number(bytes)
  if (!isFinite(value) || value < 0) return ""
  if (value < 1024) return Math.round(value) + " B"
  if (value < 1024 * 1024) return Math.round(value / 1024) + " KB"
  if (value < 1024 * 1024 * 1024) return (value / (1024 * 1024)).toFixed(1) + " MB"
  return (value / (1024 * 1024 * 1024)).toFixed(1) + " GB"
}

function formatAge(ageMs, nowMs) {
  var value = Number(ageMs)
  if (!isFinite(value) || value < 0) return ""
  var now = isFinite(Number(nowMs)) ? Number(nowMs) : value
  var seconds = Math.floor((now - value) / 1000)
  if (seconds < 45) return "just now"
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return minutes + " min ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + (hours === 1 ? " hour ago" : " hours ago")
  var days = Math.floor(hours / 24)
  if (days < 14) return days + (days === 1 ? " day ago" : " days ago")
  return new Date(value).toISOString().slice(0, 10)
}

// Modern display shapes, longest side first, with the devices that made them
// familiar. Only shapes you meet today: a 5:4 selection is just a rectangle, and
// naming it "5:4" tells nobody anything. The comparison is on the shape, so a
// portrait selection matches the same entry as its landscape twin.
var RATIOS = [
  { ratio: 32 / 9, label: "32:9", name: "super ultrawide" },
  { ratio: 21 / 9, label: "21:9", name: "ultrawide" },
  { ratio: 20 / 9, label: "20:9", name: "Android" },
  { ratio: 19.5 / 9, label: "19.5:9", name: "iPhone" },
  { ratio: 2, label: "2:1", name: "18:9" },
  { ratio: 16 / 9, label: "16:9", name: "" },
  { ratio: 16 / 10, label: "16:10", name: "MacBook" },
  { ratio: 3 / 2, label: "3:2", name: "Surface" },
  { ratio: 4 / 3, label: "4:3", name: "iPad" },
  { ratio: 1, label: "1:1", name: "" }
]

// How far off a ratio can be and still be called that ratio. A selection drawn by
// hand lands on whole pixels, so an intended 16:9 is routinely 1.777 or 1.779.
// Wide enough for the shapes the world rounds: 3440x1440 is what everyone calls 21:9
// even though it is 21.5:9, and the tightest pair in the list (16:10 and 3:2) is 6.7%
// apart, so nothing here can be mistaken for its neighbour — and when two are close,
// the closer one wins.
var RATIO_TOLERANCE = 0.03

function ratioLabel(width, height) {
  var w = Number(width), h = Number(height)
  if (!isFinite(w) || !isFinite(h) || w <= 0 || h <= 0) return ""
  var shape = Math.max(w, h) / Math.min(w, h)
  var best = null
  for (var i = 0; i < RATIOS.length; i++) {
    var off = Math.abs(shape - RATIOS[i].ratio) / RATIOS[i].ratio
    if (off <= RATIO_TOLERANCE && (best === null || off < best.off)) {
      best = { off: off, entry: RATIOS[i] }
    }
  }
  return best ? best.entry.label : ""
}

function ratioName(width, height) {
  var shape = ratioLabel(width, height)
  if (!shape) return ""
  for (var i = 0; i < RATIOS.length; i++) {
    if (RATIOS[i].label === shape) return RATIOS[i].name
  }
  return ""
}

// "1440 × 900 · 16:10": what the size label and the card's caption both say, so the
// two cannot drift apart.
function dimensionLabel(width, height) {
  var dimensions = formatDimensions(width, height)
  var ratio = ratioLabel(width, height)
  var name = ratioName(width, height)
  if (!dimensions) return ratio
  if (!ratio) return dimensions
  return dimensions + " · " + ratio + (name ? " (" + name + ")" : "")
}

function formatDimensions(width, height) {
  var w = Number(width)
  var h = Number(height)
  if (!isFinite(w) || !isFinite(h) || w <= 0 || h <= 0) return ""
  return w + " × " + h
}

function shotDetail(shot, nowMs) {
  var parts = []
  // When it was taken leads the line: that is what a history list is read for.
  // Size follows, and dimensions only when they are known (a listed file carries
  // no image size, the card's own shot does).
  var age = formatAge(shot ? shot.mtime : 0, nowMs)
  if (age) parts.push(age)
  var size = formatBytes(shot ? shot.size : 0)
  if (size) parts.push(size)
  var dimensions = formatDimensions(shot ? shot.width : 0, shot ? shot.height : 0)
  if (dimensions) parts.push(dimensions)
  return parts.join(" · ")
}

// --------------------------------------------------------------- parsing

// `find -printf '%T@\t%s\t%p\n'` output -> newest-first shot records.
function parseRecentShots(text, limit) {
  var lines = String(text || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (!line) continue
    var first = line.indexOf("\t")
    if (first < 0) continue
    var second = line.indexOf("\t", first + 1)
    if (second < 0) continue
    var mtime = Number(line.slice(0, first))
    var size = Number(line.slice(first + 1, second))
    var path = line.slice(second + 1)
    if (!path) continue
    if (!isFinite(mtime)) mtime = 0
    if (!isFinite(size)) size = 0
    out.push({ path: path, name: basename(path), size: size, mtime: Math.round(mtime * 1000) })
  }
  out.sort(function (a, b) { return b.mtime - a.mtime })
  var max = Number(limit)
  if (!isFinite(max) || max <= 0) max = out.length
  return out.slice(0, max)
}

// The capture helper prints exactly one JSON line; be tolerant of anything
// else a shell profile might have added to stdout.
function parseCaptureResult(text) {
  var lines = String(text || "").split("\n")
  for (var i = lines.length - 1; i >= 0; i--) {
    var line = String(lines[i]).replace(/^\s+|\s+$/g, "")
    if (!line || line.charAt(0) !== "{") continue
    var parsed = null
    try {
      parsed = JSON.parse(line)
    } catch (e) {
      parsed = null
    }
    if (!parsed || typeof parsed.ok !== "boolean") continue
    var monitor = parsed.monitor && typeof parsed.monitor === "object" ? parsed.monitor : null
    return {
      ok: parsed.ok === true,
      path: String(parsed.path || ""),
      reason: String(parsed.reason || ""),
      width: Number(parsed.width || 0),
      height: Number(parsed.height || 0),
      mode: String(parsed.mode || ""),
      temporary: parsed.temporary === true,
      originX: Number(parsed.x || 0),
      originY: Number(parsed.y || 0),
      monitor: monitor,
      // The helper reports whether it can cut the frame file directly; a
      // missing field means we must assume the screen-reading fallback.
      cropper: parsed.cropper === true,
      // Whether the helper managed to stop our layer surfaces from fading.
      noAnim: parsed.noAnim === true
    }
  }
  return {
    ok: false, path: "", reason: "no-output", width: 0, height: 0,
    mode: "", temporary: false, originX: 0, originY: 0, monitor: null, cropper: false,
    noAnim: false
  }
}

// `--rects` output: the focused monitor plus every window on its workspace, all
// in global logical coordinates.
function parseRects(text) {
  var lines = String(text || "").split("\n")
  for (var i = lines.length - 1; i >= 0; i--) {
    var line = String(lines[i]).replace(/^\s+|\s+$/g, "")
    if (!line || line.charAt(0) !== "{") continue
    var parsed = null
    try {
      parsed = JSON.parse(line)
    } catch (e) {
      parsed = null
    }
    if (!parsed || parsed.ok !== true) continue
    var rects = []
    if (Array.isArray(parsed.rects)) {
      for (var j = 0; j < parsed.rects.length; j++) {
        var rect = parsed.rects[j]
        if (!rect) continue
        rects.push({
          kind: String(rect.kind || "window"),
          label: String(rect.label || ""),
          x: Number(rect.x || 0),
          y: Number(rect.y || 0),
          width: Number(rect.width || 0),
          height: Number(rect.height || 0)
        })
      }
    }
    return { ok: true, rects: rects, monitor: parsed.monitor || null }
  }
  return { ok: false, rects: [], monitor: null }
}

function reasonMessage(reason) {
  var value = String(reason || "")
  if (value === "cancelled") return "Capture cancelled"
  if (value === "no-previous") return "No previous area yet — capture an area first"
  if (value === "no-image") return "No image in the clipboard"
  if (value === "clipboard-failed") return "Could not read the clipboard image"
  if (value === "grim-failed") return "Capture failed (grim)"
  if (value === "grim-missing") return "grim is not installed"
  if (value === "helper-failed") return "The capture helper failed to run"
  if (value === "freeze-failed") return "Could not freeze the screen"
  if (value === "no-monitor") return "No focused monitor"
  if (value === "no-request") return "Nothing to capture"
  if (value === "delete-failed") return "Could not delete the screenshot"
  if (value === "write-failed") return "Could not write the screenshot"
  if (value === "picker-missing") return "omarchy-capture-region is not installed"
  if (value === "no-output") return "The capture helper returned nothing"
  return "Capture failed: " + value
}

// ~/.config/user-dirs.dirs is a shell file, so read XDG_PICTURES_DIR out of it
// rather than trusting an environment variable the session may not export.
function xdgPicturesDir(text, home) {
  var match = /XDG_PICTURES_DIR="([^"]*)"/.exec(String(text || ""))
  if (!match) return ""
  var value = match[1]
  if (!value) return ""
  return value.replace(/^\$HOME/, String(home || ""))
}

// --------------------------------------------------------------- settings

function boolValue(value, fallback) {
  if (value === true || value === false) return value
  if (value === "true" || value === "yes" || value === "on" || value === 1 || value === "1") return true
  if (value === "false" || value === "no" || value === "off" || value === 0 || value === "0") return false
  return fallback
}

function normalizeDelay(value) {
  var number = Number(value)
  if (!isFinite(number) || number <= 0) return 0
  for (var i = 0; i < DELAY_CHOICES.length; i++) {
    if (DELAY_CHOICES[i] === number) return number
  }
  return 0
}

// Snaps to the nearest level, so a hand-edited shell.json still works.
function normalizeGlaze(value) { return normalizeLevel(GLAZE_CHOICES, value, 0.1) }
function glazeLabel(value) { return levelLabel(GLAZE_CHOICES, value, 0.1) }
function nextGlaze(value) { return nextLevel(GLAZE_CHOICES, value, 0.1) }

function normalizeDeleteMode(value) {
  var wanted = String(value === undefined || value === null ? "" : value)
  for (var i = 0; i < DELETE_MODES.length; i++) {
    if (DELETE_MODES[i].value === wanted) return wanted
  }
  // Anything else (including the booleans an older config might carry) is read
  // as the safe answer.
  return "trash"
}

function deleteModeLabel(value) {
  var mode = normalizeDeleteMode(value)
  for (var i = 0; i < DELETE_MODES.length; i++) {
    if (DELETE_MODES[i].value === mode) return DELETE_MODES[i].label
  }
  return DELETE_MODES[0].label
}

function nextDeleteMode(value) {
  var mode = normalizeDeleteMode(value)
  for (var i = 0; i < DELETE_MODES.length; i++) {
    if (DELETE_MODES[i].value === mode) return DELETE_MODES[(i + 1) % DELETE_MODES.length].value
  }
  return DELETE_MODES[0].value
}

function normalizeDim(value) { return normalizeLevel(DIM_CHOICES, value, 0) }
function dimLabel(value) { return levelLabel(DIM_CHOICES, value, 0) }
function nextDim(value) { return nextLevel(DIM_CHOICES, value, 0) }

function normalizeSettings(raw) {
  var out = {}
  for (var key in DEFAULT_SETTINGS) out[key] = DEFAULT_SETTINGS[key]
  if (!raw || typeof raw !== "object") return out
  if ("copyToClipboard" in raw) out.copyToClipboard = boolValue(raw.copyToClipboard, out.copyToClipboard)
  if ("saveToDisk" in raw) out.saveToDisk = boolValue(raw.saveToDisk, out.saveToDisk)
  if ("showResult" in raw) out.showResult = boolValue(raw.showResult, out.showResult)
  if ("openAnnotate" in raw) out.openAnnotate = boolValue(raw.openAnnotate, out.openAnnotate)
  if ("showCursor" in raw) out.showCursor = boolValue(raw.showCursor, out.showCursor)
  if ("confirmDelete" in raw) out.confirmDelete = boolValue(raw.confirmDelete, out.confirmDelete)
  if ("exportDir" in raw) out.exportDir = String(raw.exportDir || "")
  if ("delay" in raw) out.delay = normalizeDelay(raw.delay)
  if ("glaze" in raw) out.glaze = normalizeGlaze(raw.glaze)
  if ("dim" in raw) out.dim = normalizeDim(raw.dim)
  if ("deleteMode" in raw) out.deleteMode = normalizeDeleteMode(raw.deleteMode)
  if ("cardWidth" in raw) out.cardWidth = normalizeCardWidth(raw.cardWidth)
  return out
}

// Settings live inline on this plugin's shell.json entry: the bar layout slot
// when the widget is on the bar, otherwise a top-level plugins[] entry. Both
// are user-editable by hand, and `omarchy bar` / updateEntryInline() write the
// same place.
function entryFromShellConfig(text, pluginId) {
  var config = null
  try {
    config = JSON.parse(String(text || ""))
  } catch (e) {
    config = null
  }
  if (!config || typeof config !== "object") return null

  var layout = config.bar && config.bar.layout ? config.bar.layout : null
  var sections = ["left", "center", "right"]
  for (var s = 0; s < sections.length; s++) {
    var list = layout ? layout[sections[s]] : null
    if (!Array.isArray(list)) continue
    for (var i = 0; i < list.length; i++) {
      var candidate = list[i]
      var id = typeof candidate === "string" ? candidate : (candidate ? candidate.id : "")
      if (String(id || "") !== String(pluginId)) continue
      return typeof candidate === "string" ? { id: candidate } : candidate
    }
  }

  if (Array.isArray(config.plugins)) {
    for (var j = 0; j < config.plugins.length; j++) {
      var plugin = config.plugins[j]
      if (plugin && String(plugin.id || "") === String(pluginId)) return plugin
    }
  }
  return null
}

function settingsFromShellConfig(text, pluginId) {
  return normalizeSettings(entryFromShellConfig(text, pluginId))
}

// ------------------------------------------------------------- selection

// Two drag corners -> a rect with rounded, non-negative geometry. Rounding the
// corners before taking the difference keeps the rect aligned to whole logical
// pixels, which is what grim crops on.
function normalizeDrag(startX, startY, endX, endY) {
  var x1 = Math.round(Math.min(startX, endX))
  var y1 = Math.round(Math.min(startY, endY))
  var x2 = Math.round(Math.max(startX, endX))
  var y2 = Math.round(Math.max(startY, endY))
  return { x: x1, y: y1, width: Math.max(0, x2 - x1), height: Math.max(0, y2 - y1) }
}

// Drag maths with the picker's modifier constraints.
//
//   free   - both axes follow the pointer
//   width  - Shift: the height is frozen and only the width changes, a band
//            you widen from where the drag started
//   height - Shift+Ctrl: the mirror — the width is frozen and only the height
//            changes, a column you run down the screen
//   ratio  - Ctrl: the aspect ratio is locked
//
// A constraint with nothing to work from (no stored height, width or ratio
// yet) falls back to a free drag rather than producing a degenerate rectangle.
function dragRect(state) {
  var s = state || {}
  var anchorX = Number(s.anchorX || 0)
  var anchorY = Number(s.anchorY || 0)
  var pointerX = Number(s.pointerX || 0)
  var pointerY = Number(s.pointerY || 0)
  var mode = String(s.mode || "free")
  var bounds = s.bounds || null
  var maxWidth = bounds ? Number(bounds.width || 0) : 0
  var maxHeight = bounds ? Number(bounds.height || 0) : 0

  var rect = normalizeDrag(anchorX, anchorY, pointerX, pointerY)

  if (mode === "width") {
    var lockedHeight = Number(s.lockedHeight || 0)
    if (!(lockedHeight > 0)) return rect
    // The band hangs from where the drag started, trimmed so it cannot run off
    // the bottom of the monitor (the width stays free, so it is not clipped).
    var allowed = maxHeight > 0
      ? Math.max(1, maxHeight - Math.round(anchorY)) : lockedHeight
    return {
      x: rect.x,
      y: Math.round(anchorY),
      width: rect.width,
      height: Math.round(Math.max(1, Math.min(lockedHeight, allowed)))
    }
  }

  if (mode === "height") {
    var lockedWidth = Number(s.lockedWidth || 0)
    if (!(lockedWidth > 0)) return rect
    // A column hanging from where the drag started, trimmed so it cannot run off
    // the right edge (the height stays free, so it is not clipped).
    var allowedWidth = maxWidth > 0
      ? Math.max(1, maxWidth - Math.round(anchorX)) : lockedWidth
    return {
      x: Math.round(anchorX),
      y: rect.y,
      width: Math.round(Math.max(1, Math.min(lockedWidth, allowedWidth))),
      height: rect.height
    }
  }

  if (mode === "ratio") {
    var dx = pointerX - anchorX
    var dy = pointerY - anchorY
    var ratio = Number(s.ratio || 0)
    // With nothing to lock onto, fall back to the monitor's own shape. Deriving
    // it from the first pointer movement instead is what made Ctrl feel like a
    // horizontal drag: the opening pixels of any drag are mostly sideways, so
    // the "locked" ratio came out very wide and the box grew along x.
    if (!(ratio > 0) && maxWidth > 0 && maxHeight > 0) ratio = maxWidth / maxHeight
    if (!(ratio > 0)) return rect

    // The axis that travelled further decides the size; the other follows.
    var width = Math.max(Math.abs(dx), Math.abs(dy) * ratio)
    var height = width / ratio
    var x = dx < 0 ? anchorX - width : anchorX
    var y = dy < 0 ? anchorY - height : anchorY

    // Stay on the monitor without breaking the ratio: scale both axes down,
    // then slide back inside.
    if (maxWidth > 0 && maxHeight > 0) {
      var scale = 1
      if (width > maxWidth) scale = maxWidth / width
      if (height * scale > maxHeight) scale = maxHeight / height
      if (scale < 1) {
        width *= scale
        height *= scale
        if (dx < 0) x = anchorX - width
        if (dy < 0) y = anchorY - height
      }
      x = Math.max(0, Math.min(x, maxWidth - width))
      y = Math.max(0, Math.min(y, maxHeight - height))
    }
    return { x: Math.round(x), y: Math.round(y), width: Math.round(width), height: Math.round(height) }
  }

  return rect
}

// Which drag constraint a modifier state asks for. Shift and Ctrl both widen a
// band; together they run a column. dragRect also knows how to lock the aspect
// ratio, which no modifier is bound to at the moment — re-binding it is a
// change to this function.
function dragModeFor(shift, ctrl) {
  if (shift === true && ctrl === true) return "height"
  if (shift === true || ctrl === true) return "width"
  return "free"
}

// What the picker's legend calls the active constraint (empty for a free drag).
function dragConstraintLabel(mode) {
  var value = String(mode || "")
  if (value === "width") return "width only"
  if (value === "height") return "height only"
  if (value === "ratio") return "aspect locked"
  return ""
}

// Overlay-local rect -> the global logical geometry grim takes.
function globalGeometry(rect, originX, originY) {
  if (!rect) return ""
  var x = Math.round(Number(rect.x || 0) + Number(originX || 0))
  var y = Math.round(Number(rect.y || 0) + Number(originY || 0))
  var width = Math.round(Number(rect.width || 0))
  var height = Math.round(Number(rect.height || 0))
  if (width <= 0 || height <= 0) return ""
  return x + "," + y + " " + width + "x" + height
}

function clipRectToBounds(rect, bounds) {
  if (!rect || !bounds) return null
  var x1 = Math.max(Number(rect.x || 0), Number(bounds.x || 0))
  var y1 = Math.max(Number(rect.y || 0), Number(bounds.y || 0))
  var x2 = Math.min(Number(rect.x || 0) + Number(rect.width || 0),
    Number(bounds.x || 0) + Number(bounds.width || 0))
  var y2 = Math.min(Number(rect.y || 0) + Number(rect.height || 0),
    Number(bounds.y || 0) + Number(bounds.height || 0))
  if (x2 - x1 <= 0 || y2 - y1 <= 0) return null
  return {
    kind: String(rect.kind || "window"),
    label: String(rect.label || ""),
    x: Math.round(x1), y: Math.round(y1),
    width: Math.round(x2 - x1), height: Math.round(y2 - y1)
  }
}

// Global rects -> overlay-local rects, keeping only what the frozen monitor can
// show. Rects that straddle two monitors are clipped to this one so a snapped
// capture never asks grim for pixels the monitor does not have.
function localRects(rects, originX, originY, width, height) {
  var list = Array.isArray(rects) ? rects : []
  var bounds = { x: 0, y: 0, width: Number(width || 0), height: Number(height || 0) }
  var out = []
  for (var i = 0; i < list.length; i++) {
    var moved = {
      kind: String(list[i].kind || "window"),
      label: String(list[i].label || ""),
      x: Number(list[i].x || 0) - Number(originX || 0),
      y: Number(list[i].y || 0) - Number(originY || 0),
      width: Number(list[i].width || 0),
      height: Number(list[i].height || 0)
    }
    var clipped = clipRectToBounds(moved, bounds)
    if (clipped) out.push(clipped)
  }
  return out
}

function rectArea(rect) {
  if (!rect) return 0
  return Math.max(0, Number(rect.width || 0)) * Math.max(0, Number(rect.height || 0))
}

// Windows in reading order (top to bottom, then left to right) — the order the
// unified capture overlay cycles through with Tab.
function windowRects(rects) {
  var list = Array.isArray(rects) ? rects : []
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && String(list[i].kind || "") === "window") out.push(list[i])
  }
  out.sort(function (a, b) {
    if (a.y !== b.y) return a.y - b.y
    return a.x - b.x
  })
  return out
}

function nextRect(rects, current, delta) {
  var list = windowRects(rects)
  if (list.length === 0) return null
  var step = Number(delta) < 0 ? -1 : 1
  var index = -1
  for (var i = 0; i < list.length; i++) {
    if (current && list[i].x === current.x && list[i].y === current.y
      && list[i].width === current.width && list[i].height === current.height) {
      index = i
      break
    }
  }
  if (index === -1) return step > 0 ? list[0] : list[list.length - 1]
  return list[(index + step + list.length) % list.length]
}

// What the bar glyph should be right now: the icon itself says whether a
// self-timer is armed or a recording is running, so the state is visible
// without opening anything. Tone is semantic; the widget maps it to colours.
function barIcon(state) {
  var s = state || {}

  if (s.recording === true) {
    return {
      glyph: ICON.recordDot,
      tone: "recording",
      tooltip: "Snapmenu — recording · click to stop"
    }
  }

  var delay = normalizeDelay(s.delay)
  if (delay > 0) {
    return {
      glyph: ICON.cameraTimer,
      tone: "armed",
      tooltip: "Snapmenu — self-timer " + delayLabel(delay) + " · click for the menu"
    }
  }

  return { glyph: ICON.camera, tone: "idle", tooltip: "Snapmenu — screenshot menu" }
}

// Which actions put a question in front of the user first. Only deletion is
// destructive, and only when the setting asks for it.
function needsConfirm(action, settings) {
  if (String(action || "") !== "delete") return false
  return normalizeSettings(settings).confirmDelete === true
}

// Browsing the history: the shot next to this one, older or newer, and where a
// path sits in the list. The list is newest first, so "newer" walks backwards.
// An empty string means there is nothing that way.
function indexOfShot(shots, path) {
  var list = Array.isArray(shots) ? shots : []
  var wanted = String(path || "")
  for (var i = 0; i < list.length; i++) {
    if (String(list[i].path || "") === wanted) return i
  }
  return -1
}

function neighbourShot(shots, path, direction) {
  var list = Array.isArray(shots) ? shots : []
  if (list.length === 0) return ""
  var step = String(direction) === "newer" ? -1 : 1
  var at = indexOfShot(list, path)
  if (at === -1) return String(list[0].path || "")
  var next = at + step
  if (next < 0 || next >= list.length) return ""
  return String(list[next].path || "")
}

// Which checkbox glyph a toggle row shows.
function toggleGlyph(on) {
  return on === true ? ICON.toggleOn : ICON.toggleOff
}

function rectLabel(rect) {
  if (!rect) return ""
  var name = String(rect.label || "")
  var size = Math.round(Number(rect.width || 0)) + " × " + Math.round(Number(rect.height || 0))
  return name ? (name + "  ·  " + size) : size
}

// Smallest rect containing the point, which is how a click picks from
// overlapping window and monitor rects.
function rectAt(rects, x, y) {
  var list = Array.isArray(rects) ? rects : []
  var found = null
  for (var i = 0; i < list.length; i++) {
    var rect = list[i]
    if (!rect) continue
    if (x < rect.x || y < rect.y) continue
    if (x >= rect.x + rect.width || y >= rect.y + rect.height) continue
    if (!found || rectArea(rect) < rectArea(found)) found = rect
  }
  return found
}

// "X,Y WxH" -> { x, y, width, height } or null.
function parseGeometry(text) {
  var match = /^\s*(-?\d+)\s*,\s*(-?\d+)\s+(\d+)x(\d+)\s*$/.exec(String(text || ""))
  if (!match) return null
  var width = Number(match[3])
  var height = Number(match[4])
  if (!(width > 0) || !(height > 0)) return null
  return { x: Number(match[1]), y: Number(match[2]), width: width, height: height }
}

// ------------------------------------------------------------- selection

// The unified capture decision, in one place so it can be tested without a
// compositor: what a click or Enter would capture right now.
//
//   drag beats keyboard pick beats pointer hover beats the whole monitor
// Actions that put the shot somewhere else and are therefore finished the
// moment they run: the card has nothing left to say, so it closes. Navigation,
// settings and confirmation-first actions are not in this set.
function actionHandsOff(action) {
  var value = String(action || "")
  return value === "copy" || value === "annotate"
    || value === "share" || value === "reveal"
}

function candidateRect(state) {
  var s = state || {}
  if (s.dragging && s.selection) return s.selection
  if (s.keyboardActive && s.keyboardRect) return s.keyboardRect
  if (s.unified && s.hoverRect) return s.hoverRect
  if (s.selection) return s.selection
  return null
}

// Same, with the whole frozen monitor as the fallback, or null when there is
// not even a monitor to fall back to.
function selectionOrDefault(state) {
  var s = state || {}
  var rect = candidateRect(s)
  if (rect && Number(rect.width || 0) >= 1 && Number(rect.height || 0) >= 1) return rect

  var width = Number(s.monitorWidth || 0)
  var height = Number(s.monitorHeight || 0)
  if (width < 1 || height < 1) return null
  return { kind: "monitor", label: "", x: 0, y: 0, width: width, height: height }
}

// What the picker tells the user each gesture does, per mode.
function legendText(mode) {
  var m = String(mode || "")
  if (m === "window") return "Click a window · Tab cycles"
  if (m === "smart") return "Drag a region · Tab cycles windows · click for the screen"
  return "Drag a region · click for the screen"
}

// --------------------------------------------------------------- row lists

function delayLabel(seconds) {
  var value = normalizeDelay(seconds)
  return value > 0 ? value + " s" : "Off"
}

function nextDelay(seconds) {
  var value = normalizeDelay(seconds)
  for (var i = 0; i < DELAY_CHOICES.length; i++) {
    if (DELAY_CHOICES[i] === value) return DELAY_CHOICES[(i + 1) % DELAY_CHOICES.length]
  }
  return DELAY_CHOICES[0]
}

function shotCountLabel(count) {
  var value = Number(count)
  // Negative means "not counted here": the dropdown does not read the export
  // folder, so it says something neutral rather than claiming zero.
  if (!isFinite(value) || value < 0) return ""
  if (value === 0) return "No shots recorded yet"
  return value + (value === 1 ? " recent shot" : " recent shots")
}

// How a deleted shot left the disk, for the confirmation message.
function deleteVerb(mode) {
  if (String(mode || "") === "trash") return "Moved to trash"
  if (String(mode || "") === "missing") return "Already gone"
  return "Deleted"
}

// The capture menu, mapped onto what Omarchy can actually do. Rows are
// plain data so the QML stays presentation and key routing only.
// What `wl-paste --list-types` can offer that the import knows how to write out, in the
// order the import tries them (a test keeps this list and the script's together). An
// image type outside it — an icon, an SVG — is not something the row could open.
var CLIPBOARD_IMAGE_TYPES = ["image/png", "image/jpeg", "image/webp",
  "image/gif", "image/bmp", "image/tiff"]

// The types arrive one per line, and the image is rarely the first one: a shell paste
// carries text/plain alongside it.
function clipboardHasImage(types) {
  var lines = String(types || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var type = lines[i].replace(/^\s+|\s+$/g, "")
    if (type !== "" && CLIPBOARD_IMAGE_TYPES.indexOf(type) >= 0) return true
  }
  return false
}

function menuRows(state) {
  var s = state || {}
  var previous = s.hasPrevious === true
  var clipboardImage = s.hasClipboardImage === true
  var recording = s.recording === true
  var delay = normalizeDelay(s.delay)
  // Every selectable row carries the command a dropdown (or any other
  // renderer) sends to have it run. The overlay is the only thing that
  // executes them, so both surfaces cannot drift.
  var rows = [
    { kind: "action", id: "region-or-window", icon: ICON.regionOrWindow,
      label: "Capture Region or Window",
      detail: "Drag, or click a window or the screen",
      action: "capture", mode: "smart", payload: { action: "capture", mode: "smart" } },
    { kind: "action", id: "area", icon: ICON.area, label: "Capture Area",
      action: "capture", mode: "region", payload: { action: "capture", mode: "region" } },
    // Only offered once there is a region to repeat, the same way Stop Recording
    // only appears while something is recording. A row that cannot be used is not
    // a row that needs a sentence: it is not a row.
    previous
      ? { kind: "action", id: "previous", icon: ICON.previous, label: "Capture Previous Area",
        action: "capture", mode: "previous",
        payload: { action: "capture", mode: "previous" } }
      : null,
    { kind: "action", id: "fullscreen", icon: ICON.fullscreen, label: "Capture Fullscreen",
      detail: "The monitor under the pointer",
      action: "capture", mode: "fullscreen",
      payload: { action: "capture", mode: "fullscreen" } },
    { kind: "action", id: "window", icon: ICON.window, label: "Capture Window",
      action: "capture", mode: "window", payload: { action: "capture", mode: "window" } },
    recording
      ? { kind: "action", id: "record-stop", icon: ICON.record, label: "Stop Recording",
        action: "stop-record", urgent: true, payload: { action: "stop-record" } }
      : { kind: "action", id: "record", icon: ICON.record, label: "Record Screen",
        action: "record", payload: { action: "record" } },
    { kind: "value", id: "timer", icon: ICON.timer, label: "Self-Timer",
      value: delayLabel(delay),
      action: "cycle-delay", payload: { action: "set-delay", value: nextDelay(delay) } },
    { kind: "separator", id: "sep-line-open" },
    { kind: "action", id: "open", icon: ICON.open, label: "Open…",
      detail: "Annotate an image already on disk",
      action: "open", payload: { action: "open" } },
    clipboardImage
      ? { kind: "action", id: "from-clipboard", icon: ICON.clipboard, label: "Open from Clipboard",
        action: "from-clipboard", payload: { action: "from-clipboard" } }
      : null,
    { kind: "action", id: "history", icon: ICON.history, label: "Capture History…",
      detail: shotCountLabel(s.shotCount), action: "history",
      payload: { stage: "history" } },
    { kind: "separator", id: "sep-line-settings" },
    { kind: "action", id: "settings", icon: ICON.settings, label: "Settings…",
      action: "settings", payload: { stage: "settings" } }
  ]
  return rows.filter(function (row) { return row !== null })
}

function historyRows(shots, nowMs) {
  var list = Array.isArray(shots) ? shots : []
  var rows = []
  for (var i = 0; i < list.length; i++) {
    var shot = list[i]
    rows.push({
      kind: "shot",
      id: String(shot.path),
      icon: ICON.image,
      label: String(shot.name || basename(shot.path)),
      detail: shotDetail(shot, nowMs),
      path: String(shot.path),
      action: "open-shot"
    })
  }
  rows.push({ kind: "separator", id: "sep-line-back" })
  rows.push({ kind: "action", id: "back", icon: ICON.back, label: "Back to Menu",
    detail: "Esc", action: "menu" })
  rows.push({ kind: "action", id: "reveal-dir", icon: ICON.reveal, label: "Open Export Folder",
    detail: "Show the folder in Files", action: "reveal-dir" })
  return rows
}

// Where the cursor goes when the history list is browsed with the arrows. Only
// shot rows are targets — the Back and Reveal rows sit under the list and are not
// part of walking it — and a direction that runs out of shots stays put, so the
// cursor never wraps from the oldest shot to the newest.
function stepShotRow(rows, from, direction) {
  var list = Array.isArray(rows) ? rows : []
  var step = String(direction || "older") === "newer" ? -1 : 1
  var at = clampIndex(list, from)
  for (var i = at + step; i >= 0 && i < list.length; i += step) {
    if (list[i] && list[i].kind === "shot") return i
  }
  return at
}

// How long ago the shot on the card was taken, for a card that is showing one
// from the history rather than one that was just captured. Empty when the shot is
// not in the list (a temp file, or a capture that has not been listed yet).
function shotAge(shots, path, nowMs) {
  var list = Array.isArray(shots) ? shots : []
  var wanted = String(path || "")
  if (!wanted) return ""
  for (var i = 0; i < list.length; i++) {
    if (String(list[i].path || "") === wanted) {
      var age = formatAge(list[i].mtime, nowMs)
      // The shot on the card was usually taken seconds ago, and "just now" over
      // the picture is noise. The history list keeps it: there it is the answer to
      // when something was taken.
      return age === "just now" ? "" : age
    }
  }
  return ""
}

// The clipboard backend is passed in because the row has to say what a copy will
// actually put there. Without the native helper only the image is copied, and a
// silent downgrade is how "copy and paste does not work" gets reported.
function copyDetail(clipboardBackend) {
  return String(clipboardBackend || "") === "native"
    ? "Image and path on the clipboard"
    : "Image only — run make native for the path"
}

function resultRows(file, clipboardBackend) {
  var name = basename(file)
  return [
    { kind: "action", id: "copy", icon: ICON.copy, label: "Copy",
      detail: copyDetail(clipboardBackend), action: "copy" },
    { kind: "action", id: "annotate", icon: ICON.annotate, label: "Annotate",
      detail: "Open the shot in tensaku", action: "annotate" },
    { kind: "action", id: "share", icon: ICON.share, label: "Share…",
      detail: "Send with LocalSend", action: "share" },
    { kind: "action", id: "reveal", icon: ICON.reveal, label: "Reveal in Files",
      detail: dirname(file), action: "reveal" },
    { kind: "action", id: "delete", icon: ICON.remove, label: "Delete",
      detail: name, action: "delete", urgent: true },
    { kind: "separator", id: "sep-line-result" },
    { kind: "action", id: "back", icon: ICON.back, label: "Back to Menu",
      detail: "Keep the file", action: "menu" }
  ]
}

function settingsRows(settings, dirs) {
  var s = normalizeSettings(settings)
  // Where the files actually go: the setting when it is set, otherwise whatever
  // the Omarchy default resolves to on this machine.
  var where = dirs || {}
  var effective = String(where.effective || "")
  var fallbackDir = String(where.default || "")
  var rows = [
    // Grouped rather than one long list: what shapes the shot, what happens to it
    // afterwards, and where it goes. Headings are labels, not rows to press.
    { kind: "heading", id: "h-capture", label: "Capture" },
    { kind: "value", id: "delay", icon: ICON.timer, label: "Self-Timer",
      detail: "Default wait before a capture starts", value: delayLabel(s.delay),
      action: "cycle-delay" },
    { kind: "toggle", id: "showCursor", icon: ICON.cursor, label: "Show cursor",
      detail: "Draw the pointer into the screenshot", value: s.showCursor,
      action: "toggle-setting", key: "showCursor" },
    { kind: "value", id: "glaze", icon: ICON.glaze, label: "Selection glaze",
      detail: "Lift on the area being captured", value: glazeLabel(s.glaze),
      action: "cycle-glaze" },
    { kind: "value", id: "dim", icon: ICON.glaze, label: "Selection dim",
      detail: "Darken the rest of the screen while aiming", value: dimLabel(s.dim),
      action: "cycle-dim" },
    { kind: "heading", id: "h-after", label: "After a capture" },
    { kind: "toggle", id: "copyToClipboard", icon: ICON.copy, label: "Copy file to clipboard",
      detail: "Every shot goes on the clipboard", value: s.copyToClipboard,
      action: "toggle-setting", key: "copyToClipboard" },
    { kind: "toggle", id: "saveToDisk", icon: ICON.download, label: "Save",
      detail: "Off leaves a temp file behind", value: s.saveToDisk,
      action: "toggle-setting", key: "saveToDisk" },
    { kind: "toggle", id: "showResult", icon: ICON.eye, label: "Show action card",
      detail: "Open the quick access card after a capture", value: s.showResult,
      action: "toggle-setting", key: "showResult" },
    { kind: "toggle", id: "openAnnotate", icon: ICON.annotate, label: "Open annotate tool",
      detail: "Hand the shot straight to tensaku", value: s.openAnnotate,
      action: "toggle-setting", key: "openAnnotate" },
    { kind: "heading", id: "h-files", label: "Files" },
    { kind: "action", id: "exportDir", icon: ICON.open, label: "Export folder",
      detail: effective, value: s.exportDir ? "custom" : "default",
      action: "choose-export-dir" },
    s.exportDir ? { kind: "action", id: "resetExportDir", icon: ICON.back,
      label: "Use the default folder", detail: fallbackDir,
      action: "reset-export-dir" } : null,
    { kind: "toggle", id: "confirmDelete", icon: ICON.alert, label: "Confirm deletion",
      detail: "Ask before a screenshot is deleted", value: s.confirmDelete,
      action: "toggle-setting", key: "confirmDelete" },
    { kind: "value", id: "cardWidth", icon: ICON.window, label: "Card width",
      detail: "The card and its preview grow together", value: cardWidthLabel(s.cardWidth),
      action: "cycle-card-width" },
    { kind: "value", id: "deleteMode", icon: ICON.trash, label: "Delete to",
      detail: "Where a deleted screenshot goes", value: deleteModeLabel(s.deleteMode),
      action: "cycle-delete-mode" },
    { kind: "separator", id: "sep-line-about" },
    { kind: "action", id: "about", icon: ICON.about, label: "About Snapmenu",
      detail: "Version, paths and keybindings", value: "v" + VERSION, action: "about" },
    { kind: "separator", id: "sep-line-settings-back" },
    { kind: "action", id: "back", icon: ICON.back, label: "Back to Menu",
      detail: "Esc", action: "menu" }
  ]
  return rows.filter(function (row) { return row !== null })
}

function aboutRows(state) {
  var s = state || {}
  return [
    { kind: "info", id: "version", icon: ICON.about, label: "Snapmenu", value: "v" + VERSION },
    // About says what this plugin is, not how it or anything else is configured:
    // no settings, and nothing read back out of the desktop's own config. The
    // export folder lives in Settings, and the card's Reveal row opens the folder.
    { kind: "info", id: "plugin-dir", icon: ICON.settings, label: "Plugin folder", value: String(s.pluginDir || "") },
    { kind: "info", id: "author", icon: ICON.author, label: "Author",
      value: "Mathias Bogaert" },
    { kind: "info", id: "license", icon: ICON.about, label: "License", value: "MIT" },
    // A real link out, not a URL to retype: Enter opens it in the browser.
    { kind: "action", id: "github", icon: ICON.github, label: "GitHub",
      detail: "github.com/analytically", action: "open-url",
      url: "https://github.com/analytically" },
    { kind: "action", id: "homepage", icon: ICON.camera, label: "Project page",
      detail: "github.com/analytically/snapmenu", action: "open-url",
      url: "https://github.com/analytically/snapmenu" },
    { kind: "separator", id: "sep-line-about" },
    { kind: "action", id: "back", icon: ICON.back, label: "Back to Menu",
      detail: "Esc", action: "menu" }
  ]
}

// --------------------------------------------------------------- navigation

function rowSelectable(row) {
  if (!row) return false
  if (row.kind === "separator" || row.kind === "info" || row.kind === "heading") return false
  return row.enabled === undefined || row.enabled === true
}

function clampIndex(rows, index) {
  var list = Array.isArray(rows) ? rows : []
  if (list.length === 0) return 0
  var value = Number(index)
  if (!isFinite(value)) return 0
  if (value < 0) return 0
  if (value >= list.length) return list.length - 1
  return Math.floor(value)
}

function firstEnabledIndex(rows) {
  var list = Array.isArray(rows) ? rows : []
  for (var i = 0; i < list.length; i++) {
    if (rowSelectable(list[i])) return i
  }
  return 0
}

// Nearest selectable row at or ahead of `from`, then behind it. Stops at the
// list edges rather than wrapping: a menu that jumps from the last row to the
// first on one keypress is how people capture the wrong thing.
function nearestEnabled(rows, from, direction) {
  var list = Array.isArray(rows) ? rows : []
  if (list.length === 0) return 0
  var index = clampIndex(list, from)
  var step = Number(direction) < 0 ? -1 : 1
  var i = index
  while (i >= 0 && i < list.length) {
    if (rowSelectable(list[i])) return i
    i += step
  }
  i = index - step
  while (i >= 0 && i < list.length) {
    if (rowSelectable(list[i])) return i
    i -= step
  }
  return 0
}

function nextEnabledIndex(rows, from, delta) {
  var list = Array.isArray(rows) ? rows : []
  if (list.length === 0) return 0
  var value = Number(delta)
  if (!isFinite(value) || value === 0) return nearestEnabled(list, from, 1)
  var magnitude = Math.max(1, Math.abs(Math.floor(value)))
  var target = Math.floor(Number(from) || 0) + (value < 0 ? -magnitude : magnitude)
  return nearestEnabled(list, clampIndex(list, target), value < 0 ? -1 : 1)
}

// 1-based positional shortcut (1..9 in the card) counting only rows the user
// could actually activate.
function nthEnabledIndex(rows, position) {
  var list = Array.isArray(rows) ? rows : []
  var wanted = Math.floor(Number(position))
  if (!isFinite(wanted) || wanted < 1) return -1
  var seen = 0
  for (var i = 0; i < list.length; i++) {
    if (!rowSelectable(list[i])) continue
    seen += 1
    if (seen === wanted) return i
  }
  return -1
}
