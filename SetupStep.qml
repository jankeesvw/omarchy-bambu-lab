import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons

import qs.Commons as Commons
// One step of the first run: a number, what to do, and where useful the exact
// command, which copies itself when you click it.
//
// A step already done keeps its place rather than disappearing. Somebody
// halfway through a setup wants to see how far along they are, and a list that
// shrinks as you work is a list you cannot count.
Item {
  id: root

  property string number: ""
  property string title: ""
  property string body: ""
  property string code: ""
  property bool done: false
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family

  readonly property string iconDone: "\uf00c"

  implicitHeight: row.implicitHeight
  implicitWidth: row.implicitWidth

  RowLayout {
    id: row
    width: parent.width
    spacing: Style.space(10)

    Rectangle {
      Layout.alignment: Qt.AlignTop
      width: Style.space(22)
      height: width
      radius: width / 2
      color: root.done ? "transparent" : Util.alpha(Commons.Color.accent, 0.15)
      border.width: root.done ? 1 : 0
      border.color: Util.alpha(root.foreground, 0.25)
      antialiasing: true

      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: root.done ? root.iconDone : root.number
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        color: root.done ? Util.alpha(root.foreground, 0.4) : Commons.Color.accent
      }
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(4)

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: root.title
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: root.done ? Util.alpha(root.foreground, 0.45) : root.foreground
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        visible: root.body !== "" && !root.done
        text: root.body
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        color: Util.alpha(root.foreground, 0.55)
      }

      Rectangle {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(2)
        Layout.preferredHeight: command.implicitHeight + Style.space(14)
        visible: root.code !== "" && !root.done
        radius: Style.cornerRadius
        color: Util.alpha(root.foreground, area.containsMouse ? 0.12 : 0.07)

        Text {
          id: command
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(8)
          anchors.rightMargin: Style.space(8)
          wrapMode: Text.WrapAnywhere
          text: root.code
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: Util.alpha(root.foreground, 0.85)
        }

        Text {
          textFormat: Text.PlainText
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(4)
          text: copied.running ? "copied" : ""
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: Commons.Color.accent
        }

        MouseArea {
          id: area
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          // The command is built here out of our own strings, so handing it to
          // the clipboard is not a route for anything the printer said.
          onClicked: {
            copyProc.command = ["wl-copy", "--", root.code]
            copyProc.running = true
            copied.restart()
          }
        }

        Process { id: copyProc }
        Timer { id: copied; interval: 1600 }
      }
    }
  }
}
