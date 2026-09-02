// Checks ham.js against published references: the IARU band plan, the
// Maidenhead locator system, and real sunrise/sunset tables.
// Run with:  node tools/test-ham.mjs      (--offline skips the live checks)
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

const here = dirname(fileURLToPath(import.meta.url))
const src = readFileSync(join(here, "..", "ham.js"), "utf8").replace(/^\.pragma library\s*/, "")
const names = [...src.matchAll(/^function ([a-zA-Z0-9_]+)/gm)].map(m => m[1])
const H = new Function(`${src}\nreturn {${names.join(",")}}`)()

let failures = 0
function check(name, ok, detail) {
  if (!ok) failures++
  console.log(`${ok ? "  ok  " : "FAIL  "}${name}${detail ? "   " + detail : ""}`)
}
const eq = (n, got, want) => check(n, got === want, `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`)
const near = (n, got, want, tol) => check(n, Math.abs(got - want) <= tol, `got ${got}, want ${want}±${tol}`)

console.log("\n# Maidenhead locators — published references")
// The canonical worked examples from the ARRL and the IARU locator definition.
eq("W1AW, Newington CT", H.gridSquare(41.714, -72.727), "FN31pr")
eq("the prime meridian at the equator", H.gridSquare(0, 0), "JJ00aa")
eq("just west and south of it", H.gridSquare(-0.01, -0.01), "II99xx")
eq("Bletchley Park", H.gridSquare(51.9976, -0.7406), "IO91px")
eq("four-character form", H.gridSquare(41.714, -72.727, 4), "FN31")
eq("eight-character form", H.gridSquare(41.714, -72.727, 8).slice(0, 6), "FN31pr")
check("eight characters are eight characters", H.gridSquare(41.714, -72.727, 8).length === 8)

console.log("\n# ...and back again")
for (const [grid, lat, lon] of [["FN31pr", 41.714, -72.727], ["IO91px", 51.9976, -0.7406], ["JJ00aa", 0.02, 0.04]]) {
  const p = H.gridToLatLon(grid)
  // A six-character square is 5' x 2.5', so the centre is within about
  // 0.05 deg of any point inside it.
  check(`${grid} round-trips`, Math.abs(p.lat - lat) < 0.05 && Math.abs(p.lon - lon) < 0.09,
        `got ${p.lat.toFixed(3)},${p.lon.toFixed(3)} for ${lat},${lon}`)
}
eq("a four-character square resolves", H.gridSquare(H.gridToLatLon("IO91").lat, H.gridToLatLon("IO91").lon, 4), "IO91")
eq("rubbish is rejected", H.gridToLatLon("nope"), null)
eq("a too-short locator is rejected", H.gridToLatLon("IO"), null)

console.log("\n# the band plan")
// A frequency from each band's most-used segment.
const bandCases = [
  [1840, "160m"], [3573, "80m"], [5357, "60m"], [7074, "40m"], [10136, "30m"],
  [14074, "20m"], [18100, "17m"], [21074, "15m"], [24915, "12m"], [28074, "10m"],
  [50313, "6m"], [144174, "2m"], [432100, "70cm"],
]
for (const [khz, band] of bandCases) eq(`${khz} kHz`, H.bandFor(khz), band)
eq("a gap between bands is no band", H.bandFor(9000), "")
eq("nonsense is no band", H.bandFor("banana"), "")

console.log("\n# the two feeds disagree about units")
// POTA sends kHz as a string, SOTA sends MHz as a number.
eq("POTA style, kHz string", H.bandFor("7074.0"), "40m")
eq("SOTA style, MHz number", H.bandFor(7.14), "40m")
eq("SOTA style on 20m", H.bandFor(14.235), "20m")
eq("SOTA style on 2m", H.bandFor(145.5), "2m")
near("kHz passes through", H.toKHz("14074"), 14074, 0.01)
near("MHz is promoted", H.toKHz(14.074), 14074, 0.01)
eq("formatted for display", H.formatFreq("7074.0"), "7.074")

console.log("\n# the solar XML")
const xml = `<solar><solardata>
  <updated> 02 Sep 2026 0340 GMT</updated>
  <solarflux>101</solarflux><aindex> 7</aindex><kindex> 0</kindex>
  <sunspots>55</sunspots><xray>B8.1</xray><protonflux>19</protonflux>
  <solarwind>412.3</solarwind><magneticfield>4.1</magneticfield>
  <muf>NoRpt</muf><fof2>7.25</fof2><aurora>1</aurora>
  <signalnoise>S0-S1</signalnoise>
  <calculatedconditions>
    <band name="80m-40m" time="day">Good</band>
    <band name="80m-40m" time="night">Good</band>
    <band name="30m-20m" time="day">Good</band>
    <band name="30m-20m" time="night">Fair</band>
    <band name="17m-15m" time="day">Fair</band>
    <band name="17m-15m" time="night">Poor</band>
    <band name="12m-10m" time="day">Poor</band>
    <band name="12m-10m" time="night">Poor</band>
  </calculatedconditions>
</solardata></solar>`
const solar = H.parseSolar(xml)
eq("solar flux", solar.sfi, 101)
eq("A index, with its leading space", solar.a, 7)
eq("K index of zero is a number, not absent", solar.k, 0)
eq("sunspot number", solar.ssn, 55)
eq("X-ray class stays a string", solar.xray, "B8.1")
eq("foF2", solar.foF2, 7.25)
check("MUF of 'NoRpt' does not become a number", Number.isNaN(solar.muf), `got ${solar.muf}`)
eq("band count", solar.bands.length, 4)
eq("first band name", solar.bands[0].band, "80m-40m")
eq("day and night are both captured", solar.bands[1].day + "/" + solar.bands[1].night, "Good/Fair")
eq("empty input is null", H.parseSolar(""), null)

console.log("\n# which half of the table applies")
const daytime = H.bandsForNow(solar.bands, true)
const night = H.bandsForNow(solar.bands, false)
eq("by day, 30m-20m is Good", daytime[1].grade, "Good")
eq("by night, 30m-20m is Fair", night[1].grade, "Fair")
eq("best band by day", H.bestBand(solar.bands, true).band, "80m-40m")
eq("best band at night", H.bestBand(solar.bands, false).band, "80m-40m")
eq("grades rank", H.gradeRank("Good") > H.gradeRank("Fair") && H.gradeRank("Fair") > H.gradeRank("Poor"), true)
eq("an unknown grade ranks below Poor", H.gradeRank("Banana"), -1)

console.log("\n# bands against the groups that are graded")
// hamqsl grades four groups, not nine bands; the mapping is read out of the
// group's own label so it follows an upstream regrouping.
eq("a group names its members", H.groupCovers("80m-40m").join(","), "80m,40m")
eq("spacing does not matter", H.groupCovers("17m - 15m").join(","), "17m,15m")
eq("a single-band group works", H.groupCovers("6m").join(","), "6m")
eq("40m takes the 80m-40m verdict, by day", H.gradeForBand(solar.bands, "40m", true), "Good")
eq("...and by night", H.gradeForBand(solar.bands, "20m", false), "Fair")
eq("10m is Poor", H.gradeForBand(solar.bands, "10m", true), "Poor")
// 160m and 60m are in no published group, and borrowing a neighbour's verdict
// would be a guess dressed as a forecast.
eq("160m has no forecast", H.gradeForBand(solar.bands, "160m", true), "")
eq("60m has no forecast", H.gradeForBand(solar.bands, "60m", true), "")
eq("nonsense has no forecast", H.gradeForBand(solar.bands, "banana", true), "")

const hf = H.hfBands()
eq("the HF list starts at 160m", hf[0].band, "160m")
eq("...and ends at 10m", hf[hf.length - 1].band, "10m")
check("6m is not in the HF list", hf.every(b => b.band !== "6m"))
eq("a band knows its edges", H.bandSpan("20m").from + "-" + H.bandSpan("20m").to, "14000-14350")
eq("an unknown band has none", H.bandSpan("nope"), null)

console.log("\n# what a disturbed field means")
eq("quiet", H.geomagneticNote(1), "quiet")
eq("unsettled", H.geomagneticNote(4), "unsettled — polar paths degraded")
eq("storm", H.geomagneticNote(5), "storm — absorption on the low bands")
eq("severe", H.geomagneticNote(8), "severe storm — HF largely closed")

console.log("\n# sunrise, sunset and the grey line")
// London on the 2026 equinox: sunrise ~06:55 local, sunset ~19:03 local (BST).
const equinox = new Date(Date.UTC(2026, 8, 22, 12, 0))
const ev = H.solarEvents(equinox, 51.5074, -0.1278, -0.833)
near("London sunrise (UTC hour)", ev.rise.getUTCHours() + ev.rise.getUTCMinutes() / 60, 5.92, 0.25)
near("London sunset (UTC hour)", ev.set.getUTCHours() + ev.set.getUTCMinutes() / 60, 18.05, 0.25)
check("the sun is up at midday in London", H.isDaylight(equinox, 51.5074, -0.1278))
check("and down at midnight", !H.isDaylight(new Date(Date.UTC(2026, 8, 22, 0, 30)), 51.5074, -0.1278))
check("polar day is daylight", H.isDaylight(new Date(Date.UTC(2026, 5, 21, 0, 0)), 78, 15))
check("polar night is not", !H.isDaylight(new Date(Date.UTC(2026, 11, 21, 12, 0)), 78, 15))

// Ten minutes before sunrise is inside the grey line; four hours before is not.
const nearRise = new Date(ev.rise.getTime() - 10 * 60000)
const farOff = new Date(ev.rise.getTime() - 4 * 3600000)
const gl = H.greyLine(nearRise, 51.5074, -0.1278)
check("ten minutes before sunrise is grey line", gl && gl.active, JSON.stringify(gl && gl.kind))
eq("and it knows which event", gl.kind, "sunrise")
check("four hours out is not", !H.greyLine(farOff, 51.5074, -0.1278).active)

console.log("\n# geography")
near("a degree of latitude", H.distanceKm(0, 0, 1, 0), 111.2, 0.5)
near("London to New York", H.distanceKm(51.5074, -0.1278, 40.7128, -74.0060), 5570, 40)
near("...on a great-circle bearing of about 288", H.bearingDeg(51.5074, -0.1278, 40.7128, -74.0060), 288, 3)
eq("cardinal", H.cardinal(288), "WNW")

console.log("\n# spot normalising")
const pota = H.normalisePotaSpot({ activator: "dk5ur", frequency: "7074.0", mode: "ft8",
                                   reference: "DE-1274", parkName: "Wetterau", spotTime: "2026-09-02T03:40:08" })
eq("callsign is upper case", pota.call, "DK5UR")
eq("mode is upper case", pota.mode, "FT8")
eq("band is derived", pota.band, "40m")
eq("source is tagged", pota.source, "POTA")
const sota = H.normaliseSotaSpot({ activatorCallsign: "VK2IO/P", frequency: 7.14, mode: "SSB", summitCode: "CT-001" })
eq("SOTA MHz becomes the right band", sota.band, "40m")
eq("a stroke in the callsign survives", sota.call, "VK2IO/P")
eq("the deprecated placeholder row is dropped", H.normaliseSotaSpot({ activatorCallsign: "DEPRECATED" }), null)
eq("a spot with no callsign is dropped", H.normalisePotaSpot({ frequency: "7074" }), null)

const sorted = H.sortSpots([{ at: 1000 }, { at: 3000 }, { at: 2000 }])
eq("newest first", sorted.map(s => s.at).join(","), "3000,2000,1000")
eq("age wording", H.formatAge(45), "45m")
eq("age wording, hours", H.formatAge(90), "1h30m")

if (!process.argv.includes("--offline")) {
  console.log("\n# live feeds")
  const get = async (url, asText) => {
    const r = await fetch(url, { signal: AbortSignal.timeout(15000),
                                 headers: { "User-Agent": "omarchy-hamradio/0.1" } })
    return asText ? await r.text() : await r.json()
  }
  try {
    const live = H.parseSolar(await get("https://www.hamqsl.com/solarxml.php", true))
    check("hamqsl parsed", !!live && live.bands.length >= 4, `${live && live.bands.length} band rows`)
    check("solar flux is a plausible number", live.sfi >= 60 && live.sfi <= 400, `SFI ${live.sfi}`)
    check("K index is in range", live.k >= 0 && live.k <= 9, `K ${live.k}`)
    for (const b of live.bands) {
      check(`${b.band} grades are known words`,
            H.gradeRank(b.day) >= 0 && H.gradeRank(b.night) >= 0, `${b.day}/${b.night}`)
    }
  } catch (e) { console.log(`  skip  hamqsl unavailable (${e.message})`) }

  try {
    const spots = await get("https://api.pota.app/spot/activator")
    check("POTA returned spots", Array.isArray(spots) && spots.length > 0, `${spots.length} spots`)
    // Operators mistype frequencies and the feed passes them straight through
    // — a spot at 700.5 MHz is a fat finger, not a band we are missing. The
    // right behaviour is to refuse to map it, so this asserts that the great
    // majority land in a band and reports the ones that do not rather than
    // failing on somebody else's typo.
    const mapped = spots.map(s => H.normalisePotaSpot(s)).filter(s => s && s.freq > 0)
    const unmapped = mapped.filter(s => s.band === "")
    check("nearly every spotted frequency lands in a band",
          mapped.length > 0 && unmapped.length / mapped.length < 0.1,
          unmapped.length ? `${unmapped.length}/${mapped.length} out of band: `
                            + unmapped.slice(0, 4).map(s => (s.freq / 1000).toFixed(3) + " MHz").join(", ")
                          : `${mapped.length}/${mapped.length}`)
  } catch (e) { console.log(`  skip  POTA unavailable (${e.message})`) }
}

console.log(`\n${failures ? `${failures} FAILED` : "all checks passed"}\n`)
process.exit(failures ? 1 : 0)
