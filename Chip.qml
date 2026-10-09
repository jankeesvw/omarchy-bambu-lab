import QtQuick
import qs.Commons

import qs.Commons as Commons
// A rounded pill with a glyph and a value in it. The panel is mostly rows of
// these: a printer has a dozen small facts and a pill each keeps them from
// running together into a paragraph.
Item {
  id: root

  property string icon: ""
  property string text: ""
  property color iconColor: Commons.Color.foreground
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  property bool interactive: false
  // Drawn when the keyboard cursor is on this chip, matching the ring the
  // round buttons get: one cursor walks both kinds of control.
  property bool hasCursor: false

  signal clicked()

  implicitWidth: body.implicitWidth + Style.space(20)
  implicitHeight: Style.space(26)

  Rectangle {
    anchors.fill: parent
    radius: height / 2
    color: Util.alpha(root.foreground,
                      (area.containsMouse && root.interactive) || root.hasCursor ? 0.14 : 0.07)
    border.width: root.hasCursor ? Math.max(1, Style.space(2)) : 0
    border.color: Util.alpha(root.foreground, 0.5)
  }

  Row {
    id: body
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      visible: root.icon !== ""
      text: root.icon
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      color: root.iconColor
    }

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      visible: root.text !== ""
      text: root.text
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      color: Util.alpha(root.foreground, 0.85)
    }
  }

  MouseArea {
    id: area
    anchors.fill: parent
    hoverEnabled: true
    enabled: root.interactive
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
