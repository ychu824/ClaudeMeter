#!/usr/bin/env python3
# TokenTide app icon: two progress rings (5h outer, 7d inner) around a small tide wave.
import cairosvg, sys

def wave(cx, cy, w, amp, color, sw):
    # two smooth humps (a small tide) centered at (cx, cy)
    x0 = cx - w/2; q = w/4
    d = (f"M {x0} {cy} "
         f"C {x0+q*0.5} {cy-amp}, {x0+q*1.5} {cy-amp}, {x0+q*2} {cy} "
         f"S {x0+q*3.5} {cy+amp}, {x0+q*4} {cy}")
    return f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{sw}" stroke-linecap="round"/>'

import math
def ring(r, pct, color, track, sw):
    tc, to = track
    L = 2*math.pi*r
    return (f'<circle cx="512" cy="512" r="{r}" fill="none" stroke="{tc}" stroke-opacity="{to}" stroke-width="{sw}"/>'
            f'<circle cx="512" cy="512" r="{r}" fill="none" stroke="{color}" stroke-width="{sw}" '
            f'stroke-linecap="round" stroke-dasharray="{L*pct/100:.1f} {L:.1f}" transform="rotate(-90 512 512)"/>')

def icon(bg_defs, bg_fill, outer, inner, track, wave_color, rim):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>{bg_defs}
<filter id="sh" x="-20%" y="-20%" width="140%" height="140%">
  <feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#000" flood-opacity="0.28"/></filter>
</defs>
<rect x="100" y="100" width="824" height="824" rx="185" fill="{bg_fill}" filter="url(#sh)"/>
<rect x="101" y="101" width="822" height="822" rx="184" fill="none" stroke="{rim[0]}" stroke-opacity="{rim[1]}" stroke-width="2"/>
{ring(262, 74, outer, track, 58)}
{ring(176, 52, inner, track, 46)}
{wave(512, 512, 150, 34, wave_color, 26)}
</svg>'''

variants = {
 "A_dark": icon(
   '<linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2E2420"/><stop offset="1" stop-color="#1A1513"/></linearGradient>',
   "url(#g)", "#D97757", "#F0B49B", ("#FFFFFF",0.10), "#FAF9F5", ("#FFFFFF",0.12)),
 "B_ivory": icon(
   '<linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFDF8"/><stop offset="1" stop-color="#F1ECE2"/></linearGradient>',
   "url(#g)", "#D97757", "#E9A688", ("#2A1E17",0.08), "#C2603F", ("#000000",0.08)),
 "C_clay": icon(
   '<linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#E58C69"/><stop offset="1" stop-color="#C15C3B"/></linearGradient>',
   "url(#g)", "#FFFFFF", "#FFE3D6", ("#FFFFFF",0.22), "#FFFFFF", ("#FFFFFF",0.18)),
}
# Usage: python3 scripts/make-icon.py [A_dark|B_ivory|C_clay]   (needs: pip install cairosvg)
# Writes assets/AppIcon.svg and assets/AppIcon.png (1024x1024). build.sh turns the PNG into AppIcon.icns.
import os
name = sys.argv[1] if len(sys.argv) > 1 else "A_dark"
out = os.path.join(os.path.dirname(__file__), "..", "assets")
svg = variants[name]
open(os.path.join(out, "AppIcon.svg"), "w").write(svg)
cairosvg.svg2png(bytestring=svg.encode(), write_to=os.path.join(out, "AppIcon.png"), output_width=1024, output_height=1024)
print("wrote assets/AppIcon.{svg,png} from", name)
