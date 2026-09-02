import QtQuick
import "ham.js" as Ham

// The HF spectrum, 1.8 to 30 MHz, with each amateur band drawn at its real
// place and filled with the grade in force — and the frequencies people are
// actually working right now as ticks along the top of the same axis.
//
// Conditions and activity are otherwise two separate screens that never meet.
// On one axis they answer each other: the shape of the opening is visible at a
// glance, and so is whether anyone is exploiting it.
//
// The axis is logarithmic. Linear would give 10m nearly half the width and
// squeeze 160m through 40m — the bands that carry most of the traffic — into
// the first fifth.
Item {
  id: root

  property var bands: []               // the graded groups, from parseSolar()
  property var spotFreqs: []           // kHz
  property bool isDay: true
  property var gradeColor: function (g) { return "#888" }
  property color inkColor: "white"
  property color mutedColor: "#888"
  property string fontFamily: "monospace"
  property real labelSize: 10
  property bool animate: true

  implicitWidth: 340
  implicitHeight: tickRow + barHeight + labelSize * 1.9

  readonly property real tickRow: 12
  // Wider than tall wherever the band allows it, so the segments read as
  // stretches of an axis rather than as free-standing bars.
  readonly property real barHeight: 12
  readonly property real loMHz: 1.7
  readonly property real hiMHz: 30.5
  readonly property real logLo: Math.log(loMHz) / Math.LN10
  readonly property real logSpan: Math.log(hiMHz) / Math.LN10 - logLo

  function xFor(khz) {
    var mhz = Number(khz) / 1000
    if (!isFinite(mhz) || mhz <= 0) return -1
    var t = (Math.log(mhz) / Math.LN10 - logLo) / logSpan
    return t * width
  }

  readonly property var segments: {
    var out = []
    var list = Ham.hfBands()
    for (var i = 0; i < list.length; i++) {
      var b = list[i]
      var grade = Ham.gradeForBand(bands, b.band, isDay)
      var x0 = xFor(b.from)
      var x1 = xFor(b.to)
      out.push({
        band: b.band,
        grade: grade,
        x: x0,
        // The narrow bands (30m is 50 kHz wide) would otherwise be invisible;
        // a floor keeps them findable without distorting the wide ones.
        w: Math.max(6, x1 - x0)
      })
    }
    return out
  }

  property real reveal: 1.0
  function play() {
    if (!animate) { reveal = 1.0; return }
    reveal = 0
    sweep.restart()
  }
  NumberAnimation {
    id: sweep; target: root; property: "reveal"; to: 1.0
    duration: 620; easing.type: Easing.OutCubic
  }

  // Spot ticks, above the bar.
  Item {
    id: ticks
    width: parent.width
    height: root.tickRow

    Repeater {
      model: root.spotFreqs
      Rectangle {
        required property var modelData
        readonly property real px: root.xFor(modelData)
        visible: px >= 0 && px <= root.width && px <= root.width * root.reveal
        x: px - 0.5
        y: root.tickRow * 0.25
        width: 1
        height: root.tickRow * 0.75
        color: root.inkColor
        opacity: 0.55
      }
    }
  }

  // The bands.
  Item {
    id: bar
    anchors.top: ticks.bottom
    width: parent.width
    height: root.barHeight

    // The axis itself. Without it the segments float; with it they are
    // obviously stretches of one continuous spectrum with gaps between them.
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width * root.reveal
      height: 1
      color: root.mutedColor
      opacity: 0.3
    }

    Repeater {
      model: root.segments

      Rectangle {
        required property var modelData
        x: modelData.x
        width: modelData.w
        height: parent.height
        radius: 2
        visible: modelData.x <= root.width * root.reveal
        // A band nobody publishes a grade for is drawn as an outline. Borrowing
        // a neighbour's verdict would be a guess wearing the colour of a
        // forecast, and 160m behaves nothing like 40m.
        color: modelData.grade !== "" ? root.gradeColor(modelData.grade) : "transparent"
        border.width: modelData.grade !== "" ? 0 : 1
        border.color: root.mutedColor
        opacity: modelData.grade !== "" ? 0.92 : 0.45

        Behavior on color {
          enabled: root.animate
          ColorAnimation { duration: 420; easing.type: Easing.InOutQuad }
        }
      }
    }
  }

  // Band names. Rather than only labelling segments wide enough to contain
  // their own text — which on a log axis is almost none of them — walk left to
  // right and place every label that clears the previous one.
  readonly property var labelled: {
    var out = []
    var lastRight = -1e9
    var approx = labelSize * 0.62          // per character, at this size
    for (var i = 0; i < segments.length; i++) {
      var seg = segments[i]
      var w = seg.band.length * approx
      var x = seg.x + seg.w / 2 - w / 2
      if (x < lastRight + labelSize * 0.5) continue
      lastRight = x + w
      out.push({ band: seg.band, grade: seg.grade, x: x })
    }
    return out
  }

  Item {
    anchors.top: bar.bottom
    anchors.topMargin: 4
    width: parent.width
    height: root.labelSize + 3

    Repeater {
      model: root.labelled
      Text {
        required property var modelData
        textFormat: Text.PlainText
        x: modelData.x
        text: modelData.band
        color: root.inkColor
        opacity: (modelData.grade !== "" ? 0.6 : 0.32) * root.reveal
        font.family: root.fontFamily
        font.pixelSize: root.labelSize * 0.9
      }
    }
  }

}
