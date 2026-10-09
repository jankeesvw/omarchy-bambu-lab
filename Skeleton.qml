import QtQuick
import QtQuick.Layouts
import qs.Commons

import qs.Commons as Commons
// The panel with the printer taken out of it: the same blocks in the same
// order, drawn as empty shapes.
//
// A printer that is switched off is the ordinary case, not a fault, and the
// panel should look like it is waiting rather than like it is broken. A single
// line of text on an empty card reads as the latter -- this reads as the
// former, and it also tells somebody who has never seen the panel full what
// they are going to get once the printer wakes up.
//
// One spinner, in the middle of where the picture goes. That is the only thing
// in this plugin that moves, and it earns it: the difference between "waiting"
// and "given up" is hard to draw any other way. The blocks themselves sit
// still -- a whole panel breathing on top of a spinner is two animations
// competing to say the same thing.
ColumnLayout {
  id: root

  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  property string message: ""
  property int pad: Style.space(12)
  property int labelGap: Style.space(6)

  spacing: Style.space(14)

  // One tone for everything, so the whole thing reads as a single absence
  // rather than as a set of separate greyed-out controls.
  readonly property color ghost: Util.alpha(foreground, 0.09)
  readonly property color ghostSoft: Util.alpha(foreground, 0.055)

  // The chamber, with the spinner where the picture would be.
  Rectangle {
    Layout.fillWidth: true
    Layout.preferredHeight: Math.round(width * 9 / 16)
    radius: Style.cornerRadius
    color: root.ghostSoft

    Column {
      anchors.centerIn: parent
      spacing: Style.space(12)

      Spinner {
        anchors.horizontalCenter: parent.horizontalCenter
        size: Style.space(30)
        spinning: root.visible
        color: Util.alpha(root.foreground, 0.55)
        track: Util.alpha(root.foreground, 0.12)
      }

      Text {
        textFormat: Text.PlainText
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.message !== ""
        text: root.message
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        color: Util.alpha(root.foreground, 0.45)
      }
    }
  }

  // The AMS, label and all.
  ColumnLayout {
    Layout.fillWidth: true
    spacing: root.labelGap

    Rectangle {
      Layout.preferredWidth: Style.space(30)
      Layout.preferredHeight: Style.space(9)
      radius: height / 2
      color: root.ghost
    }

    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: spools.implicitHeight + root.pad * 2
      radius: Style.cornerRadius
      color: root.ghostSoft

      // Cells are plain Items, and the content is centred inside them with
      // anchors. A nested ColumnLayout with Layout.fillWidth does not actually
      // stretch -- it settles at its own implicit width and the four of them
      // pack against the left, leaving a cell's worth of nothing on the right.
      RowLayout {
        id: spools
        anchors.centerIn: parent
        width: parent.width
        spacing: 0

        Repeater {
          model: 4
          delegate: Item {
            Layout.fillWidth: true
            Layout.preferredWidth: 0
            Layout.preferredHeight: spool.height

            Column {
              id: spool
              anchors.centerIn: parent
              spacing: Style.space(6)

              Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Style.space(34)
                height: width
                radius: width / 2
                color: root.ghost
              }
              Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Style.space(24)
                height: Style.space(8)
                radius: height / 2
                color: root.ghost
              }
            }
          }
        }
      }
    }
  }

  // The row of chips the printer would be describing itself in.
  RowLayout {
    Layout.fillWidth: true
    spacing: Style.space(6)

    Rectangle {
      Layout.preferredWidth: Style.space(40)
      Layout.preferredHeight: Style.space(9)
      radius: height / 2
      color: root.ghost
    }
    Item { Layout.fillWidth: true }
    Repeater {
      model: [58, 40, 36]
      delegate: Rectangle {
        Layout.preferredWidth: Style.space(modelData)
        Layout.preferredHeight: Style.space(26)
        radius: height / 2
        color: root.ghostSoft
      }
    }
  }

  // The four readings.
  Rectangle {
    Layout.fillWidth: true
    Layout.preferredHeight: readings.implicitHeight + root.pad * 2
    radius: Style.cornerRadius
    color: root.ghostSoft

    RowLayout {
      id: readings
      anchors.centerIn: parent
      width: parent.width
      spacing: 0

      Repeater {
        model: 4
        delegate: Item {
          Layout.fillWidth: true
          Layout.preferredWidth: 0
          Layout.preferredHeight: reading.height

          Column {
            id: reading
            anchors.centerIn: parent
            spacing: Style.space(6)

            Rectangle {
              anchors.horizontalCenter: parent.horizontalCenter
              width: Style.space(12)
              height: Style.space(12)
              radius: Style.space(3)
              color: root.ghost
            }
            Rectangle {
              anchors.horizontalCenter: parent.horizontalCenter
              width: Style.space(34)
              height: Style.space(8)
              radius: height / 2
              color: root.ghost
            }
          }
        }
      }
    }
  }

  // Where the progress bar goes.
  Rectangle {
    Layout.fillWidth: true
    Layout.preferredHeight: Style.space(6)
    radius: height / 2
    color: root.ghost
  }
}
