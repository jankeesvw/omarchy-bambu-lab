import QtQuick
import QtQuick.Shapes
import qs.Commons

import qs.Commons as Commons
// A ring with a gap in it, turning.
//
// Drawn rather than animated as a strip of glyphs, so it stays smooth at any
// size and takes its colour from the theme. The faint full circle underneath
// is what keeps it from reading as a fragment sliding around in the dark: you
// see a ring with a bright part travelling along it, which is the shape people
// already read as "working on it".
Item {
  id: root

  property real size: Style.space(28)
  property color color: Commons.Color.accent
  property color track: Util.alpha(Commons.Color.foreground, 0.12)
  property int period: 1100
  // Stops when it is not on screen. An animation left running behind a closed
  // panel is a wakeup a few times a second for nobody.
  property bool spinning: true

  implicitWidth: size
  implicitHeight: size

  readonly property real stroke: Math.max(2, Math.round(size * 0.09))

  Shape {
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4
    preferredRendererType: Shape.CurveRenderer

    // The track.
    ShapePath {
      fillColor: "transparent"
      strokeColor: root.track
      strokeWidth: root.stroke
      capStyle: ShapePath.RoundCap

      PathAngleArc {
        centerX: root.size / 2
        centerY: root.size / 2
        radiusX: (root.size - root.stroke) / 2
        radiusY: (root.size - root.stroke) / 2
        startAngle: 0
        sweepAngle: 360
      }
    }
  }

  Shape {
    id: arc
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4
    preferredRendererType: Shape.CurveRenderer
    transformOrigin: Item.Center

    ShapePath {
      fillColor: "transparent"
      strokeColor: root.color
      strokeWidth: root.stroke
      capStyle: ShapePath.RoundCap

      PathAngleArc {
        centerX: root.size / 2
        centerY: root.size / 2
        radiusX: (root.size - root.stroke) / 2
        radiusY: (root.size - root.stroke) / 2
        startAngle: -90
        // A quarter of the ring: enough to see it turn, little enough that the
        // gap still reads as a gap.
        sweepAngle: 95
      }
    }

    RotationAnimation on rotation {
      running: root.spinning && root.visible
      loops: Animation.Infinite
      from: 0
      to: 360
      duration: root.period
    }
  }
}
