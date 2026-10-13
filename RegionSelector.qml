import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import "SnapmenuModel.js" as Model

// The frozen-screen region picker, drawn by the shell instead of by slurp.
//
// The frame shown here was captured by bin/snapmenu-capture.sh --freeze *before*
// this surface was mapped, so the overlay can never appear inside its own
// screenshot. Everything the picker draws (dimming, border, crosshair, size
// label) is kept strictly outside the selection rectangle, which means the
// caller can crop with `grim -g` while this window is still up and get the
// frozen pixels back untouched.
//
//   region - freeform drag; a click without a drag takes the whole monitor
//   smart  - freeform drag, but a click snaps to the window under the cursor
//   window - no dragging: the window under the cursor is highlighted and
//            captured on click
PanelWindow {
  id: selector

  property var targetScreen: null
  property string freezePath: ""
  property var rects: []
  property string mode: "region"
  // While the caller crops, the chrome goes away but the frozen frame stays.
  property bool capturing: false
  // Dimming around the selection, driven by the Selection dim setting. Off by
  // default: the glaze and the hairline say what is chosen, and the rest of the
  // screen stays as readable as it was.
  property real scrimAlpha: 0
  // The wash over a picked window. Visible on a dark theme, mild on a light one.
  // Overridden by the setting; this is the same default it carries.
  property real glazeAlpha: 0.1
  readonly property color scrim: Util.alpha(Color.background, scrimAlpha)

  // Drag state, in overlay-local logical pixels.
  property bool dragging: false
  property real startX: 0
  property real startY: 0
  property real cursorX: 0
  property real cursorY: 0
  property var selection: null
  property var hoverRect: null
  // Tab moves the target between windows without the pointer.
  property var keyboardRect: null
  property bool keyboardActive: false
  // Modifier constraints while dragging: Shift keeps the height and lets the
  // width move (a band); Ctrl does the same as Shift, and Shift with Ctrl freezes
  // the width instead, so only the height moves. (A ratio lock exists in the model
  // but nothing is bound to it.) The locks start from the
  // selection being edited, or from the last one dragged in this session, so a
  // second band can keep the first one's height.
  property string dragMode: "free"
  property real dragLockedWidth: 0
  property real dragLockedHeight: 0
  property real dragLockedRatio: 0
  property real lastDragWidth: 0
  property real lastDragHeight: 0
  property real lastDragRatio: 0

  // Shift and Ctrl both widen a band, Shift+Ctrl runs a column. The mapping
  // lives in the model so the bindings are unit tested; dragRect still knows how
  // to lock the aspect ratio, nothing is bound to it just now.
  function dragModeFor(modifiers) {
    return Model.dragModeFor((modifiers & Qt.ShiftModifier) !== 0,
      (modifiers & Qt.ControlModifier) !== 0)
  }
  // Last key the picker actually received, for debugState.
  property string lastKey: ""
  readonly property bool hasKeyFocus: keys.activeFocus

  signal selected(real x, real y, real width, real height)
  signal cancelled()


  readonly property bool snapMode: mode === "window"
  // The frozen frame is the point of this surface; until it is decoded the drag
  // is not offered (Esc still cancels).
  readonly property bool frameReady: frame.status === Image.Ready
  // The unified capture promise: the gesture decides the target. Pointer hover and
  // Tab both pick windows, a drag overrides both, and a click on empty space
  // means the whole screen.
  readonly property bool unified: mode === "smart" || snapMode
  readonly property var activeRect: dragging || !unified
    ? (dragging ? selection : null)
    : (keyboardActive && keyboardRect ? keyboardRect : (hoverRect || selection))
  readonly property bool showRect: activeRect !== null && activeRect !== undefined
    && activeRect.width > 0 && activeRect.height > 0

  // ---------------------------------------------------------------- legend

  // Says what a gesture will do, and names the window the pointer or Tab has
  // picked. The unified mode is the only one that needs explaining.
  function legendText() {
    return Model.legendText(mode)
  }

  function reset() {
    dragging = false
    selection = null
    hoverRect = null
    keyboardRect = null
    keyboardActive = false
    // Locks and remembered shapes do not carry into the next capture: a Shift band
    // in the second pick must not inherit the first one's height.
    dragLockedWidth = 0
    dragLockedHeight = 0
    dragLockedRatio = 0
    lastDragWidth = 0
    lastDragHeight = 0
    lastDragRatio = 0
    cursorX = width / 2
    cursorY = height / 2
    // `capturing` is deliberately not set here: the overlay owns it through a
    // binding, and assigning it once from the picker tears that binding down, so
    // the chrome meant to be hidden for the crop stays on screen and lands in it.
    // The surface is on screen before Qt necessarily hands the keyboard to an
    // item in it; a keypress in that window is lost, so keep asserting focus for
    // a moment (the first Escape is the one that matters most).
    keys.forceActiveFocus()
    focusRetry.restart()
  }

  Timer {
    id: focusRetry
    interval: 80
    repeat: true
    property int tries: 0
    onTriggered: {
      tries += 1
      if (!visible || keys.activeFocus || tries > 4) {
        stop()
        tries = 0
        return
      }
      keys.forceActiveFocus()
    }
  }

  // What a click or Enter would capture right now. The precedence lives in the
  // model so it can be unit tested; this only gathers the state.
  function candidateRect() {
    return Model.candidateRect({
      dragging: selector.dragging,
      selection: selector.selection,
      keyboardActive: selector.keyboardActive,
      keyboardRect: selector.keyboardRect,
      hoverRect: selector.hoverRect,
      unified: selector.unified
    })
  }

  function cycleWindow(delta) {
    var next = Model.nextRect(selector.rects, selector.keyboardActive ? selector.keyboardRect : null, delta)
    if (!next) return
    selector.keyboardRect = next
    selector.keyboardActive = true
  }

  function commit(draggedFromRelease) {
    // A click that lands on nothing (or a window-mode click over empty space)
    // takes the whole frozen monitor rather than doing nothing.
    var dragging = draggedFromRelease === undefined
      ? selector.dragging : draggedFromRelease === true
    var rect = Model.selectionOrDefault({
      dragging: dragging,
      selection: selector.selection,
      keyboardActive: selector.keyboardActive,
      keyboardRect: selector.keyboardRect,
      hoverRect: selector.hoverRect,
      unified: selector.unified,
      monitorWidth: selector.width,
      monitorHeight: selector.height
    })
    if (!rect) return
    selector.selected(rect.x, rect.y, rect.width, rect.height)
  }

  screen: targetScreen
  visible: false
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "snapmenu"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

  // Without explicit anchors the layer surface has no size of its own and is
  // never mapped, which looks exactly like "nothing happened".
  anchors {
    top: true
    bottom: true
    left: true
    right: true
  }

  onVisibleChanged: if (visible) reset()

  // The frozen frame: exactly the monitor's pixels, so overlay-local
  // coordinates are the frame's coordinates.
  Image {
    id: frame
    anchors.fill: parent
    source: selector.freezePath ? Util.fileUrl(selector.freezePath) : ""
    fillMode: Image.PreserveAspectFit
    // Decoded off the GUI thread: the surface, its dimming and the legend come
    // up immediately and the frozen frame lands a moment later, instead of the
    // whole picker waiting on a 5-megapixel PNG. Dragging stays gated on
    // frameReady so nobody can select against a screen that is still live.
    asynchronous: true
    cache: false
  }

  // Dimming, built from four rectangles that together cover everything except the
  // selection, so the selected pixels are untouched. The glaze is drawn *over* the
  // selection on purpose — it marks the target — which is why the whole chrome is
  // hidden for a crop (the `capturing` flag the overlay drives) rather than being
  // kept outside the selection by construction.
  Item {
    id: chrome
    anchors.fill: parent
    visible: !selector.capturing

    readonly property var rect: selector.showRect
      ? selector.activeRect
      : { x: -1, y: -1, width: 0, height: 0 }

    Rectangle {
      color: selector.scrim
      x: 0
      y: 0
      width: parent.width
      height: Math.max(0, chrome.rect.y)
    }

    Rectangle {
      color: selector.scrim
      x: 0
      y: chrome.rect.y + chrome.rect.height
      width: parent.width
      height: Math.max(0, parent.height - (chrome.rect.y + chrome.rect.height))
    }

    Rectangle {
      color: selector.scrim
      x: 0
      y: chrome.rect.y
      width: Math.max(0, chrome.rect.x)
      height: chrome.rect.height
    }

    Rectangle {
      color: selector.scrim
      x: chrome.rect.x + chrome.rect.width
      y: chrome.rect.y
      width: Math.max(0, parent.width - (chrome.rect.x + chrome.rect.width))
      height: chrome.rect.height
    }

    // The glaze, over whatever the selection currently is: a window picked by
    // pointer or Tab, or a region being dragged out. It is only ever on the
    // overlay — a crop is taken from the frozen frame — so it marks the target
    // without touching a single pixel of the shot.
    Rectangle {
      visible: selector.showRect
      x: chrome.rect.x
      y: chrome.rect.y
      width: chrome.rect.width
      height: chrome.rect.height
      color: Util.alpha(Color.foreground, selector.glazeAlpha)
    }

    // Crosshair, before anything is selected.
    Rectangle {
      visible: !selector.dragging && !selector.keyboardActive
      x: selector.cursorX
      y: 0
      width: 1
      height: parent.height
      color: Util.alpha(Color.foreground, 0.45)
    }

    Rectangle {
      visible: !selector.dragging && !selector.keyboardActive
      x: 0
      y: selector.cursorY
      width: parent.width
      height: 1
      color: Util.alpha(Color.foreground, 0.45)
    }

    Rectangle {
      id: legend
      width: Math.min(selector.width - Style.space(40),
        legendRow.implicitWidth + Style.space(20))
      height: Style.space(34)
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Style.space(18)
      radius: Style.cornerRadius
      color: Util.alpha(Color.background, 0.85)
      border.width: 1
      border.color: Util.alpha(Color.foreground, 0.25)

      Row {
        id: legendRow
        anchors.centerIn: parent
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          text: Model.ICON.camera
          color: Color.accent
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.iconLarge
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          id: legendHint
          textFormat: Text.PlainText
          text: selector.legendText()
          color: Color.foreground
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          textFormat: Text.PlainText
          visible: selector.dragging || selector.showRect
          text: {
            var label = selector.dragging
              ? Model.rectLabel(selector.selection)
              : Model.rectLabel(selector.activeRect)
            var constraint = selector.dragging
              ? Model.dragConstraintLabel(selector.dragMode) : ""
            return constraint ? ("—  " + label + "  ·  " + constraint) : ("—  " + label)
          }
          color: Color.accent
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: Math.min(implicitWidth, legend.width - legendHint.width - Style.space(60))
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }

    // Selection / snap outline, drawn entirely outside the selection so the
    // pixels that get cropped stay clean.
    Rectangle {
      visible: selector.showRect
      // One pixel, and drawn entirely outside the selection: inside it must stay
      // the frozen frame's pixels, which is what gets cropped.
      x: chrome.rect.x - 1
      y: chrome.rect.y - 1
      width: chrome.rect.width + 2
      height: chrome.rect.height + 2
      color: "transparent"
      border.width: 1
      border.color: selector.snapMode
        ? Util.alpha(Color.accent, 0.85) : Util.alpha(Color.foreground, 0.55)
    }

    Rectangle {
      id: sizeLabel
      visible: selector.showRect
      width: labelText.implicitWidth + Style.space(12)
      height: labelText.implicitHeight + Style.space(6)
      radius: Style.space(4)
      color: Util.alpha(Color.background, 0.8)

      x: Math.max(0, Math.min(selector.width - width,
        chrome.rect.x + chrome.rect.width / 2 - width / 2))
      y: chrome.rect.y - height - Style.space(6) >= 0
        ? chrome.rect.y - height - Style.space(6)
        : chrome.rect.y + chrome.rect.height + Style.space(6)

      Text {
        id: labelText
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: Model.dimensionLabel(chrome.rect.width, chrome.rect.height)
        color: Color.foreground
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.body
      }
    }
  }

  Item {
    id: keys
    anchors.fill: parent
    focus: true
    z: 10

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function (event) {
      selector.lastKey = String(event.key)
      if (selector.capturing) return
      if (event.key === Qt.Key_Escape || event.key === Qt.Key_Q) {
        selector.cancelled()
        event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        selector.commit()
        event.accepted = true
      } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
        selector.cycleWindow(event.key === Qt.Key_Backtab
          || (event.modifiers & Qt.ShiftModifier) ? -1 : 1)
        event.accepted = true
      } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right
        || event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
        selector.moveCursor(event.key, event.modifiers)
        event.accepted = true
      }
    }
  }

  // Hover highlight (snap modes) plus the drag itself.
  MouseArea {
    id: mouse
    anchors.fill: parent
    z: 5
    enabled: !selector.capturing && selector.frameReady
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.CrossCursor

    function updateHover(x, y) {
      // Deliberately does not clear the keyboard pick: moving the mouse across
      // the surface while aiming should not discard the window Tab chose. A
      // press is what hands control back to the pointer.
      if (!selector.unified) {
        selector.hoverRect = null
        return
      }
      var found = Model.rectAt(selector.rects, x, y)
      // Never highlight the monitor rect while the point is inside a window.
      selector.hoverRect = found && found.kind === "monitor" ? null : found
    }

    // The pointer arrives in view coordinates and everything below — the cursor, the
    // The picker draws the frozen frame at its own size and the frame's origin is the
    // frozen monitor's, so a pointer position is already a frame position and this
    // only rounds. It used to map through the zoom's view transform as well.
    //
    // Everything below — the cursor, the selection, the snapping hit test — is in
    // frame coordinates.
    function toFrame(x, y) {
      return { x: Math.round(x), y: Math.round(y) }
    }

    onPositionChanged: function (mouse) {
      var framePoint = toFrame(mouse.x, mouse.y)
      selector.cursorX = framePoint.x
      selector.cursorY = framePoint.y
      if (selector.dragging) {
        var mode = selector.dragModeFor(mouse.modifiers)
        selector.dragMode = mode
        // A constraint pressed mid-drag locks onto what is already selected.
        if (selector.selection && selector.selection.height > 0) {
          if (mode === "width" && !(selector.dragLockedHeight > 0))
            selector.dragLockedHeight = selector.selection.height
          if (mode === "height" && !(selector.dragLockedWidth > 0))
            selector.dragLockedWidth = selector.selection.width
          if (mode === "ratio" && !(selector.dragLockedRatio > 0))
            selector.dragLockedRatio = selector.selection.width / selector.selection.height
        }
        selector.selection = Model.dragRect({
          anchorX: selector.startX,
          anchorY: selector.startY,
          pointerX: framePoint.x,
          pointerY: framePoint.y,
          mode: mode,
          lockedWidth: selector.dragLockedWidth,
          lockedHeight: selector.dragLockedHeight,
          ratio: selector.dragLockedRatio,
          bounds: { width: selector.width, height: selector.height }
        })
        return
      }
      updateHover(framePoint.x, framePoint.y)
    }

    onPressed: function (mouse) {
      if (mouse.button === Qt.RightButton) {
        selector.cancelled()
        return
      }
      var framePoint = toFrame(mouse.x, mouse.y)
      selector.dragging = true
      selector.keyboardActive = false
      selector.keyboardRect = null
      selector.startX = framePoint.x
      selector.startY = framePoint.y
      selector.dragMode = selector.dragModeFor(mouse.modifiers)
      var existing = selector.selection && selector.selection.height > 0
        ? selector.selection : null
      selector.dragLockedWidth = existing ? existing.width : selector.lastDragWidth
      selector.dragLockedHeight = existing ? existing.height : selector.lastDragHeight
      selector.dragLockedRatio = existing
        ? existing.width / existing.height : selector.lastDragRatio
      selector.selection = Model.dragRect({
        anchorX: selector.startX,
        anchorY: selector.startY,
        pointerX: framePoint.x,
        pointerY: framePoint.y,
        mode: selector.dragMode,
        lockedWidth: selector.dragLockedWidth,
        lockedHeight: selector.dragLockedHeight,
        ratio: selector.dragLockedRatio,
        bounds: { width: selector.width, height: selector.height }
      })
      updateHover(selector.startX, selector.startY)
    }

    onReleased: function (mouse) {
      if (mouse.button === Qt.RightButton) return
      // Remember the shape for the next band or proportional drag.
      if (selector.selection && selector.selection.height > 0) {
        selector.lastDragWidth = selector.selection.width
        selector.lastDragHeight = selector.selection.height
        selector.lastDragRatio = selector.selection.width / selector.selection.height
      }
      selector.dragMode = "free"
      var rect = selector.selection
      var dragged = !!(rect && (rect.width >= 8 || rect.height >= 8))

      // A click is not a selection. Below the threshold the selection is dropped so
      // the fallback decides: the window under the pointer in the unified mode, the
      // whole monitor otherwise — which is what selectionOrDefault is for.
      if (!dragged) selector.selection = null
      // Committed *before* `dragging` is cleared, and told which it was. The commit
      // reads that flag to choose between the rectangle just dragged and the window
      // under the pointer; clearing it first is what made a smart-mode drag capture
      // the window it was dragged over instead of the rectangle.
      // Window mode has no dragging to speak of: a drag there still means "this
      // window", which is what its legend says it does.
      selector.commit(dragged && !selector.snapMode)
      selector.dragging = false
    }
  }

  // Precise placement with the keyboard: move the cursor, or the selection's
  // corner while dragging.
  function moveCursor(key, modifiers) {
    var step = modifiers & Qt.ShiftModifier ? 10 : 1
    var dx = key === Qt.Key_Left ? -step : (key === Qt.Key_Right ? step : 0)
    var dy = key === Qt.Key_Up ? -step : (key === Qt.Key_Down ? step : 0)

    if (dragging && selection) {
      selection = {
        x: selection.x, y: selection.y,
        width: Math.max(1, selection.width + dx),
        height: Math.max(1, selection.height + dy)
      }
      return
    }
    keyboardActive = false
    cursorX = Math.max(0, Math.min(width - 1, cursorX + dx))
    cursorY = Math.max(0, Math.min(height - 1, cursorY + dy))
    var found = Model.rectAt(rects, Math.round(cursorX), Math.round(cursorY))
    if (unified) hoverRect = found && found.kind === "monitor" ? null : found
  }
}
