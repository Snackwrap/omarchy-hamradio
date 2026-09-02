import QtQuick

// Today, as a 24-hour strip: night dark, day light, and the two grey-line
// windows picked out where the terminator passes overhead.
//
// The grey line is the band of twilight sweeping round the earth. Along it the
// D layer that absorbs the low bands by day has decayed while the F layer is
// still lit, so 160 through 40 metres reach much further than at any other
// time. The window is short and it moves with the season, which is exactly why
// it is worth drawing rather than describing.
Item {
  id: root

  property double dayStartMs: 0        // sunrise
  property double dayEndMs: 0          // sunset
  property double windowStartMs: 0     // start of the strip (local midnight)
  property double nowMs: 0
  property int greyMinutes: 40
  property bool polarDay: false
  property bool polarNight: false

  property color dayColor: "#3a4258"
  property color nightColor: "#171a24"
  property color greyColor: "#e0a63a"
  property color inkColor: "white"
  property string fontFamily: "monospace"
  property real labelSize: 10
  property bool animate: true

  implicitWidth: 320
  implicitHeight: 58

  readonly property real barHeight: 22
  readonly property double spanMs: 86400000

  function xFor(ms) {
    return Math.max(0, Math.min(width, (ms - windowStartMs) / spanMs * width))
  }

  property real reveal: 1.0
  function play() {
    if (!animate) { reveal = 1.0; return }
    reveal = 0
    wipe.restart()
  }
  NumberAnimation {
    id: wipe; target: root; property: "reveal"; to: 1.0
    duration: 600; easing.type: Easing.OutCubic
  }

  // Night is the ground colour; day is painted over it.
  Rectangle {
    id: bar
    width: parent.width
    height: root.barHeight
    radius: 3
    color: root.polarDay ? root.dayColor : root.nightColor

    Item {
      anchors.fill: parent
      clip: true

      // Daylight. A day that runs past midnight at high latitudes is drawn as
      // two pieces rather than one that wraps off the end of the strip.
      Rectangle {
        visible: !root.polarDay && !root.polarNight && root.dayEndMs > root.dayStartMs
        x: root.xFor(root.dayStartMs)
        width: Math.max(0, root.xFor(root.dayEndMs) - root.xFor(root.dayStartMs))
        height: parent.height
        color: root.dayColor
      }

      // The two grey-line windows.
      Repeater {
        model: (root.polarDay || root.polarNight) ? [] : [root.dayStartMs, root.dayEndMs]
        Rectangle {
          required property var modelData
          x: root.xFor(modelData - root.greyMinutes * 60000)
          width: Math.max(2, root.xFor(modelData + root.greyMinutes * 60000)
                             - root.xFor(modelData - root.greyMinutes * 60000))
          height: parent.height
          color: root.greyColor
          opacity: 0.85
        }
      }

      // The reveal is a shutter travelling across, so the strip is laid down
      // along its own time axis.
      Rectangle {
        x: parent.width * root.reveal
        width: parent.width
        height: parent.height
        color: root.nightColor
        visible: root.reveal < 1
      }
    }
  }

  // Now.
  Rectangle {
    visible: root.nowMs >= root.windowStartMs
             && root.nowMs <= root.windowStartMs + root.spanMs
             && root.xFor(root.nowMs) <= root.width * root.reveal
    x: root.xFor(root.nowMs) - 1
    y: -3
    width: 2
    height: root.barHeight + 6
    color: root.inkColor
  }

  // Six-hour ticks. Any denser and the labels collide at panel width.
  Item {
    anchors.top: bar.bottom
    anchors.topMargin: 4
    width: parent.width
    height: root.labelSize + 4

    Repeater {
      model: [0, 6, 12, 18, 24]
      Text {
        required property var modelData
        textFormat: Text.PlainText
        x: Math.min(root.width - implicitWidth,
                    Math.max(0, root.xFor(root.windowStartMs + modelData * 3600000) - implicitWidth / 2))
        text: (modelData < 10 ? "0" : "") + modelData
        color: root.inkColor
        opacity: 0.45
        font.family: root.fontFamily
        font.pixelSize: root.labelSize
      }
    }
  }
}
