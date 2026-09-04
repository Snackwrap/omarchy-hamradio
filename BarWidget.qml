import QtQuick
import qs.Commons
import qs.Ui

// Bar pill: a radio glyph plus the best band open right now. All fetching and the
// popup itself live in Panel.qml; this is just the bar-slot button and the
// popout-identity shim the bar expects.
BarWidget {
  id: root
  moduleName: "com.leafbox.hamradio"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // The argument is forwarded, not swallowed: a middle-click is an explicit
  // request for spots even when the popup is shut.
  function refresh(wantSpots) {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh(wantSpots)
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing: the bar identifies a
  // panel by the widget mounted in its slot (this file), so open/close/opened
  // have to live here and forward to the nested Panel.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // BarIconButton is a *fixed-width* slot sized for a single glyph, and the
  // glyph inside it is drawn centred with no clipping — so a pill carrying text
  // as well ("\uf072 MVFR") silently overhangs its neighbours on both sides.
  // Measure the actual string and widen the slot to match.
  TextMetrics {
    id: pillMetrics
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.bar.iconFont
    text: button.text
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: panelLoader.item ? panelLoader.item.label : ""
    slotSize: Math.max(Style.bar.statusSlot,
                       Math.ceil(pillMetrics.width) + Style.space(9))
    // The glyph canvas has to grow with the slot too, or the text is centred
    // inside a 16px box in the middle of a much wider button.
    opticalSize: slotSize
    tooltipText: panelLoader.item ? panelLoader.item.tooltip : "Ham Radio"
    // The pill is coloured by how good the conditions are, so it reads without
    // being read. Falls back to the bar's own foreground when nothing has
    // loaded yet.
    foreground: (panelLoader.item && panelLoader.item.gradeColor !== "")
      ? panelLoader.item.gradeColor
      : (root.bar ? root.bar.barForeground : Color.foreground)

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.MiddleButton) root.refresh(true)
      else root.togglePanel()
    }
  }
}
