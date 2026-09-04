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
  readonly property string sotaUrl: "https://api-db2.sota.org.uk/api/spots/20/all/all"
  readonly property string sotaSummitUrl: "https://api-db2.sota.org.uk/api/summits/"
  readonly property string ua: "omarchy-hamradio/0.3.1"

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
    text = text.replace(/[\u0000-\u001F\u007F\u0080-\u009F]+/g, " ")
                   // Bidi and other invisible format controls can reorder or
                   // hide what is shown without changing what was checked.
                   .replace(/[\u061C\u200B-\u200F\u202A-\u202E\u2060-\u2064\u2066-\u206F\uFEFF]/g, "").replace(/^\s+|\s+$/g, "")
    var cap = limit || maxFieldChars
    return text.length > cap ? text.slice(0, cap) + "\u2026" : text
  }

  // The bar pill and its tooltip render in Text elements the shell owns, where
  // textFormat is not ours to set, so the markup comes out of the string.
  // A tooltip is deliberately several lines, and safe() strips newlines along
  // with every other C0 control — so the boundary is applied per line and the
  // structure is rebuilt, rather than the whole thing being flattened.
  function safeBareLines(v, perLine, maxLines) {
    var lines = String(v === null || v === undefined ? "" : v).split("\n")
    var out = []
    for (var i = 0; i < lines.length && out.length < (maxLines || 12); i++) {
      out.push(safeBare(lines[i], perLine || 80))
    }
    return out.join("\n")
  }

  function safeBare(v, limit) { return safe(v, limit).replace(/[<>&]/g, " ") }

  function boundedList(v, cap) {
    if (!v || !v.length) return []
    return v.length > cap ? v.slice(0, cap) : v
  }

  function copyMap(v) {
    var out = {}
    for (var k in (v || {})) {
      if (Object.prototype.hasOwnProperty.call(v, k)) out[k] = v[k]
    }
    return out
  }

  // ---- Location ---------------------------------------------------------
  // Explicit coordinates override a locator; otherwise use the locator, then the
  // location the built-in weather widget already knows.
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
    onStarted: root.weatherStartedMs = Date.now()
    onExited: root.weatherStartedMs = 0
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
  property bool potaStale: false
  property bool sotaStale: false
  property double lastPotaSuccessMs: 0
  property double lastSotaSuccessMs: 0

  // These are intentionally session-only.  The manifest/CLI settings remain
  // the persistent policy; these chips are just a fast way to focus the list
  // while the popup is open.
  property string spotUiSource: "all"
  property string spotUiBand: ""

  // SOTA's spot feed identifies the summit but does not reliably carry its
  // coordinates.  Resolve each unseen summit through the official summit API,
  // one at a time, and cache it for the lifetime of the shell.
  property var sotaGeoCache: ({})
  property var sotaGeoCacheOrder: []
  property var sotaGeoRetryAfter: ({})
  property var sotaGeoRetryCount: ({})
  property var sotaGeoRetryOrder: []
  property double sotaGeoPauseUntilMs: 0
  property var sotaGeoQueue: []
  property string sotaGeoCurrent: ""
  property double sotaGeoStartedMs: 0
  property bool sotaGeoExitSeen: false
  property bool sotaGeoStreamDone: false
  property int sotaGeoExitCode: -1
  property string sotaGeoStreamText: ""
  property bool sotaGeoCancelled: false
  property bool sotaGeoDirty: false

  // Detached browser launches must not block a cold-starting browser, but the
  // same row double-clicked while that browser starts should still be one user
  // action. Different spot URLs are never throttled against each other.
  property string lastSpotOpenUrl: ""
  property double lastSpotOpenMs: 0

  // ---- Derived ----------------------------------------------------------
  readonly property bool isDay: hasSite ? Ham.isDaylight(new Date(nowMs), siteLat, siteLon) : true
  readonly property var bandRows: solar ? Ham.bandsForNow(solar.bands, isDay) : []
  readonly property var best: solar ? Ham.bestBand(solar.bands, isDay) : null
  readonly property var greyLine: hasSite ? Ham.greyLine(new Date(nowMs), siteLat, siteLon) : null
  readonly property var nextTransition: hasSite ? Ham.nextSolarEvent(new Date(nowMs), siteLat, siteLon) : null

  readonly property var spots: {
    var all = []
    if (spotSource === "both" || spotSource === "pota") all = all.concat(potaSpots)
    if (spotSource === "both" || spotSource === "sota") all = all.concat(sotaSpots)
    if (bandFilter.length) {
      all = all.filter(function (s) { return bandFilter.indexOf(String(s.band).toLowerCase()) >= 0 })
    }
    return Ham.sortSpots(all, hasSite ? { lat: siteLat, lon: siteLon } : null)
  }

  readonly property var sourceSpots: {
    if (spotUiSource === "all") return spots
    var wantSource = spotUiSource.toUpperCase()
    return spots.filter(function (s) { return String(s.source).toUpperCase() === wantSource })
  }

  readonly property var displaySpots: {
    var out = sourceSpots
    if (spotUiBand === "__other__") {
      out = out.filter(function (s) { return String(s.band || "") === "" })
    } else if (spotUiBand !== "") {
      var wantBand = spotUiBand.toLowerCase()
      out = out.filter(function (s) { return String(s.band).toLowerCase() === wantBand })
    }
    return out
  }

  // The quick band row is derived from the spots that can actually be shown
  // for the selected source.  That makes ALL exactly the union of the visible
  // buckets instead of silently meaning "HF plus everything else".  Anything
  // outside the known band plan remains reachable through OTHER.
  readonly property var spotBandOptions: {
    var buckets = Ham.spotBandBuckets(sourceSpots)
    var out = [{ band: "", label: "ALL BANDS", count: sourceSpots.length }]
    for (var i = 0; i < buckets.length; i++) {
      var band = buckets[i].band
      out.push({ band: band, label: band === "__other__" ? "OTHER" : band, count: buckets[i].count })
    }
    return out
  }


  onSpotBandOptionsChanged: {
    if (spotUiBand === "") return
    for (var i = 0; i < spotBandOptions.length; i++) {
      if (spotBandOptions[i].band === spotUiBand) return
    }
    spotUiBand = ""
  }

  readonly property int totalPotaCount: spots.filter(function (s) { return s.source === "POTA" }).length
  readonly property int totalSotaCount: spots.filter(function (s) { return s.source === "SOTA" }).length
  readonly property int visiblePotaCount: displaySpots.filter(function (s) { return s.source === "POTA" }).length
  readonly property int visibleSotaCount: displaySpots.filter(function (s) { return s.source === "SOTA" }).length
  readonly property double lastSpotSuccessMs:
    spotSource === "pota" ? lastPotaSuccessMs
    : (spotSource === "sota" ? lastSotaSuccessMs
       : (spotSource === "both" ? Math.max(lastPotaSuccessMs, lastSotaSuccessMs) : 0))
  readonly property bool spotsStale:
    (spotSource === "both" && (potaStale || sotaStale))
    || (spotSource === "pota" && potaStale)
    || (spotSource === "sota" && sotaStale)
  readonly property bool refreshing: solarProc.running || potaProc.running || sotaProc.running

  // Frequencies only, for the spectrum's ticks. Quick source/band filters are
  // presentation state, so the spectrum follows the same view the operator is
  // looking at rather than silently showing hidden spots.
  readonly property var spotFreqs: {
    var out = []
    var list = displaySpots
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

  function ageText(at) {
    return Ham.formatAge(Ham.minutesAgo(at, nowMs))
  }

  function distanceForSpot(s) {
    if (!hasSite || !s) return NaN
    if (isFinite(s.distanceKm)) return Number(s.distanceKm)
    if (!isFinite(s.lat) || !isFinite(s.lon)) return NaN
    return Ham.distanceKm(siteLat, siteLon, Number(s.lat), Number(s.lon))
  }

  function distanceText(s) {
    var km = distanceForSpot(s)
    if (!isFinite(km)) return ""
    var bearing = isFinite(s && s.bearingDeg) ? Number(s.bearingDeg)
      : Ham.bearingDeg(siteLat, siteLon, Number(s.lat), Number(s.lon))
    return Math.round(km) + " km " + Ham.cardinal(bearing)
  }

  function spotUrl(s) {
    if (!s || !s.ref) return ""
    var ref = String(s.ref).toUpperCase().replace(/[^A-Z0-9\-\/]/g, "").slice(0, 20)
    if (ref === "") return ""
    if (s.source === "POTA") return "https://pota.app/#/park/" + ref.replace(/\//g, "")
    if (s.source === "SOTA" && ref.indexOf("/") > 0) return "https://summits.sota.org.uk/summit/" + ref
    return ""
  }

  function openSpot(s) {
    var url = spotUrl(s)
    if (url === "") return
    var now = Date.now()
    if (url === lastSpotOpenUrl && now - lastSpotOpenMs < 1200) return
    lastSpotOpenUrl = url
    lastSpotOpenMs = now
    // xdg-open may stay alive while a cold browser starts. A tracked Process
    // would then make later clicks look "busy" and drop them, so each accepted
    // click is detached; the same-URL debounce above only collapses double-clicks.
    Quickshell.execDetached(["xdg-open", url])
  }

  function setSpotSourceFilter(value) {
    spotUiSource = value
    spotUiBand = ""
    Qt.callLater(function () { if (spotList) spotList.positionViewAtBeginning() })
  }

  function setSpotBandFilter(value) {
    spotUiBand = (value !== "" && spotUiBand === value) ? "" : value
    Qt.callLater(function () { if (spotList) spotList.positionViewAtBeginning() })
  }

  function spotGrade(s) {
    return Ham.gradeForBand(solar ? solar.bands : [], s ? s.band : "", isDay)
  }

  function scrollSpotRows(rows) {
    if (!spotList || !spotList.visible || spotList.contentHeight <= spotList.height) return
    var maxY = Math.max(0, spotList.contentHeight - spotList.height)
    var nextY = spotList.contentY + Number(rows) * Style.space(34)
    spotList.contentY = Math.max(0, Math.min(maxY, nextY))
  }

  function spotFreshness() {
    if (!lastSpotSuccessMs) return "waiting for first update"
    var age = Ham.formatAge(Ham.minutesAgo(lastSpotSuccessMs, nowMs))
    return age === "now" ? "updated now" : "updated " + age + " ago"
  }

  function durationText(ms) {
    var m = Math.ceil(Math.max(0, Number(ms)) / 60000)
    return m < 1 ? "<1m" : Ham.formatAge(m)
  }

  function transitionText() {
    if (!hasSite) return ""
    if (!nextTransition) {
      return todayEvents && todayEvents.always === "above" ? "POLAR DAY" :
             (todayEvents && todayEvents.always === "below" ? "POLAR NIGHT" : (isDay ? "DAY" : "NIGHT"))
    }
    return (isDay ? "DAY" : "NIGHT") + " · " + nextTransition.kind + " in "
      + durationText(nextTransition.delta)
  }

  function greyWindowCenter() {
    if (greyLine && greyLine.active) return greyLine
    return nextTransition
  }

  function greyWindowStatus() {
    var center = greyWindowCenter()
    if (!center || !center.at) return ""
    var span = (Ham.GREY_LINE_MINUTES || 40) * 60000
    if (greyLine && greyLine.active) {
      var remaining = center.at.getTime() + span - nowMs
      return "OPEN · " + durationText(remaining) + " remaining"
    }
    return "next " + center.kind + " in " + durationText(center.at.getTime() - nowMs)
  }

  function greyWindowRange() {
    var center = greyWindowCenter()
    if (!center || !center.at) return ""
    var span = (Ham.GREY_LINE_MINUTES || 40) * 60000
    return clock(center.at.getTime() - span) + "–" + clock(center.at.getTime() + span)
  }

  // ---- Bar pill ---------------------------------------------------------
  readonly property string label: safeBare(rawLabel, 40)

  readonly property string rawLabel: {
    if (!solar) return glyph
    if (pillContent === "sfi") return glyph + "  SFI " + (isFinite(solar.sfi) ? solar.sfi : "--")
    if (pillContent === "k") return glyph + "  K " + (isFinite(solar.k) ? solar.k : "--")
    if (pillContent === "spots") return glyph + "  " + spots.length
    return glyph + "  " + (best ? safeBare(best.band, 12) : "--")
  }

  // Both of these render in Text elements the shell owns, where this plugin
  // cannot set textFormat — so the boundary is applied to the finished string
  // rather than trusting that every piece was clean on the way in.
  readonly property string tooltip: safeBareLines(rawTooltip, 80, 10)

  readonly property string rawTooltip: {
    var parts = []
    if (lastError !== "") parts.push("Ham radio — " + lastError)
    if (myGrid !== "") {
      var transition = transitionText()
      parts.push(myGrid + (transition !== "" ? " · " + transition.toLowerCase() : ""))
    }
    if (!solar) {
      if (!parts.length) parts.push("Ham radio — loading")
      return parts.join("\n")
    }
    parts.push("SFI " + (isFinite(solar.sfi) ? solar.sfi : "--")
               + "  A " + (isFinite(solar.a) ? solar.a : "--")
               + "  K " + (isFinite(solar.k) ? solar.k : "--"))
    for (var i = 0; i < bandRows.length; i++) {
      parts.push(safeBare(bandRows[i].band, 12) + "  " + safeBare(bandRows[i].grade, 8))
    }
    parts.push(spots.length + " activations" + (spotsStale ? " · stale source" : ""))
    if (greyLine && greyLine.active) parts.push("Grey line · " + greyWindowStatus())
    else if (greyWindowCenter()) parts.push("Grey line · " + greyWindowStatus())
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

  readonly property var guardedProcs: [solarProc, potaProc, sotaProc]
  readonly property var guardLimits: [20, 20, 20]
  property var guardStarted: [0, 0, 0]
  property var guardActive: [false, false, false]
  property var guardStopping: [false, false, false]
  property var guardExitSeen: [false, false, false]
  property var guardStreamDone: [false, false, false]
  property double weatherStartedMs: 0

  property var pendingCmd: [null, null, null]

  // A Process can report exit and close its stdout in either order.  A slot is
  // therefore not reusable until *both* signals for the old run have arrived.
  // This keeps a cancelled/stale collector from observing stamps belonging to
  // its replacement, especially when spotSource changes mid-request.
  function launch(i, cmd) {
    var pc = pendingCmd; pc[i] = cmd; pendingCmd = pc
    var proc = guardedProcs[i]
    if (guardActive[i] || proc.running) {
      if (proc.running && !guardStopping[i]) {
        var stopping = guardStopping; stopping[i] = true; guardStopping = stopping
        proc.running = false
      }
      return
    }
    startPending(i)
  }

  function startPending(i) {
    if (guardActive[i] || guardedProcs[i].running) return
    var cmd = pendingCmd[i]
    if (!cmd) return
    var pc = pendingCmd; pc[i] = null; pendingCmd = pc
    var g = procGen; g[i] = fetchGen; procGen = g
    var active = guardActive; active[i] = true; guardActive = active
    var exits = guardExitSeen; exits[i] = false; guardExitSeen = exits
    var streams = guardStreamDone; streams[i] = false; guardStreamDone = streams
    var stopping = guardStopping; stopping[i] = false; guardStopping = stopping
    var proc = guardedProcs[i]
    proc.command = cmd
    var started = guardStarted; started[i] = Date.now(); guardStarted = started
    proc.running = true
  }

  function fresh(i) { return procGen[i] === fetchGen }

  function guardedExited(i) {
    var exits = guardExitSeen; exits[i] = true; guardExitSeen = exits
    maybeReleaseGuard(i)
  }

  function guardedStreamFinished(i) {
    var streams = guardStreamDone; streams[i] = true; guardStreamDone = streams
    maybeReleaseGuard(i)
  }

  function maybeReleaseGuard(i) {
    if (!guardActive[i] || !guardExitSeen[i] || !guardStreamDone[i]) return
    var active = guardActive; active[i] = false; guardActive = active
    var stopping = guardStopping; stopping[i] = false; guardStopping = stopping
    var started = guardStarted; started[i] = 0; guardStarted = started
    Qt.callLater(function () { root.startPending(i) })
  }

  function invalidate() {
    fetchGen += 1
    var pc = pendingCmd
    var stopping = guardStopping
    for (var i = 0; i < guardedProcs.length; i++) {
      pc[i] = null
      if (guardActive[i] || guardedProcs[i].running) {
        stopping[i] = true
        if (guardedProcs[i].running) guardedProcs[i].running = false
      }
    }
    pendingCmd = pc
    guardStopping = stopping
    loading = false
  }

  function openFromHotkey() { open() }

  function sotaGeoFetchArgs(seconds, url) {
    // Summit lookups need the HTTP status so permanent misses (404/410) can be
    // cached separately from transient transport/server failures.  Do not use
    // -f here: it would collapse every HTTP failure into curl exit 22.
    return ["curl", "-q", "-sS", "-A", ua,
            "--proto", "=https",
            "--max-time", String(seconds),
            "--max-filesize", String(maxResponseBytes),
            "--write-out", "\n%{http_code}",
            url]
  }

  function parseHttpEnvelope(raw) {
    var text = String(raw || "")
    var m = /\n([0-9]{3})$/.exec(text)
    if (!m) return { status: 0, body: "" }
    var body = text.slice(0, m.index)
    if (body.length > maxResponseBytes) body = ""
    return { status: parseInt(m[1]), body: body }
  }

  function clearSotaGeoRetry(key) {
    var cacheKey = "k:" + key
    var after = copyMap(sotaGeoRetryAfter); delete after[cacheKey]; sotaGeoRetryAfter = after
    var counts = copyMap(sotaGeoRetryCount); delete counts[cacheKey]; sotaGeoRetryCount = counts
    var order = sotaGeoRetryOrder.slice(0)
    var at = order.indexOf(cacheKey)
    if (at >= 0) order.splice(at, 1)
    sotaGeoRetryOrder = order
  }

  function storeSotaGeoCache(key, value) {
    var cacheKey = "k:" + key
    var cache = copyMap(sotaGeoCache)
    var order = sotaGeoCacheOrder.slice(0)
    if (!Object.prototype.hasOwnProperty.call(cache, cacheKey)) order.push(cacheKey)
    while (order.length > 512) {
      var expired = order.shift()
      delete cache[expired]
    }
    cache[cacheKey] = value
    sotaGeoCache = cache
    sotaGeoCacheOrder = order
    clearSotaGeoRetry(key)
  }

  function rememberSotaGeoFailure(key, status) {
    var cacheKey = "k:" + key
    var counts = copyMap(sotaGeoRetryCount)
    var attempt = Number(counts[cacheKey] || 0) + 1
    var policy = Ham.sotaGeoFailurePolicy(status, attempt)
    if (policy.permanent) {
      // A real 404/410 cannot become useful by polling it every three minutes.
      // Keep a terminal sentinel for this shell session; a shell restart or a
      // future spot carrying coordinates naturally gives the summit a new path.
      storeSotaGeoCache(key, { missing: true })
      return
    }

    counts[cacheKey] = attempt
    var after = copyMap(sotaGeoRetryAfter)
    after[cacheKey] = Date.now() + policy.retryMs
    var order = sotaGeoRetryOrder.slice(0)
    if (order.indexOf(cacheKey) < 0) order.push(cacheKey)
    while (order.length > 512) {
      var expired = order.shift()
      delete after[expired]
      delete counts[expired]
    }
    sotaGeoRetryCount = counts
    sotaGeoRetryAfter = after
    sotaGeoRetryOrder = order
    if (policy.globalMs > 0) sotaGeoPauseUntilMs = Math.max(sotaGeoPauseUntilMs, Date.now() + policy.globalMs)
  }

  function applyCachedSotaGeo(s) {
    if (!s || s.geoKey === "") return false
    var cacheKey = "k:" + s.geoKey
    if (!Object.prototype.hasOwnProperty.call(sotaGeoCache, cacheKey)) return false
    var v = sotaGeoCache[cacheKey]
    if (v && v.missing === true) return true
    if (!v || !isFinite(v.lat) || !isFinite(v.lon)) return false
    s.lat = Number(v.lat); s.lon = Number(v.lon)
    return true
  }

  function applySotaGeoBatch() {
    if (!sotaGeoDirty) return
    var list = sotaSpots.slice(0)
    var changed = false
    for (var i = 0; i < list.length; i++) {
      var beforeLat = Number(list[i].lat), beforeLon = Number(list[i].lon)
      root.applyCachedSotaGeo(list[i])
      if ((!isFinite(beforeLat) || !isFinite(beforeLon)) && isFinite(list[i].lat) && isFinite(list[i].lon)) changed = true
    }
    sotaGeoDirty = false
    if (changed) sotaSpots = list
  }

  function scheduleNextSotaGeo(delayMs) {
    if (!sotaGeoQueue.length || sotaGeoCurrent !== "" || sotaGeoProc.running) return
    var delay = Math.max(1500, Number(delayMs) || 1500)
    sotaGeoNextTimer.interval = Math.min(delay, 1800000)
    sotaGeoNextTimer.restart()
  }

  function queueSotaGeo(list) {
    if (!hasSite) return
    var q = sotaGeoQueue.slice(0)
    var now = Date.now()
    for (var i = 0; i < (list || []).length; i++) {
      var s = list[i]
      if (!s || s.geoKey === "" || (isFinite(s.lat) && isFinite(s.lon)) || applyCachedSotaGeo(s)) continue
      var retryAt = Number(sotaGeoRetryAfter["k:" + s.geoKey] || 0)
      if (retryAt > now) continue
      if (s.geoKey === sotaGeoCurrent || q.indexOf(s.geoKey) >= 0) continue
      q.push(s.geoKey)
    }
    // Bounded and serialized: an initial global SOTA list must never turn into
    // an unbounded fan-out against SOTA infrastructure.
    sotaGeoQueue = q.slice(0, 32)
    if (sotaGeoQueue.length && !sotaGeoProc.running && sotaGeoCurrent === "") {
      var pause = Math.max(0, sotaGeoPauseUntilMs - now)
      scheduleNextSotaGeo(pause)
    }
  }

  function startNextSotaGeo() {
    if (!hasSite || sotaGeoProc.running || sotaGeoCurrent !== "" || !sotaGeoQueue.length) return
    var now = Date.now()
    if (sotaGeoPauseUntilMs > now) { scheduleNextSotaGeo(sotaGeoPauseUntilMs - now); return }
    var q = sotaGeoQueue.slice(0)
    var key = String(q.shift() || "").toUpperCase().replace(/[^A-Z0-9\-\/]/g, "").slice(0, 24)
    sotaGeoQueue = q
    if (!/^[A-Z0-9]{1,8}\/[A-Z0-9]{1,8}-[0-9]{1,4}$/.test(key)) {
      scheduleNextSotaGeo(1500); return
    }
    sotaGeoCurrent = key
    sotaGeoStartedMs = now
    sotaGeoExitSeen = false
    sotaGeoStreamDone = false
    sotaGeoExitCode = -1
    sotaGeoStreamText = ""
    sotaGeoCancelled = false
    sotaGeoProc.command = sotaGeoFetchArgs(12, sotaSummitUrl + key)
    sotaGeoProc.running = true
  }

  function tryFinishSotaGeo() {
    if (sotaGeoCurrent === "" || !sotaGeoExitSeen || !sotaGeoStreamDone) return
    var key = sotaGeoCurrent
    var cancelled = sotaGeoCancelled
    var exitCode = sotaGeoExitCode
    var envelope = parseHttpEnvelope(sotaGeoStreamText)

    // Clear the run identity exactly once before any cache/list assignment can
    // trigger bindings.  onExited and streamFinished may arrive in either order.
    sotaGeoCurrent = ""
    sotaGeoStartedMs = 0
    sotaGeoExitSeen = false
    sotaGeoStreamDone = false
    sotaGeoExitCode = -1
    sotaGeoStreamText = ""
    sotaGeoCancelled = false

    if (!cancelled) {
      if (exitCode === 0 && envelope.status >= 200 && envelope.status < 300) {
        try {
          var d = envelope.body === "" ? null : JSON.parse(envelope.body)
          if (Array.isArray(d)) d = d.length ? d[0] : null
          var lat = d ? parseFloat(String(d.latitude === null || d.latitude === undefined ? "" : d.latitude)) : NaN
          var lon = d ? parseFloat(String(d.longitude === null || d.longitude === undefined ? "" : d.longitude)) : NaN
          if (isFinite(lat) && isFinite(lon) && Math.abs(lat) <= 90 && Math.abs(lon) <= 180) {
            storeSotaGeoCache(key, { lat: lat, lon: lon })
            sotaGeoDirty = true
            if (!sotaGeoFlushTimer.running) sotaGeoFlushTimer.start()
          } else {
            // A syntactically successful response with no usable coordinates is
            // transient: do not convert an upstream schema hiccup into a session
            // long negative cache.
            rememberSotaGeoFailure(key, 502)
          }
        } catch (e) { rememberSotaGeoFailure(key, 502) }
      } else {
        rememberSotaGeoFailure(key, envelope.status || 0)
      }
    }

    if (sotaGeoQueue.length) {
      var pause = Math.max(0, sotaGeoPauseUntilMs - Date.now())
      scheduleNextSotaGeo(pause)
    }
  }

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
  onSpotSourceChanged: {
    invalidate()
    if (spotSource !== "both" && spotSource !== "sota") {
      sotaGeoQueue = []
      if (sotaGeoCurrent !== "") sotaGeoCancelled = true
      if (sotaGeoProc.running) sotaGeoProc.running = false
    }
    refresh()
  }

  onHasSiteChanged: {
    if (hasSite) {
      queueSotaGeo(sotaSpots)
    } else {
      // Coordinates have no value without an operator position to measure from.
      sotaGeoQueue = []
      if (sotaGeoCurrent !== "") sotaGeoCancelled = true
      if (sotaGeoProc.running) sotaGeoProc.running = false
    }
  }

  // The solar feed is regenerated roughly hourly; the spot feeds move
  // constantly but a bar widget does not need to see every one of them.
  Timer { interval: 900000; running: true; repeat: true; onTriggered: root.refresh() }
  Timer { interval: 180000; running: true; repeat: true
          onTriggered: { if (root.spotSource !== "off") root.refresh() } }
  Timer { interval: 1000; running: true; repeat: true; onTriggered: root.nowMs = Date.now() }
  // Summit enrichment is intentionally slower than the spot polling path: one
  // request at a time, at most every 1.5s. Coordinate results are applied to the
  // visible list in small batches so nearest-first ordering does not reshuffle
  // beneath the pointer after every individual summit lookup.
  Timer { id: sotaGeoNextTimer; interval: 1500; onTriggered: root.startNextSotaGeo() }
  Timer { id: sotaGeoFlushTimer; interval: 5000; onTriggered: root.applySotaGeoBatch() }
  Timer {
    interval: 1000; running: true; repeat: true
    onTriggered: {
      if (sotaGeoProc.running && root.sotaGeoStartedMs
          && Date.now() - root.sotaGeoStartedMs > 17000) {
        // Do not finalize here. Setting running=false causes the normal exit and
        // stream-finished signals; tryFinishSotaGeo() joins those exactly once.
        sotaGeoProc.running = false
      }
    }
  }

  // curl's --max-time is curl's own clock. This is an independent one. A killed
  // slot remains active until both process-exit and stdout-finished are observed.
  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: {
      var now = Date.now()
      var started = root.guardStarted
      var stopping = root.guardStopping
      for (var i = 0; i < root.guardedProcs.length; i++) {
        var proc = root.guardedProcs[i]
        if (!root.guardActive[i] || !started[i]) continue
        if (now - started[i] > (root.guardLimits[i] + 5) * 1000) {
          stopping[i] = true
          if (proc.running) proc.running = false
          started[i] = 0
          root.loading = false
        }
      }
      root.guardStarted = started
      root.guardStopping = stopping

      // The weather reader does not use the network queue, but its process is
      // still independently time-bounded as the README promises.
      if (weatherReader.running && root.weatherStartedMs
          && now - root.weatherStartedMs > 5000) weatherReader.running = false
    }
  }

  Process {
    id: solarProc
    command: ["true"]            // replaced at launch
    onExited: function (exitCode, exitStatus) { root.loading = false; root.guardedExited(0) }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          if (!root.fresh(0)) return
          var body = root.boundedText(text)
          if (body === "") { root.lastError = "no solar data"; return }
          var parsed = Ham.parseSolar(body)
          if (!parsed || !parsed.bands.length) { root.lastError = "could not read the solar feed"; return }
          parsed.bands = root.boundedList(parsed.bands, 12)
          root.solar = parsed
          root.lastError = ""
        } finally { root.guardedStreamFinished(0) }
      }
    }
  }

  Process {
    id: potaProc
    command: ["true"]            // replaced at launch
    onExited: function (exitCode, exitStatus) { root.guardedExited(1) }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          if (!root.fresh(1)) return
          try {
            var arr = root.parseBounded(text)
            if (!arr || !Array.isArray(arr)) { root.potaStale = true; return }
            arr = root.boundedList(arr, 120)
            var out = []
            for (var i = 0; i < arr.length; i++) {
              var s = Ham.normalisePotaSpot(arr[i])
              if (s) { s.place = root.safe(s.place, 40); out.push(s) }
            }
            root.potaSpots = out
            root.lastPotaSuccessMs = Date.now()
            root.potaStale = false
          } catch (e) { root.potaStale = true /* keep the previous list */ }
        } finally { root.guardedStreamFinished(1) }
      }
    }
  }

  Process {
    id: sotaProc
    command: ["true"]            // replaced at launch
    onExited: function (exitCode, exitStatus) { root.guardedExited(2) }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          if (!root.fresh(2)) return
          try {
            var arr = root.parseBounded(text)
            if (!arr || !Array.isArray(arr)) { root.sotaStale = true; return }
            arr = root.boundedList(arr, 120)
            var out = Ham.reconcileSotaSpots(arr)
            for (var i = 0; i < out.length; i++) {
              out[i].place = root.safe(out[i].place, 40)
              root.applyCachedSotaGeo(out[i])
            }
            root.sotaSpots = out
            root.lastSotaSuccessMs = Date.now()
            root.sotaStale = false
            root.queueSotaGeo(out)
          } catch (e) { root.sotaStale = true /* keep the previous list */ }
        } finally { root.guardedStreamFinished(2) }
      }
    }
  }

  Process {
    id: sotaGeoProc
    command: ["true"]
    onExited: function (exitCode, exitStatus) {
      root.sotaGeoExitCode = exitCode
      root.sotaGeoExitSeen = true
      root.tryFinishSotaGeo()
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.sotaGeoStreamText = String(text || "")
        root.sotaGeoStreamDone = true
        root.tryFinishSotaGeo()
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
      onMoveRequested: function (dx, dy) {
        if (root.view === "spots" && dy !== 0) root.scrollSpotRows(dy)
      }

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

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(7)

            Text {
              textFormat: Text.PlainText
              text: root.myGrid !== "" ? (root.myGrid + "  ·  " + (root.isDay ? "day" : "night")) : ""
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.space(11)
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: refreshGlyph
              textFormat: Text.PlainText
              text: "↻"
              color: Color.popups.text
              opacity: root.refreshing ? 0.45 : 0.8
              font.family: Style.font.family
              font.pixelSize: Style.space(13)
              anchors.verticalCenter: parent.verticalCenter

              NumberAnimation on rotation {
                from: 0; to: 360; duration: 850
                loops: Animation.Infinite
                running: root.refreshing
              }

              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(5)
                cursorShape: Qt.PointingHandCursor
                onClicked: root.refresh()
              }
            }
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
            width: parent.width
            text: root.transitionText()
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.space(11)
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
          id: spotsColumn
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
            width: parent.width
            text: root.spotSource === "off" ? ""
              : ("POTA " + root.visiblePotaCount + "  ·  SOTA " + root.visibleSotaCount
                 + "  ·  " + root.spotFreshness()
                 + (root.spotsStale ? "  ·  STALE SOURCE" : ""))
            color: root.spotsStale ? "#d9a441" : Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.space(10)
            wrapMode: Text.WordWrap
          }

          Flow {
            width: parent.width
            height: implicitHeight
            spacing: Style.space(5)

            FilterChip {
              label: "ALL " + root.spots.length
              selected: root.spotUiSource === "all"
              onClicked: root.setSpotSourceFilter("all")
            }
            FilterChip {
              label: "POTA " + root.totalPotaCount
              selected: root.spotUiSource === "pota"
              onClicked: root.setSpotSourceFilter("pota")
            }
            FilterChip {
              label: "SOTA " + root.totalSotaCount
              selected: root.spotUiSource === "sota"
              onClicked: root.setSpotSourceFilter("sota")
            }
          }

          Flow {
            width: parent.width
            height: implicitHeight
            spacing: Style.space(4)
            Repeater {
              model: root.spotBandOptions
              FilterChip {
                required property var modelData
                label: modelData.label + " " + modelData.count
                selected: root.spotUiBand === modelData.band
                onClicked: root.setSpotBandFilter(modelData.band)
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.displaySpots.some(function (s) { return root.spotGrade(s) === "" })
            width: parent.width
            text: root.solar
              ? "Outlined stripe = no N0NBH propagation grade for that band"
              : "Outlined stripe = propagation grade not loaded"
            color: Color.muted
            opacity: 0.72
            font.family: Style.font.family
            font.pixelSize: Style.space(9)
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            visible: root.displaySpots.length === 0
            width: parent.width
            text: root.spotSource === "off"
              ? "Spot fetching is turned off. Set spotSource to pota, sota or both to see live activations."
              : (root.spotUiSource !== "all" || root.spotUiBand !== ""
                 ? "No activations match the quick filters right now."
                 : (root.bandFilter.length
                 ? "No activations on those bands right now."
                 : "No activations reported right now."))
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.space(12)
            wrapMode: Text.WordWrap
          }

          Item {
            id: spotListFrame
            width: parent.width
            visible: root.displaySpots.length > 0
            readonly property real rowHeight: Style.space(34)
            readonly property real naturalHeight: root.displaySpots.length * rowHeight
            readonly property real maxHeight: {
              if (panel.availableCardHeight <= 0) return naturalHeight

              var above = spotsColumn.y + spotListFrame.y
              var below = content.spacing + footerAttribution.implicitHeight
              return Math.max(
                0,
                panel.availableCardHeight
                  - panel.verticalContentInset
                  - above
                  - below
              )
	    }

            height: visible ? Math.min(naturalHeight, maxHeight) : 0

            ListView {
              id: spotList
              anchors.fill: parent
              anchors.rightMargin: scrollThumb.visible ? Style.space(6) : 0
              clip: true
              model: root.displaySpots
              boundsBehavior: Flickable.StopAtBounds
              flickableDirection: Flickable.VerticalFlick
              cacheBuffer: Math.max(height, Style.space(340))

              delegate: Item {
                id: sp
                required property var modelData
                width: ListView.view ? ListView.view.width : 0
                height: spotListFrame.rowHeight
                readonly property string rowGrade: root.spotGrade(modelData)

                Rectangle {
                  anchors.fill: parent
                  radius: Style.space(3)
                  color: Color.accent
                  opacity: clickArea.pressed ? 0.14 : (clickArea.containsMouse ? 0.045 : 0)
                }

                Rectangle {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(3)
                  height: Style.space(26)
                  radius: Style.space(2)
                  // Filled Good/Fair/Poor means N0NBH actually grades this band.
                  // An outline is deliberately different from "Poor": it means
                  // there is no published N0NBH grade (e.g. 160m, 60m, VHF/UHF).
                  color: sp.rowGrade !== "" ? root.gradeFor(sp.rowGrade) : "transparent"
                  border.width: sp.rowGrade === "" ? 1 : 0
                  border.color: Color.muted
                  opacity: sp.rowGrade !== "" ? 0.85 : 0.70
                }

                Column {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(1)

                  Row {
                    width: parent.width
                    spacing: Style.space(7)
                    clip: true
                    Text {
                      textFormat: Text.PlainText
                      width: Style.space(82)
                      text: root.safe(sp.modelData.call, 16)
                      color: Color.popups.text
                      font.family: Style.font.family
                      font.pixelSize: Style.space(12)
                      font.bold: true
                      elide: Text.ElideRight
                    }
                    Text {
                      textFormat: Text.PlainText
                      width: Style.space(38)
                      text: sp.modelData.band ? root.safe(sp.modelData.band, 6) : "OTHER"
                      color: Color.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.space(11)
                    }
                    Text {
                      textFormat: Text.PlainText
                      width: Style.space(58)
                      text: Ham.formatFreq(sp.modelData.freq)
                      color: Color.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.space(11)
                      horizontalAlignment: Text.AlignRight
                    }
                    Text {
                      textFormat: Text.PlainText
                      width: Style.space(40)
                      text: root.safe(sp.modelData.mode, 6)
                      color: Color.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.space(11)
                    }
                    Text {
                      textFormat: Text.PlainText
                      // Fill exactly the remainder after the preceding columns
                      // and Row spacing. Using this child's positioned x avoids
                      // duplicated width arithmetic and cannot overflow the row.
                      width: Math.max(0, parent.width - x)
                      text: root.distanceText(sp.modelData)
                      color: Color.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.space(10)
                      horizontalAlignment: Text.AlignRight
                      elide: Text.ElideRight
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: root.safe(sp.modelData.source, 6) + " " + root.safe(sp.modelData.ref, 20)
                      + (sp.modelData.place ? "  ·  " + root.safe(sp.modelData.place, 40) : "")
                      + (root.ageText(sp.modelData.at) ? "  ·  " + root.ageText(sp.modelData.at) : "")
                    color: Color.muted
                    opacity: 0.78
                    font.family: Style.font.family
                    font.pixelSize: Style.space(9)
                    elide: Text.ElideRight
                  }
                }

                MouseArea {
                  id: clickArea
                  anchors.fill: parent
                  enabled: root.spotUrl(sp.modelData) !== ""
                  hoverEnabled: true
                  cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: root.openSpot(sp.modelData)
                }
              }
            }

            // Tiny compositor-native scroll indicator without pulling in a
            // QtQuick.Controls style just for one scrollbar.
            Rectangle {
              id: scrollThumb
              anchors.right: parent.right
              width: Style.space(2)
              radius: width / 2
              visible: spotList.contentHeight > spotList.height + 1
              color: Color.muted
              opacity: 0.45
              height: visible ? Math.max(Style.space(18), spotList.height * spotList.height / spotList.contentHeight) : 0
              y: visible && spotList.contentHeight > spotList.height
                ? (spotList.contentY / (spotList.contentHeight - spotList.height)) * (spotList.height - height)
                : 0
            }
          }
        }

        // ---- Grey line ----
        Column {
          visible: root.view === "greyline"
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: root.greyLine && root.greyLine.active ? "GREY LINE · OPEN" : "GREY LINE · NEXT"
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
              label: "Grey window"
              value: root.greyWindowRange() || "--"
              valueWidth: Style.space(110)
              note: root.greyWindowStatus()
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
          id: footerAttribution
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

  component FilterChip: Rectangle {
    id: fc
    property string label: ""
    property bool selected: false
    signal clicked()

    implicitWidth: chipLabel.implicitWidth + Style.space(12)
    implicitHeight: Style.space(20)
    width: implicitWidth
    height: implicitHeight
    radius: Style.space(4)
    color: selected ? Color.accent : "transparent"
    border.width: 1
    border.color: selected ? Color.accent : Color.muted
    opacity: selected ? 0.95 : 0.72

    Text {
      id: chipLabel
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: fc.label
      color: fc.selected ? Color.popups.background : Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.space(9)
      font.bold: fc.selected
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: fc.clicked()
    }
  }

  component StatRow: Row {
    id: sr
    property string label: ""
    property string value: ""
    property string note: ""
    property bool highlight: false
    property real valueWidth: Style.space(80)
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
      width: sr.valueWidth
      text: sr.value
      color: sr.highlight ? Color.accent : Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.space(13)
      font.bold: sr.highlight
    }
    Text {
      textFormat: Text.PlainText
      width: Math.max(Style.space(20), sr.width - Style.space(130 + 16) - sr.valueWidth)
      text: sr.note
      color: Color.muted
      elide: Text.ElideRight
      font.family: Style.font.family
      font.pixelSize: Style.space(12)
    }
  }
}
