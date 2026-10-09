import QtQuick
import qs.Commons

import qs.Commons as Commons
// One slot: the spool, and what is on it.
//
// The label runs to two lines rather than being cut off. "Bambu PETG Basic"
// is a normal thing for a slot to contain, and a column of "Bambu PET…" tells
// you which spools you have without telling you which is which.
Item {
  id: root

  property int slot: 0
  property bool present: false
  property string label: ""
  property var colors: []
  property bool active: false
  property color foreground: Commons.Color.foreground
  property color background: Commons.Color.background
  property string fontFamily: Style.font.family
  property real spoolSize: Style.space(38)

  implicitWidth: Math.max(spoolSize, Style.space(64))
  implicitHeight: column.implicitHeight

  Column {
    id: column
    width: parent.width
    spacing: Style.space(6)

    Item {
      width: root.spoolSize
      height: root.spoolSize
      anchors.horizontalCenter: parent.horizontalCenter

      SpoolMark {
        anchors.fill: parent
        iconSize: root.spoolSize
        holder: true
        filament: root.present ? root.colors : []
        stroke: root.present ? root.foreground : Util.alpha(root.foreground, 0.5)
        behind: root.background
        opacity: root.present ? 1.0 : 0.55
      }

      // The spool that is feeding the nozzle, ringed. The mark sits outside
      // the holder so it never eats into the colour it is pointing at.
      Rectangle {
        anchors.fill: parent
        anchors.margins: -Style.space(3)
        radius: width / 2
        color: "transparent"
        visible: root.active
        border.width: Math.max(1, Style.space(2))
        border.color: Commons.Color.accent
        antialiasing: true
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      maximumLineCount: 2
      elide: Text.ElideRight
      text: root.present ? root.label : "empty"
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      color: root.active ? Commons.Color.accent
                         : Util.alpha(root.foreground, root.present ? 0.75 : 0.35)
    }
  }
}
