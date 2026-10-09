import QtQuick
import qs.Commons

import qs.Commons as Commons
// One of the three controls in the panel header: stop, pause, resume.
//
// Round and unlabelled, the way the printer's own app draws them. They are
// large enough to hit and far enough apart that stop is not next to resume by
// accident.
Item {
  id: root

  property string icon: ""
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  property bool danger: false
  property bool enabled: true
  property bool hasCursor: false

  signal activated()

  readonly property color tint: danger ? Commons.Color.urgent : foreground

  implicitWidth: Style.space(30)
  implicitHeight: Style.space(30)

  Rectangle {
    anchors.fill: parent
    radius: width / 2
    color: Util.alpha(root.tint,
                      (area.containsMouse || root.hasCursor) && root.enabled ? 0.16 : 0.07)
    border.width: root.hasCursor ? Math.max(1, Style.space(2)) : 0
    border.color: root.tint
    antialiasing: true
  }

  Text {
    textFormat: Text.PlainText
    anchors.centerIn: parent
    text: root.icon
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    color: root.tint
    opacity: root.enabled ? 1.0 : 0.35
  }

  MouseArea {
    id: area
    anchors.fill: parent
    hoverEnabled: true
    enabled: root.enabled
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }
}
