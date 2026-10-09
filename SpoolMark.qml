import QtQuick
import qs.Commons

import qs.Commons as Commons
// A spool of filament, seen end on: the filament as a ring, the hub as the
// hole through the middle, sitting on the round holder it clips into.
//
// This is the shape greghesp's Home Assistant cards made the familiar one for
// Bambu printers. Theirs is ISC licensed, so it could have been copied; it is
// a stylesheet, though, and this is a scene graph, so it is redrawn either
// way. The README says where it came from.
//
// Two things are deliberately different. The greys are theme tokens rather
// than fixed hex, because a holder hardcoded to a dark grey disappears on
// Catppuccin Latte. And nothing moves: theirs wiggles and catches a
// travelling highlight, which is charming on a wall tablet you glance at and
// wearing in a bar you look at all day.
//
// The ring is always drawn full. The printer can report how much is left, but
// only with remaining-filament estimation switched on and only for spools
// carrying a Bambu tag, so on most setups the figure is simply absent -- and a
// ring drawn at some invented level is a guess dressed up as a measurement.
Item {
  id: root

  property real iconSize: Style.font.icon
  // The colour of the filament. Two of them is a spool wound with two, which
  // is what the printer reports for the gradient filaments.
  property var filament: []
  property color stroke: Commons.Color.foreground
  // Painted in the hub and behind the ring, so an empty spool reads as empty
  // rather than as one loaded with whatever the panel is sitting on.
  property color behind: Commons.Color.background
  // The holder the spool sits in. Drawn only where there is room for it.
  property bool holder: false

  readonly property bool loaded: filament.length > 0
  readonly property color primary: loaded ? filament[0] : "transparent"
  readonly property color secondary: filament.length > 1 ? filament[1] : primary

  implicitWidth: iconSize
  implicitHeight: iconSize

  // The round seat in the AMS that the spool drops into.
  Rectangle {
    anchors.centerIn: parent
    width: root.iconSize
    height: width
    radius: width / 2
    visible: root.holder
    color: Util.alpha(root.stroke, 0.12)
    antialiasing: true
  }

  // The filament itself, as the ring you see looking at the end of a spool.
  Rectangle {
    id: ring
    anchors.centerIn: parent
    width: root.iconSize * (root.holder ? 0.62 : 0.94)
    height: width
    radius: width / 2
    antialiasing: true
    color: root.loaded ? (root.filament.length > 1 ? "transparent" : root.primary)
                       : "transparent"
    gradient: (root.loaded && root.filament.length > 1) ? twoTone : null
    // The outline is what keeps a white spool on a light theme and a near
    // black one on a dark theme from vanishing into the panel behind them.
    border.width: Math.max(1, Math.round(root.iconSize * 0.045))
    border.color: root.loaded ? Util.alpha(root.stroke, 0.45)
                              : Util.alpha(root.stroke, 0.3)

    Gradient {
      id: twoTone
      orientation: Gradient.Horizontal
      GradientStop { position: 0.0; color: root.primary }
      GradientStop { position: 0.49; color: root.primary }
      GradientStop { position: 0.51; color: root.secondary }
      GradientStop { position: 1.0; color: root.secondary }
    }
  }

  // The hole through the middle.
  Rectangle {
    anchors.centerIn: parent
    width: ring.width * 0.34
    height: width
    radius: width / 2
    color: root.behind
    antialiasing: true
    border.width: Math.max(1, Math.round(root.iconSize * 0.03))
    border.color: Util.alpha(root.stroke, 0.35)
  }
}
