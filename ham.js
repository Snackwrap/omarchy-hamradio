.pragma library

// Everything that turns solar numbers and a pile of spots into something an
// operator can act on. No Qt types in here, so tools/test-ham.mjs can run the
// same code under node and check it against published references — the band
// plan, the Maidenhead system, and real sunrise tables.

var D2R = Math.PI / 180
var R2D = 180 / Math.PI

// ---- Maidenhead locators ---------------------------------------------------

// The grid is anchored at 180 W, 90 S and divides the world into fields of
// 20 deg longitude by 10 deg latitude (A-R), each into 100 squares of 2 by 1
// (0-9), each into 576 subsquares of 5 by 2.5 minutes (a-x). Longitude always
// takes the wider step because a degree of it is worth less.
var A = "A".charCodeAt(0)
var LOWER_A = "a".charCodeAt(0)
var ZERO = "0".charCodeAt(0)

function gridSquare(lat, lon, chars) {
  var la = Number(lat), lo = Number(lon)
  if (!isFinite(la) || !isFinite(lo)) return ""
  la = Math.max(-90, Math.min(89.99999, la))
  lo = Math.max(-180, Math.min(179.99999, lo))

  var n = chars === 4 ? 4 : (chars === 8 ? 8 : 6)
  var x = lo + 180
  var y = la + 90

  var out = String.fromCharCode(A + Math.floor(x / 20)) +
            String.fromCharCode(A + Math.floor(y / 10))
  x %= 20; y %= 10
  out += String.fromCharCode(ZERO + Math.floor(x / 2)) +
         String.fromCharCode(ZERO + Math.floor(y / 1))
  if (n === 4) return out

  x %= 2; y %= 1
  out += String.fromCharCode(LOWER_A + Math.floor(x / (2 / 24))) +
         String.fromCharCode(LOWER_A + Math.floor(y / (1 / 24)))
  if (n === 6) return out

  x %= (2 / 24); y %= (1 / 24)
  out += String.fromCharCode(ZERO + Math.floor(x / (2 / 240))) +
         String.fromCharCode(ZERO + Math.floor(y / (1 / 240)))
  return out
}

// The centre of the named square, which is what you want for a distance: the
// corner would bias every bearing towards the south-west.
function gridToLatLon(grid) {
  var g = String(grid || "").trim()
  if (g.length < 4) return null
  var up = g.toUpperCase()
  var lon = (up.charCodeAt(0) - A) * 20 - 180
  var lat = (up.charCodeAt(1) - A) * 10 - 90
  var lonSize = 20, latSize = 10

  if (!/^[A-R]{2}$/.test(up.slice(0, 2))) return null
  if (!/^[0-9]{2}$/.test(up.slice(2, 4))) return null
  lon += (up.charCodeAt(2) - ZERO) * 2
  lat += (up.charCodeAt(3) - ZERO) * 1
  lonSize = 2; latSize = 1

  if (g.length >= 6 && /^[A-X]{2}$/.test(up.slice(4, 6))) {
    lon += (up.charCodeAt(4) - A) * (2 / 24)
    lat += (up.charCodeAt(5) - A) * (1 / 24)
    lonSize = 2 / 24; latSize = 1 / 24
  }
  return { lat: lat + latSize / 2, lon: lon + lonSize / 2 }
}

// ---- The band plan ---------------------------------------------------------

// IARU amateur allocations, in kHz. Spots arrive as a frequency and nothing
// else, so this is what turns one into a band the operator thinks in.
var BANDS = [
  { band: "2200m", from: 135.7, to: 137.8 },
  { band: "630m", from: 472, to: 479 },
  { band: "160m", from: 1800, to: 2000 },
  { band: "80m", from: 3500, to: 4000 },
  { band: "60m", from: 5250, to: 5450 },
  { band: "40m", from: 7000, to: 7300 },
  { band: "30m", from: 10100, to: 10150 },
  { band: "20m", from: 14000, to: 14350 },
  { band: "17m", from: 18068, to: 18168 },
  { band: "15m", from: 21000, to: 21450 },
  { band: "12m", from: 24890, to: 24990 },
  { band: "10m", from: 28000, to: 29700 },
  { band: "6m", from: 50000, to: 54000 },
  { band: "4m", from: 70000, to: 70500 },
  { band: "2m", from: 144000, to: 148000 },
  { band: "70cm", from: 420000, to: 450000 },
  { band: "23cm", from: 1240000, to: 1300000 }
]

// Spot feeds are inconsistent about units: POTA sends kHz as a string
// ("7074.0"), SOTA sends MHz as a number (7.14). Anything that looks like a
// plausible MHz value for an amateur band is promoted.
function toKHz(freq) {
  var f = Number(String(freq === null || freq === undefined ? "" : freq).replace(/[^0-9.]/g, ""))
  if (!isFinite(f) || f <= 0) return NaN
  return f < 1500 ? f * 1000 : f
}

function bandFor(freq) {
  var khz = toKHz(freq)
  if (!isFinite(khz)) return ""
  for (var i = 0; i < BANDS.length; i++) {
    if (khz >= BANDS[i].from && khz <= BANDS[i].to) return BANDS[i].band
  }
  return ""
}

function formatFreq(freq) {
  var khz = toKHz(freq)
  if (!isFinite(khz)) return ""
  return (khz / 1000).toFixed(3)
}

// ---- Conditions ------------------------------------------------------------

var GRADES = ["Poor", "Fair", "Good"]

function gradeRank(g) {
  var i = GRADES.indexOf(String(g || "").trim())
  return i < 0 ? -1 : i
}

// hamqsl publishes its own day/night verdict per band group. Which half
// applies depends on whether the sun is up where the operator is, not on the
// clock — that is the whole reason the plugin needs a location.
function bandsForNow(bands, isDay) {
  var out = []
  for (var i = 0; i < (bands || []).length; i++) {
    var b = bands[i]
    out.push({ band: b.band, grade: isDay ? b.day : b.night, day: b.day, night: b.night })
  }
  return out
}

// The band to put in the pill: best grade wins, and among equals the lowest
// frequency, because it is the one most likely to still be open in an hour.
function bestBand(bands, isDay) {
  var list = bandsForNow(bands, isDay)
  var best = null
  for (var i = 0; i < list.length; i++) {
    var rank = gradeRank(list[i].grade)
    if (rank < 0) continue
    if (!best || rank > gradeRank(best.grade)) best = list[i]
  }
  return best
}

// A disturbed field is worth saying out loud, because it explains a bad band
// report that the flux alone would not.
function geomagneticNote(k) {
  var v = Number(k)
  if (!isFinite(v)) return ""
  if (v >= 7) return "severe storm — HF largely closed"
  if (v >= 5) return "storm — absorption on the low bands"
  if (v >= 4) return "unsettled — polar paths degraded"
  if (v >= 3) return "slightly unsettled"
  return "quiet"
}

// ---- The solar XML ---------------------------------------------------------

// hamqsl serves a small flat XML document. A tolerant reader beats a real
// parser here: the document is one level deep apart from the band table, and
// the fields drift in and out depending on what N0NBH has available.
function tagValue(text, tag) {
  var m = new RegExp("<" + tag + ">([^<]*)</" + tag + ">", "i").exec(String(text || ""))
  return m ? m[1].replace(/^\s+|\s+$/g, "") : ""
}

function tagNumber(text, tag) {
  var v = tagValue(text, tag).replace(/[^0-9.\-]/g, "")
  var n = Number(v)
  return isFinite(n) && v !== "" ? n : NaN
}

function parseSolar(text) {
  var raw = String(text || "")
  if (raw.length === 0) return null

  // The band table is keyed by a name that comes straight out of the remote
  // document. A plain object inherits from Object.prototype, so a group calling
  // itself "__proto__" would have its day/night assignment land on the shared
  // prototype rather than in the map. A null prototype removes the question,
  // and names and grades are normalised and capped before they are used as
  // keys or values at all.
  var MAX_GROUPS = 12
  var bands = []
  var byName = Object.create(null)
  var re = /<band\s+name="([^"]{1,32})"\s+time="([^"]{1,16})"\s*>([^<]{0,32})<\/band>/gi
  var m
  while ((m = re.exec(raw)) !== null) {
    var name = m[1].replace(/[^A-Za-z0-9 \-]/g, "").replace(/^\s+|\s+$/g, "").slice(0, 24)
    if (name === "") continue
    var when = m[2].toLowerCase().replace(/[^a-z]/g, "")
    var grade = m[3].replace(/[^A-Za-z ]/g, "").replace(/^\s+|\s+$/g, "").slice(0, 12)
    if (!byName[name]) {
      // Stop at the cap rather than collecting everything and truncating
      // afterwards; a document with ten thousand groups should cost ten
      // thousand regex steps, not ten thousand objects.
      if (bands.length >= MAX_GROUPS) continue
      byName[name] = { band: name, day: "", night: "" }
      bands.push(byName[name])
    }
    if (when === "day") byName[name].day = grade
    else if (when === "night") byName[name].night = grade
  }

  return {
    updated: tagValue(raw, "updated"),
    sfi: tagNumber(raw, "solarflux"),
    a: tagNumber(raw, "aindex"),
    k: tagNumber(raw, "kindex"),
    ssn: tagNumber(raw, "sunspots"),
    xray: tagValue(raw, "xray"),
    protonFlux: tagNumber(raw, "protonflux"),
    solarWind: tagNumber(raw, "solarwind"),
    magneticField: tagNumber(raw, "magneticfield"),
    // MUF and foF2 are often "NoRpt", which is not a number and must not
    // become one.
    muf: tagNumber(raw, "muf"),
    foF2: tagNumber(raw, "fof2"),
    aurora: tagNumber(raw, "aurora"),
    signalNoise: tagValue(raw, "signalnoise"),
    bands: bands
  }
}

// ---- Grey line -------------------------------------------------------------

// Sunrise and sunset for a place, by the same method the space-weather plugin
// uses. `angle` is the sun's altitude: -0.833 is the geometric horizon with
// refraction and the solar radius allowed for.
function solarEvents(date, lat, lon, angle) {
  var jdate = date.getTime() / 86400000 + 2440587.5
  var n = Math.round(jdate - 2451545.0 + 0.0008)
  var jstar = n - lon / 360
  var M = (357.5291 + 0.98560028 * jstar) % 360
  var Mr = M * D2R
  var C = 1.9148 * Math.sin(Mr) + 0.02 * Math.sin(2 * Mr) + 0.0003 * Math.sin(3 * Mr)
  var lambda = (M + C + 180 + 102.9372) % 360
  var lr = lambda * D2R
  var jtransit = 2451545.0 + jstar + 0.0053 * Math.sin(Mr) - 0.0069 * Math.sin(2 * lr)
  var sinDec = Math.sin(lr) * Math.sin(23.4397 * D2R)
  var cosDec = Math.cos(Math.asin(sinDec))
  var p = lat * D2R
  var cosOmega = (Math.sin(angle * D2R) - Math.sin(p) * sinDec) / (Math.cos(p) * cosDec)
  if (cosOmega > 1) return { rise: null, set: null, always: "below" }
  if (cosOmega < -1) return { rise: null, set: null, always: "above" }
  var omega = Math.acos(cosOmega) * R2D
  var toDate = function (j) { return new Date((j - 2440587.5) * 86400000) }
  return { rise: toDate(jtransit - omega / 360), set: toDate(jtransit + omega / 360), always: null }
}

function isDaylight(now, lat, lon) {
  var ev = solarEvents(now, lat, lon, -0.833)
  if (ev.always === "above") return true
  if (ev.always === "below") return false
  if (!ev.rise || !ev.set) return true
  var t = now.getTime()
  return t >= ev.rise.getTime() && t < ev.set.getTime()
}

// The grey line is the band of twilight sweeping round the earth. Along it the
// D layer — which absorbs the low bands by day — has decayed while the F layer
// is still lit, so 160 through 40 metres carry much further than they do at
// any other time. The window is short, which is exactly why a bar widget is a
// reasonable place to be told about it.
var GREY_LINE_MINUTES = 40

function greyLine(now, lat, lon) {
  var day = 86400000
  var best = null
  for (var i = -1; i <= 1; i++) {
    var ev = solarEvents(new Date(now.getTime() + i * day), lat, lon, -0.833)
    if (!ev || ev.always) continue
    var candidates = [
      { kind: "sunrise", at: ev.rise },
      { kind: "sunset", at: ev.set }
    ]
    for (var c = 0; c < candidates.length; c++) {
      var at = candidates[c].at
      if (!at) continue
      var delta = at.getTime() - now.getTime()
      // Keep the nearest event either side, so "in 20 minutes" and "25 minutes
      // ago" both read as being in the window.
      if (best === null || Math.abs(delta) < Math.abs(best.delta)) {
        best = { kind: candidates[c].kind, at: at, delta: delta }
      }
    }
  }
  if (!best) return null
  best.active = Math.abs(best.delta) <= GREY_LINE_MINUTES * 60000
  return best
}

// The next sunrise or sunset strictly after `now`.  greyLine() deliberately
// chooses the closest event on either side because that is what an *active*
// grey-line window needs; UI copy such as "sunset in 2h" needs the next event
// instead, not the sunrise that happened twenty minutes ago.
function nextSolarEvent(now, lat, lon) {
  var day = 86400000
  var best = null
  // solarEvents() chooses a Julian cycle from the UTC timestamp.  At western
  // longitudes, local evening is already the next UTC date, so the local-day
  // sunset can belong to cycle n-1.  Include that cycle or an afternoon in
  // Hawaii/California can incorrectly skip straight to tomorrow's sunrise.
  for (var i = -1; i <= 2; i++) {
    var ev = solarEvents(new Date(now.getTime() + i * day), lat, lon, -0.833)
    if (!ev || ev.always) continue
    var candidates = [
      { kind: "sunrise", at: ev.rise },
      { kind: "sunset", at: ev.set }
    ]
    for (var c = 0; c < candidates.length; c++) {
      var at = candidates[c].at
      if (!at) continue
      var delta = at.getTime() - now.getTime()
      if (delta <= 0) continue
      if (best === null || delta < best.delta) {
        best = { kind: candidates[c].kind, at: at, delta: delta }
      }
    }
  }
  return best
}

// ---- Geography -------------------------------------------------------------

function distanceKm(lat1, lon1, lat2, lon2) {
  var dLat = (lat2 - lat1) * D2R
  var dLon = (lon2 - lon1) * D2R
  var a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
          Math.cos(lat1 * D2R) * Math.cos(lat2 * D2R) *
          Math.sin(dLon / 2) * Math.sin(dLon / 2)
  return 6371.0088 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
}

function bearingDeg(lat1, lon1, lat2, lon2) {
  var y = Math.sin((lon2 - lon1) * D2R) * Math.cos(lat2 * D2R)
  var x = Math.cos(lat1 * D2R) * Math.sin(lat2 * D2R) -
          Math.sin(lat1 * D2R) * Math.cos(lat2 * D2R) * Math.cos((lon2 - lon1) * D2R)
  return (Math.atan2(y, x) * R2D + 360) % 360
}

var COMPASS = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
               "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]

function cardinal(deg) {
  var d = Number(deg)
  if (!isFinite(d)) return ""
  return COMPASS[Math.round(((d % 360) + 360) % 360 / 22.5) % 16]
}

// ---- Spots -----------------------------------------------------------------

// Both feeds describe timestamps as UTC, but historical/current payloads differ
// on whether they include an explicit Z/offset. Add Z only when the source is
// timezone-less; appending it to an already-offset timestamp would make a valid
// ISO-8601 value unparsable.
function parseSpotTime(value) {
  var text = String(value === null || value === undefined ? "" : value).replace(/^\s+|\s+$/g, "")
  if (text === "") return NaN
  if (!/(?:Z|[+\-][0-9]{2}:?[0-9]{2})$/i.test(text)) text += "Z"
  return Date.parse(text)
}

// POTA and SOTA describe the same event with different field names. One shape
// downstream keeps the panel from caring which feed a row came from.
function normalisePotaSpot(s, here) {
  if (!s) return null
  var call = String(s.activator || "").toUpperCase().replace(/[^A-Z0-9\/]/g, "").slice(0, 16)
  if (call === "") return null
  var lat = parseFloat(String(s.latitude === null || s.latitude === undefined ? "" : s.latitude))
  var lon = parseFloat(String(s.longitude === null || s.longitude === undefined ? "" : s.longitude))
  if (!isFinite(lat) || !isFinite(lon) || Math.abs(lat) > 90 || Math.abs(lon) > 180) {
    var grid = gridToLatLon(String(s.grid6 || s.grid4 || ""))
    lat = grid ? grid.lat : NaN
    lon = grid ? grid.lon : NaN
  }
  return {
    source: "POTA",
    call: call,
    freq: toKHz(s.frequency),
    mode: String(s.mode || "").toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 8),
    band: bandFor(s.frequency),
    ref: String(s.reference || "").toUpperCase().replace(/[^A-Z0-9\-]/g, "").slice(0, 12),
    place: String(s.parkName || s.name || ""),
    at: parseSpotTime(s.spotTime),
    lat: lat, lon: lon,
    geoKey: ""
  }
}

function normaliseSotaSpot(s, here) {
  if (!s) return null
  var call = String(s.activatorCallsign || "").toUpperCase().replace(/[^A-Z0-9\/]/g, "").slice(0, 16)
  if (call === "" || call === "DEPRECATED") return null
  var rawRef = String(s.summitCode || "").toUpperCase().replace(/[^A-Z0-9\-\/]/g, "").slice(0, 20)
  var assoc = String(s.associationCode || "").toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 8)
  var summit = rawRef
  var slash = rawRef.indexOf("/")
  if (slash > 0) {
    assoc = rawRef.slice(0, slash).replace(/[^A-Z0-9]/g, "").slice(0, 8)
    summit = rawRef.slice(slash + 1).replace(/[^A-Z0-9\-]/g, "").slice(0, 12)
  } else {
    summit = rawRef.replace(/[^A-Z0-9\-]/g, "").slice(0, 12)
  }
  var fullRef = assoc !== "" && summit !== "" ? assoc + "/" + summit : rawRef
  var lat = parseFloat(String(s.latitude === null || s.latitude === undefined ? "" : s.latitude))
  var lon = parseFloat(String(s.longitude === null || s.longitude === undefined ? "" : s.longitude))
  if (!isFinite(lat) || !isFinite(lon) || Math.abs(lat) > 90 || Math.abs(lon) > 180) {
    lat = NaN; lon = NaN
  }
  var type = String(s.type || "NORMAL").toUpperCase().replace(/[^A-Z]/g, "").slice(0, 12)
  if (type === "") type = "NORMAL"
  return {
    source: "SOTA",
    call: call,
    freq: toKHz(s.frequency),
    mode: String(s.mode || "").toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 8),
    band: bandFor(s.frequency),
    ref: fullRef.slice(0, 20),
    place: String(s.summitName || s.summitDetails || ""),
    at: parseSpotTime(s.timeStamp),
    lat: lat, lon: lon,
    spotType: type,
    epoch: String(s.epoch || "").replace(/[^A-Za-z0-9\-]/g, "").slice(0, 64),
    // The official summit-detail API is /api/summits/{association}/{summit}.
    // Keep only an allow-listed path shape so it is safe to append to that
    // fixed HTTPS origin when the panel enriches a spot with coordinates.
    geoKey: assoc !== "" && summit !== "" ? assoc + "/" + summit : ""
  }
}

// SOTA's current spot endpoint is a recent event stream, not a pre-reconciled
// list of stations. TEST is not an activation. QRT is a tombstone for an older
// spot from the same activator/summit; simply hiding the QRT row would let that
// older spot reappear. Keep only the newest still-active record for each key.
function reconcileSotaSpots(rows) {
  var normalised = []
  for (var i = 0; i < (rows || []).length; i++) {
    var s = normaliseSotaSpot(rows[i])
    if (s) normalised.push(s)
  }
  normalised.sort(function (a, b) {
    var at = isFinite(a.at) ? a.at : 0
    var bt = isFinite(b.at) ? b.at : 0
    return bt - at
  })

  var closed = Object.create(null)
  var seen = Object.create(null)
  var out = []
  for (var j = 0; j < normalised.length; j++) {
    var spot = normalised[j]
    var callKey = "c:" + spot.call
    var exactKey = "r:" + spot.call + "|" + spot.ref
    var key = spot.ref !== "" ? exactKey : callKey

    if (spot.spotType === "TEST") continue
    if (spot.spotType === "QRT") {
      closed[key] = true
      // A QRT without a usable summit reference still closes that activator's
      // older entries; with a reference, do not hide an unrelated summit.
      if (spot.ref === "") closed[callKey] = true
      continue
    }
    if (closed[key] || closed[callKey] || seen[key]) continue
    seen[key] = true
    out.push(spot)
  }
  return out
}

// With a local position, nearest activation first.  Unknown coordinates sort
// after known ones and retain newest-first order among themselves.  Without a
// local position, preserve the original newest-first behaviour.
function sortSpots(spots, here) {
  var out = (spots || []).slice(0)
  var useDistance = here && isFinite(Number(here.lat)) && isFinite(Number(here.lon))
  var hlat = useDistance ? Number(here.lat) : NaN
  var hlon = useDistance ? Number(here.lon) : NaN

  // Compute the expensive great-circle values once per spot per station
  // location, not O(N log N) times from inside the sort comparator.  These are
  // presentation fields on already-normalised ephemeral spot objects; every
  // call refreshes them, so changing the station location cannot leave stale
  // distances behind.
  for (var i = 0; i < out.length; i++) {
    var s = out[i]
    if (useDistance && s && isFinite(s.lat) && isFinite(s.lon)) {
      s.distanceKm = distanceKm(hlat, hlon, Number(s.lat), Number(s.lon))
      s.bearingDeg = bearingDeg(hlat, hlon, Number(s.lat), Number(s.lon))
    } else if (s) {
      s.distanceKm = NaN
      s.bearingDeg = NaN
    }
  }

  out.sort(function (a, b) {
    if (useDistance) {
      var ad = a && isFinite(a.distanceKm) ? Number(a.distanceKm) : Infinity
      var bd = b && isFinite(b.distanceKm) ? Number(b.distanceKm) : Infinity
      if (ad !== bd) return ad - bd
    }
    var at = a && isFinite(a.at) ? a.at : 0
    var bt = b && isFinite(b.at) ? b.at : 0
    return bt - at
  })
  return out
}

// Failure policy for the SOTA summit-coordinate enrichment path.  Invalid, missing or
// retired summit requests are terminal for this shell session; transport/server errors
// back off exponentially, while rate/auth failures also pause the whole queue
// so one bad response cannot fan out across dozens of summit references.
function sotaGeoFailurePolicy(status, attempt) {
  var code = Number(status)
  var n = Math.max(1, Math.min(8, Number(attempt) || 1))
  if (code === 400 || code === 404 || code === 410 || code === 422) return { permanent: true, retryMs: 0, globalMs: 0 }
  if (code === 401 || code === 403) return { permanent: false, retryMs: 1800000, globalMs: 1800000 }
  if (code === 429) return { permanent: false, retryMs: 900000, globalMs: 900000 }
  var retry = Math.min(3600000, 300000 * Math.pow(2, n - 1))
  var global = (code === 0 || code === 408 || code >= 500) ? Math.min(retry, 300000) : 0
  return { permanent: false, retryMs: retry, globalMs: global }
}

function minutesAgo(ms, nowMs) {
  var t = Number(ms), n = Number(nowMs)
  if (!isFinite(t) || !isFinite(n)) return NaN
  return (n - t) / 60000
}

function formatAge(minutes) {
  var m = Number(minutes)
  if (!isFinite(m)) return ""
  if (m < 1) return "now"
  if (m < 60) return Math.round(m) + "m"
  var h = Math.floor(m / 60)
  return h + "h" + (Math.round(m - h * 60) ? Math.round(m - h * 60) + "m" : "")
}

// ---- Bands against the groups that are actually graded ---------------------

// N0NBH publishes a verdict for four *groups* ("80m-40m", "30m-20m" ...), not
// for the nine HF bands. Rather than hard-code that mapping, read the band
// names out of the group's own label: if the grouping ever changes upstream,
// this follows it instead of quietly mis-colouring a band. Bands with no group
// — 160m and 60m, today — have no forecast, and saying so is better than
// borrowing a neighbour's.
function groupCovers(groupName) {
  var found = String(groupName || "").toLowerCase().match(/\d+\s*(?:m|cm)/g)
  if (!found) return []
  var out = []
  for (var i = 0; i < found.length; i++) out.push(found[i].replace(/\s+/g, ""))
  return out
}

function gradeForBand(bands, bandName, isDay) {
  var want = String(bandName || "").toLowerCase()
  if (want === "") return ""
  for (var i = 0; i < (bands || []).length; i++) {
    var covers = groupCovers(bands[i].band)
    if (covers.indexOf(want) < 0) continue
    return isDay ? bands[i].day : bands[i].night
  }
  return ""
}

// Return exactly the band buckets represented by a spot collection, in band-
// plan order. Unmapped/fat-finger frequencies are deliberately retained as an
// explicit OTHER bucket so an ALL view can never contain invisible categories.
function spotBandBuckets(spots) {
  var counts = Object.create(null)
  var unknown = 0
  for (var i = 0; i < (spots || []).length; i++) {
    var band = String(spots[i] && spots[i].band || "").toLowerCase()
    if (band === "") { unknown += 1; continue }
    counts[band] = (counts[band] || 0) + 1
  }
  var out = []
  for (var j = 0; j < BANDS.length; j++) {
    var key = BANDS[j].band.toLowerCase()
    if (counts[key]) out.push({ band: BANDS[j].band, count: counts[key] })
  }
  // Future/new upstream bands still remain reachable even before BANDS learns
  // their exact frequency edges.
  var extras = []
  for (var name in counts) {
    if (!Object.prototype.hasOwnProperty.call(counts, name)) continue
    var known = false
    for (var k = 0; k < BANDS.length; k++) {
      if (BANDS[k].band.toLowerCase() === name) { known = true; break }
    }
    if (!known) extras.push(name)
  }
  extras.sort()
  for (var e = 0; e < extras.length; e++) out.push({ band: extras[e], count: counts[extras[e]] })
  if (unknown) out.push({ band: "__other__", count: unknown })
  return out
}

// The HF bands, in order, for anything that draws a frequency axis.
function hfBands() {
  var out = []
  for (var i = 0; i < BANDS.length; i++) {
    if (BANDS[i].from >= 1800 && BANDS[i].to <= 29700) out.push(BANDS[i])
  }
  return out
}

function bandSpan(bandName) {
  var want = String(bandName || "").toLowerCase()
  for (var i = 0; i < BANDS.length; i++) {
    if (BANDS[i].band.toLowerCase() === want) return BANDS[i]
  }
  return null
}