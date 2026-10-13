import QtQuick
import qs.Commons
import qs.Ui
import "SnapmenuModel.js" as Model

// One row of the snapmenu card: the usual menu-item shape (glyph, label,
// optional detail, trailing value) rendered with the same [menu] surface
// tokens Omarchy's own command menu uses, so a theme styles both alike.
BorderSurface {
  id: root

  property var row: null
  property bool hasCursor: false
  property color foreground: Color.menu.text
  property color selectedText: Color.menu.selectedText
  property color selectedBackground: Color.menu.selectedBackground
  property var selectedBorderSpec: null
  property color urgentColor: Color.urgent
  property string fontFamily: Style.font.menuFamily
  property int cornerRadius: Style.cornerRadius
  property string toggleOnGlyph: Model.ICON.toggleOn
  property string toggleOffGlyph: Model.ICON.toggleOff
  // A trailing value is capped so a long one (a path, in the About screen) shrinks
  // and elides instead of growing backwards over its own label and off the card.
  // Wide enough for the longest value that should stay whole ("Super + Shift + S"),
  // narrow enough that a path still leaves its label room.
  property real trailMaxWidth: Style.space(126)

  signal activated()
  signal hovered()

  readonly property bool isSeparator: !!(row && row.kind === "separator")
  // A group label in the settings list: drawn like a section header, never a
  // cursor target (the model's rowSelectable skips it).
  readonly property bool isHeading: !!(row && row.kind === "heading")
  readonly property bool enabled: row ? (row.enabled === undefined || row.enabled === true) : false
  readonly property bool urgent: !!(row && row.urgent === true)
  readonly property bool hasIcon: !!(row && row.icon)
  readonly property bool isToggle: !!(row && row.kind === "toggle")
  readonly property bool hasDetail: !!(row && row.detail)
  readonly property string valueText: row && row.value !== undefined && row.value !== null
    ? String(row.value) : ""
  readonly property color iconColor: {
    if (!enabled) return Util.alpha(foreground, 0.4)
    if (urgent) return hasCursor ? selectedText : urgentColor
    return hasCursor ? selectedText : foreground
  }
  readonly property color labelColor: {
    if (!enabled) return Util.alpha(foreground, 0.45)
    if (urgent) return hasCursor ? selectedText : urgentColor
    return hasCursor ? selectedText : foreground
  }

  implicitHeight: isSeparator ? Style.space(13)
    : (isHeading ? Style.space(30) : (hasDetail ? Style.space(46) : Style.space(36)))
  radius: cornerRadius
  padding: 0
  color: hasCursor && enabled && !isSeparator ? selectedBackground : "transparent"
  borderSpec: hasCursor && enabled && !isSeparator
    ? (selectedBorderSpec && typeof selectedBorderSpec === "object"
      ? selectedBorderSpec
      : Border.controlSpec("hover-cursor", selectedText, selectedText))
    : Border.none()

  Text {
    visible: root.isHeading
    anchors.left: parent.left
    anchors.leftMargin: Style.space(12)
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.isHeading ? String(root.row.label || "") : ""
    color: root.foreground
    opacity: 0.45
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.weight: Font.DemiBold
    font.letterSpacing: 0.6
  }

  Rectangle {
    visible: root.isSeparator
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    height: Style.spacing.hairline
    color: Util.alpha(root.foreground, 0.18)
  }

  Text {
    id: glyph
    textFormat: Text.PlainText
    visible: !root.isSeparator && root.hasIcon
    text: (root.row && root.row.icon) ? root.row.icon : ""
    color: root.iconColor
    font.family: root.fontFamily
    font.pixelSize: Style.font.iconLarge
    width: Style.space(34)
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    anchors.left: parent.left
    anchors.leftMargin: Style.space(10)
    y: content.y + labelText.y + (labelText.height - height) / 2
  }

  Column {
    id: content
    visible: !root.isHeading
    anchors.left: root.hasIcon ? glyph.right : parent.left
    anchors.leftMargin: root.hasIcon ? Style.space(4) : Style.space(14)
    anchors.right: trail.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    Text {
      id: labelText
      textFormat: Text.PlainText
      width: parent.width
      text: root.row ? String(root.row.label || "") : ""
      color: root.labelColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.heading
      font.weight: Font.Medium
      elide: Text.ElideRight
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: root.hasDetail
      text: root.hasDetail ? String(root.row.detail) : ""
      color: root.labelColor
      opacity: 0.52
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideMiddle
    }
  }

  Item {
    id: trail
    visible: !root.isHeading
    width: {
      if (root.isToggle) return Style.space(24)
      if (root.valueText) return Math.min(root.trailMaxWidth, Math.max(Style.space(24), trailText.implicitWidth))
      return 0
    }
    height: Style.space(20)
    anchors.right: parent.right
    anchors.rightMargin: Style.space(12)
    y: content.y + labelText.y + (labelText.height - height) / 2

    Text {
      id: trailText
      textFormat: Text.PlainText
      visible: !root.isToggle
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      // The middle goes first: a path's end is what identifies it.
      width: Math.min(implicitWidth, root.trailMaxWidth)
      elide: Text.ElideMiddle
      horizontalAlignment: Text.AlignRight
      text: root.valueText
      color: root.hasCursor ? root.selectedText : root.iconColor
      opacity: root.enabled ? 0.85 : 0.4
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      textFormat: Text.PlainText
      visible: root.isToggle
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: Model.toggleGlyph(root.row ? root.row.value === true : false)
      color: (root.row && root.row.value === true)
        ? (root.hasCursor ? root.selectedText : Color.accent)
        : Util.alpha(root.foreground, 0.35)
      font.family: root.fontFamily
      font.pixelSize: Style.font.iconLarge
    }
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    enabled: !root.isSeparator
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onContainsMouseChanged: if (containsMouse) root.hovered()
    onClicked: root.activated()
  }
}
