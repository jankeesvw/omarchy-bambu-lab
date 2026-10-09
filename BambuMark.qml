import QtQuick
import QtQuick.Shapes
import qs.Commons

import qs.Commons as Commons
// The Bambu Lab mark, drawn rather than typed.
//
// The path is Simple Icons' bambulab, which is CC0, on their 24×24 grid;
// everything here scales that grid to whatever size the bar hands over, so the
// mark stays sharp at any font size. Same approach as the Tesla widget next
// door, and for the same reason: a generic printer glyph would say "a
// printer", and this says "your Bambu".
//
// Four solid quadrants is also the reason it survives being small. What was
// here before was a spool drawn as concentric rings, and three thin circles
// inside sixteen pixels stop being a spool and become a bullseye.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Commons.Color.foreground

  implicitWidth: iconSize
  implicitHeight: iconSize

  Item {
    anchors.centerIn: parent
    width: 24
    height: 24
    scale: root.iconSize / 24

    Shape {
      anchors.fill: parent
      antialiasing: true
      // The quadrants meet at thin diagonal seams; without multisampling those
      // edges crawl at bar sizes.
      layer.enabled: true
      layer.samples: 4
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        fillColor: root.color
        strokeWidth: 0
        fillRule: ShapePath.WindingFill

        PathSvg {
          path: "M12.662 24V8.959l8.535 3.369V24zm-9.859-.003v-7.521l8.534-3.371-.001 10.892zM2.803 0h8.533l.001 11.672-8.534 3.369zm9.859 0h8.535v10.892l-8.535-3.371z"
        }
      }
    }
  }
}
