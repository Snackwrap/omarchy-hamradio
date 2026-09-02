import QtQuick

// The band table, day and night side by side.
//
// N0NBH publishes a verdict for each band group twice — once for daylight and
// once for darkness — and which half applies depends on whether the sun is up
// where the operator is standing. Showing both, with the one in force picked
// out, answers the follow-up question ("and later?") without a second tab.
Item {
  id: root

  property var rows: []            // from Ham.bandsForNow()
  property bool isDay: true
  property var gradeColor: function (g) { return "#888" }
  property color inkColor: "white"
  property color mutedColor: "#888"
  property string fontFamily: "monospace"
  property real fontSize: 12
  property bool animate: true

  readonly property real rowHeight: fontSize * 2.0
  readonly property real labelWidth: fontSize * 6.5
  readonly property real colWidth: (width - labelWidth) / 2

  implicitWidth: 320
  implicitHeight: header.height + rows.length * rowHeight

  property real reveal: 1.0
  function play() {
    if (!animate) { reveal = 1.0; return }
    reveal = 0
    grow.restart()
  }
  NumberAnimation {
    id: grow; target: root; property: "reveal"; to: 1.0
    duration: 520; easing.type: Easing.OutCubic
  }

  Row {
    id: header
    width: parent.width
    height: root.fontSize * 1.6

    Item { width: root.labelWidth; height: 1 }
    Repeater {
      model: ["DAY", "NIGHT"]
      Text {
        required property var modelData
        required property int index
        textFormat: Text.PlainText
        width: root.colWidth
        text: modelData
        // The half that is in force now is the one that is not dimmed.
        color: (index === 0) === root.isDay ? root.inkColor : root.mutedColor
        opacity: (index === 0) === root.isDay ? 0.75 : 0.4
        font.family: root.fontFamily
        font.pixelSize: root.fontSize * 0.85
        font.bold: (index === 0) === root.isDay
        font.letterSpacing: 1.5
      }
    }
  }

  Column {
    anchors.top: header.bottom
    width: parent.width

    Repeater {
      model: root.rows

      Item {
        id: bandRow
        required property var modelData
        required property int index
        width: parent ? parent.width : 0
        height: root.rowHeight

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          width: root.labelWidth
          text: String(bandRow.modelData.band || "")
          color: root.inkColor
          font.family: root.fontFamily
          font.pixelSize: root.fontSize
        }

        Row {
          anchors.left: parent.left
          anchors.leftMargin: root.labelWidth
          anchors.verticalCenter: parent.verticalCenter

          Repeater {
            model: [bandRow.modelData.day, bandRow.modelData.night]

            Item {
              required property var modelData
              required property int index
              width: root.colWidth
              height: root.rowHeight * 0.72

              readonly property bool inForce: (index === 0) === root.isDay

              // A bar rather than a word: three grades read faster as three
              // lengths, and the colour then only has to confirm it.
              Rectangle {
                id: chip
                anchors.verticalCenter: parent.verticalCenter
                width: {
                  // The grade word sits to the right of the bar and inside the
                  // same column, so the bar can only have what is left after it.
                  var full = root.colWidth - root.fontSize * 4.6
                  var share = modelData === "Good" ? 1.0 : (modelData === "Fair" ? 0.62 : 0.3)
                  return Math.max(4, full * share * root.reveal)
                }
                height: root.fontSize * 0.85
                radius: 2
                color: root.gradeColor(modelData)
                opacity: parent.inForce ? 0.95 : 0.32
                Behavior on width {
                  enabled: root.animate
                  NumberAnimation { duration: 420; easing.type: Easing.OutCubic }
                }
              }

              Text {
                textFormat: Text.PlainText
                anchors.left: chip.right
                anchors.leftMargin: root.fontSize * 0.5
                anchors.verticalCenter: parent.verticalCenter
                text: String(modelData || "")
                color: parent.inForce ? root.inkColor : root.mutedColor
                opacity: (parent.inForce ? 0.9 : 0.45) * root.reveal
                font.family: root.fontFamily
                font.pixelSize: root.fontSize * 0.85
                visible: root.colWidth > root.fontSize * 6
              }
            }
          }
        }
      }
    }
  }
}
