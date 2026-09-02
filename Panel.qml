import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "ham.js" as Ham

// Pulls HF band conditions from N0NBH's solar feed and live activations from
// POTA and SOTA, works out which half of the day/night table applies where the
// operator actually is, exposes a `label`/`tooltip`/`gradeColor` for the bar
// pill, and renders the tabbed popup.
//
// Everything fetched here is remote, so the ceilings, the plain-text pinning
// and the request/response binding below are load-bearing rather than
// decoration — see the README section on that.
Panel {
  id: root
  moduleName: "com.leafbox.hamradio"
  ipcTarget: "com.leafbox.hamradio"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var panelFrame: null
  readonly property var barIdentity: hostWidget || root

  property double nowMs: Date.now()

  property string chosenView: ""
  readonly property string defaultTab: {
    var t = String(setting("defaultTab", "bands"))
    return (t === "spots" || t === "greyline") ? t : "bands"
  }
  readonly property string view: chosenView !== "" ? chosenView : defaultTab

  // nf-fa-microchip is the closest a Nerd Font gets to a transceiver; written
  // as an escape because private-use characters get stripped in transit.
  readonly property string glyph: "\uf2db"

  readonly property string solarUrl: "https://www.hamqsl.com/solarxml.php"
  readonly property string potaUrl: "https://api.pota.app/spot/activator"
  readonly property string sotaUrl: "https://api2.sota.org.uk/api/spots/20/all"
  readonly property string ua: "omarchy-hamradio/0.1"

  // ---- Settings ---------------------------------------------------------
  function boolSetting(name, dflt) { var v = setting(name, dflt); return v === true || v === "true" || v === 1 }
  readonly property string pillContent: String(setting("pillContent", "band"))
  readonly property string spotSource: String(setting("spotSource", "both"))
  readonly property bool utc: String(setting("timeFormat", "local")) === "utc"
  readonly property bool animOn: boolSetting("animations", true)
  readonly property bool alertGreyLine: boolSetting("greyLineAlert", false)
  readonly property bool debugGeometry: boolSetting("debugGeometry", false)

  // Held to the shape a locator has, and capped, because it becomes a lookup.
  readonly property string ownGrid:
    String(setting("grid", "")).toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 8)

  // A comma list of bands to keep, normalised once rather than per row.
  readonly property var bandFilter: {
    var raw = String(setting("spotBands", "")).toLowerCase().replace(/[^0-9a-z,]/g, "")
    if (raw === "") return []
    return raw.split(",").filter(function (s) { return s !== "" }).slice(0, 20)
  }

  // ---- Remote data hygiene ----------------------------------------------
  // Two ceilings rather than one: curl refuses to download past
  // maxResponseBytes, and parseBounded refuses the same limit — a chunked
  // response has no Content-Length for curl to check.
  readonly property int maxResponseBytes: 524288
  readonly property int maxFieldChars: 64

  function fetchArgs(seconds, url) {
    // -q must come first: without it curl reads ~/.curlrc, which could add a
    // proxy, an output file, or --insecure to what is otherwise a fixed
    // request.
    return ["curl", "-q", "-fsS", "-A", ua,
            "--proto", "=https",
            "--max-time", String(seconds),
            "--max-filesize", String(maxResponseBytes),
            url]
  }

  function boundedText(raw) {
    var text = String(raw || "")
    return (text.length === 0 || text.length > maxResponseBytes) ? "" : text
  }

  function parseBounded(raw) {
    var text = boundedText(raw)
    return text === "" ? null : JSON.parse(text)
  }

  // Qt's Text defaults to AutoText, which renders a string as rich text when it
  // looks like markup. Every remote value goes through here, and the Text
  // elements that show them are pinned to PlainText besides.
  function safe(v, limit) {
    var text = String(v === null || v === undefined ? "" : v)
    text = text.replace(/[\u0000-\u001F\u007F]+/g, " ").replace(/^\s+|\s+$/g, "")
    var cap = limit || maxFieldChars
    return text.length > cap ? text.slice(0, cap) + "\u2026" : text
  }

  // The bar pill and its tooltip render in Text elements the shell owns, where
  // textFormat is not ours to set, so the markup comes out of the string.
  function safeBare(v, limit) { return safe(v, limit).replace(/[<>&]/g, " ") }

  function boundedList(v, cap) {
    if (!v || !v.length) return []
    return v.length > cap ? v.slice(0, cap) : v
  }

  // ---- Location ---------------------------------------------------------
  // An explicit locator wins, then explicit coordinates, then the location the
  // built-in weather widget already knows.
  property var weatherLocation: ({ name: "", latitude: null, longitude: null })

  readonly property string weatherPath:
    Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"

  // FileView has no size cap and no regular-file check, and text() on a planted
  // FIFO would block a long-lived shell forever, so it watches only and the
  // read is bounded in both directions.
  FileView {
    id: weatherFile
    path: root.weatherPath
    watchChanges: true
    preload: false
    printErrors: false
    onFileChanged: weatherReadTimer.restart()
  }

  Timer { id: weatherReadTimer; interval: 250; onTriggered: weatherReader.running = true }
  Timer { interval: 1500; running: true; onTriggered: weatherReader.running = true }

  // Opening with O_NOFOLLOW and O_NONBLOCK means a symlink cannot redirect the
  // read and a planted FIFO cannot block it, and every check is made through
  // that same descriptor rather than on the path, so there is no window between
  // the check and the read. perl rather than python because Omarchy depends on
  // perl and does not depend on python.
  readonly property string safeReadScript:
    "use strict; use Fcntl qw(:DEFAULT :mode);" +
    "sysopen(my $fh, $ARGV[0], O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or exit 1;" +
    "my @s = stat($fh) or exit 1;" +
    "exit 1 unless S_ISREG($s[2]);" +
    "exit 1 unless $s[4] == $<;" +
    "exit 1 if $s[3] > 1;" +
    "exit 1 if $s[7] > 8192;" +
    "exit 1 if ($s[2] & 0022);" +
    "my $buf = \"\"; sysread($fh, $buf, 8192); print $buf;"

  Process {
    id: weatherReader
    command: ["perl", "-e", root.safeReadScript, root.weatherPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        if (raw.length === 0 || raw.length > 8192) return
        try {
          var d = JSON.parse(raw)
          root.weatherLocation = {
            name: typeof d.name === "string" ? root.safe(d.name, 80) : "",
            latitude: parseFloat(d.latitude),
            longitude: parseFloat(d.longitude)
          }
        } catch (e) { /* leave the fallback in place */ }
      }
    }
  }

  readonly property double ownLat: parseFloat(String(setting("latitude", "")))
  readonly property double ownLon: parseFloat(String(setting("longitude", "")))
  readonly property bool hasOwnCoords: isFinite(ownLat) && isFinite(ownLon)
                                       && Math.abs(ownLat) <= 90 && Math.abs(ownLon) <= 180
  readonly property var gridPoint: ownGrid !== "" ? Ham.gridToLatLon(ownGrid) : null
  readonly property double weatherLat: parseFloat(String(weatherLocation.latitude))
  readonly property double weatherLon: parseFloat(String(weatherLocation.longitude))

  readonly property double siteLat: hasOwnCoords ? ownLat
    : (gridPoint ? gridPoint.lat : weatherLat)
  readonly property double siteLon: hasOwnCoords ? ownLon
    : (gridPoint ? gridPoint.lon : weatherLon)
  readonly property bool hasSite: isFinite(siteLat) && isFinite(siteLon)
  readonly property string myGrid: hasSite ? Ham.gridSquare(siteLat, siteLon, 6) : ""

  // ---- Fetched state ----------------------------------------------------
  property var solar: null
  property var potaSpots: []
  property var sotaSpots: []
  property string lastError: ""
  property bool loading: false

  // ---- Derived ----------------------------------------------------------
  readonly property bool isDay: hasSite ? Ham.isDaylight(new Date(nowMs), siteLat, siteLon) : true
  readonly property var bandRows: solar ? Ham.bandsForNow(solar.bands, isDay) : []
  readonly property var best: solar ? Ham.bestBand(solar.bands, isDay) : null
  readonly property var greyLine: hasSite ? Ham.greyLine(new Date(nowMs), siteLat, siteLon) : null

  readonly property var spots: {
    var all = []
    if (spotSource === "both" || spotSource === "pota") all = all.concat(potaSpots)
    if (spotSource === "both" || spotSource === "sota") all = all.concat(sotaSpots)
    if (bandFilter.length) {
      all = all.filter(function (s) { return bandFilter.indexOf(String(s.band).toLowerCase()) >= 0 })
    }
    return Ham.sortSpots(all)
  }

  // Frequencies only, for the spectrum's ticks — the spot list itself is
  // already capped, and this follows whatever filter is applied to it.
  readonly property var spotFreqs: {
    var out = []
    var list = spots
    for (var i = 0; i < list.length && out.length < 200; i++) {
      if (isFinite(list[i].freq)) out.push(list[i].freq)
    }
    return out
  }

  function gradeFor(g) {
    switch (String(g || "")) {
    case "Good": return "#3fb950"
    case "Fair": return "#d9a441"
    case "Poor": return "#c8503c"
    }
    return String(Color.muted)
  }
  readonly property string gradeColor: best ? gradeFor(best.grade) : ""

  // ---- Bar pill ---------------------------------------------------------
  readonly property string label: {
    if (!solar) return glyph
    if (pillContent === "sfi") return glyph + "  SFI " + (isFinite(solar.sfi) ? solar.sfi : "--")
    if (pillContent === "k") return glyph + "  K " + (isFinite(solar.k) ? solar.k : "--")
    if (pillContent === "spots") return glyph + "  " + spots.length
    return glyph + "  " + (best ? safeBare(best.band, 12) : "--")
  }

  readonly property string tooltip: {
    if (lastError !== "") return "Ham radio — " + lastError
    if (!solar) return "Ham radio — loading"
    var parts = []
    parts.push("SFI " + (isFinite(solar.sfi) ? solar.sfi : "--")
               + "  A " + (isFinite(solar.a) ? solar.a : "--")
               + "  K " + (isFinite(solar.k) ? solar.k : "--"))
    for (var i = 0; i < bandRows.length; i++) {
      parts.push(safeBare(bandRows[i].band, 12) + "  " + safeBare(bandRows[i].grade, 8))
    }
    if (greyLine && greyLine.active) parts.push("Grey line now (" + greyLine.kind + ")")
    return parts.join("\n")
  }

  // ---- Notification -----------------------------------------------------
  Process { id: notifyProc; command: ["true"] }
  property bool greyArmed: true

  onGreyLineChanged: {
    if (!alertGreyLine || !greyLine) return
    if (!greyLine.active) { greyArmed = true; return }
    if (!greyArmed) return
    greyArmed = false
    notifyProc.command = ["omarchy-notification-send", "-g", glyph, "-u", "normal",
                          "Grey line — " + safe(greyLine.kind, 12),
                          safe("Low bands open for about " + (Ham.GREY_LINE_MINUTES || 40) + " minutes", 90)]
    notifyProc.running = true
  }

  // ---- Networking -------------------------------------------------------
  // Each request carries the generation that made it; a completion whose stamp
  // no longer matches is discarded rather than assigned to whatever is selected
  // by the time it lands.
  property int fetchGen: 0
  property var procGen: [0, 0, 0]

  readonly property var guardedProcs: [solarProc, potaProc, sotaProc, weatherReader]
  readonly property var guardLimits: [20, 20, 20, 4]
  property var guardStarted: [0, 0, 0, 0]

  property var pendingCmd: [null, null, null]

  // Start now if the slot is idle, otherwise queue: a superseded process can
  // still flush its collector after `running = false`, and if the replacement
  // had already rewritten the stamps that stale output would validate against
  // the new request's checks. onExited starts the queued run, by which point
  // the old collector has already run and been rejected.
  function launch(i, cmd) {
    var pc = pendingCmd; pc[i] = cmd; pendingCmd = pc
    var proc = guardedProcs[i]
    if (proc.running) { proc.running = false; return }
    startPending(i)
  }

  function startPending(i) {
    var started = guardStarted; started[i] = 0; guardStarted = started
    var cmd = pendingCmd[i]
    if (!cmd) return
    var pc = pendingCmd; pc[i] = null; pendingCmd = pc
    var g = procGen; g[i] = fetchGen; procGen = g
    var proc = guardedProcs[i]
    proc.command = cmd
    // Bound to the launch, not to the watchdog's next tick — otherwise a quick
    // completion followed by a new run inherits the old run's age.
    started = guardStarted; started[i] = Date.now(); guardStarted = started
    proc.running = true
  }

  function fresh(i) { return procGen[i] === fetchGen }

  function invalidate() {
    fetchGen += 1
    var pc = pendingCmd
    for (var i = 0; i < 3; i++) {
      pc[i] = null
      if (guardedProcs[i].running) guardedProcs[i].running = false
    }
    pendingCmd = pc
    loading = false
  }

  function openFromHotkey() { open() }

  function refresh() {
    if (!solarProc.running) { loading = true; launch(0, fetchArgs(20, solarUrl)) }
    if (spotSource === "both" || spotSource === "pota") { if (!potaProc.running) launch(1, fetchArgs(20, potaUrl)) }
    if (spotSource === "both" || spotSource === "sota") { if (!sotaProc.running) launch(2, fetchArgs(20, sotaUrl)) }
  }

  Component.onCompleted: refresh()
  onOpenedChanged: {
    if (!opened) return
    refresh()
    Qt.callLater(playForView)
    if (debugGeometry) geometryTimer.restart()
  }
  onSpotSourceChanged: { invalidate(); refresh() }

  // The solar feed is regenerated roughly hourly; the spot feeds move
  // constantly but a bar widget does not need to see every one of them.
  Timer { interval: 900000; running: true; repeat: true; onTriggered: root.refresh() }
  Timer { interval: 180000; running: true; repeat: true
          onTriggered: { if (root.spotSource !== "off") root.refresh() } }
  Timer { interval: 1000; running: true; repeat: true; onTriggered: root.nowMs = Date.now() }

  // curl's --max-time is curl's own clock. This is an independent one.
  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: {
      var now = Date.now()
      var started = root.guardStarted
      for (var i = 0; i < root.guardedProcs.length; i++) {
        var proc = root.guardedProcs[i]
        if (!proc.running || !started[i]) continue
        if (now - started[i] > (root.guardLimits[i] + 5) * 1000) {
          proc.running = false
          started[i] = 0
          root.loading = false
        }
      }
      root.guardStarted = started
    }
  }

  Process {
    id: solarProc
    command: ["true"]            // replaced at launch
    onExited: { root.loading = false; root.startPending(0) }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.fresh(0)) return
        var body = root.boundedText(text)
        if (body === "") { root.lastError = "no solar data"; return }
        var parsed = Ham.parseSolar(body)
        if (!parsed || !parsed.bands.length) { root.lastError = "could not read the solar feed"; return }
        parsed.bands = root.boundedList(parsed.bands, 12)
        root.solar = parsed
        root.lastError = ""
      }
    }
  }

  Process {
    id: potaProc
    command: ["true"]            // replaced at launch
    onExited: root.startPending(1)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.fresh(1)) return
        try {
          var arr = root.parseBounded(text)
          if (!arr) return
          arr = root.boundedList(arr, 120)
          var out = []
          for (var i = 0; i < arr.length; i++) {
            var s = Ham.normalisePotaSpot(arr[i])
            if (s) { s.place = root.safe(s.place, 40); out.push(s) }
          }
          root.potaSpots = out
        } catch (e) { /* keep the previous list */ }
      }
    }
  }

  Process {
    id: sotaProc
    command: ["true"]            // replaced at launch
    onExited: root.startPending(2)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.fresh(2)) return
        try {
          var arr = root.parseBounded(text)
          if (!arr) return
          arr = root.boundedList(arr, 120)
          var out = []
          for (var i = 0; i < arr.length; i++) {
            var s = Ham.normaliseSotaSpot(arr[i])
            if (s) { s.place = root.safe(s.place, 40); out.push(s) }
          }
          root.sotaSpots = out
        } catch (e) { /* keep the previous list */ }
      }
    }
  }

  // ---- Grey-line strip geometry -----------------------------------------
  readonly property double localMidnightMs: {
    var d = new Date(nowMs)
    if (utc) return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate())
    return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
  }
  readonly property var todayEvents: hasSite
    ? Ham.solarEvents(new Date(localMidnightMs + 43200000), siteLat, siteLon, -0.833) : null

  // ---- Formatting -------------------------------------------------------
  function clock(ms) {
    if (!isFinite(ms)) return "--"
    var d = new Date(ms)
    var h = utc ? d.getUTCHours() : d.getHours()
    var m = utc ? d.getUTCMinutes() : d.getMinutes()
    return (h < 10 ? "0" + h : h) + ":" + (m < 10 ? "0" + m : m) + (utc ? "Z" : "")
  }

  function playForView() {
    if (view === "bands") {
      if (spectrum) spectrum.play()
      if (bandTable) bandTable.play()
    }
    else if (view === "greyline" && greyStrip) greyStrip.play()
  }
  onViewChanged: if (opened) Qt.callLater(playForView)

  Timer { id: geometryTimer; interval: 1200; onTriggered: root.reportGeometry() }
  // Re-arm on *any* geometry change, not only height. The panel clamps its own
  // x against the screen edge once it knows its final width, so a rect reported
  // before that lands is a couple of hundred pixels out — and the crop then
  // photographs whatever is beside the popup instead.
  Connections {
    target: root.debugGeometry ? root.panelFrame : null
    function onHeightChanged() { geometryTimer.restart() }
    function onWidthChanged() { geometryTimer.restart() }
    function onXChanged() { geometryTimer.restart() }
    function onYChanged() { geometryTimer.restart() }
  }

  // The popup lives in a fullscreen layer surface, so nothing outside the shell
  // can work out its rectangle. With debugGeometry on it says so itself, which
  // is what tools/capture-preview.sh crops to.
  function reportGeometry() {
    if (!panelFrame) return
    var inset = panel.padding + Math.max(1, Style.space(2))
    var o = panelFrame.mapToGlobal(0, 0)
    console.log("HAM_GEOMETRY " + Math.round(o.x - inset) + " " + Math.round(o.y - inset)
                + " " + Math.round(panelFrame.width + inset * 2)
                + " " + Math.round(panelFrame.height + inset * 2))
  }

  // ---- Popup ------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: String(root.setting("popupPosition", "icon")) === "center"
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      Component.onCompleted: root.panelFrame = keyCatcher
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        // Masthead.
        Item {
          width: parent.width
          height: brandRow.implicitHeight

          Row {
            id: brandRow
            spacing: Style.space(7)
            anchors.left: parent.left
            Text {
              textFormat: Text.PlainText
              text: root.glyph
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              textFormat: Text.PlainText
              text: "HF PROPAGATION"
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.space(11)
              font.bold: true
              font.letterSpacing: Style.space(3)
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Text {
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.myGrid !== "" ? (root.myGrid + "  ·  " + (root.isDay ? "day" : "night")) : ""
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.space(11)
          }
        }

        // Headline: the band to try, at the size it deserves.
        Column {
          width: parent.width
          spacing: Style.space(1)

          Row {
            spacing: Style.space(9)
            Text {
              textFormat: Text.PlainText
              text: root.best ? root.safe(root.best.band, 12) : "—"
              color: root.best ? root.gradeFor(root.best.grade) : Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.space(24)
              font.bold: true
              anchors.bottom: parent.bottom
              Behavior on color {
                enabled: root.animOn
                ColorAnimation { duration: 420; easing.type: Easing.InOutQuad }
              }
            }
            Text {
              textFormat: Text.PlainText
              text: root.best ? root.safe(root.best.grade, 8)
                    : (root.lastError !== "" ? root.lastError : "loading")
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.space(14)
              anchors.bottom: parent.bottom
              bottomPadding: Style.space(4)
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.greyLine !== null && root.greyLine.active
            width: parent.width
            text: root.greyLine
              ? ("Grey line now — " + root.greyLine.kind + ", low bands long")
              : ""
            color: "#e0a63a"
            font.family: Style.font.family
            font.pixelSize: Style.space(12)
            wrapMode: Text.WordWrap
          }
        }

        ButtonGroup {
          options: [
            { value: "bands", label: "Bands" },
            { value: "spots", label: "Spots" },
            { value: "greyline", label: "Grey line" }
          ]
          value: root.view
          focusable: false
          foreground: Color.popups.text
          background: Color.popups.background
          accent: Color.accent
          fontSize: Style.space(12)
          onChanged: function (v) { root.chosenView = v }
        }

        // ---- Bands ----
        Column {
          visible: root.view === "bands"
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: {
              if (!root.solar) return "BAND CONDITIONS"
              var head = "UPDATED " + root.safe(root.solar.updated, 32)
              return root.spotFreqs.length
                ? head + "  \u00b7  " + root.spotFreqs.length + " ON THE AIR" : head
            }
            foreground: Color.popups.text
            font.letterSpacing: Style.space(2)
          }

          Spectrum {
            id: spectrum
            width: parent.width
            bands: root.solar ? root.solar.bands : []
            spotFreqs: root.spotFreqs
            isDay: root.isDay
            gradeColor: root.gradeFor
            inkColor: Color.popups.text
            mutedColor: Color.muted
            fontFamily: Style.font.family
            labelSize: Style.space(10)
            animate: root.animOn
          }

          PanelSeparator { foreground: Color.popups.text }

          BandTable {
            id: bandTable
            width: parent.width
            rows: root.bandRows
            isDay: root.isDay
            gradeColor: root.gradeFor
            inkColor: Color.popups.text
            mutedColor: Color.muted
            fontFamily: Style.font.family
            fontSize: Style.space(12)
            animate: root.animOn
          }

          PanelSeparator { foreground: Color.popups.text }

          Column {
            width: parent.width
            spacing: Style.space(3)
            StatRow {
              label: "Solar flux"
              value: root.solar && isFinite(root.solar.sfi) ? String(root.solar.sfi) : "--"
              note: "10.7 cm"
            }
            StatRow {
              label: "Sunspot number"
              value: root.solar && isFinite(root.solar.ssn) ? String(root.solar.ssn) : "--"
            }
            StatRow {
              label: "A / K index"
              value: root.solar
                ? ((isFinite(root.solar.a) ? root.solar.a : "--") + " / "
                   + (isFinite(root.solar.k) ? root.solar.k : "--")) : "--"
              note: root.solar ? Ham.geomagneticNote(root.solar.k) : ""
              highlight: root.solar && isFinite(root.solar.k) && root.solar.k >= 4
            }
            StatRow {
              label: "X-ray"
              value: root.solar ? root.safe(root.solar.xray, 10) : "--"
              note: root.solar && isFinite(root.solar.foF2) ? ("foF2 " + root.solar.foF2 + " MHz") : ""
            }
            StatRow {
              visible: root.solar && root.solar.signalNoise !== ""
              label: "Signal noise"
              value: root.solar ? root.safe(root.solar.signalNoise, 12) : "--"
            }
          }
        }

        // ---- Spots ----
        Column {
          visible: root.view === "spots"
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: root.spotSource === "off" ? "SPOTS OFF" : "ON THE AIR NOW"
            foreground: Color.popups.text
            font.letterSpacing: Style.space(2)
          }

          Text {
            textFormat: Text.PlainText
            visible: root.spots.length === 0
            width: parent.width
            text: root.spotSource === "off"
              ? "Spot fetching is turned off. Set spotSource to pota, sota or both to see live activations."
              : (root.bandFilter.length
                 ? "No activations on those bands right now."
                 : "No activations reported right now.")
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.space(12)
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.spots.slice(0, 14)
            Row {
              id: sp
              required property var modelData
              width: parent ? parent.width : 0
              spacing: Style.space(7)

              Rectangle {
                width: Style.space(3)
                height: Style.space(15)
                radius: Style.space(2)
                // The colour of the band's current grade, so the list says
                // whether a spot is workable without a trip to the Bands tab.
                // A band with no published forecast stays neutral.
                color: {
                  var g = Ham.gradeForBand(root.solar ? root.solar.bands : [],
                                           sp.modelData.band, root.isDay)
                  return g !== "" ? root.gradeFor(g) : Color.muted
                }
                opacity: 0.85
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                textFormat: Text.PlainText
                width: Style.space(74)
                text: root.safe(sp.modelData.call, 16)
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.space(12)
                elide: Text.ElideRight
              }
              Text {
                textFormat: Text.PlainText
                width: Style.space(38)
                text: root.safe(sp.modelData.band, 6)
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.space(11)
              }
              Text {
                textFormat: Text.PlainText
                width: Style.space(52)
                text: Ham.formatFreq(sp.modelData.freq)
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.space(11)
                horizontalAlignment: Text.AlignRight
              }
              Text {
                textFormat: Text.PlainText
                width: Style.space(34)
                text: root.safe(sp.modelData.mode, 6)
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.space(11)
              }
              Text {
                textFormat: Text.PlainText
                width: Math.max(Style.space(20), sp.width - Style.space(220))
                text: root.safe(sp.modelData.ref, 12)
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.space(11)
                elide: Text.ElideRight
              }
            }
          }
        }

        // ---- Grey line ----
        Column {
          visible: root.view === "greyline"
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "TODAY"
            foreground: Color.popups.text
            font.letterSpacing: Style.space(2)
          }

          GreyLineStrip {
            id: greyStrip
            width: parent.width
            dayStartMs: (root.todayEvents && root.todayEvents.rise) ? root.todayEvents.rise.getTime() : 0
            dayEndMs: (root.todayEvents && root.todayEvents.set) ? root.todayEvents.set.getTime() : 0
            windowStartMs: root.localMidnightMs
            nowMs: root.nowMs
            polarDay: root.todayEvents ? root.todayEvents.always === "above" : false
            polarNight: root.todayEvents ? root.todayEvents.always === "below" : false
            inkColor: Color.popups.text
            fontFamily: Style.font.family
            labelSize: Style.space(10)
            animate: root.animOn
          }

          Column {
            width: parent.width
            spacing: Style.space(3)
            StatRow {
              label: "Sunrise"
              value: (root.todayEvents && root.todayEvents.rise)
                ? root.clock(root.todayEvents.rise.getTime()) : "--"
              note: "grey line ± 40 min"
            }
            StatRow {
              label: "Sunset"
              value: (root.todayEvents && root.todayEvents.set)
                ? root.clock(root.todayEvents.set.getTime()) : "--"
              note: "grey line ± 40 min"
            }
            StatRow {
              label: "Next window"
              value: root.greyLine ? root.clock(root.greyLine.at.getTime()) : "--"
              note: root.greyLine
                ? (root.greyLine.active ? "open now"
                   : (root.greyLine.delta > 0 ? "in " + Math.round(root.greyLine.delta / 60000) + " min"
                                              : Math.round(-root.greyLine.delta / 60000) + " min ago"))
                : ""
              highlight: root.greyLine !== null && root.greyLine.active
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Along the terminator the D layer has decayed while the F layer is still lit, so 160 through 40 metres carry much further than at any other time. The window is short."
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.space(11)
            wrapMode: Text.WordWrap
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: "Conditions from N0NBH (hamqsl.com); spots from POTA and SOTA."
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.space(10)
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  component StatRow: Row {
    id: sr
    property string label: ""
    property string value: ""
    property string note: ""
    property bool highlight: false
    width: parent ? parent.width : 0
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      width: Style.space(130)
      text: sr.label
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.space(13)
      elide: Text.ElideRight
    }
    Text {
      textFormat: Text.PlainText
      width: Style.space(80)
      text: sr.value
      color: sr.highlight ? Color.accent : Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.space(13)
      font.bold: sr.highlight
    }
    Text {
      textFormat: Text.PlainText
      width: Math.max(Style.space(20), sr.width - Style.space(130 + 80 + 16))
      text: sr.note
      color: Color.muted
      elide: Text.ElideRight
      font.family: Style.font.family
      font.pixelSize: Style.space(12)
    }
  }
}
