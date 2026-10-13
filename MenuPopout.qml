import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "SnapmenuModel.js" as Model

// The dropdown half of snapmenu: the capture menu, anchored under the camera
// glyph in the bar.
//
// It renders the same rows the full overlay menu renders (both come from
// Model.menuRows) and sends the overlay a command for whatever is clicked,
// instead of doing any of the work itself. That keeps one implementation of
// "take a screenshot" — the overlay — and lets the dropdown stay a menu.
//
// The bar owns the popup: qs.Ui.KeyboardPanel positions it against the icon,
// grabs the pointer for click-outside dismissal, and the bar's popout
// coordinator closes it when another widget's popup opens.
Item {
  id: root

  // Injected by BarWidget.qml.
  property var bar: null
  property var anchorItem: null
  property var hostWidget: null
  property var settings: ({})

  readonly property string pluginId: "io.github.analytically.snapmenu"
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME")
    || (Quickshell.env("HOME") + "/.local/state")) + "/snapmenu"

  readonly property int delay: {
    var value = settings ? Number(settings.delay) : 0
    return isFinite(value) && value > 0 ? value : 0
  }

  property bool hasPrevious: false
  property bool recording: false
  property var rows: []
  property int selectedIndex: 0
  property string toast: ""

  readonly property bool opened: panel.open
  readonly property bool popoutSwitchClosing: panel.popoutSwitchClosing

  // ---- lifecycle, forwarded from the widget ---------------------------------

  function open() {
    root.toast = ""
    root.reload()
    panel.open = true
  }

  function close() {
    panel.open = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function closeForPopoutSwitch() {
    // KeyboardPanel has the flag but not qs.Ui.Panel's helper, so do what Panel
    // does: mark the switch, close, and clear it once the bar has moved on.
    panel.popoutSwitchClosing = true
    panel.close()
    Qt.callLater(function () { panel.popoutSwitchClosing = false })
  }

  // ---- rows -----------------------------------------------------------------

  function reload() {
    root.rows = Model.menuRows({
      hasPrevious: root.hasPrevious,
      delay: root.delay,
      recording: root.recording
      // No shot count here: the dropdown does not need to walk the export
      // folder to be useful, and the row says so instead of guessing zero.
    })
    root.selectedIndex = Model.firstEnabledIndex(root.rows)
    if (!previousProc.running) previousProc.running = true
    if (!recordProc.running) recordProc.running = true
  }

  function rowsJson() {
    return JSON.stringify(root.rows)
  }

  function moveCursor(delta) {
    root.selectedIndex = Model.nextEnabledIndex(root.rows, root.selectedIndex, delta)
  }

  function activate(index) {
    var row = root.rows[index]
    if (!row || !Model.rowSelectable(row)) return
    if (!row.payload) return
    // A setting change keeps the menu open (the row now shows the new value);
    // everything else hands over to the overlay and gets out of the way.
    root.send(row.payload, row.action === "set-delay")
  }

  // The overlay owns every action, so this only forwards the command. If the
  // plugin has no bar entry shell (unlikely — we are that entry), fall back to
  // an IPC call so the row is never a dead button.
  // The rectangle the panel actually paints in. The popup is a full-screen layer of
  // Omarchy's own, so a capture that starts here has to watch this area to not
  // freeze the popout mid-fade; the middle of the screen never changes.
  function settleArea() {
    var origin = panel.cardOrigin
    if (!origin) return ""
    return Math.round(origin.x) + "," + Math.round(origin.y) + " " +
      Math.round(panel.contentWidth) + "x" + Math.round(panel.contentHeight)
  }

  function send(payload, keepOpen) {
    if (!keepOpen) root.close()
    var outgoing = payload
    if (payload.action === "capture") {
      outgoing = {}
      for (var key in payload) outgoing[key] = payload[key]
      outgoing.settleArea = root.settleArea()
    }
    var json = JSON.stringify({ command: outgoing })
    if (root.bar && root.bar.shell && typeof root.bar.shell.summon === "function"
      && root.bar.shell.summon(root.pluginId, json)) return
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", root.pluginId, json])
  }

  // ---- state the rows need ---------------------------------------------------

  Process {
    id: previousProc
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

  // ---- the popup -------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    bar: root.bar
    owner: root.hostWidget
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(370))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    onOpenChanged: if (open) root.reload()

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.activate(root.selectedIndex)
      onReturnRequested: root.activate(root.selectedIndex)
      onCloseRequested: root.close()

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        // The wheel walks the cursor, like the overlay menu.
        WheelHandler {
          onWheel: function (event) {
            root.moveCursor(event.angleDelta.y > 0 ? -1 : 1)
            event.accepted = true
          }
        }

        Column {
          id: column
          width: scroll.width
          spacing: 0

          Repeater {
            model: root.rows

            delegate: ActionRow {
              required property var modelData
              required property int index

              width: column.width
              row: modelData
              hasCursor: index === root.selectedIndex
              foreground: Color.popups.text
              selectedText: Color.accent
              selectedBackground: Util.alpha(Color.foreground, 0.08)
              fontFamily: Style.font.menuFamily
              cornerRadius: Style.cornerRadius
              onHovered: root.selectedIndex = index
              onActivated: {
                root.selectedIndex = index
                root.activate(index)
              }
            }
          }
        }
      }

      // A dimmed row is not a dead button: saying why is friendlier than
      // closing the menu and doing nothing.
      Text {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: Style.space(6)
        visible: root.toast.length > 0
        textFormat: Text.PlainText
        text: root.toast
        color: Color.accent
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
