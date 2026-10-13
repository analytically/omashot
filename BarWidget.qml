import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "SnapmenuModel.js" as Model

// The menu bar half of snapmenu: one glyph that drops the capture menu down from
// the bar, and that says what the plugin is doing.
//
// The widget owns nothing but the popup's lifecycle and the icon's state — the
// menu lives in MenuPopout.qml and every action is executed by the overlay
// (Snapmenu.qml), so this file stays a button plus the wiring the bar needs to
// treat it as a panel owner.
//
//   left click   - drop down the menu
//   middle click - capture history
//   right click  - capture an area straight away
BarWidget {
  id: root
  moduleName: "io.github.analytically.snapmenu"

  readonly property string pluginId: "io.github.analytically.snapmenu"

  readonly property int delay: {
    var value = settings ? Number(settings.delay) : 0
    return isFinite(value) && value > 0 ? value : 0
  }

  property bool recording: false

  // What the glyph, its tint and its tooltip should be: the model decides, so
  // the states are unit tested (see barIcon in SnapmenuModel.js).
  readonly property var icon: Model.barIcon({ recording: root.recording, delay: root.delay })

  function refreshIconState() {
    if (recordProc.running) return
    recordProc.command = ["/usr/bin/pgrep", "--quiet", "-f", "^gpu-screen-recorder"]
    recordProc.running = true
  }

  // ---- the bar's panel contract ---------------------------------------------

  readonly property bool opened: popupLoader.item ? popupLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: popupLoader.item
    ? popupLoader.item.popoutSwitchClosing === true : false

  function open() {
    if (popupLoader.item) popupLoader.item.open()
  }

  function close() {
    if (popupLoader.item) popupLoader.item.close()
  }

  function togglePanel() {
    if (popupLoader.item) popupLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (popupLoader.item) popupLoader.item.closeForPopoutSwitch()
  }

  // The bar identifies a panel by the item mounted in its slot — this widget —
  // while the popup window belongs to MenuPopout.qml. Handing the popup its
  // host keeps the open-panel indicator and popout coordination comparing
  // against the same object the bar does.
  function injectPanel() {
    var target = popupLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function send(payload) {
    var json = JSON.stringify({ command: payload })
    if (root.bar && root.bar.shell && typeof root.bar.shell.summon === "function"
      && root.bar.shell.summon(root.pluginId, json)) return
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", root.pluginId, json])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: {
    injectPanel()
    refreshIconState()
  }
  onSettingsChanged: injectPanel()
  Component.onCompleted: refreshIconState()

  // BarIconButton, not a bare WidgetButton: it is the component the bar's own
  // icon widgets use, so the glyph gets the bar's icon size, the standard slot
  // width and optical centering against its neighbours.
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon.glyph
    active: root.icon.tone !== "idle"
    activeColor: root.icon.tone === "recording" ? Color.urgent : Color.accent
    tooltipText: root.icon.tooltip
    onPressed: function (eventButton) {
      if (!root.bar) return
      if (eventButton === Qt.RightButton) {
        root.send({ action: "capture", mode: "region" })
      } else if (eventButton === Qt.MiddleButton) {
        root.send({ stage: "history" })
      } else {
        root.togglePanel()
      }
    }
  }

  // Recording can start or stop anywhere — a keybinding, Omarchy's own capture
  // menu, its screen-recording indicator — so the glyph follows with a slow
  // poll instead of waiting to be told. One pgrep every five seconds is the
  // cheapest way to stay honest.
  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: root.refreshIconState()
  }

  Process {
    id: recordProc
    onExited: function (exitCode) { root.recording = exitCode === 0 }
  }

  Loader {
    id: popupLoader
    active: true
    source: Qt.resolvedUrl("MenuPopout.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // A bar surface exists per monitor, so the handler that wins the target
  // relays to the others (Ui/BarWidget.broadcast) — the pattern every bar
  // widget with an IPC target uses.
  IpcHandler {
    target: "snapmenu.menu"

    function open(): void { root.broadcast("open") }
    function close(): void { root.broadcast("close") }
    function show(): void { root.broadcast("open") }
    function hide(): void { root.broadcast("close") }
    function toggle(): void { root.broadcast("togglePanel") }

    // Activate a row exactly as a click does: the dropdown sends the row's
    // payload to the overlay through the bar's shell API. Scripts and the live
    // test use this so the real send path is exercised, not a copy of it.
    function activate(index: string): string {
      var item = popupLoader.item
      if (!item) return "no-popup"
      item.activate(parseInt(index, 10) || 0)
      return "ok"
    }

    // The rows this dropdown would render, for scripts and the live test.
    function rows(): string {
      var item = popupLoader.item
      return item && item.rowsJson ? item.rowsJson() : "[]"
    }

    function isOpen(): string {
      return root.opened ? "true" : "false"
    }

    // What the bar glyph is showing right now, and a way to make that fresh
    // before asking (the poll is deliberately slow).
    function icon(): string {
      return JSON.stringify({
        glyph: root.icon.glyph,
        tone: root.icon.tone,
        tooltip: root.icon.tooltip
      })
    }

    function refresh(): void { root.broadcast("refreshIconState") }
  }
}
