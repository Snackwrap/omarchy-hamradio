#!/usr/bin/env python3
"""Generate tools/promo.html — the marketplace card — with the tab captures inlined.

The screenshots are embedded as data URIs so the page renders identically from
any working directory and needs nothing fetched at build time.
"""
import base64
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
TABS = ROOT / "assets" / "tabs"

# Every capture is 770 wide but its height follows its content, so crop them all
# to a common band from the top.
BAND = 688

PANELS = [
    ("bands.png",    "BANDS",     "day and night, and which one is in force"),
    ("spots.png",    "SPOTS",     "live POTA and SOTA activations"),
    ("greyline.png", "GREY LINE", "when the low bands go long"),
]


def uri(name):
    out = subprocess.run(
        ["magick", str(TABS / name), "-crop", f"770x{BAND}+0+0", "+repage", "png:-"],
        check=True, capture_output=True).stdout
    return "data:image/png;base64," + base64.b64encode(out).decode()


cards = "\n".join(
    f'''      <figure class="card">
        <div class="shot"><img src="{uri(f)}" alt="{label} tab"></div>
        <figcaption><b>{label}</b> {note}</figcaption>
      </figure>''' for f, label, note in PANELS)

HTML = f"""<!DOCTYPE html><html><head><meta charset="utf-8"><style>
  * {{ margin:0; padding:0; box-sizing:border-box; }}
  body {{ width:1600px; height:1000px; background:#12151c; overflow:hidden;
         font-family:'JetBrainsMono Nerd Font','JetBrainsMono NF',monospace; }}
  .wrap {{ padding:56px 60px; height:100%; display:flex; flex-direction:column; }}
  .brand {{ display:flex; align-items:center; gap:13px; margin-bottom:22px; }}
  .brand .mark {{ color:#3fb950; font-size:23px; }}
  .brand .word {{ color:#68718f; font-size:15px; font-weight:700; letter-spacing:6px; }}
  .head {{ display:flex; gap:64px; align-items:flex-end; margin-bottom:34px; }}
  h1 {{ color:#dde3f4; font-size:44px; line-height:1.14; font-weight:800; letter-spacing:-0.5px; flex:none; }}
  h1 .acc {{ color:#3fb950; }}
  .side {{ flex:1; padding-bottom:6px; }}
  .sub {{ color:#858ead; font-size:16.5px; line-height:1.55; }}
  .feat {{ list-style:none; margin-top:16px; display:flex; gap:34px; }}
  .feat li {{ color:#aab2cd; font-size:14.5px; line-height:1.45; padding-left:19px;
              position:relative; flex:1; }}
  .feat li::before {{ content:"\\25B8"; color:#3fb950; font-weight:700; position:absolute; left:0; }}
  .feat b {{ color:#dde3f4; }}
  .grid {{ flex:1; display:grid; grid-template-columns:repeat(3, 1fr); gap:0 40px; align-items:start; }}
  .card {{ display:flex; flex-direction:column; min-height:0; }}
  /* The shot fills whatever height is left rather than being sized by the
     source image, so the row of panels reaches the bottom of the card. */
  .card .shot {{ border-radius:9px; border:1px solid #2f3546;
                overflow:hidden; box-shadow:0 18px 44px rgba(0,0,0,.55);
                -webkit-mask-image:linear-gradient(to bottom,#000 86%,transparent 100%);
                mask-image:linear-gradient(to bottom,#000 86%,transparent 100%); }}
  .card .shot img {{ display:block; width:100%; }}
  .card figcaption {{ margin-top:12px; color:#68718f; font-size:13px; }}
  .card figcaption b {{ color:#3fb950; letter-spacing:2.2px; margin-right:9px; }}
  .install {{ margin-top:26px; display:inline-block; background:#181c26; border:1px solid #2b3140;
             border-radius:9px; padding:12px 18px; color:#aab2cd; font-size:13.5px; white-space:nowrap; }}
  .install .p {{ color:#68718f; }} .install .c {{ color:#3fb950; }}
</style></head><body>
  <div class="wrap">
    <div class="brand"><span class="mark">&#xf2db;</span><span class="word">HF PROPAGATION</span></div>
    <div class="head">
      <h1>Which band<br><span class="acc">is open?</span></h1>
      <div class="side">
        <div class="sub">Band conditions for right now &mdash; day or night decided by where you actually are, not by the clock &mdash; with the solar numbers behind them, your grey-line windows, and who is on the air.</div>
        <ul class="feat">
          <li><b>Both halves of the table</b>, the one in force picked out</li>
          <li><b>Live POTA and SOTA</b> spots, band derived from the frequency</li>
          <li><b>No key, no account.</b> Finds your grid square on its own</li>
        </ul>
        <div class="install"><span class="p">$</span> omarchy plugin add <span class="c">github.com/Snackwrap/omarchy-hamradio</span></div>
      </div>
    </div>
    <div class="grid">
{cards}
    </div>
  </div>
</body></html>"""

(ROOT / "tools" / "promo.html").write_text(HTML, encoding="utf-8")
print("tools/promo.html written")
