import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "SnapmenuModel.js" as Model

// snapmenu — a screenshot command menu for the Omarchy shell.
//
// One overlay hosts four stages (menu, history, result, settings/about) and
// owns the whole screenshot round trip: it hides its own layer surface before
// grim runs, shells out to bin/snapmenu-capture.sh for the pixels, then offers
// the after-capture actions (copy, annotate, share, reveal, delete).
//
// Lifecycle is the standard shell plugin contract: summon calls open(payload),
// hide calls close(). Payload keys:
//   {"stage":"menu"|"history"|"settings"|"about"}   open on a stage
//   {"path":"/abs/shot.png"}                       open the action card for a file
//   {"mode":"region"|"smart"|"window"|"fullscreen"|"previous"}  capture right away
//   {"delay":3}                                    self-timer override for this run
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null

  // The shell contract: the host reads `opened` and calls open()/close().
  property bool opened: false

  readonly property string pluginDir: Model.localPathFromUrl(Qt.resolvedUrl("."))
  readonly property string captureScript: root.pluginDir + "/bin/snapmenu-capture.sh"
  readonly property string home: Quickshell.env("HOME")
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (root.home + "/.config")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (root.home + "/.local/state")
  readonly property string stateDir: root.stateHome + "/snapmenu"
  readonly property string shellConfigPath: root.configHome + "/omarchy/shell.json"
  readonly property string userDirsPath: root.configHome + "/user-dirs.dirs"

  property string picturesDir: root.home + "/Pictures"
  // Where shots go when no export folder is configured: the same order the
  // capture helper uses.
  readonly property string defaultShotDir: Quickshell.env("OMARCHY_SCREENSHOT_DIR")
    || root.picturesDir
  readonly property string shotDir: {
    if (root.settings.exportDir) return root.settings.exportDir
    var configured = Quickshell.env("OMARCHY_SCREENSHOT_DIR")
    return configured ? configured : root.picturesDir
  }

  property var settings: Model.normalizeSettings(null)
  property string shellConfigRaw: ""
  property var shots: []
  property real nowMs: Date.now()

  // While the card is up, "just now" has to become "1 min ago" on its own.
  Timer {
    interval: 15000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }
  property bool recording: false
  property bool hasPrevious: false

  property string stage: "menu"
  property string currentFile: ""
  property int currentWidth: 0
  property int currentHeight: 0
  property bool currentTemporary: false
  // A temporary shot (Save off) that the card is holding. The file is there so the
  // card's rows can work on it, and it goes when the card closes without anything
  // having taken it — see claimTempShot() and releaseTempShot().
  property string pendingTempShot: ""

  property int selectedIndex: 0
  property bool cursorActive: true
  property string toast: ""
  property bool busy: false
  property string pendingMode: ""
  // A capture started from the bar dropdown has an Omarchy layer (the popout) fading
  // out behind it, which the no-anim rule we set for our own namespace does not
  // cover. Those captures keep the helper's settle probe; a hotkey capture has
  // nothing to settle and skips it.
  property bool captureFromPopout: false
  // Every capture gets a token, and results are only honoured while it still matches.
  // Without it, dismissing a card left the freeze still running, and its reply mapped
  // the picker or re-opened the result card after the user had closed it.
  property int captureToken: 0
  // The rectangle a capture started from a popout must watch: the popout's own card
  // area, which the popup knows and passes along. Empty for other captures.
  property string settleArea: ""
  property int countdown: 0
  property bool countingDown: false
  property bool deleteConfirmOpen: false
  property string deleteTarget: ""
  property var actionCallback: null
  property string deletingPath: ""
  // Bounded breadcrumb trail of state transitions, for the debugState IPC.
  // Each entry carries the milliseconds since the previous one, so the trace
  // doubles as a latency budget: "+297ms handleFreeze" is grim finishing.
  property string traceLog: ""
  property real traceMark: 0

  function trace(message) {
    var now = Date.now()
    var delta = root.traceMark > 0 ? Math.round(now - root.traceMark) : 0
    root.traceMark = now
    root.traceLog = (root.traceLog + "|+" + delta + "ms " + message).slice(-700)
  }

  // Region selection: the shell freezes the monitor to a PNG, shows it in its
  // own layer surface, drags the selection there, then crops with grim while
  // that frozen frame is still on screen.
  property bool selectorActive: false
  property bool selectorCapturing: false
  property var selectorScreen: null
  property string selectorMode: "region"
  property var selectorRects: []
  property string freezePath: ""
  property real freezeOriginX: 0
  property real freezeOriginY: 0
  property real freezeWidth: 0
  property real freezeHeight: 0
  property real freezeScale: 1
  property var pendingRect: null
  property string scriptedGeometry: ""
  // Whether the helper found a cropper: it decides if the crop is cut from the
  // frame file (exact, and nothing on screen can get into it) or read back off
  // the composited frozen frame.
  property bool cropperAvailable: false
  // Which owner the copy uses: the native helper when it has been built, else
  // wl-copy, which can only carry one representation at a time.
  readonly property string clipboardHelper: root.pluginDir + "/bin/snapmenu-clipboard"
  property string clipboardBackend: "wl-copy"
  // Whether the compositor's layer fade is off for our namespace, so a frame
  // taken right after the card unmaps cannot contain a ghost of it.
  property bool animationsDisabled: false

  readonly property var rows: {
    if (root.stage === "history") return Model.historyRows(root.shots, root.nowMs)
    if (root.stage === "result") return Model.resultRows(root.currentFile, root.clipboardBackend)
    if (root.stage === "settings") {
      return Model.settingsRows(root.settings, {
        effective: root.shotDir,
        default: root.defaultShotDir
      })
    }
    if (root.stage === "about") {
      return Model.aboutRows({
        shotDir: root.shotDir,
        pluginDir: root.pluginDir,
        barHint: "Super + Shift + S"
      })
    }
    return Model.menuRows({
      hasPrevious: root.hasPrevious,
      delay: root.settings.delay,
      recording: root.recording,
      shotCount: root.shots.length
    })
  }

  readonly property color scrim: Color.menu.scrim
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color selectedText: Color.menu.selectedText
  readonly property color selectedBackground: Color.menu.selectedBackground
  // The surface token the theme uses for popups and menus, which resolves to the
  // accent unless a theme overrides it — the same border the bar dropdown draws, so
  // the menu looks the same wherever it appears.
  readonly property var borderSpec: Border.surfaceSpec("popups", "border",
    Color.popups.border, Math.max(1, Style.space(2)))
  readonly property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border",
    selectedText, Style.space(1))
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int cornerRadius: Style.cornerRadius
  readonly property int contentMargin: Style.spacing.panelPadding

  // ------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    root.trace("open:" + String(payloadJson || "").slice(0, 40))
    var payload = {}
    try {
      payload = JSON.parse(payloadJson || "{}") || {}
    } catch (e) {
      payload = {}
    }

    root.deleteConfirmOpen = false
    root.countingDown = false
    root.busy = false
    root.toast = ""
    // Set again by runCommand when this open is a capture: only a capture the
    // popout itself started has a popout fading behind it.
    root.captureFromPopout = false
    root.settleArea = ""

    // A command payload runs one action and shows nothing by itself: the bar
    // dropdown sends these (see the payloads in Model.menuRows), so both
    // surfaces execute through the same code.
    if (payload.command && typeof payload.command === "object") {
      root.trace("open:command:" + String(payload.command.action || payload.command.stage || "?"))
      root.runCommand(payload.command)
      return
    }

    if (payload.path) {
      root.currentFile = String(payload.path)
      root.setStage("result")
    } else if (payload.stage) {
      root.setStage(String(payload.stage))
    } else {
      root.setStage("menu")
    }

    root.opened = true
    root.refreshEnvironment()

    if (payload.delay !== undefined && payload.delay !== null) {
      var requested = Number(payload.delay)
      if (isFinite(requested) && requested >= 0) root.persistSettings({ delay: requested })
    }
    if (payload.mode) {
      root.runCapture(String(payload.mode))
      return
    }
    root.focusCard()
  }

  function close() {
    root.trace("close")
    // The card is the only thing holding a temporary shot. Whatever closed the overlay
    // — Escape, a hand-off, the bar icon — nothing took the file, so it goes. A shot
    // released here was never the user's, so it does not go to the Trash. (A delete
    // already in flight wins: the temp folder is pruned on the next capture either way.)
    root.releaseTempShot()
    // Anything in flight belongs to a session the user has walked away from.
    root.captureToken += 1
    if (freezeProc.running) freezeProc.running = false
    if (rectsProc.running) rectsProc.running = false
    if (cropProc.running) cropProc.running = false
    cropWatchdog.stop()
    root.opened = false
    root.countingDown = false
    root.busy = false
    root.deleteConfirmOpen = false
    countdownTimer.stop()
    graceTimer.stop()
    // Hiding the plugin while a selection is up must take the selector with it,
    // or a frozen full-screen layer would be left behind with no way back.
    if (root.selectorActive) root.hideSelector()
  }

  function dismiss() {
    root.trace("dismiss")
    root.close()
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(Model.PLUGIN_ID)
  }

  function focusCard() {
    // A layer surface can be on screen before Qt gives the keyboard to an item
    // in it, and a keypress in that window goes to whatever had focus before —
    // the first Escape or Enter after opening would simply be lost, so the focus
    // is asserted again for a moment. Only when it is not already held: asking a
    // layer surface for keyboard focus it already has is a round trip to the
    // compositor, and every stage change would pay for it.
    if (keyCatcher.activeFocus) return
    keyCatcher.forceActiveFocus()
    cardFocusRetry.restart()
  }

  Timer {
    id: cardFocusRetry
    interval: 80
    repeat: true
    property int tries: 0
    onTriggered: {
      tries += 1
      // Five tries was 400ms, which is not always enough for the compositor to grant
      // the keyboard to a fresh layer surface: the first Tab or Escape after opening
      // was occasionally lost. Ten is 800ms and still stops as soon as it has focus.
      if (!root.opened || keyCatcher.activeFocus || tries > 9) {
        stop()
        tries = 0
        return
      }
      keyCatcher.forceActiveFocus()
    }
  }

  function setStage(name) {
    root.stage = String(name || "menu")
    root.selectedIndex = Model.firstEnabledIndex(root.rows)
    root.cursorActive = true
    root.trace("stage:" + root.stage)
    root.focusCard()
  }

  function refreshEnvironment() {
    if (!statProc.running) statProc.running = true
    if (!recordProc.running) recordProc.running = true
    if (root.stage !== "settings") root.refreshShots()
  }

  function refreshShots() {
    if (listProc.running) return
    listProc.running = true
  }

  function clampSelection() {
    root.selectedIndex = Model.clampIndex(root.rows, root.selectedIndex)
  }

  function moveCursor(delta) {
    root.cursorActive = true
    root.selectedIndex = Model.nextEnabledIndex(root.rows, root.selectedIndex, delta)
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function notify(message) {
    var text = String(message || "")
    if (!text) return
    if (root.opened) {
      root.toast = text
      toastTimer.restart()
    } else {
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send", text])
    }
  }

  // -------------------------------------------------------------- settings

  function applyShellConfig(text) {
    root.shellConfigRaw = String(text || "")
    root.settings = Model.settingsFromShellConfig(root.shellConfigRaw, Model.PLUGIN_ID)
  }

  // Settings live inline on this plugin's shell.json entry, which is what the
  // bar widget writes and what the shell's updateEntryInline() rewrites. With
  // no entry (overlay used without the bar widget) changes stay in memory.
  function persistSettings(patch) {
    var merged = {}
    for (var key in root.settings) merged[key] = root.settings[key]
    for (var patchKey in patch) merged[patchKey] = patch[patchKey]
    root.settings = Model.normalizeSettings(merged)

    var hasEntry = Model.entryFromShellConfig(root.shellConfigRaw, Model.PLUGIN_ID) !== null
    if (!hasEntry) {
      root.notify("Settings are session-only until Snapmenu sits on the bar")
      return
    }
    if (root.shell && typeof root.shell.updateEntryInline === "function") {
      root.shell.updateEntryInline(Model.PLUGIN_ID, root.settings)
    }
  }

  function toggleSetting(key) {
    var patch = {}
    patch[String(key)] = !root.settings[String(key)]
    root.persistSettings(patch)
  }

  // ---------------------------------------------------------------- capture

  function runCapture(mode) {
    if (root.busy) return
    root.traceMark = 0
    root.trace("runCapture:" + String(mode))
    root.busy = true
    root.pendingMode = String(mode || "smart")
    root.cursorActive = true

    if (root.settings.delay > 0) {
      root.countdown = root.settings.delay
      root.countingDown = true
      // Only the countdown pill is drawn while counting, so opening here shows
      // the timer without flashing the card — and it is the only way a
      // command-driven capture (the bar dropdown) announces the wait at all.
      root.opened = true
      countdownTimer.restart()
      root.focusCard()
      return
    }
    root.beginCapture()
  }

  function cancelCountdown() {
    countdownTimer.stop()
    root.countingDown = false
    root.busy = false
    root.pendingMode = ""
    root.setStage("menu")
    root.notify("Capture cancelled")
  }

  // Get our layer surface off the screen *before* grim runs, with a short
  // grace period so the compositor has actually withdrawn it — otherwise the
  // card ends up baked into the screenshot.
  function beginCapture() {
    root.trace("beginCapture")
    root.countingDown = false
    countdownTimer.stop()
    root.opened = false
    graceTimer.restart()
  }

  function startCaptureProcess() {
    root.trace("startCaptureProcess:" + root.pendingMode)
    if (!root.busy) return
    var mode = root.pendingMode

    // Area, smart and window all go through the shell's own frozen-frame
    // selector; fullscreen and previous are single grim calls.
    if (mode === "region" || mode === "smart" || mode === "window") {
      root.startFreeze(mode)
      return
    }

    var args = ["--mode", mode]
    // Fullscreen and previous-area shoot straight away, but the menu they were
    // chosen from may still be on screen; the helper waits for it, and for the bar
    // popout's fade when this came from the dropdown.
    if (root.settleArea !== "") args = args.concat(["--settle-area", root.settleArea])
    if (root.settings.showCursor) args = args.concat(["--cursor"])
    if (root.settings.exportDir) args = args.concat(["--dir", root.settings.exportDir])
    if (!root.settings.saveToDisk) args = args.concat(["--temp"])
    captureProc.command = ["/usr/bin/bash", root.captureScript].concat(args)
    captureProc.running = true
  }

  // ---------------------------------------------------------- region picking

  function screenForName(name) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i] && String(screens[i].name) === String(name)) return screens[i]
    }
    return screens.length > 0 ? screens[0] : null
  }

  function startFreeze(mode) {
    // A picker that opens over a card ends that card's session: a temporary shot the
    // card was holding is not carried into the next capture.
    root.releaseTempShot()
    root.selectorMode = String(mode || "region")
    // The picker's `capturing` flag is bound to this and never assigned by the
    // picker itself, so a session starts with it clear.
    root.selectorCapturing = false
    root.selectorActive = false
    // The helper owns the shutter sound: it knows the moment the frame is
    // taken, and it never plays for a crop or for a capture that failed.
    var args = ["--freeze"]
    if (root.settings.showCursor) args = args.concat(["--cursor"])
    // The fade rule is applied once at startup; when it took, the helper does not
    // have to probe the screen for a fade that cannot happen.
    if (root.animationsDisabled && !root.captureFromPopout) {
      args = args.concat(["--no-settle"])
    }
    if (root.settleArea !== "") args = args.concat(["--settle-area", root.settleArea])
    root.captureToken += 1
    freezeProc.token = root.captureToken
    freezeProc.command = ["/usr/bin/bash", root.captureScript].concat(args)
    freezeProc.running = true
  }

  function finishSelection(x, y, width, height) {
    root.pendingRect = { x: x, y: y, width: width, height: height }
    // Drop the chrome first: with a cropper installed the crop is cut from the
    // frame file, so waiting for the screen to catch up would just be delay;
    // without one, grim reads the screen and needs that frame to be clean.
    root.selectorCapturing = true
    cropWatchdog.restart()
    selectionTimer.interval = root.cropperAvailable ? 1 : 80
    selectionTimer.restart()
  }

  function requestCrop() {
    root.trace("requestCrop")
    var geometry = Model.globalGeometry(root.pendingRect, root.freezeOriginX, root.freezeOriginY)
    if (!geometry) {
      root.cancelSelection()
      return
    }

    // The origin travels with the crop: the helper crops the frame file in
    // monitor-local coordinates and falls back to grim in global ones.
    cropProc.token = root.captureToken
    var args = ["--crop", geometry,
      "--origin", root.freezeOriginX + "," + root.freezeOriginY,
      "--mode", root.selectorMode]
    if (root.freezePath) args = args.concat(["--freeze-file", root.freezePath])
    if (root.freezeScale > 0) args = args.concat(["--scale", String(root.freezeScale)])
    if (root.settings.exportDir) args = args.concat(["--dir", root.settings.exportDir])
    if (!root.settings.saveToDisk) args = args.concat(["--temp"])
    cropProc.command = ["/usr/bin/bash", root.captureScript].concat(args)
    cropProc.running = true
  }

  function hideSelector() {
    root.trace("hideSelector")
    cropWatchdog.stop()
    root.selectorActive = false
    root.selectorCapturing = false
    root.pendingRect = null
    root.scriptedGeometry = ""
    root.freezePath = ""
    root.selectorRects = []
  }

  function cancelSelection() {
    // A crop already in flight belongs to the cancelled session from here on.
    root.captureToken += 1
    cropWatchdog.stop()
    // The freeze frame is scratch space; a cancelled pick must not leave it on
    // disk (the next freeze clears leftovers anyway, this just keeps it tidy).
    if (root.freezePath) root.runAction(["/usr/bin/rm", "-f", root.freezePath])
    root.hideSelector()
    root.abortCapture("cancelled")
  }

  function abortCapture(reason) {
    root.captureFromPopout = false
    root.settleArea = ""
    root.trace("abortCapture:" + reason)
    root.busy = false
    root.pendingMode = ""
    root.setStage("menu")
    root.opened = true
    root.notify(Model.reasonMessage(reason))
  }

  function finishCapture(stdout, exitCode) {
    root.captureFromPopout = false
    root.settleArea = ""
    var result = Model.parseCaptureResult(stdout)
    root.trace("finishCapture:ok=" + result.ok + ":reason=" + result.reason
      + ":showResult=" + root.settings.showResult)
    root.busy = false
    root.pendingMode = ""

    if (!result.ok) {
      if (!result.reason) result.reason = exitCode === 0 || exitCode === undefined
        ? "no-output" : "helper-failed"
      if (result.reason === "cancelled") {
        root.setStage("menu")
        root.opened = true
        root.notify("Capture cancelled")
        return
      }
      root.setStage("menu")
      root.opened = true
      root.notify(Model.reasonMessage(result.reason))
      return
    }

    root.currentFile = result.path
    root.currentWidth = result.width
    root.currentHeight = result.height
    root.currentTemporary = result.temporary === true
    root.nowMs = Date.now()
    if (root.stage !== "settings") root.refreshShots()

    var temporary = result.temporary === true && !root.settings.saveToDisk
    var copied = false
    if (root.settings.copyToClipboard) {
      copied = true
      root.copyFile(result.path, temporary)
    }

    // A temporary shot (Save off) is not deleted here any more. The card is about to
    // offer Copy, Annotate and Share on it, and deleting it first made those rows act
    // on a file that was already gone — the delete's own completion then threw the
    // card back to the menu, so a Save-off capture never showed a card at all.
    root.pendingTempShot = temporary && !copied ? result.path : ""

    if (root.settings.openAnnotate) root.annotateFile(result.path)

    if (root.settings.showResult) {
      root.currentFile = result.path
      root.setStage("result")
      root.opened = true
      root.focusCard()
      return
    }

    var label = Model.basename(result.path)
    // No card is coming, so nothing is going to hold a temporary shot: it goes now,
    // and the notification below is the only thing that mentions it.
    if (temporary && !copied) root.removeFile(result.path, true)
    var kept = !result.temporary || root.settings.saveToDisk
    root.notify(label + (!kept ? " was discarded"
      : (copied ? " copied to the clipboard" : " saved")))
  }

  // A temporary shot the card is holding: something took it (every row that hands the
  // shot off claims it), so the card is no longer what finishes with it. It lives in
  // the temp folder until a later capture prunes it, which is what makes a copied or
  // annotated shot safe from the card closing behind it.
  function claimTempShot(path) {
    if (root.pendingTempShot !== "" && String(path) === root.pendingTempShot) {
      root.pendingTempShot = ""
    }
  }

  // The other half: nothing took the shot, so the card closing is what ends it.
  function releaseTempShot() {
    var path = root.pendingTempShot
    root.pendingTempShot = ""
    if (path !== "") root.removeFile(path, true)
  }

  function startRecording() {
    if (root.busy) return
    root.busy = true
    root.opened = false
    recordingProc.command = [root.omarchyPath + "/bin/omarchy-capture-screenrecording"]
    recordingProc.running = true
  }

  function stopRecording() {
    if (root.busy) return
    root.busy = true
    recordingProc.command = [root.omarchyPath + "/bin/omarchy-capture-screenrecording", "--stop-recording"]
    recordingProc.running = true
  }

  function openFromClipboard() {
    if (root.busy) return
    root.busy = true
    root.opened = false
    var args = ["--from-clipboard"]
    if (root.settings.exportDir) args = args.concat(["--dir", root.settings.exportDir])
    clipboardProc.command = ["/usr/bin/bash", root.captureScript].concat(args)
    clipboardProc.running = true
  }

  // ---------------------------------------------------------------- actions

  // One selection, several representations: image/png for the apps and agents
  // that want a picture, text/plain (the real path) for shells, and the file
  // types pointing at a snapshot for anything that pastes a file. wl-copy
  // cannot do that — it keeps only the last --type — so the native helper owns
  // the selection instead (see native/, built by `make native`).
  function copyFile(path, removeAfter) {
    root.claimTempShot(path)
    if (root.clipboardBackend === "native") {
      var argv = [root.clipboardHelper, String(path)]
      if (removeAfter) argv = argv.concat(["--temporary"])
      Quickshell.execDetached(argv)
      return
    }
    // Without the helper: wl-copy, which is the image alone. A temporary file
    // is removed once the copy has had time to read it.
    var fallback = ["/usr/bin/bash", "-c",
      "exec /usr/bin/wl-copy --type image/png < \"$1\"", "snapmenu-copy", String(path)]
    if (removeAfter) root.runAction(fallback, function () { root.removeFile(path) })
    else root.runAction(fallback)
  }

  function copyCurrent() {
    var path = root.activeFile()
    if (!path) return
    // A temporary shot (Save off) was never meant to stay: the copy is what it was for,
    // so the file goes once the helper has the selection — the same bargain the copy
    // struck at capture time. A shot from the history is the user's file, and stays.
    root.copyFile(path, root.currentTemporary && !root.settings.saveToDisk)
    root.afterHandoff()
    root.notify("Copied " + Model.basename(path))
  }

  // The image on the clipboard is invisible to a shell — pasting at a prompt
  // does nothing — so the path is copied as text too, where commands want it.

  // A hand-off action closes the card: the shot is on the clipboard or in
  // another app by then, and the inline toast would disappear with the card
  // anyway (so notify() turns into a desktop notification). Only the result
  // card — one specific shot — closes; browsing history stays put, so several
  // shots can be copied in a row.
  function afterHandoff() {
    if (root.stage !== "result") return false
    root.dismiss()
    return true
  }

  function removeFile(path, permanently) {
    // Deliberately removing the shot the card holds settles it: nothing is left for
    // the card to release afterwards.
    root.claimTempShot(path)
    // One delete at a time: the report names the path this process was started with,
    // and a second X press would otherwise make the first report name the second file.
    if (deleteProc.running) return
    root.deletingPath = String(path)
    // Trash unless the setting says otherwise: a shot deleted by mistake should
    // still be recoverable by default.
    var args = ["--delete", root.deletingPath]
    // A shot the plugin is throwing away is not the user's file, so it never goes to
    // the Trash; a shot the user deleted follows the Delete to setting.
    if (permanently === true || root.settings.deleteMode === "permanently") {
      args = args.concat(["--permanently"])
    }
    deleteProc.command = ["/usr/bin/bash", root.captureScript].concat(args)
    deleteProc.running = true
  }

  // Delete reports how the file left the disk (trash, rm, already gone) on
  // stdout, so the follow-up happens when the stream closes rather than on exit.
  function handleDelete(stdout) {
    var result = Model.parseCaptureResult(stdout)
    var target = root.deletingPath
    root.deletingPath = ""
    if (root.currentFile === target) {
      root.currentFile = ""
      // The card's subject is gone; an action list pointing at nothing is worse
      // than going back to where the shot was chosen from.
      if (root.stage === "result") root.setStage("menu")
    }
    root.refreshShots()
    root.notify((result.ok
      ? Model.deleteVerb(result.mode)
      : Model.reasonMessage(result.reason || "delete-failed")) + " " + Model.basename(target))
  }

  function annotateFile(path) {
    if (!path) return
    root.claimTempShot(path)
    Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-launch-tui",
      "/usr/bin/tensaku-edit", String(path)])
  }

  // A link out of the card, handed to the desktop's own opener. Nothing about the
  // card's subject changes, so the screen stays where it is.
  function openUrl(url) {
    var target = String(url || "")
    if (target.indexOf("https://") !== 0) return
    Quickshell.execDetached(["/usr/bin/xdg-open", target])
  }

  function shareFile(path) {
    if (!path) return
    root.claimTempShot(path)
    Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-menu-share", "file", String(path)])
  }

  function revealFile(path) {
    if (!path) return
    root.claimTempShot(path)
    root.runAction(["/usr/bin/bash", "-c",
      "if command -v nautilus >/dev/null 2>&1; then exec nautilus --select \"$1\"; fi;"
      + " exec xdg-open \"$(dirname -- \"$1\")\"", "snapmenu-reveal", String(path)])
  }

  function revealFolder(path) {
    if (!path) return
    root.runAction(["/usr/bin/bash", "-c",
      "if command -v nautilus >/dev/null 2>&1; then exec nautilus --new-window \"$1\"; fi;"
      + " exec xdg-open \"$1\"", "snapmenu-reveal-dir", String(path)])
  }

  function pickFile() {
    if (root.busy) return
    root.busy = true
    root.opened = false
    pickProc.command = [root.omarchyPath + "/bin/omarchy-file-select",
      "--title", "Snapmenu · Open image", "--extensions", "png jpg jpeg webp"]
    pickProc.running = true
  }

  function pickExportDir() {
    if (root.busy) return
    root.busy = true
    root.opened = false
    dirProc.command = [root.omarchyPath + "/bin/omarchy-file-select",
      "--title", "Snapmenu · Export folder", "--directory"]
    dirProc.running = true
  }

  function runAction(argv, callback) {
    root.actionCallback = callback || null
    actionProc.command = argv
    actionProc.running = true
  }

  // One command from a payload: the dropdown's vocabulary, mapped onto the same
  // functions the overlay's own menu uses.
  function runCommand(command) {
    var c = command || {}
    var action = String(c.action || "")
    // A capture asked for from the bar dropdown: the popout is a full-screen layer
    // of Omarchy's own (omarchy-keyboard-panel), so its fade-out is not covered by
    // the no-anim rule this plugin sets for its own namespace.
    if (action === "capture") {
      root.captureFromPopout = true
      root.settleArea = String(c.settleArea || "")
    }

    if (c.stage) {
      root.setStage(String(c.stage))
      root.opened = true
      root.refreshEnvironment()
      root.focusCard()
      return
    }
    if (action === "capture") {
      root.runCapture(String(c.mode || "smart"))
      return
    }
    if (action === "set-delay") {
      root.persistSettings({ delay: Number(c.value) })
      return
    }
    if (action === "record") {
      root.startRecording()
      return
    }
    if (action === "stop-record") {
      root.stopRecording()
      return
    }
    if (action === "open") {
      root.pickFile()
      return
    }
    if (action === "from-clipboard") {
      root.openFromClipboard()
      return
    }
    if (action === "set-setting") {
      // One generic door for scripts and the live tests: {"key": …, "value": …}
      var key = String(c.key || "")
      if (key) {
        var patch = {}
        patch[key] = c.value
        root.persistSettings(patch)
      }
      return
    }
    if (action === "reset-export-dir") {
      root.persistSettings({ exportDir: "" })
      return
    }
    if (action === "set-export-dir") {
      root.persistSettings({ exportDir: String(c.value || "") })
      return
    }
    if (action === "capture-at") {
      root.captureAreaAt(String(c.geometry || ""))
      return
    }
    root.notify("Unknown command: " + (action || "?"))
  }

  function activate(row) {
    if (!row || !Model.rowSelectable(row)) return
    root.trace("activate:" + String(row.id || ""))
    var action = String(row.action || "")
    var path = String(row.path || root.currentFile || "")

    if (action === "capture") root.runCapture(row.mode)
    else if (action === "record") root.startRecording()
    else if (action === "stop-record") root.stopRecording()
    else if (action === "cycle-delay") root.persistSettings({ delay: Model.nextDelay(root.settings.delay) })
    else if (action === "cycle-glaze") root.persistSettings({ glaze: Model.nextGlaze(root.settings.glaze) })
    else if (action === "cycle-card-width") {
      root.persistSettings({ cardWidth: Model.nextCardWidth(root.settings.cardWidth) })
    }
    else if (action === "cycle-dim") root.persistSettings({ dim: Model.nextDim(root.settings.dim) })
    else if (action === "open-url") root.openUrl(String(row.url || ""))
    else if (action === "cycle-delete-mode") {
      root.persistSettings({ deleteMode: Model.nextDeleteMode(root.settings.deleteMode) })
    }
    else if (action === "open") root.pickFile()
    else if (action === "from-clipboard") root.openFromClipboard()
    else if (action === "history") { root.setStage("history"); root.refreshShots() }
    else if (action === "settings") root.setStage("settings")
    else if (action === "about") root.setStage("about")
    else if (action === "menu") root.setStage("menu")
    else if (action === "open-shot") { root.currentFile = path; root.setStage("result") }
    else if (action === "copy") root.copyCurrent()
    else if (action === "annotate") root.annotateFile(path)
    else if (action === "share") root.shareFile(path)
    else if (action === "reveal") root.revealFile(path)
    else if (action === "reveal-dir") root.revealFolder(root.shotDir)
    else if (action === "delete") {
      root.requestDelete(path)
      return
    } else if (action === "toggle-setting") root.toggleSetting(row.key)
    else if (action === "choose-export-dir") root.pickExportDir()
    else if (action === "reset-export-dir") root.persistSettings({ exportDir: "" })

    // Rows that hand the shot off close the card in the same breath.
    if (Model.actionHandsOff(action)) root.afterHandoff()

    root.cursorActive = true
    root.clampSelection()
  }

  function activateSelected() {
    var row = root.rows[root.selectedIndex]
    if (row && row.enabled === false) {
      root.notify(row.id === "previous" ? Model.reasonMessage("no-previous") : "Not available")
      return
    }
    root.activate(row)
  }

  // The file an action applies to: the one on the action card, or the history
  // row under the cursor.
  function activeFile() {
    if (root.stage === "history") {
      var row = root.rows[root.selectedIndex]
      if (row && row.kind === "shot") return String(row.path || "")
      return ""
    }
    return root.currentFile
  }

  function deleteActive() {
    root.requestDelete(root.activeFile())
  }

  // Deleting is immediate unless the Confirm deletion setting asks for a question
  // first. The Delete row and the X key both come through here, so they cannot
  // disagree about what the setting means.
  function requestDelete(path) {
    if (!path) return
    if (Model.needsConfirm("delete", root.settings)) {
      root.deleteTarget = path
      root.deleteConfirmOpen = true
      return
    }
    root.removeFile(path)
  }

  // The history buttons at the foot of the card, and the left/right arrow keys,
  // walk the recent shots. The list is newest first, so "older" is backwards.
  function stepShot(direction) {
    var next = Model.neighbourShot(root.shots, root.currentFile, String(direction || "older"))
    if (!next || next === root.currentFile) return "none"
    root.currentFile = next
    root.currentWidth = 0
    root.currentHeight = 0
    root.currentTemporary = false
    root.setStage("result")
    root.opened = true
    root.focusCard()
    return "ok"
  }

  // Walking the history screen's own list: the chevrons and the arrow keys move
  // the cursor from the newest shot downwards, and stop at the ends.
  function stepHistory(direction) {
    var at = Model.stepShotRow(root.rows, root.selectedIndex, String(direction || "older"))
    root.cursorActive = true
    root.selectedIndex = at
    return "ok"
  }

  function canStepHistory(direction) {
    return Model.stepShotRow(root.rows, root.selectedIndex, String(direction || "older"))
      !== Model.clampIndex(root.rows, root.selectedIndex)
  }

  function canStepShot(direction) {
    return Model.neighbourShot(root.shots, root.currentFile, String(direction || "older")) !== ""
  }

  function goBack() {
    if (root.deleteConfirmOpen) {
      root.deleteConfirmOpen = false
      return
    }
    if (root.countingDown) {
      root.cancelCountdown()
      return
    }
    // The card is where a shot is finished with, so Escape closes the whole thing
    // rather than dropping back to the menu: the shot is already saved or copied, and
    // there is nothing left to choose from. The menu, history, settings and about are
    // steps on the way somewhere else, so those do step back.
    if (root.stage === "menu" || root.stage === "result") root.dismiss()
    else root.setStage("menu")
  }

  function confirmDelete() {
    var target = root.deleteTarget
    root.deleteConfirmOpen = false
    root.deleteTarget = ""
    if (!target) return
    root.removeFile(target)
  }

  function cancelDelete() {
    root.deleteConfirmOpen = false
    root.deleteTarget = ""
  }

  function footerHint() {
    if (root.countingDown) return "Esc cancels the self-timer"
    if (root.stage === "history") return "Enter open · ←→ browse · C copy · Esc back"
    if (root.stage === "result") return "C copy · ←→ history · Esc close"
    if (root.stage === "settings") return "Enter toggle · Esc back"
    if (root.stage === "about") return "Esc back"
    return "Enter run · D timer · Esc close"
  }

  function stageTitle() {
    if (root.stage === "history") return "Capture History"
    // Never the file name: a long one would run into the hint beside it and
    // push the rows around. The shot identifies itself under the preview.
    if (root.stage === "result") return "Screenshot"
    if (root.stage === "settings") return "Settings"
    if (root.stage === "about") return "About Snapmenu"
    return "Snapmenu"
  }

  // ---------------------------------------------------------------- timers

  Timer {
    id: countdownTimer
    interval: 1000
    repeat: true
    onTriggered: {
      root.countdown = root.countdown - 1
      if (root.countdown <= 0) {
        countdownTimer.stop()
        root.beginCapture()
      }
    }
  }

  // A crop is a bash process plus a cropper. If either hangs, the picker would sit
  // there with a disabled MouseArea and its keys swallowed — a surface that only the
  // IPC or a shell restart could clear. This is the way out.
  Timer {
    id: cropWatchdog
    interval: 5000
    onTriggered: {
      root.trace("crop-watchdog")
      root.notify("The crop did not finish")
      root.cancelSelection()
    }
  }

  Timer {
    id: graceTimer
    // Only enough for the card to start unmapping: bin/snapmenu-capture.sh waits
    // for the layer surface itself (hyprctl layers) before it freezes, so a sleep
    // here is latency for nothing — it was 50ms of the click-to-picker time.
    interval: 0
    onTriggered: root.startCaptureProcess()
  }

  Timer {
    id: selectionTimer
    // Long enough for one frame with the picker's chrome hidden, which the grim
    // fallback needs and a file crop does not — see finishSelection().
    interval: 1
    onTriggered: root.requestCrop()
  }


  Timer {
    id: toastTimer
    interval: 2600
    onTriggered: root.toast = ""
  }

  // -------------------------------------------------------------- processes

  Process {
    id: captureProc
    // Reading the collector in onExited races the stream shutdown and yields an
    // empty string; the data is only guaranteed at onStreamFinished.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishCapture(String(text || ""))
    }
  }

  Process {
    id: freezeProc
    property int token: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleFreeze(String(text || ""))
    }
  }

  function handleFreeze(stdout) {
      if (freezeProc.token !== root.captureToken) return
      root.trace("handleFreeze")
      var result = Model.parseCaptureResult(stdout)
      if (!result.ok || !result.path) {
        root.abortCapture(result.reason || "freeze-failed")
        return
      }

      root.freezePath = result.path
      root.freezeOriginX = result.originX
      root.freezeOriginY = result.originY
      root.freezeWidth = result.width
      root.freezeHeight = result.height
      root.freezeScale = result.monitor && result.monitor.scale
        ? Number(result.monitor.scale) : 1
      root.cropperAvailable = result.cropper === true
      root.selectorScreen = root.screenForName(result.monitor ? result.monitor.name : "")

      if (root.scriptedGeometry) {
        // A scripted geometry is given in global coordinates; the overlay draws
        // in monitor-local ones. Map the frozen frame with the rect pre-selected
        // and its chrome hidden, so the crop below goes through exactly the same
        // path a drag does.
        var wanted = Model.parseGeometry(root.scriptedGeometry)
        if (!wanted) {
          root.hideSelector()
          root.abortCapture("no-geometry")
          return
        }
        root.pendingRect = Model.normalizeDrag(wanted.x - root.freezeOriginX,
          wanted.y - root.freezeOriginY, wanted.x - root.freezeOriginX + wanted.width,
          wanted.y - root.freezeOriginY + wanted.height)
        root.selectorCapturing = true
        root.selectorActive = true
        selectionTimer.restart()
        return
      }

      // The picker goes up now, on the frame that is already on disk: it is usable
      // for a drag straight away, and the snapping rectangles land a moment later.
      root.selectorActive = true
      root.trace("selectorActive")
      rectsProc.token = root.captureToken
      rectsProc.command = ["/usr/bin/bash", root.captureScript, "--rects"]
      rectsProc.running = true
  }

  Process {
    id: rectsProc
    property int token: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleRects(String(text || ""))
    }
  }

  function handleRects(stdout) {
      if (rectsProc.token !== root.captureToken) return
      // Snapping rectangles are a convenience: a failed query must still leave
      // a usable freeform selector rather than a frozen screen and no overlay.
      var parsed = Model.parseRects(stdout)
      root.selectorRects = parsed.ok
        ? Model.localRects(parsed.rects, root.freezeOriginX, root.freezeOriginY,
          root.freezeWidth, root.freezeHeight)
        : []
      // Only a session that is still running: a cancelled pick has already hidden the
      // picker and cleared the frame path, and re-mapping it here left a dead,
      // frameless, keyboard-exclusive surface on screen.
      if (root.busy && root.freezePath !== "" && !root.selectorActive) {
        root.selectorActive = true
        root.trace("selectorActive")
      } else {
        root.trace("rects")
      }
  }

  Process {
    id: cropProc
    property int token: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var stdout = String(text || "")
        // A crop the user has since cancelled, or a card they have closed: the reply
        // is real but it belongs to a session that is over.
        if (cropProc.token !== root.captureToken) return
        root.hideSelector()
        root.finishCapture(stdout)
      }
    }
  }

  Process {
    id: clipboardProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleClipboard(String(text || ""))
    }
  }

  function handleClipboard(stdout) {
      var result = Model.parseCaptureResult(stdout)
      root.busy = false
      if (!result.ok) {
        root.setStage("menu")
        root.opened = true
        root.notify(Model.reasonMessage(result.reason || "clipboard-failed"))
        return
      }
      root.currentFile = result.path
      root.currentWidth = result.width
      root.currentHeight = result.height
      root.currentTemporary = false
      root.nowMs = Date.now()
      root.refreshShots()
      root.setStage("result")
      root.opened = true
      root.focusCard()
  }

  Process {
    id: recordingProc
    onExited: function () {
      root.busy = false
      root.opened = true
      root.setStage("menu")
      if (!recordProc.running) recordProc.running = true
    }
  }

  Process {
    id: listProc
    command: ["/usr/bin/find", root.shotDir, "-maxdepth", "1", "-type", "f",
      "-name", "*.png", "-printf", "%T@\t%s\t%p\n"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.shots = Model.parseRecentShots(String(text || ""), 24)
        root.nowMs = Date.now()
        root.clampSelection()
      }
    }
  }

  Process {
    id: statProc
    command: ["/usr/bin/stat", "-c", "%s", root.stateDir + "/last-region"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var size = Number(String(text || "").replace(/^\s+|\s+$/g, ""))
        root.hasPrevious = isFinite(size) && size > 0
      }
    }
  }

  Process {
    id: recordProc
    command: ["/usr/bin/pgrep", "-f", "^gpu-screen-recorder"]
    onExited: function (exitCode) { root.recording = exitCode === 0 }
  }

  Process {
    id: pickProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.busy = false
        root.opened = true
        var picked = String(text || "").split("\n")[0].replace(/^\s+|\s+$/g, "")
        if (!picked) {
          root.setStage("menu")
          return
        }
        root.currentFile = picked
        root.currentWidth = 0
        root.currentHeight = 0
        root.currentTemporary = false
        root.setStage("result")
        root.focusCard()
      }
    }
  }

  Process {
    id: dirProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.busy = false
        root.opened = true
        root.setStage("settings")
        var picked = String(text || "").split("\n")[0].replace(/^\s+|\s+$/g, "")
        if (picked) root.persistSettings({ exportDir: picked })
      }
    }
  }

  // Omarchy fades layer surfaces out, and the picker freezes the screen a few
  // milliseconds after the card starts unmapping — long enough to catch that
  // fade. One rule turns it off for the surfaces this plugin draws.
  Process {
    id: noAnimProc
    running: true
    command: ["/usr/bin/bash", root.captureScript, "--no-anim"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = Model.parseCaptureResult(text)
        root.animationsDisabled = result.ok && result.noAnim
        if (!root.animationsDisabled) root.trace("animations: layer fade still on")
      }
    }
  }

  Process {
    id: clipboardProbe
    running: true
    command: ["/usr/bin/test", "-x", root.clipboardHelper]
    onExited: function (exitCode) {
      root.clipboardBackend = exitCode === 0 ? "native" : "wl-copy"
      if (exitCode !== 0) root.trace("clipboard: wl-copy fallback")
    }
  }

  Process {
    id: actionProc
    onExited: function () {
      var callback = root.actionCallback
      root.actionCallback = null
      if (callback) callback()
    }
  }

  Process {
    id: deleteProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleDelete(String(text || ""))
    }
  }

  // ---------------------------------------------------------------- config

  FileView {
    id: shellConfigFile
    path: root.shellConfigPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyShellConfig(text())
    onLoadFailed: function () { root.applyShellConfig("") }
  }

  FileView {
    id: userDirsFile
    path: root.userDirsPath
    printErrors: false
    onLoaded: {
      var dir = Model.xdgPicturesDir(text(), root.home)
      if (dir) root.picturesDir = dir
    }
  }

  // ------------------------------------------------------------------- ui

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "snapmenu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // The setting, clamped to what fits: the preview fills this width, so the card's
    // size is the size of the shot you are looking at.
    readonly property int cardWidth: Math.min(
      Style.space(root.settings.cardWidth), width - Style.gapsOut * 2)
    readonly property int cardMaxHeight: height - Style.space(80)
    readonly property int listMaxHeight: cardMaxHeight - Style.space(120)

    Rectangle {
      anchors.fill: parent
      visible: !root.countingDown
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      enabled: !root.countingDown && !root.deleteConfirmOpen
      onClicked: {
        root.trace("scrim-click")
        root.dismiss()
      }
    }

    // Self-timer pill: the only thing on screen during the wait, and it is
    // withdrawn itself before grim runs.
    BorderSurface {
      id: countdownPill
      visible: root.countingDown
      // Hovering the pill turns the hint into a button: the countdown is the one
      // moment a click should cancel rather than capture.
      property bool pointerOn: false
      width: countdownRow.implicitWidth + Style.space(24)
      height: Style.space(38)
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Style.space(48)
      radius: root.cornerRadius
      color: root.background
      borderSpec: countdownPill.pointerOn
        ? Border.controlSpec("hover-cursor", root.selectedText, root.selectedText)
        : root.borderSpec

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onContainsMouseChanged: countdownPill.pointerOn = containsMouse
        onClicked: root.cancelCountdown()
      }

      Row {
        id: countdownRow
        anchors.centerIn: parent
        spacing: Style.space(10)

        Text {
          textFormat: Text.PlainText
          text: Model.ICON.timer
          color: root.selectedText
          font.family: root.fontFamily
          font.pixelSize: Style.font.iconLarge
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          textFormat: Text.PlainText
          text: root.countdown + " s"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          textFormat: Text.PlainText
          text: countdownPill.pointerOn
            ? (Model.ICON.close + "  Cancel")
            : "Esc to cancel"
          color: countdownPill.pointerOn ? root.selectedText : root.foreground
          opacity: countdownPill.pointerOn ? 1 : 0.55
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }

    BorderSurface {
      id: card
      visible: !root.countingDown
      width: panel.cardWidth

      // Resizing: drag either edge, and the card grows the way a centred window
      // does — both sides out together, snapping to the offered widths. The grip is
      // invisible until you reach for it, so the card stays clean.
      Repeater {
        model: ["left", "right"]

        delegate: Item {
          required property string modelData
          width: Style.space(10)
          height: parent.height
          x: modelData === "left" ? -width / 2 : parent.width - width / 2
          z: 10

          // Visible at rest, however faintly: a handle nobody can see is a feature
          // nobody has, which is exactly how "I can't resize the card" happened.
          Rectangle {
            anchors.fill: parent
            anchors.margins: Style.space(2)
            radius: width / 2
            color: grip.pressed || grip.containsMouse
              ? Util.alpha(Color.foreground, 0.4)
              : Util.alpha(Color.foreground, 0.14)
          }

          MouseArea {
            id: grip
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.SizeHorCursor
            onPositionChanged: function (mouse) {
              if (!pressed) return
              // Mapped rather than arithmetic: the grip sits on the card's edge, so
              // the pointer has two offsets between it and the card's parent.
              var here = grip.mapToItem(card.parent, mouse.x, mouse.y)
              var raw = Model.dragCardWidth(modelData, here.x, card.parent.width / 2, root.width)
              var snapped = Model.normalizeCardWidth(raw)
              if (snapped !== root.settings.cardWidth) {
                root.persistSettings({ cardWidth: snapped })
              }
            }
          }
        }
      }
      height: Math.min(panel.cardMaxHeight, header.height + content.implicitHeight + Style.space(34))
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter
      radius: root.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
          if (root.deleteConfirmOpen) {
            if (deleteConfirm.handleKey(event)) event.accepted = true
            return
          }
          if (root.busy) {
            if (event.key === Qt.Key_Escape) {
              root.dismiss()
              event.accepted = true
            }
            return
          }
          if (root.countingDown) {
            if (event.key === Qt.Key_Escape) {
              root.cancelCountdown()
              event.accepted = true
            }
            return
          }

          if (event.key === Qt.Key_Escape) {
            root.trace("key:" + event.key)
            root.goBack()
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.moveCursor(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.moveCursor(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.moveCursor(-6)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.moveCursor(6)
            event.accepted = true
          } else if (root.stage === "history" && event.key === Qt.Key_Left) {
            root.stepHistory("older")
            event.accepted = true
          } else if (root.stage === "history" && event.key === Qt.Key_Right) {
            root.stepHistory("newer")
            event.accepted = true
          } else if (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal) {
            root.persistSettings({ cardWidth: Model.nextCardWidth(root.settings.cardWidth) })
            event.accepted = true
          } else if (event.key === Qt.Key_Minus || event.key === Qt.Key_Underscore) {
            root.persistSettings({ cardWidth: Model.prevCardWidth(root.settings.cardWidth) })
            event.accepted = true
          } else if (root.stage === "result" && event.key === Qt.Key_Right) {
            // Above the activate clause on purpose: → steps through the shots on the
            // card, and only Enter runs the selected row.
            root.stepShot("newer")
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
            || event.key === Qt.Key_Right) {
            root.activateSelected()
            event.accepted = true
          } else if (event.key === Qt.Key_D && root.stage === "menu") {
            root.persistSettings({ delay: Model.nextDelay(root.settings.delay) })
            event.accepted = true
          } else if (event.key === Qt.Key_C) {
            if (root.stage === "history" || root.stage === "result") root.copyCurrent()
            else if (root.stage === "menu") root.runCapture("region")
            event.accepted = true
          } else if (root.stage === "result" && event.key === Qt.Key_Left) {
            root.stepShot("older")
            event.accepted = true
          } else if (event.key === Qt.Key_A && (root.stage === "result" || root.stage === "history")) {
            root.annotateFile(root.activeFile())
            event.accepted = true
          } else if (event.key === Qt.Key_S && (root.stage === "result" || root.stage === "history")) {
            root.shareFile(root.activeFile())
            event.accepted = true
          } else if (event.key === Qt.Key_R && (root.stage === "result" || root.stage === "history")) {
            root.revealFile(root.activeFile())
            event.accepted = true
          } else if (event.key === Qt.Key_X && (root.stage === "result" || root.stage === "history")) {
            root.deleteActive()
            event.accepted = true
          } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9 && root.stage === "menu") {
            var position = event.key - Qt.Key_0
            var index = Model.nthEnabledIndex(root.rows, position)
            if (index >= 0) {
              root.cursorActive = true
              root.selectedIndex = index
              root.activateSelected()
            }
            event.accepted = true
          } else if (event.key === Qt.Key_O && root.stage === "menu") {
            root.pickFile()
            event.accepted = true
          } else if (event.key === Qt.Key_H && root.stage === "menu") {
            root.setStage("history")
            root.refreshShots()
            event.accepted = true
          }
        }

        Column {
          id: content
          anchors.fill: parent
          anchors.topMargin: card.contentTopInset
          anchors.rightMargin: card.contentRightInset
          anchors.bottomMargin: card.contentBottomInset
          anchors.leftMargin: card.contentLeftInset
          spacing: Style.spacing.md

          Item {
            id: header
            width: parent.width
            height: Math.max(Style.space(30), Style.font.heading + Style.spacing.lg)

            Text {
              id: headerHint
              textFormat: Text.PlainText
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.toast ? root.toast : root.footerHint()
              color: root.toast ? root.selectedText : root.foreground
              opacity: root.toast ? 1 : 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignRight
              elide: Text.ElideRight
              width: Math.min(implicitWidth, parent.width * 0.5)
            }

            Row {
              anchors.left: parent.left
              anchors.right: headerHint.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                id: headerGlyph
                textFormat: Text.PlainText
                text: Model.ICON.camera
                color: root.selectedText
                font.family: root.fontFamily
                font.pixelSize: Style.font.iconLarge
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: headerTitle
                textFormat: Text.PlainText
                text: root.stageTitle()
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.weight: Font.Medium
                elide: Text.ElideRight
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, parent.width - headerGlyph.width - parent.spacing)
              }
            }
          }

          Item {
            id: preview
            width: parent.width
            height: (root.stage === "result" && root.currentFile) ? Math.min(Style.space(210), parent.height * 0.4) : 0
            visible: height > 0

            Rectangle {
              anchors.fill: parent
              color: Util.alpha(root.foreground, 0.05)
              radius: Style.space(4)
            }

            Image {
              anchors.fill: parent
              anchors.margins: 1
              source: (root.stage === "result" && root.currentFile) ? Util.fileUrl(root.currentFile) : ""
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              cache: false
              sourceSize.width: preview.width * Screen.devicePixelRatio
              sourceSize.height: preview.height * Screen.devicePixelRatio
            }

            Text {
              // Flush with the card's own left edge, the one the rows and the header
              // start from: the preview is inset by the card's padding already, and a
              // margin here put the size line six pixels right of everything else.
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.leftMargin: 0
              anchors.rightMargin: Style.space(6)
              anchors.bottomMargin: Style.space(6)
              textFormat: Text.PlainText
              text: {
                // The name is the card's header; over the picture it is noise. What
                // is worth saying down here is how big it is and, when the card is
                // showing an older shot, when it was taken.
                var parts = []
                var dimensions = Model.dimensionLabel(root.currentWidth, root.currentHeight)
                if (dimensions) parts.push(dimensions)
                var age = Model.shotAge(root.shots, root.currentFile, root.nowMs)
                if (age) parts.push(age)
                return parts.join("  ·  ")
              }
              elide: Text.ElideMiddle
              color: root.foreground
              opacity: 0.75
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          ListView {
            id: resultList
            width: parent.width
            height: Math.min(panel.listMaxHeight, contentHeight)
            model: root.rows
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            spacing: 0
            currentIndex: root.selectedIndex

            delegate: ActionRow {
              required property var modelData
              required property int index

              width: resultList.width
              row: modelData
              hasCursor: root.cursorActive && index === root.selectedIndex
              foreground: root.foreground
              selectedText: root.selectedText
              selectedBackground: root.selectedBackground
              selectedBorderSpec: root.selectedBorderSpec
              fontFamily: root.fontFamily
              cornerRadius: root.cornerRadius
              onHovered: {
                root.cursorActive = true
                root.selectedIndex = index
              }
              onActivated: {
                root.cursorActive = true
                root.selectedIndex = index
                root.activateSelected()
              }
            }
          }

          // Browsing the history from the card: two buttons side by side, with
          // the position at the end of the row. Left and right arrow keys do the
          // same thing (see the key handler above).
          Item {
            // Only where it means something: on the menu and settings screens
            // these arrows have nowhere to step to, and a leftover hover box and
            // tooltip from the card would sit in the middle of the menu.
            visible: root.stage === "result" || root.stage === "history"
            width: parent.width
            height: visible ? Style.space(42) : 0

            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              PanelActionButton {
                iconText: Model.ICON.chevronLeft
                tooltipText: "Older shot"
                foreground: root.foreground
                hasCursor: false
                size: Style.space(40)
                fontSize: Style.font.display
                enabled: root.stage === "history"
                  ? root.canStepHistory("older") : root.canStepShot("older")
                onClicked: root.stage === "history"
                  ? root.stepHistory("older") : root.stepShot("older")
              }

              PanelActionButton {
                iconText: Model.ICON.chevronRight
                tooltipText: "Newer shot"
                foreground: root.foreground
                hasCursor: false
                size: Style.space(40)
                fontSize: Style.font.display
                enabled: root.stage === "history"
                  ? root.canStepHistory("newer") : root.canStepShot("newer")
                onClicked: root.stage === "history"
                  ? root.stepHistory("newer") : root.stepShot("newer")
              }
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: {
                // On the history screen the cursor is what is being walked, so the
                // position counts rows; on the card it is the shot being shown.
                var at = root.stage === "history"
                  ? root.selectedIndex
                  : Model.indexOfShot(root.shots, root.currentFile)
                return (at >= 0 && root.shots.length > 0)
                  ? (at + 1) + " / " + root.shots.length : ""
              }
              color: root.foreground
              opacity: 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }
        }

        ConfirmDialog {
          id: deleteConfirm
          anchors.fill: parent
          opened: root.deleteConfirmOpen
          z: 10
          message: "Delete " + Model.basename(root.deleteTarget) + "?"
          confirmText: "Delete"
          cancelText: "Keep"
          background: root.background
          foreground: root.foreground
          scrim: Util.alpha(root.background, 0.5)
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.cancelDelete()
          onConfirmed: root.confirmDelete()
        }
      }
    }
  }

  // The frozen-frame selector. Mapped only while a selection is in progress, on
  // the monitor that was frozen.
  RegionSelector {
    id: selector
    visible: root.selectorActive
    onFrameReadyChanged: if (frameReady) root.trace("frameReady")
    targetScreen: root.selectorScreen
    freezePath: root.freezePath
    // No origin is passed: the rects arrive already translated into the frame's own
    // coordinates by Model.localRects, and the crop uses root.freezeOrigin* directly.
    rects: root.selectorRects
    mode: root.selectorMode
    capturing: root.selectorCapturing
    glazeAlpha: root.settings.glaze
    scrimAlpha: root.settings.dim
    onSelected: function (x, y, width, height) { root.finishSelection(x, y, width, height) }
    onCancelled: root.cancelSelection()
  }

  // IPC methods so keybindings can go straight to a capture without opening
  // the menu: omarchy-shell shell call io.github.analytically.snapmenu captureArea ''
  function captureArea(): string {
    root.opened = true
    root.setStage("menu")
    root.runCapture("region")
    return "ok"
  }

  // Scripted area capture: freeze the monitor, then crop the given global
  // logical geometry ("X,Y WxH") off that frozen frame without any dragging.
  // Used by keybindings and by the plugin's own end-to-end test.
  function captureAreaAt(geometry): string {
    var wanted = String(geometry || "")
    if (!Model.parseGeometry(wanted)) return "no-geometry"
    if (root.busy) return "busy"
    root.busy = true
    root.pendingMode = "region"
    root.scriptedGeometry = wanted
    root.opened = false
    root.startFreeze("region")
    return "ok"
  }

  // Development aid: what the plugin thinks it is doing right now.
  function debugState(): string {
    return JSON.stringify({
      stage: root.stage,
      currentFile: root.currentFile,
      opened: root.opened,
      busy: root.busy,
      countingDown: root.countingDown,
      pendingMode: root.pendingMode,
      selectorActive: root.selectorActive,
      selectorMode: root.selectorMode,
      freezePath: root.freezePath,
      freezeOriginX: root.freezeOriginX,
      freezeOriginY: root.freezeOriginY,
      freezeWidth: root.freezeWidth,
      freezeHeight: root.freezeHeight,
      freezeScale: root.freezeScale,
      rectCount: root.selectorRects.length,
      screenName: root.selectorScreen ? String(root.selectorScreen.name) : "",
      shotCount: root.shots.length,
      delay: root.settings.delay,
      showResult: root.settings.showResult,
      traceLog: root.traceLog,
      hoverRect: selector.hoverRect,
      keyboardRect: selector.keyboardRect,
      keyboardActive: selector.keyboardActive,
      lastKey: selector.lastKey,
      hasKeyFocus: selector.hasKeyFocus,
      cardFocus: keyCatcher.activeFocus,
      deleteConfirmOpen: root.deleteConfirmOpen,
      canStepOlder: root.canStepShot("older"),
      canStepNewer: root.canStepShot("newer"),
      frameReady: selector.frameReady,
      glazeAlpha: selector.glazeAlpha,
      settingGlaze: root.settings.glaze,
      showRect: selector.showRect,
      dragMode: selector.dragMode,
      cropper: root.cropperAvailable,
      clipboardBackend: root.clipboardBackend,
      animationsDisabled: root.animationsDisabled,
      settleArea: root.settleArea,
      selectorWidth: selector.width,
      selectorHeight: selector.height,
      selection: selector.selection,
      rects: selector.rects
    })
  }

  // Abort whatever is in flight (a self-timer, a freeze, a live selection).
  function cancelCapture(): string {
    if (root.countingDown) {
      root.cancelCountdown()
      return "ok"
    }
    if (root.selectorActive) {
      root.cancelSelection()
      return "ok"
    }
    if (root.busy) {
      root.abortCapture("cancelled")
      return "ok"
    }
    return "idle"
  }

  function captureScreen(): string {
    root.opened = true
    root.setStage("menu")
    root.runCapture("fullscreen")
    return "ok"
  }

  function captureSmart(): string {
    root.opened = true
    root.setStage("menu")
    root.runCapture("smart")
    return "ok"
  }

  function capturePrevious(): string {
    root.opened = true
    root.setStage("menu")
    root.runCapture("previous")
    return "ok"
  }

  function openHistory(): string {
    root.opened = true
    root.setStage("history")
    root.refreshEnvironment()
    return "ok"
  }
}
