// Unit tests for SnapmenuModel.js — the plugin's pure logic.
//
// The model is a QML JS library (`.pragma library`, no module syntax) because
// QJSEngine loads it that way. Strip the pragma and evaluate it in a function
// scope, then hand the exports back as an object.
//
//   node --test tests/
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"
import assert from "node:assert/strict"
import test from "node:test"

const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(join(here, "..", "SnapmenuModel.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "")

const EXPORTS = [
  "PLUGIN_ID", "VERSION", "ICON", "ICON_CODEPOINTS", "glyphForCodePoint", "DEFAULT_SETTINGS",
  "DELAY_CHOICES", "localPathFromUrl", "basename", "dirname", "formatBytes", "formatAge",
  "formatDimensions", "shotDetail", "parseRecentShots", "parseCaptureResult", "parseRects", "parseGeometry",
  "candidateRect", "selectionOrDefault", "legendText", "toggleGlyph", "actionHandsOff", "reasonMessage",
  "xdgPicturesDir", "boolValue", "normalizeDelay", "normalizeSettings", "entryFromShellConfig", "settingsFromShellConfig",
  "delayLabel", "nextDelay", "normalizeGlaze", "glazeLabel", "nextGlaze", "GLAZE_CHOICES",
  "normalizeDim", "dimLabel", "nextDim", "DIM_CHOICES", "normalizeDeleteMode", "deleteModeLabel",
  "nextDeleteMode", "DELETE_MODES", "normalizeLevel", "levelLabel", "nextLevel", "shotCountLabel",
  "deleteVerb", "needsConfirm", "indexOfShot", "neighbourShot", "barIcon", "menuRows",
  "CLIPBOARD_IMAGE_TYPES", "clipboardHasImage",
  "historyRows", "resultRows", "settingsRows", "aboutRows", "normalizeDrag", "dragRect",
  "dragConstraintLabel", "dragModeFor", "globalGeometry", "clipRectToBounds", "localRects", "rectAt",
  "rectArea", "windowRects", "nextRect", "rectLabel", "rowSelectable", "clampIndex",
  "firstEnabledIndex", "nearestEnabled", "nextEnabledIndex", "nthEnabledIndex", "stepShotRow", "shotAge",
  "copyDetail",
  "ratioLabel", "ratioName", "dimensionLabel",
  "RATIOS", "RATIO_TOLERANCE", "normalizeCardWidth", "cardWidthLabel", "nextCardWidth", "prevCardWidth",
  "dragCardWidth", "CARD_WIDTHS"
]

const Model = new Function(
  source + "\nreturn {" + EXPORTS.join(",") + "};"
)()

test("plugin identity is a valid, non-reserved id", () => {
  assert.equal(Model.PLUGIN_ID, "io.github.analytically.snapmenu")
  assert.match(Model.PLUGIN_ID, /^[A-Za-z0-9][A-Za-z0-9._-]*$/)
  assert.ok(!Model.PLUGIN_ID.startsWith("omarchy."))
})

test("every icon is one glyph at its documented codepoint", () => {
  for (const [name, codepoint] of Object.entries(Model.ICON_CODEPOINTS)) {
    assert.equal(typeof codepoint, "number", name)
    assert.ok(codepoint >= 0xE000 && codepoint <= 0x10FFFD, `${name} lives in a private use area`)

    const glyph = Model.ICON[name]
    assert.equal(typeof glyph, "string", name)
    assert.equal([...glyph].length, 1, `${name} must be one codepoint`)
    assert.equal([...glyph][0].codePointAt(0), codepoint, `${name} codepoint`)
  }
})

test("glyphForCodePoint builds surrogate pairs for the astral plane", () => {
  assert.equal(Model.glyphForCodePoint(0xF030), "\uF030")
  assert.equal(Model.glyphForCodePoint(0xF0101), "\uDB80\uDD01")
  assert.equal([...Model.glyphForCodePoint(0xF0101)][0].codePointAt(0), 0xF0101)
  assert.equal(Model.glyphForCodePoint(-1), "")
  assert.equal(Model.glyphForCodePoint("nope"), "")
})

test("localPathFromUrl unwraps file URLs and trims the trailing slash", () => {
  assert.equal(
    Model.localPathFromUrl("file:///home/me/.config/omarchy/plugins/x.y.z/"),
    "/home/me/.config/omarchy/plugins/x.y.z"
  )
  assert.equal(
    Model.localPathFromUrl("file:///home/me/My%20Plugins/x"),
    "/home/me/My Plugins/x"
  )
  assert.equal(Model.localPathFromUrl("/already/a/path"), "/already/a/path")
  assert.equal(Model.localPathFromUrl(""), "")
})

test("basename/dirname", () => {
  assert.equal(Model.basename("/a/b/screenshot-1.png"), "screenshot-1.png")
  assert.equal(Model.basename("shot.png"), "shot.png")
  assert.equal(Model.dirname("/a/b/shot.png"), "/a/b")
  assert.equal(Model.dirname("shot.png"), "/")
})

test("formatBytes", () => {
  assert.equal(Model.formatBytes(0), "0 B")
  assert.equal(Model.formatBytes(512), "512 B")
  assert.equal(Model.formatBytes(2048), "2 KB")
  assert.equal(Model.formatBytes(5 * 1024 * 1024), "5.0 MB")
  assert.equal(Model.formatBytes(3 * 1024 * 1024 * 1024), "3.0 GB")
  assert.equal(Model.formatBytes(-1), "")
  assert.equal(Model.formatBytes("nope"), "")
})

test("formatAge", () => {
  const now = 1_700_000_000_000
  assert.equal(Model.formatAge(now - 5_000, now), "just now")
  assert.equal(Model.formatAge(now - 5 * 60_000, now), "5 min ago")
  assert.equal(Model.formatAge(now - 3 * 3_600_000, now), "3 hours ago")
  assert.equal(Model.formatAge(now - 2 * 86_400_000, now), "2 days ago")
  assert.match(Model.formatAge(now - 60 * 86_400_000, now), /^\d{4}-\d{2}-\d{2}$/)
})

test("parseRecentShots sorts newest first, limits, ignores junk", () => {
  const stdout = [
    "1700000000\t1024\t/home/me/Pictures/old.png",
    "1700000500\t2048\t/home/me/Pictures/new.png",
    "",
    "not-a-shot",
    "1700000100\t512\t/home/me/Pictures/middle.png"
  ].join("\n")

  const all = Model.parseRecentShots(stdout, 0)
  assert.deepEqual(all.map((s) => s.name), ["new.png", "middle.png", "old.png"])
  assert.equal(all[0].size, 2048)
  assert.equal(all[0].mtime, 1_700_000_500_000)

  assert.equal(Model.parseRecentShots(stdout, 2).length, 2)
  assert.deepEqual(Model.parseRecentShots("", 5), [])
})

test("parseCaptureResult reads the helper's JSON line", () => {
  const ok = Model.parseCaptureResult(
    '{"ok":true,"path":"/tmp/shot.png","width":1600,"height":900,"mode":"region","temporary":false}\n'
  )
  assert.deepEqual(ok, {
    ok: true, path: "/tmp/shot.png", reason: "", width: 1600, height: 900,
    mode: "region", temporary: false, originX: 0, originY: 0, monitor: null, cropper: false,
    noAnim: false
  })

  // Whether the helper found a cropper decides if the picker may skip waiting
  // for its own chrome to leave the screen before cropping; a missing field
  // must mean "no", so the safe path is the default.
  assert.equal(Model.parseCaptureResult('{"ok":true,"cropper":true}').cropper, true)
  assert.equal(Model.parseCaptureResult('{"ok":true,"cropper":false}').cropper, false)
  assert.equal(Model.parseCaptureResult('{"ok":true}').cropper, false)
  // The animation rule report, so the plugin can tell whether the picker is
  // protected from the compositor's layer fade.
  assert.equal(Model.parseCaptureResult('{"ok":true,"noAnim":true}').noAnim, true)
  assert.equal(Model.parseCaptureResult('{"ok":true,"noAnim":false}').noAnim, false)

  const freeze = Model.parseCaptureResult(
    '{"ok":true,"mode":"freeze","path":"/state/freeze.png","temporary":false,'
    + '"x":-1920,"y":0,"width":1920,"height":1080,'
    + '"monitor":{"kind":"monitor","name":"DP-1","x":-1920,"y":0,"width":1920,"height":1080}}'
  )
  assert.equal(freeze.ok, true)
  assert.equal(freeze.mode, "freeze")
  assert.equal(freeze.originX, -1920)
  assert.equal(freeze.monitor.name, "DP-1")
  assert.equal(freeze.cropper, false)

  const cancelled = Model.parseCaptureResult('{"ok":false,"reason":"cancelled"}\n')
  assert.equal(cancelled.ok, false)
  assert.equal(cancelled.reason, "cancelled")

  const noise = Model.parseCaptureResult("some warning\n{\"unrelated\":true}\n")
  assert.equal(noise.ok, false)
  assert.equal(noise.reason, "no-output")
  assert.equal(Model.parseCaptureResult("").reason, "no-output")
})

test("parseRects reads the snapping rectangles", () => {
  const stdout = '{"ok":true,"monitor":{"kind":"monitor","x":0,"y":0,"width":1800,"height":1125},'
    + '"rects":[{"kind":"monitor","x":0,"y":0,"width":1800,"height":1125},'
    + '{"kind":"window","x":12,"y":38,"width":881,"height":531}]}\n'
  const parsed = Model.parseRects(stdout)
  assert.equal(parsed.ok, true)
  assert.equal(parsed.rects.length, 2)
  assert.equal(parsed.rects[1].kind, "window")
  assert.equal(parsed.rects[1].width, 881)

  assert.deepEqual(Model.parseRects(""), { ok: false, rects: [], monitor: null })
  assert.deepEqual(Model.parseRects("{\"ok\":false}\n").rects, [])
})

test("parseGeometry accepts grim's geometry syntax", () => {
  assert.deepEqual(Model.parseGeometry("100,200 300x400"),
    { x: 100, y: 200, width: 300, height: 400 })
  assert.deepEqual(Model.parseGeometry("-1920,0 100x50"),
    { x: -1920, y: 0, width: 100, height: 50 })
  assert.deepEqual(Model.parseGeometry("  10 , 20   30x40 "),
    { x: 10, y: 20, width: 30, height: 40 })
  assert.equal(Model.parseGeometry("10,20 0x40"), null)
  assert.equal(Model.parseGeometry("nonsense"), null)
  assert.equal(Model.parseGeometry(""), null)
  assert.equal(Model.parseGeometry(null), null)
})

test("normalizeDrag rounds to whole pixels from any corner order", () => {
  assert.deepEqual(Model.normalizeDrag(100, 200, 300, 400),
    { x: 100, y: 200, width: 200, height: 200 })
  assert.deepEqual(Model.normalizeDrag(300.4, 400.6, 100.2, 200.2),
    { x: 100, y: 200, width: 200, height: 201 })
  assert.deepEqual(Model.normalizeDrag(50, 50, 50, 50),
    { x: 50, y: 50, width: 0, height: 0 })
})

test("dragRect honours the drag modifiers", () => {
  const bounds = { width: 1800, height: 1125 }

  // Free: both axes follow the pointer.
  assert.deepEqual(Model.dragRect({ anchorX: 100, anchorY: 100, pointerX: 300, pointerY: 250,
    mode: "free", bounds }), { x: 100, y: 100, width: 200, height: 150 })

  // Shift: the height is frozen and only the width moves, anchored where the
  // drag started.
  assert.deepEqual(Model.dragRect({ anchorX: 100, anchorY: 100, pointerX: 500, pointerY: 900,
    mode: "width", lockedHeight: 150, bounds }), { x: 100, y: 100, width: 400, height: 150 })
  assert.deepEqual(Model.dragRect({ anchorX: 400, anchorY: 100, pointerX: 100, pointerY: 900,
    mode: "width", lockedHeight: 150, bounds }), { x: 100, y: 100, width: 300, height: 150 })

  // Nothing to freeze: a free drag, not a degenerate band.
  assert.deepEqual(Model.dragRect({ anchorX: 100, anchorY: 100, pointerX: 300, pointerY: 250,
    mode: "width", lockedHeight: 0, bounds }), { x: 100, y: 100, width: 200, height: 150 })

  // A frozen height that would run off the monitor is trimmed, not allowed out.
  assert.deepEqual(Model.dragRect({ anchorX: 100, anchorY: 1000, pointerX: 400, pointerY: 1100,
    mode: "width", lockedHeight: 400, bounds }), { x: 100, y: 1000, width: 300, height: 125 })

  // Shift+Ctrl: the mirror of Shift — the width is frozen and the height moves,
  // anchored where the drag started and trimmed to the monitor's right edge.
  assert.deepEqual(Model.dragRect({ anchorX: 100, anchorY: 100, pointerX: 900, pointerY: 500,
    mode: "height", lockedWidth: 200, bounds }), { x: 100, y: 100, width: 200, height: 400 })
  assert.deepEqual(Model.dragRect({ anchorX: 400, anchorY: 600, pointerX: 100, pointerY: 200,
    mode: "height", lockedWidth: 150, bounds }), { x: 400, y: 200, width: 150, height: 400 })
  assert.deepEqual(Model.dragRect({ anchorX: 100, anchorY: 100, pointerX: 300, pointerY: 250,
    mode: "height", lockedWidth: 0, bounds }), { x: 100, y: 100, width: 200, height: 150 })
  assert.deepEqual(Model.dragRect({ anchorX: 1700, anchorY: 100, pointerX: 1750, pointerY: 400,
    mode: "height", lockedWidth: 400, bounds }), { x: 1700, y: 100, width: 100, height: 300 })

  // Ctrl: the ratio holds however the pointer moves, and the dominant axis is
  // the one that travelled furthest.
  const wide = Model.dragRect({ anchorX: 0, anchorY: 0, pointerX: 1600, pointerY: 450,
    mode: "ratio", ratio: 16 / 9, bounds })
  assert.equal(Math.round((wide.width / wide.height) * 100) / 100, 1.78)
  assert.equal(wide.x, 0)
  assert.equal(wide.y, 0)

  // Dragging up and left keeps the ratio and stays anchored at the pointer's side.
  assert.deepEqual(Model.dragRect({ anchorX: 800, anchorY: 600, pointerX: 300, pointerY: 100,
    mode: "ratio", ratio: 1, bounds }), { x: 300, y: 100, width: 500, height: 500 })

  // With nothing to lock onto, the monitor's own shape is the ratio — NOT the
  // pointer's first movement, which is always mostly sideways and made Ctrl look
  // like a horizontal (or free) drag.
  const fresh = Model.dragRect({ anchorX: 0, anchorY: 0, pointerX: 200, pointerY: 100,
    mode: "ratio", ratio: 0, bounds })
  assert.equal(Math.round((fresh.width / fresh.height) * 100) / 100, 1.6)
  assert.deepEqual(fresh, { x: 0, y: 0, width: 200, height: 125 })

  // A ratio too wide for the monitor is scaled down rather than clipped.
  const tall = Model.dragRect({ anchorX: 0, anchorY: 0, pointerX: 1800, pointerY: 5,
    mode: "ratio", ratio: 10, bounds })
  assert.ok(tall.width <= bounds.width && tall.height <= bounds.height)
  assert.equal(Math.round((tall.width / tall.height) * 100) / 100, 10)
})

test("dragModeFor maps the modifiers the picker reads", () => {
  assert.equal(Model.dragModeFor(false, false), "free")
  // Shift widens a band, and so does Ctrl.
  assert.equal(Model.dragModeFor(true, false), "width")
  assert.equal(Model.dragModeFor(false, true), "width")
  // Together they run a column.
  assert.equal(Model.dragModeFor(true, true), "height")

  // The ratio lock is still implemented in dragRect, it is simply not bound to
  // a modifier any more: re-binding it is a change to this one mapping.
  assert.equal(Model.dragConstraintLabel("ratio"), "aspect locked")
  const locked = Model.dragRect({ anchorX: 0, anchorY: 0, pointerX: 400, pointerY: 400,
    mode: "ratio", ratio: 2, bounds: { width: 1800, height: 1125 } })
  assert.equal(locked.width / locked.height, 2)
  assert.deepEqual(locked, { x: 0, y: 0, width: 800, height: 400 })
})

test("the picker legend names the active drag constraint", () => {
  assert.equal(Model.dragConstraintLabel("free"), "")
  assert.equal(Model.dragConstraintLabel("width"), "width only")
  assert.equal(Model.dragConstraintLabel("height"), "height only")
  assert.equal(Model.dragConstraintLabel("ratio"), "aspect locked")
  assert.equal(Model.dragConstraintLabel("nonsense"), "")
})

test("globalGeometry adds the monitor origin and refuses empty rects", () => {
  assert.equal(Model.globalGeometry({ x: 10, y: 20, width: 100, height: 50 }, 0, 0),
    "10,20 100x50")
  assert.equal(Model.globalGeometry({ x: 10, y: 20, width: 100, height: 50 }, -1920, 0),
    "-1910,20 100x50")
  assert.equal(Model.globalGeometry({ x: 1, y: 1, width: 0, height: 50 }, 0, 0), "")
  assert.equal(Model.globalGeometry(null, 0, 0), "")
})

test("localRects translates to the overlay and clips to the frozen monitor", () => {
  const rects = [
    { kind: "monitor", x: -1920, y: 0, width: 1920, height: 1080 },
    { kind: "window", x: -1900, y: 40, width: 400, height: 300 },
    { kind: "window", x: 0, y: 0, width: 800, height: 600 } // other monitor
  ]
  const local = Model.localRects(rects, -1920, 0, 1920, 1080)
  assert.equal(local.length, 2)
  assert.deepEqual(local[0],
    { kind: "monitor", label: "", x: 0, y: 0, width: 1920, height: 1080 })
  assert.deepEqual(local[1],
    { kind: "window", label: "", x: 20, y: 40, width: 400, height: 300 })

  const straddling = Model.localRects(
    [{ kind: "window", x: 1900, y: 0, width: 200, height: 200 }], 0, 0, 1920, 1080)
  assert.deepEqual(straddling,
    [{ kind: "window", label: "", x: 1900, y: 0, width: 20, height: 200 }])

  assert.equal(Model.clipRectToBounds({ x: 5000, y: 0, width: 10, height: 10 },
    { x: 0, y: 0, width: 100, height: 100 }), null)
})

test("rectAt picks the smallest covering rect", () => {
  const rects = [
    { kind: "monitor", x: 0, y: 0, width: 1920, height: 1080 },
    { kind: "window", x: 100, y: 100, width: 400, height: 400 },
    { kind: "window", x: 150, y: 150, width: 100, height: 100 }
  ]
  assert.equal(Model.rectAt(rects, 200, 200).width, 100)
  assert.equal(Model.rectAt(rects, 300, 300).width, 400)
  assert.equal(Model.rectAt(rects, 1900, 1000).kind, "monitor")
  assert.equal(Model.rectAt(rects, -5, -5), null)
  assert.equal(Model.rectAt([], 10, 10), null)
  assert.equal(Model.rectArea({ width: 3, height: 4 }), 12)
})

test("candidateRect resolves the unified capture row from the gesture", () => {
  const windowRect = { kind: "window", label: "Editor", x: 12, y: 38, width: 881, height: 531 }
  const hoverRect = { kind: "window", label: "Browser", x: 907, y: 38, width: 881, height: 1075 }
  const drag = { x: 100, y: 100, width: 200, height: 150 }

  // Drag beats everything: a freeform selection is an explicit gesture.
  assert.deepEqual(Model.candidateRect({
    dragging: true, selection: drag, keyboardActive: true, keyboardRect: windowRect,
    hoverRect: hoverRect, unified: true
  }), drag)

  // A keyboard pick beats the pointer, so Tab is stable while the mouse sits still.
  assert.deepEqual(Model.candidateRect({
    keyboardActive: true, keyboardRect: windowRect, hoverRect: hoverRect, unified: true
  }), windowRect)

  // Pointer hover only counts in the unified modes.
  assert.deepEqual(Model.candidateRect({ hoverRect: hoverRect, unified: true }), hoverRect)
  assert.equal(Model.candidateRect({ hoverRect: hoverRect, unified: false }), null)

  // The release path: the picker tells the model whether a drag actually happened. A
  // drag takes the rectangle that was dragged; anything else is a click, and in the
  // unified mode a click takes the window under the pointer. Getting this backwards
  // is what captured the window a rectangle was dragged over.
  const released = {
    selection: drag, hoverRect: hoverRect, unified: true,
    monitorWidth: 1800, monitorHeight: 1125
  }
  assert.deepEqual(Model.selectionOrDefault({ ...released, dragging: true }), drag)
  assert.deepEqual(Model.selectionOrDefault({ ...released, dragging: false }), hoverRect)
  // A click with nothing hovered and a selection the picker did *not* clear (it clears
  // them below its own drag threshold) still resolves to that selection, not the monitor.
  assert.deepEqual(Model.selectionOrDefault({ ...released, hoverRect: null, dragging: false }), drag)

  // Nothing picked at all.
  assert.equal(Model.candidateRect({}), null)
  assert.equal(Model.candidateRect(null), null)
})

test("selectionOrDefault falls back to the whole monitor", () => {
  const monitor = { monitorWidth: 1800, monitorHeight: 1125 }
  assert.deepEqual(Model.selectionOrDefault(monitor),
    { kind: "monitor", label: "", x: 0, y: 0, width: 1800, height: 1125 })

  // A degenerate drag is treated as no selection at all.
  assert.deepEqual(Model.selectionOrDefault({
    dragging: false, selection: { x: 5, y: 5, width: 0, height: 0 }, ...monitor
  }), { kind: "monitor", label: "", x: 0, y: 0, width: 1800, height: 1125 })

  // With no monitor size there is nothing to capture, so nothing is emitted.
  assert.equal(Model.selectionOrDefault({}), null)

  const picked = { x: 1, y: 2, width: 3, height: 4 }
  assert.deepEqual(Model.selectionOrDefault({ selection: picked, ...monitor }), picked)
})

test("toggleGlyph picks the checkbox for the value", () => {
  assert.equal(Model.toggleGlyph(true), Model.ICON.toggleOn)
  assert.equal(Model.toggleGlyph(false), Model.ICON.toggleOff)
  assert.equal(Model.toggleGlyph(undefined), Model.ICON.toggleOff)
  assert.equal(Model.toggleGlyph("true"), Model.ICON.toggleOff) // only real booleans count
})

test("legendText explains each mode's gestures", () => {
  assert.match(Model.legendText("smart"), /click for the screen/)
  assert.match(Model.legendText("smart"), /Tab cycles/)
  assert.match(Model.legendText("region"), /Drag a region/)
  assert.equal(Model.legendText("region").includes("Tab"), false)
  assert.match(Model.legendText("window"), /^Click a window/)
  assert.equal(Model.legendText(""), Model.legendText("region"))
})

test("reasonMessage covers every reason the helper emits", () => {
  for (const reason of ["cancelled", "no-previous", "no-image", "clipboard-failed",
    "grim-failed", "grim-missing", "helper-failed", "write-failed",
    "picker-missing", "no-output", "freeze-failed", "no-monitor", "no-request", "delete-failed"]) {
    const message = Model.reasonMessage(reason)
    assert.equal(typeof message, "string")
    assert.ok(message.length > 0, reason)
    assert.ok(!message.includes("undefined"), reason)
  }
  assert.match(Model.reasonMessage("weird-new-reason"), /weird-new-reason/)
})

test("xdgPicturesDir reads the user-dirs file", () => {
  const file = 'XDG_DESKTOP_DIR="$HOME/Desktop"\nXDG_PICTURES_DIR="$HOME/Shots"\n'
  assert.equal(Model.xdgPicturesDir(file, "/home/me"), "/home/me/Shots")
  assert.equal(Model.xdgPicturesDir("", "/home/me"), "")
  assert.equal(Model.xdgPicturesDir('XDG_PICTURES_DIR=""', "/home/me"), "")
})

test("deleteVerb describes where the shot went", () => {
  assert.equal(Model.deleteVerb("trash"), "Moved to trash")
  assert.equal(Model.deleteVerb("delete"), "Deleted")
  assert.equal(Model.deleteVerb("missing"), "Already gone")
  assert.equal(Model.deleteVerb(""), "Deleted")
  assert.equal(Model.deleteVerb(undefined), "Deleted")
})

test("shell.json lookups find the bar slot, then plugins[]", () => {
  const barConfig = JSON.stringify({
    version: 1,
    bar: { layout: { left: [], center: [], right: [{ id: Model.PLUGIN_ID, exportDir: "/tmp/shots" }] } }
  })
  const entry = Model.entryFromShellConfig(barConfig, Model.PLUGIN_ID)
  assert.equal(entry.exportDir, "/tmp/shots")

  const pluginConfig = JSON.stringify({
    version: 1,
    bar: { layout: { left: [], center: [], right: [] } },
    plugins: [{ id: Model.PLUGIN_ID, delay: 5 }]
  })
  assert.equal(Model.entryFromShellConfig(pluginConfig, Model.PLUGIN_ID).delay, 5)

  const stringEntry = JSON.stringify({
    bar: { layout: { left: [], center: [], right: [Model.PLUGIN_ID] } }
  })
  assert.deepEqual(Model.entryFromShellConfig(stringEntry, Model.PLUGIN_ID), { id: Model.PLUGIN_ID })

  assert.equal(Model.entryFromShellConfig(barConfig, "someone.else"), null)
  assert.equal(Model.entryFromShellConfig("{ not json", Model.PLUGIN_ID), null)
  assert.equal(Model.entryFromShellConfig("", Model.PLUGIN_ID), null)
})

test("settings fall back to defaults and coerce hand-edited values", () => {
  assert.deepEqual(Model.settingsFromShellConfig("", Model.PLUGIN_ID), Model.DEFAULT_SETTINGS)

  const raw = JSON.stringify({
    bar: { layout: { right: [{ id: Model.PLUGIN_ID, copyToClipboard: "false", saveToDisk: "no", delay: 7 }] } }
  })
  const settings = Model.settingsFromShellConfig(raw, Model.PLUGIN_ID)
  assert.equal(settings.copyToClipboard, false)
  assert.equal(settings.saveToDisk, false)
  assert.equal(settings.delay, 0) // 7 is not one of the offered steps
  assert.equal(settings.showResult, true) // untouched default
})

test("delay helpers cycle through the offered steps", () => {
  assert.equal(Model.delayLabel(0), "Off")
  assert.equal(Model.delayLabel(3), "3 s")
  assert.deepEqual(Model.DELAY_CHOICES, [0, 3, 5, 10, 15])
  assert.equal(Model.nextDelay(0), 3)
  assert.equal(Model.nextDelay(3), 5)
  assert.equal(Model.nextDelay(5), 10)
  assert.equal(Model.nextDelay(10), 15)
  assert.equal(Model.nextDelay(15), 0)
  assert.equal(Model.delayLabel(15), "15 s")
  assert.equal(Model.nextDelay(99), 3) // unknown value is read as Off first
})

test("the glaze steps through its levels, and snaps when hand-edited", () => {
  // 0.05 was invisible and 0.16 was raised as too much: the levels sit between
  // them and the default is the middle one.
  assert.equal(Model.DEFAULT_SETTINGS.glaze, 0.1)
  assert.equal(Model.glazeLabel(0), "Off")
  assert.equal(Model.glazeLabel(0.06), "Subtle")
  assert.equal(Model.glazeLabel(0.1), "Light")
  assert.equal(Model.glazeLabel(0.14), "Medium")
  assert.equal(Model.glazeLabel(0.2), "Strong")
  assert.deepEqual(Model.GLAZE_CHOICES.map((c) => c.value), [0, 0.06, 0.1, 0.14, 0.2])

  assert.equal(Model.nextGlaze(0), 0.06)
  assert.equal(Model.nextGlaze(0.1), 0.14)
  assert.equal(Model.nextGlaze(0.2), 0) // wraps back to Off
  assert.equal(Model.nextGlaze(0.16), 0.2) // unknown reads as the nearest level

  // A shell.json someone typed by hand is snapped, not rejected.
  assert.equal(Model.glazeLabel(0.15), "Medium")
  assert.equal(Model.glazeLabel(0.02), "Off")
  assert.equal(Model.glazeLabel(-1), "Off")
  assert.equal(Model.glazeLabel("nonsense"), "Light")
})

test("settings lines fit the row they are on", () => {
  // The settings rows carry a value or a checkbox on the right, which leaves the
  // detail about 44 characters before it is elided mid-word.
  for (const row of Model.settingsRows({}, {})) {
    if (row.kind === "separator" || row.kind === "action") continue // paths and labels are their own thing
    if (!row.detail) continue
    assert.ok(row.detail.length <= 44, `${row.id}: ${row.detail.length} chars — ${row.detail}`)
  }
})

test("the dim is a setting too, off by default", () => {
  assert.equal(Model.DEFAULT_SETTINGS.dim, 0)
  assert.equal(Model.dimLabel(0), "Off")
  assert.equal(Model.dimLabel(0.25), "Light")
  assert.equal(Model.dimLabel(0.4), "Medium")
  assert.equal(Model.dimLabel(0.55), "Strong")
  assert.equal(Model.nextDim(0), 0.25)
  assert.equal(Model.nextDim(0.55), 0) // wraps
  assert.equal(Model.nextDim("nonsense"), 0.25) // unknown reads as the nearest step
  assert.equal(Model.dimLabel(0.5), "Strong")
  assert.equal(Model.dimLabel(-3), "Off")
})

test("deleting goes to the trash unless the setting says otherwise", () => {
  // Safe by default: the file manager can still get it back.
  assert.equal(Model.DEFAULT_SETTINGS.deleteMode, "trash")
  assert.equal(Model.deleteModeLabel("trash"), "Trash")
  assert.equal(Model.deleteModeLabel("permanently"), "Permanently")
  assert.equal(Model.nextDeleteMode("trash"), "permanently")
  assert.equal(Model.nextDeleteMode("permanently"), "trash")
  // Anything unrecognised is read as the recoverable choice.
  assert.equal(Model.deleteModeLabel("shred"), "Trash")
  assert.equal(Model.deleteModeLabel(true), "Trash")
  assert.equal(Model.deleteModeLabel(undefined), "Trash")

  const s = Model.normalizeSettings({ deleteMode: "permanently" })
  assert.equal(s.deleteMode, "permanently")
  assert.equal(Model.normalizeSettings({ deleteMode: "nope" }).deleteMode, "trash")
})

test("the history list is walked from the newest shot to the oldest", () => {
  const shots = [0, 1, 2].map((i) => ({
    path: `/p/${i}.png`, name: `${i}.png`, size: 1024, mtime: 1_700_000_000_000 - i * 1000
  }))
  const rows = Model.historyRows(shots, 1_700_000_060_000)
  assert.deepEqual(rows.filter((r) => r.kind === "shot").map((r) => r.label),
    ["0.png", "1.png", "2.png"]) // newest first

  // Walking it: "older" is further down the list, "newer" is back up, and the
  // ends hold instead of wrapping around.
  assert.equal(Model.stepShotRow(rows, 0, "older"), 1)
  assert.equal(Model.stepShotRow(rows, 1, "older"), 2)
  assert.equal(Model.stepShotRow(rows, 2, "older"), 2)
  assert.equal(Model.stepShotRow(rows, 2, "newer"), 1)
  assert.equal(Model.stepShotRow(rows, 0, "newer"), 0)
  // Rows below the list (Back, Reveal) are not shot rows and are never landed on.
  const last = rows.length - 1
  assert.equal(Model.stepShotRow(rows, last, "newer"), 2)
  assert.equal(rows[Model.stepShotRow(rows, Model.stepShotRow(rows, 0, "older"), "older")].kind, "shot")
  // An empty history has nowhere to go.
  assert.equal(Model.stepShotRow([], 0, "older"), 0)
})

test("the card can say how long ago the shot it is showing was taken", () => {
  const now = 1_700_000_600_000
  const shots = [
    { path: "/p/new.png", name: "new.png", size: 1024, mtime: now - 5_000 },
    { path: "/p/old.png", name: "old.png", size: 1024, mtime: now - 25 * 60_000 }
  ]
  // A shot taken seconds ago says nothing about its age on the card: "just now" over
  // the picture is noise. The history list is where that belongs, and keeps it.
  assert.equal(Model.shotAge(shots, "/p/new.png", now), "")
  assert.match(Model.shotDetail(shots[0], now), /just now/)
  assert.equal(Model.shotAge(shots, "/p/old.png", now), "25 min ago")
  // Nothing to say for a shot that is not in the list (a temp file, or one that
  // has not been listed yet), and nothing to crash on either.
  assert.equal(Model.shotAge(shots, "/p/temp.png", now), "")
  assert.equal(Model.shotAge(shots, "", now), "")
  assert.equal(Model.shotAge([], "/p/new.png", now), "")
  assert.equal(Model.shotAge(null, "/p/new.png", now), "")
})

test("Open from Clipboard is only offered when there is an image to open", () => {
  // The row writes the clipboard's image out to a file. A text payload — a path, a
  // URL, a paragraph — has nothing for it to open, so the row is not offered: the
  // same treatment Capture Previous Area gets with nothing to repeat.
  assert.equal(Model.clipboardHasImage("image/png\n"), true)
  assert.equal(Model.clipboardHasImage("text/plain\ntext/uri-list\n"), false)
  assert.equal(Model.clipboardHasImage(""), false)
  assert.equal(Model.clipboardHasImage("   "), false)
  // Types arrive one per line and the wanted one is rarely first.
  assert.equal(Model.clipboardHasImage("text/plain\nimage/jpeg\n"), true)
  // An image type the import cannot write out is not an image it can open: the row
  // would appear and then fail with "no image on the clipboard".
  assert.equal(Model.clipboardHasImage("image/svg+xml\n"), false)
  assert.equal(Model.clipboardHasImage("image/x-icon\n"), false)

  const withImage = Model.menuRows({ hasClipboardImage: true })
  const row = withImage.find((entry) => entry.id === "from-clipboard")
  assert.ok(row, "the row appears with an image on the clipboard")
  assert.equal(row.label, "Open from Clipboard")
  assert.deepEqual(row.payload, { action: "from-clipboard" })
  assert.equal(row.detail, undefined)
  assert.equal(Model.menuRows({ hasClipboardImage: false }).some((entry) => entry.id === "from-clipboard"), false)
  assert.equal(Model.menuRows({}).some((entry) => entry.id === "from-clipboard"), false)
  // Hidden, not disabled: a row that cannot be used is not a row to explain.
  assert.equal(withImage.some((entry) => entry === null), false)
})

test("the model and the capture script agree about which images can be opened", () => {
  // The list lives in two places — the model decides whether to offer the row, the
  // script decides whether it can write the image out — and a change in one that
  // misses the other is a row that appears and then fails.
  const script = readFileSync(join(here, "..", "bin", "snapmenu-capture.sh"), "utf8")
  const line = script.split("\n").find((l) => /for candidate in image\//.test(l))
  assert.ok(line, "the script still lists candidate image types")
  const types = line.replace(/.*for candidate in /, "").replace(/;.*$/, "").trim().split(/\s+/)
  assert.deepEqual(types, Model.CLIPBOARD_IMAGE_TYPES)
})

test("each capture row is drawn with its own glyph", () => {
  // The previous-area row lost its glyph to a copy of another row once already:
  // repeat, refresh and camera are three different promises on a menu.
  const ids = ["region-or-window", "area", "previous", "fullscreen", "window", "record"]
  const glyphs = Model.menuRows({ hasPrevious: true }).filter((r) => ids.includes(r.id)).map((r) => r.icon)
  assert.equal(glyphs.length, ids.length)
  assert.equal(new Set(glyphs).size, glyphs.length, "capture rows share a glyph: " + glyphs.join(" "))
  // Icons may be numbers or already-rendered glyphs depending on how the model is
  // loaded, so compare the codepoint, which is the actual decision.
  assert.equal(String(Model.ICON.previous).codePointAt(0), 0xF0450)
})

test("the named-level engine is the same one every stepped setting uses", () => {
  // Glaze, dim and card width all delegate to these three. A fault here would be a
  // fault in every one of them, so they are tested where they live.
  assert.equal(Model.normalizeLevel(Model.GLAZE_CHOICES, 0.16, 0.1), 0.14)
  // Exactly between two steps, and it resolves downwards rather than up: a tie has
  // to go somewhere, and the lower step is the one that was asked for less.
  assert.equal(Model.normalizeLevel(Model.GLAZE_CHOICES, 0.17, 0.1), 0.14)
  assert.equal(Model.normalizeLevel(Model.GLAZE_CHOICES, 0.03, 0.1), 0)
  assert.equal(Model.normalizeLevel(Model.GLAZE_CHOICES, "nonsense", 0.1), 0.1)
  // An explicit null is a number to JS (0), so it snaps to the lowest step; it is
  // undefined, and genuine junk, that take the fallback.
  assert.equal(Model.normalizeLevel(Model.GLAZE_CHOICES, null, 0.1), 0)
  assert.equal(Model.normalizeLevel(Model.GLAZE_CHOICES, undefined, 0.1), 0.1)
  assert.equal(Model.normalizeLevel(Model.GLAZE_CHOICES, -5, 0.1), 0) // clamps to the lowest step
  assert.equal(Model.normalizeLevel(Model.GLAZE_CHOICES, 99, 0.1), 0.2) // and the highest
  assert.equal(Model.levelLabel(Model.GLAZE_CHOICES, 0.06, 0.1), "Subtle")
  assert.equal(Model.levelLabel(Model.GLAZE_CHOICES, -1, 0.1), "Off")
  assert.equal(Model.nextLevel(Model.GLAZE_CHOICES, 0.2, 0.1), 0) // wraps
  assert.equal(Model.nextLevel(Model.DIM_CHOICES, 0, 0), 0.25)
  assert.equal(Model.nextLevel(Model.CARD_WIDTHS, 700, 440), 360) // shared by the card too
})

test("every stepped setting keeps its own steps in order", () => {
  for (const [name, choices] of Object.entries({
    GLAZE_CHOICES: Model.GLAZE_CHOICES,
    DIM_CHOICES: Model.DIM_CHOICES,
    CARD_WIDTHS: Model.CARD_WIDTHS
  })) {
    assert.ok(choices.length >= 2, name + " offers a choice")
    const values = choices.map((c) => c.value)
    assert.deepEqual(values, values.slice().sort((a, b) => a - b), name + " is in ascending order")
    assert.equal(new Set(values).size, values.length, name + " has no duplicate step")
    assert.equal(values[0], Math.min(...values), name + " starts at its lowest step")
    for (const choice of choices) {
      assert.equal(typeof choice.label, "string", name + " labels every step")
      assert.ok(choice.label.length > 0, name + " label is not empty")
      assert.ok(Number.isFinite(choice.value), name + " has a finite value")
    }
  }
  // The defaults offered in the settings are steps that exist.
  assert.ok(Model.GLAZE_CHOICES.some((c) => c.value === Model.DEFAULT_SETTINGS.glaze))
  assert.ok(Model.DIM_CHOICES.some((c) => c.value === Model.DEFAULT_SETTINGS.dim))
  assert.ok(Model.CARD_WIDTHS.some((c) => c.value === Model.DEFAULT_SETTINGS.cardWidth))
  assert.ok(Model.DELETE_MODES.some((m) => m.value === Model.DEFAULT_SETTINGS.deleteMode))
})

test("the ratio table has no entry that can never be reached", () => {
  // Every offered ratio must win for some shape: an entry that is always beaten by
  // a neighbour is a label that can never appear, which is worse than not listing
  // it. This is what would catch a duplicated or too-closely-spaced entry.
  for (const entry of Model.RATIOS) {
    const near = entry.ratio
    assert.equal(Model.ratioLabel(near * 1000, 1000), entry.label,
      entry.label + " is reachable at its own ratio")
  }
  // And they are listed longest-side-first, which is the order the picker reports
  // them in when two are within tolerance of a shape.
  const ratios = Model.RATIOS.map((r) => r.ratio)
  assert.deepEqual(ratios, ratios.slice().sort((a, b) => b - a))
  assert.equal(new Set(Model.RATIOS.map((r) => r.label)).size, Model.RATIOS.length)
  assert.ok(Model.RATIO_TOLERANCE > 0 && Model.RATIO_TOLERANCE < 0.1)
  // Nothing legacy sneaks in on its own terms: 5:4 is 6% off 4:3 and gets nothing.
  assert.equal(Model.ratioLabel(1280, 1024), "")
  // 1400x900 is 14:9 and lands 2.8% from 16:10, so it is called 16:10. That is the
  // same tolerance that lets 3440x1440 be 21:9 (2.4% off) — the wide band the user
  // asked for cannot tell those two apart, and a narrower one loses the ultrawide.
  assert.equal(Model.ratioLabel(1400, 900), "16:10")
})

test("the small pure helpers behave at their edges", () => {
  // formatDimensions is what every size line starts from.
  assert.equal(Model.formatDimensions(1600, 900), "1600 × 900")
  assert.equal(Model.formatDimensions(0, 900), "")
  assert.equal(Model.formatDimensions(1600, 0), "")
  assert.equal(Model.formatDimensions(undefined, undefined), "")
  assert.equal(Model.formatDimensions(-5, -5), "")

  // boolValue is how shell.json is read, and it has to be forgiving.
  for (const truthy of [true, "true", "yes", "on", 1, "1"]) {
    assert.equal(Model.boolValue(truthy, false), true, String(truthy))
  }
  for (const falsy of [false, "false", "no", "off", 0, "0"]) {
    assert.equal(Model.boolValue(falsy, true), false, String(falsy))
  }
  assert.equal(Model.boolValue(undefined, true), true) // the fallback
  assert.equal(Model.boolValue("something else", false), false)

  // The settings normalisers, called directly rather than through normalizeSettings.
  assert.equal(Model.normalizeDelay(7), 0)
  assert.equal(Model.normalizeDelay("5"), 5)
  assert.equal(Model.normalizeDelay(-3), 0)
  assert.equal(Model.normalizeGlaze(0.15), 0.14)
  assert.equal(Model.normalizeGlaze("nonsense"), 0.1)
  assert.equal(Model.normalizeDim(0.5), 0.55)
  assert.equal(Model.normalizeDeleteMode("permanently"), "permanently")
  assert.equal(Model.normalizeDeleteMode("shred"), "trash")

})

test("the manifest and the model agree about every setting", () => {
  // Two places describe the same settings, and a drift between them is invisible
  // until someone edits shell.json by hand and gets something the plugin cannot do.
  const manifest = JSON.parse(
    readFileSync(join(here, "..", "manifest.json"), "utf8"))
  const defaults = manifest.barWidget.defaults
  for (const [key, value] of Object.entries(Model.DEFAULT_SETTINGS)) {
    assert.deepEqual(defaults[key], value, "manifest default for " + key)
  }
  const schema = new Map(manifest.barWidget.schema.map((entry) => [entry.key, entry]))
  for (const key of Object.keys(Model.DEFAULT_SETTINGS)) {
    assert.ok(schema.has(key), "manifest schema describes " + key)
    assert.deepEqual(schema.get(key).defaultValue, Model.DEFAULT_SETTINGS[key], key + " default in the schema")
  }
  // Every numeric step the model offers has to be inside the range the schema
  // advertises, or the settings UI and the card would disagree.
  const steps = { delay: Model.DELAY_CHOICES, glaze: Model.GLAZE_CHOICES.map((c) => c.value),
    dim: Model.DIM_CHOICES.map((c) => c.value), cardWidth: Model.CARD_WIDTHS.map((c) => c.value) }
  for (const [key, values] of Object.entries(steps)) {
    const entry = schema.get(key)
    // Both numeric types: skipping "integer" is how a max of 10 next to a choice of
    // 15 stayed invisible to this check.
    if (!entry || (entry.type !== "number" && entry.type !== "integer")) continue
    for (const value of values) {
      assert.ok(value >= entry.min && value <= entry.max, `${key} step ${value} is inside the schema range`)
    }
  }
  // Every offered step has to be reachable from the schema's own min on its own step
  // grid, or a settings UI built from the schema cannot offer the values the model
  // accepts: 0.06 is not on a 0.04 grid from 0.
  for (const key of Object.keys(steps)) {
    const entry = schema.get(key)
    if (!entry || !entry.step) continue
    for (const value of steps[key]) {
      const offset = (value - entry.min) / entry.step
      assert.ok(Math.abs(offset - Math.round(offset)) < 1e-6,
        `${key} step ${value} is not on the schema's ${entry.step} grid from ${entry.min}`)
    }
  }

  const deleteMode = schema.get("deleteMode")
  if (deleteMode && deleteMode.type === "select") {
    assert.deepEqual(deleteMode.options.map((o) => o.value), Model.DELETE_MODES.map((m) => m.value))
  }
})

test("a selection is named after the shape it is, if it is a known one", () => {
  assert.equal(Model.ratioLabel(1600, 900), "16:9")
  assert.equal(Model.ratioLabel(1440, 900), "16:10")
  assert.equal(Model.ratioLabel(3000, 2000), "3:2")
  assert.equal(Model.ratioLabel(1080, 1080), "1:1")
  assert.equal(Model.ratioLabel(5120, 1440), "32:9")

  // The shapes the world rounds: 3440x1440 is the classic ultrawide everybody calls
  // 21:9, and an iPhone is not exactly 19.5:9 either.
  assert.equal(Model.ratioLabel(3440, 1440), "21:9")
  assert.equal(Model.ratioLabel(1170, 2532), "19.5:9")
  // A shape is a shape whichever way up it is.
  assert.equal(Model.ratioLabel(2532, 1170), "19.5:9")
  assert.equal(Model.ratioLabel(1600, 900), Model.ratioLabel(900, 1600))

  // Not every rectangle is a famous one, and a wrong label is worse than none.
  assert.equal(Model.ratioLabel(800, 560), "")
  assert.equal(Model.ratioLabel(1280, 1024), "") // 5:4, not a modern shape
  assert.equal(Model.ratioLabel(100, 37), "")
  assert.equal(Model.ratioLabel(0, 100), "")
  assert.equal(Model.ratioLabel(-16, -9), "")
  assert.equal(Model.ratioLabel("x", "y"), "")

  // Named shapes say so; the plain ones do not invent a nickname.
  assert.equal(Model.ratioName(1170, 2532), "iPhone")
  assert.equal(Model.ratioName(1440, 900), "MacBook")
  assert.equal(Model.ratioName(1600, 900), "")
  assert.equal(Model.dimensionLabel(1440, 900), "1440 × 900 · 16:10 (MacBook)")
  assert.equal(Model.dimensionLabel(1600, 900), "1600 × 900 · 16:9")
  assert.equal(Model.dimensionLabel(800, 560), "800 × 560")
})

test("the card has a width you can grow, and it stays sane", () => {
  // The preview fills the card's width, so this setting is the size of the shot on
  // screen — and the rows get the room with it.
  assert.equal(Model.DEFAULT_SETTINGS.cardWidth, 500)
  assert.deepEqual(Model.CARD_WIDTHS.map((c) => c.value), [360, 500, 620, 760])
  assert.equal(Model.cardWidthLabel(500), "Normal")
  assert.equal(Model.cardWidthLabel(620), "Wide")
  assert.equal(Model.cardWidthLabel(760), "Extra wide")
  assert.equal(Model.nextCardWidth(500), 620)
  assert.equal(Model.nextCardWidth(760), 360) // wraps round
  // A width saved before the steps moved snaps to the nearest one rather than
  // being rejected: 440 is 60 from 500 and 80 from 360.
  assert.equal(Model.normalizeCardWidth(440), 500)
  // A width typed into shell.json is snapped to the nearest step rather than used
  // raw: a card wider than the screen is not an improvement.
  assert.equal(Model.normalizeCardWidth(600), 620)
  assert.equal(Model.normalizeCardWidth(9999), 760)
  assert.equal(Model.normalizeCardWidth(10), 360)
  assert.equal(Model.normalizeCardWidth("nonsense"), 500)
  assert.equal(Model.normalizeCardWidth(undefined), 500)
  assert.equal(Model.normalizeSettings({ cardWidth: 620 }).cardWidth, 620)
  assert.equal(Model.settingsRows({}, {}).find((r) => r.id === "cardWidth").value, "Normal")
  assert.equal(Model.prevCardWidth(500), 360)
  assert.equal(Model.prevCardWidth(360), 760) // wraps the other way

  // Dragging an edge: the width is twice the distance from the middle, so both
  // edges behave the same way and the card grows symmetrically like a centred
  // window. The result is raw pixels, snapped to an offered width by the caller.
  assert.equal(Model.dragCardWidth("right", 620, 400, 800), 440)
  assert.equal(Model.dragCardWidth("left", 180, 400, 800), 440)
  assert.equal(Model.dragCardWidth("right", 700, 400, 800), 600)
  assert.equal(Model.dragCardWidth("left", 100, 400, 800), 600)
  // Dragging past the middle would be a negative width, and past the screen is
  // clamped to it.
  assert.equal(Model.dragCardWidth("right", 300, 400, 800), 0)
  assert.equal(Model.dragCardWidth("right", 5000, 400, 800), 800)
  assert.equal(Model.dragCardWidth("right", NaN, 400, 800), 0)
  // And the snapping the caller does: a drag just past a step lands on it.
  assert.equal(Model.normalizeCardWidth(Model.dragCardWidth("right", 610, 400, 1200)), 360)
  // 660 is nearer 620 than 760; 560 would be a tie, and ties resolve downwards.
  assert.equal(Model.normalizeCardWidth(Model.dragCardWidth("right", 730, 400, 1200)), 620)
})

test("hand-off actions are the ones that finish the card's job", () => {
  // These put the shot somewhere else — clipboard, editor, sharing, file
  // manager — so the card has nothing left to say and closes.
  for (const action of ["copy", "annotate", "share", "reveal"]) {
    assert.equal(Model.actionHandsOff(action), true, action)
  }

  // These keep the card: they navigate, change a setting, or need a
  // confirmation before anything happens.
  for (const action of ["back", "menu", "settings", "toggle-setting", "cycle-delay",
    "set-delay", "delete", "capture", "ocr", "record", "stop-record", "open",
    "from-clipboard", "open-shot", "reveal-dir", "choose-export-dir", "about"]) {
    assert.equal(Model.actionHandsOff(action), false, action)
  }

  assert.equal(Model.actionHandsOff(""), false)
  assert.equal(Model.actionHandsOff(undefined), false)
})

test("menuRows mirrors the capture menu and reflects state", () => {
  const noHistory = Model.menuRows({ hasPrevious: false, shotCount: 0 })
  // The first row is the one that decides from the gesture, so its label names
  // both targets instead of borrowing a marketing term.
  assert.equal(noHistory[0].label, "Capture Region or Window")
  assert.match(noHistory[0].detail, /click a window or the screen/)
  // Nothing to repeat yet, so the row is not there at all — the same treatment
  // Stop Recording gets while nothing is recording.
  assert.equal(noHistory.some((row) => row.id === "previous"), false)
  assert.equal(noHistory.some((row) => row === null), false)

  const withHistory = Model.menuRows({ hasPrevious: true, shotCount: 3, delay: 5 })
  const previous = withHistory.find((row) => row.id === "previous")
  assert.ok(previous, "the row appears once there is a region")
  // Not dimmed, not annotated: an enabled row is one with nothing to explain.
  assert.notEqual(previous.enabled, false)
  assert.equal(previous.detail, undefined)
  assert.equal(withHistory.find((row) => row.id === "timer").value, "5 s")
  assert.equal(withHistory.find((row) => row.id === "history").detail, "3 recent shots")
  assert.equal(withHistory.find((row) => row.id === "record").label, "Record Screen")

  const recording = Model.menuRows({ recording: true })
  assert.equal(recording.find((row) => row.id === "record"), undefined)
  assert.equal(recording.find((row) => row.id === "record-stop").label, "Stop Recording")

  const ids = noHistory.map((row) => row.id)
  for (const wanted of ["region-or-window", "area", "fullscreen", "window",
    "record", "timer", "open", "history", "settings"]) {
    assert.ok(ids.includes(wanted), `missing row ${wanted}`)
  }
  // The rows that come and go with state: what a capture needs, and what the
  // clipboard can be asked to open.
  assert.ok(withHistory.map((row) => row.id).includes("previous"))
  assert.ok(!ids.includes("from-clipboard"))
  // About lives under Settings, not on the menu, and text extraction is off the
  // menu for now.
  assert.ok(!ids.includes("about"))
  assert.ok(!ids.includes("ocr"))
  for (const row of noHistory) {
    if (row.kind === "separator") continue
    assert.ok(row.icon, `${row.id} has an icon`)
    assert.ok(row.label, `${row.id} has a label`)
  }
})

test("the bar icon says what the plugin is doing", () => {
  // Idle: the camera, nothing tinted.
  const idle = Model.barIcon({})
  assert.equal(idle.glyph, Model.ICON.camera)
  assert.equal(idle.tone, "idle")
  assert.match(idle.tooltip, /screenshot menu/i)

  // A self-timer that is armed shows in the icon itself, and the tooltip says
  // how long the wait is.
  const armed = Model.barIcon({ delay: 5 })
  assert.equal(armed.glyph, Model.ICON.cameraTimer)
  assert.equal(armed.tone, "armed")
  assert.match(armed.tooltip, /5 s/)

  // Recording outranks everything: it is the state with a way out of it.
  const recording = Model.barIcon({ delay: 5, recording: true })
  assert.equal(recording.glyph, Model.ICON.recordDot)
  assert.equal(recording.tone, "recording")
  assert.match(recording.tooltip, /stop/i)

  // A delay the plugin would not honour is not "armed".
  assert.equal(Model.barIcon({ delay: 7 }).tone, "idle")
  assert.equal(Model.barIcon({ delay: "junk" }).tone, "idle")
  assert.equal(Model.barIcon(null).tone, "idle")
})

test("a capture does not touch the clipboard unless Copy is pressed", () => {
  // The clipboard is the user's: taking a shot must not replace what is already on
  // it. Copying is a press on the card, and copying on every capture is something
  // to opt into.
  assert.equal(Model.DEFAULT_SETTINGS.copyToClipboard, false)
  const row = Model.settingsRows({}).find((entry) => entry.id === "copyToClipboard")
  assert.equal(row.kind, "toggle")
  assert.equal(row.value, false)
  // The opt-in still reads back, including from a hand-edited shell.json string.
  assert.equal(Model.normalizeSettings({ copyToClipboard: true }).copyToClipboard, true)
  assert.equal(Model.normalizeSettings({ copyToClipboard: "true" }).copyToClipboard, true)
  assert.equal(Model.normalizeSettings({ copyToClipboard: "no" }).copyToClipboard, false)
})

test("confirming a delete is a setting, off by default", () => {
  // Off by default: deleting a shot is a deliberate press, and the card says
  // which file it is.
  assert.equal(Model.DEFAULT_SETTINGS.confirmDelete, false)
  assert.equal(Model.normalizeSettings({ confirmDelete: "true" }).confirmDelete, true)

  const row = Model.settingsRows({}).find((entry) => entry.id === "confirmDelete")
  assert.equal(row.kind, "toggle")
  assert.equal(row.value, false)
  assert.equal(row.key, "confirmDelete")
  assert.match(row.detail, /delet/i)

  // The decision lives here so both the row and the X key ask the same question.
  assert.equal(Model.needsConfirm("delete", { confirmDelete: false }), false)
  assert.equal(Model.needsConfirm("delete", { confirmDelete: true }), true)
  assert.equal(Model.needsConfirm("delete", {}), false)
  // Nothing else is ever confirmed: a capture is not destructive.
  for (const action of ["copy", "annotate", "share", "reveal", "menu", "capture"]) {
    assert.equal(Model.needsConfirm(action, { confirmDelete: true }), false, action)
  }
})

test("walking the history, older and newer", () => {
  const shots = [{ path: "/p/newest.png" }, { path: "/p/middle.png" }, { path: "/p/oldest.png" }]

  assert.equal(Model.indexOfShot(shots, "/p/middle.png"), 1)
  assert.equal(Model.indexOfShot(shots, "/p/nope.png"), -1)

  assert.equal(Model.neighbourShot(shots, "/p/middle.png", "older"), "/p/oldest.png")
  assert.equal(Model.neighbourShot(shots, "/p/middle.png", "newer"), "/p/newest.png")
  // The ends are ends, not a wrap-around.
  assert.equal(Model.neighbourShot(shots, "/p/oldest.png", "older"), "")
  assert.equal(Model.neighbourShot(shots, "/p/newest.png", "newer"), "")
  // A file that is not in the list starts from the newest.
  assert.equal(Model.neighbourShot(shots, "/p/nope.png", "older"), "/p/newest.png")
  assert.equal(Model.neighbourShot([], "/p/x.png", "older"), "")
})

test("menu subtext only where it says something the label does not", () => {
  const rows = Model.menuRows({ hasPrevious: true, delay: 5, recording: false, shotCount: 3 })
  const detailOf = (id) => {
    const row = rows.find((entry) => entry.id === id)
    return row && row.detail ? row.detail : ""
  }

  // Restating the label is noise: the row already says "Capture Area", and that
  // you drag is what the menu is for.
  for (const id of ["area", "window", "record", "timer"]) {
    assert.equal(detailOf(id), "", id + " has no subtext")
  }

  // What does earn its line, reviewed: the gesture the unified row accepts, which
  // monitor "fullscreen" means, the history count, and what "Open…" actually does.
  // No row explains why it is unavailable: an unavailable row is not offered.
  assert.match(detailOf("region-or-window"), /click a window or the screen/)
  assert.ok(detailOf("region-or-window").length < 45, "and it fits the dropdown")
  assert.match(detailOf("fullscreen"), /monitor/)
  assert.match(detailOf("open"), /annotate/i)
  assert.match(detailOf("history"), /3 recent shots/)
  // Settings says everything it needs to in one word.
  assert.equal(detailOf("settings"), "")
  // The label already says "Open from Clipboard".
  assert.equal(detailOf("from-clipboard"), "")

  // The previous-area row is the one that comes and goes, and it says nothing
  // about itself when it is there: there is nothing to explain.
  assert.equal(Model.menuRows({ hasPrevious: false }).some((r) => r.id === "previous"), false)
  assert.equal(detailOf("previous"), "")
})

test("every menu row carries the command the dropdown sends", () => {
  const rows = Model.menuRows({ hasPrevious: true, delay: 3, recording: true, shotCount: 4,
    hasClipboardImage: true })
  const payloadOf = (id) => rows.find((row) => row.id === id).payload

  // Capture rows name their mode; the overlay runs it.
  assert.deepEqual(payloadOf("region-or-window"), { action: "capture", mode: "smart" })
  assert.deepEqual(payloadOf("area"), { action: "capture", mode: "region" })
  assert.deepEqual(payloadOf("previous"), { action: "capture", mode: "previous" })
  assert.deepEqual(payloadOf("fullscreen"), { action: "capture", mode: "fullscreen" })
  assert.deepEqual(payloadOf("window"), { action: "capture", mode: "window" })

  // The self-timer carries the value to set, not "cycle": whoever renders the
  // row already knows what it shows.
  assert.deepEqual(payloadOf("timer"), { action: "set-delay", value: Model.nextDelay(3) })

  // Rows that open another stage just name it.
  assert.deepEqual(payloadOf("history"), { stage: "history" })
  assert.deepEqual(payloadOf("settings"), { stage: "settings" })

  // Rows with a plain action need no arguments.
  assert.deepEqual(payloadOf("record-stop"), { action: "stop-record" })
  assert.deepEqual(payloadOf("open"), { action: "open" })
  assert.deepEqual(payloadOf("from-clipboard"), { action: "from-clipboard" })

  // Separators carry nothing to send.
  for (const row of rows.filter((r) => r.kind === "separator")) {
    assert.equal(row.payload, undefined)
  }

  // Every selectable row must be sendable: a dropdown that renders a row it
  // cannot act on is a dead button.
  for (const row of rows) {
    if (row.kind === "separator") continue
    assert.equal(typeof row.payload, "object", `${row.id} has a payload`)
    assert.ok(Object.keys(row.payload).length > 0, `${row.id} payload is not empty`)
  }
})

test("a row that does not know the shot count says so", () => {
  // The overlay counts the export folder; the dropdown does not.
  assert.equal(Model.shotCountLabel(0), "No shots recorded yet")
  assert.equal(Model.shotCountLabel(1), "1 recent shot")
  assert.equal(Model.shotCountLabel(3), "3 recent shots")
  assert.equal(Model.shotCountLabel(-1), "")
  assert.equal(Model.shotCountLabel(undefined), "")

  // Without a count the row is just its label: "Capture History…" says it.
  assert.equal(Model.menuRows({}).find((r) => r.id === "history").detail, "")
  assert.equal(Model.menuRows({ shotCount: 2 }).find((r) => r.id === "history").detail,
    "2 recent shots")
})

test("menu rows omit record-stop when nothing is recording", () => {
  const rows = Model.menuRows({ recording: false })
  const ids = rows.map((row) => row.id)
  assert.ok(ids.includes("record"))
  assert.ok(!ids.includes("record-stop"))
  assert.deepEqual(rows.find((r) => r.id === "record").payload, { action: "record" })
})

test("history, result, settings and about row shapes", () => {
  const shots = [
    { path: "/p/a.png", name: "a.png", size: 2048, mtime: 1_700_000_000_000 }
  ]
  const history = Model.historyRows(shots, 1_700_000_060_000)
  assert.equal(history[0].kind, "shot")
  assert.equal(history[0].path, "/p/a.png")
  // The age leads the line: a history list is read for when things were taken.
  assert.match(history[0].detail, /^1 min ago · 2 KB$/)
  assert.ok(Model.historyRows([], 0).some((row) => row.id === "back"))
  assert.deepEqual(Model.historyRows([], 0).filter((row) => row.kind === "shot"), [])

  // What a copy puts on the clipboard depends on the backend, and the row says so:
  // "image and path" with the native helper, "image only" without it.
  assert.equal(Model.copyDetail("native"), "Image and path on the clipboard")
  assert.match(Model.copyDetail("wl-copy"), /^Image only/)
  assert.match(Model.copyDetail(""), /^Image only/)
  assert.equal(Model.resultRows("/p/a.png", "native").find((r) => r.action === "copy").detail,
    "Image and path on the clipboard")
  assert.match(Model.resultRows("/p/a.png", "wl-copy").find((r) => r.action === "copy").detail,
    /^Image only/)

  const result = Model.resultRows("/p/a.png")
  assert.deepEqual(result.filter((r) => r.kind === "action").map((r) => r.action),
    ["copy", "annotate", "share", "reveal", "delete", "menu"])
  // No separate "Copy Path" row or key: the copy already carries the path as
  // text alongside the image.
  assert.equal(result.some((row) => row.action === "copy-path"), false)
  assert.equal(result.find((row) => row.action === "copy").label, "Copy")
  assert.match(result.find((row) => row.action === "copy").detail, /path/)

  const settings = Model.settingsRows({ delay: 3, exportDir: "" })
  // Grouped by what the setting is about, in the order the groups are read: what
  // shapes the capture, what happens to it, and where it goes.
  assert.deepEqual(settings.filter((r) => r.kind === "heading").map((r) => r.label),
    ["Capture", "After a capture", "Files"])
  assert.equal(settings.filter((r) => r.kind === "heading").every((r) => r.icon === undefined), true)
  for (const heading of settings.filter((r) => r.kind === "heading")) {
    assert.equal(Model.rowSelectable(heading), false, heading.label)
  }

  // Each group holds the settings that belong to it, in their own order.
  const group = (name) => {
    const start = settings.findIndex((r) => r.kind === "heading" && r.label === name)
    const rest = settings.slice(start + 1)
    // A group runs to the next heading, or to the separator that closes the list
    // (the About row sits below it, outside any group).
    const next = rest.findIndex((r) => r.kind === "heading" || r.kind === "separator")
    return next === -1 ? rest : rest.slice(0, next)
  }
  assert.deepEqual(group("Capture").map((r) => r.id), ["delay", "showCursor", "glaze", "dim"])
  assert.deepEqual(group("After a capture").map((r) => r.id),
    ["copyToClipboard", "saveToDisk", "showResult", "openAnnotate"])
  assert.deepEqual(group("Files").map((r) => r.id),
    ["exportDir", "confirmDelete", "cardWidth", "deleteMode"])

  const toggles = settings.filter((r) => r.kind === "toggle")
  assert.deepEqual(toggles.map((r) => r.key),
    ["showCursor", "copyToClipboard", "saveToDisk", "showResult", "openAnnotate",
      "confirmDelete"])
  assert.equal(toggles.every((r) => r.value === true || r.value === false), true)
  assert.equal(settings.find((r) => r.id === "delay").value, "3 s")
  // Both selection visuals and the delete destination are named steps, not numbers.
  assert.equal(settings.find((r) => r.id === "glaze").value, "Light")
  assert.equal(settings.find((r) => r.id === "dim").value, "Off")
  assert.equal(settings.find((r) => r.id === "deleteMode").value, "Trash")

  // The folder row shows the directory shots actually land in, not the word
  // "default", and offers a way back once a custom one is set.
  const dirs = { effective: "/home/me/Pictures", default: "/home/me/Pictures" }
  const folder = Model.settingsRows({}, dirs).find((r) => r.id === "exportDir")
  assert.equal(folder.detail, "/home/me/Pictures")
  assert.equal(folder.value, "default")
  assert.ok(!Model.settingsRows({}, dirs).some((r) => r.action === "reset-export-dir"))

  const custom = Model.settingsRows({ exportDir: "/home/me/Shots" },
    { effective: "/home/me/Shots", default: "/home/me/Pictures" })
  assert.equal(custom.find((r) => r.id === "exportDir").detail, "/home/me/Shots")
  assert.equal(custom.find((r) => r.id === "exportDir").value, "custom")
  const reset = custom.find((r) => r.action === "reset-export-dir")
  assert.equal(reset.label, "Use the default folder")
  assert.equal(reset.detail, "/home/me/Pictures")
  assert.equal(Model.actionHandsOff("reset-export-dir"), false)

  // About moved off the menu and into Settings, where it is one row before Back.
  const aboutRow = settings.find((r) => r.id === "about")
  assert.equal(aboutRow.action, "about")
  assert.equal(aboutRow.value, "v" + Model.VERSION)
  assert.equal(settings[settings.length - 1].id, "back")

  // About is about the plugin: no settings on it, and no actions except the way
  // back. The export folder belongs to Settings, and revealing the folder is the
  // card's Reveal row.
  const about = Model.aboutRows({ shotDir: "/p", pluginDir: "/x", barHint: "Super + Shift + S" })
  assert.equal(about[0].value, "v" + Model.VERSION)
  assert.equal(about.some((r) => r.id === "export"), false)
  assert.equal(about.some((r) => r.action === "reveal-dir"), false)
  assert.equal(about.find((r) => r.id === "plugin-dir").value, "/x")
  // Nothing read back out of the desktop's config either, which is what the menu
  // keybinding row was.
  assert.equal(about.some((r) => r.id === "menu-bind"), false)
  assert.equal(about.find((r) => r.id === "author").value, "Mathias Bogaert")
  assert.equal(about.find((r) => r.id === "license").value, "MIT")
  // Links out are actions carrying a real https URL, and they are not hand-offs:
  // opening a browser must not close the screen the link was on.
  for (const row of about.filter((r) => r.action === "open-url")) {
    assert.match(String(row.url), /^https:\/\//, row.id)
    assert.equal(Model.actionHandsOff(row.action), false, row.id)
  }
  assert.equal(about.find((r) => r.id === "github").url, "https://github.com/analytically")
  assert.equal(about.find((r) => r.id === "homepage").url, "https://github.com/analytically/snapmenu")
  // The only actions are the two links out and the way back.
  assert.deepEqual(about.filter((r) => r.kind === "action").map((r) => r.id),
    ["github", "homepage", "back"])
  // Information rows are not cursor targets.
  for (const row of about.filter((r) => r.kind === "info")) {
    assert.equal(Model.rowSelectable(row), false, row.id)
  }
})

test("window rects cycle in reading order for Tab", () => {
  const rects = [
    { kind: "monitor", label: "Screen eDP-1", x: 0, y: 0, width: 1800, height: 1125 },
    { kind: "window", label: "bottom", x: 12, y: 583, width: 881, height: 530 },
    { kind: "window", label: "top-right", x: 907, y: 38, width: 881, height: 1075 },
    { kind: "window", label: "top-left", x: 12, y: 38, width: 881, height: 531 }
  ]
  assert.deepEqual(Model.windowRects(rects).map((r) => r.label),
    ["top-left", "top-right", "bottom"])

  // No current target: Tab starts at the first window, Shift+Tab at the last.
  assert.equal(Model.nextRect(rects, null, 1).label, "top-left")
  assert.equal(Model.nextRect(rects, null, -1).label, "bottom")
  assert.equal(Model.nextRect(rects, rects[3], 1).label, "top-right")
  assert.equal(Model.nextRect(rects, rects[3], -1).label, "bottom")
  assert.equal(Model.nextRect(rects, rects[1], 1).label, "top-left")
  assert.equal(Model.nextRect([{ kind: "monitor" }], null, 1), null)
  assert.equal(Model.nextRect([], null, 1), null)
})

test("rectLabel names the target and its size", () => {
  assert.equal(Model.rectLabel({ label: "Ghostty", width: 881, height: 531 }),
    "Ghostty  ·  881 × 531")
  assert.equal(Model.rectLabel({ width: 800, height: 600 }), "800 × 600")
  assert.equal(Model.rectLabel(null), "")
})

test("rect labels survive the move into overlay coordinates", () => {
  const rects = [{ kind: "window", label: "Terminal", x: -1900, y: 40, width: 400, height: 300 }]
  const local = Model.localRects(rects, -1920, 0, 1920, 1080)
  assert.equal(local[0].label, "Terminal")
  assert.equal(Model.clipRectToBounds(rects[0], { x: -1900, y: 0, width: 1900, height: 1080 }).label,
    "Terminal")
})

test("parseRects keeps the labels the helper sends", () => {
  const stdout = '{"ok":true,"rects":[{"kind":"window","label":"Working (24s)","x":1,"y":2,'
    + '"width":3,"height":4}]}\n'
  assert.equal(Model.parseRects(stdout).rects[0].label, "Working (24s)")
  assert.equal(Model.parseRects(stdout).rects[0].kind, "window")
})

test("navigation skips separators, disabled and info rows", () => {
  const rows = [
    { kind: "action", id: "a" },
    { kind: "separator", id: "s" },
    { kind: "action", id: "b", enabled: false },
    { kind: "action", id: "c" },
    { kind: "info", id: "i" }
  ]
  const selectable = rows.map(Model.rowSelectable)
  assert.deepEqual(selectable, [true, false, false, true, false])

  assert.equal(Model.firstEnabledIndex(rows), 0)
  assert.equal(Model.clampIndex(rows, 99), 4)
  assert.equal(Model.clampIndex(rows, -3), 0)
  assert.equal(Model.nextEnabledIndex(rows, 0, 1), 3)
  assert.equal(Model.nextEnabledIndex(rows, 3, 1), 3) // stays, no wrap
  assert.equal(Model.nextEnabledIndex(rows, 3, -1), 0)
  assert.equal(Model.nearestEnabled(rows, 2, 1), 3)
  assert.equal(Model.nearestEnabled(rows, 2, -1), 0)
  assert.equal(Model.nthEnabledIndex(rows, 1), 0)
  assert.equal(Model.nthEnabledIndex(rows, 2), 3)
  assert.equal(Model.nthEnabledIndex(rows, 3), -1)
  assert.equal(Model.nextEnabledIndex([], 0, 1), 0)
})
