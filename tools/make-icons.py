# Draws the Delos icons (SVG): night/Artemis moon + day/Apollo sun around a play button.
# python3 tools/make-icons.py  → icon.svg, icon_fg.svg, maskable.svg, favicon.svg in the current folder
# then render with rsvg-convert (see the commit that added this file for the sizes used).
import math
def mark(cx=476, cy=512, r=300, play=True):
    """Delos: one disc, night (Artemis, moon) on the left, day (Apollo, sun) on the right."""
    rays = []
    for i in range(9):
        a = math.radians(-80 + i * 20)  # right side fan
        x1, y1 = cx + (r + 34) * math.cos(a), cy + (r + 34) * math.sin(a)
        x2, y2 = cx + (r + 96) * math.cos(a), cy + (r + 96) * math.sin(a)
        rays.append(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}"/>')
    # crescent on the night side
    mx, my, mr = cx - r * 0.50, cy - r * 0.42, r * 0.26
    stars = ''.join(f'<circle cx="{cx + dx * r:.1f}" cy="{cy + dy * r:.1f}" r="{s * r:.1f}" fill="#dbe8ff"/>'
                    for dx, dy, s in [(-0.70, 0.30, 0.035), (-0.42, 0.62, 0.028), (-0.80, -0.02, 0.022), (-0.20, -0.62, 0.02)])
    tri = ''
    if play:
        h = r * 0.50
        tri = (f'<path d="M{cx - h*0.36:.1f},{cy - h*0.5:.1f} L{cx + h*0.56:.1f},{cy:.1f} L{cx - h*0.36:.1f},{cy + h*0.5:.1f} Z" '
               f'fill="#ffffff" stroke="#ffffff" stroke-width="{r*0.06:.1f}" stroke-linejoin="round"/>')
    return f'''
  <defs>
    <linearGradient id="night" gradientUnits="userSpaceOnUse" x1="0" y1="{cy-r}" x2="0" y2="{cy+r}"><stop offset="0" stop-color="#3a5bd9"/><stop offset="1" stop-color="#1b2a6b"/></linearGradient>
    <linearGradient id="day" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffcf5a"/><stop offset="1" stop-color="#f08a24"/></linearGradient>
    <clipPath id="disc"><circle cx="{cx}" cy="{cy}" r="{r}"/></clipPath>
  </defs>
  <g stroke="#ffb83f" stroke-width="{r*0.11:.1f}" stroke-linecap="round">{''.join(rays)}</g>
  <g clip-path="url(#disc)">
    <rect x="{cx-r}" y="{cy-r}" width="{r}" height="{2*r}" fill="url(#night)"/>
    <rect x="{cx}" y="{cy-r}" width="{r}" height="{2*r}" fill="url(#day)"/>
    <circle cx="{mx:.1f}" cy="{my:.1f}" r="{mr:.1f}" fill="#e8f0ff"/>
    <circle cx="{mx + mr*0.42:.1f}" cy="{my - mr*0.22:.1f}" r="{mr*0.86:.1f}" fill="url(#night)"/>
    {stars}
  </g>
  {tri}'''

def bg(size=1024, rounded=False):
    rr = f' rx="{size*0.22:.0f}"' if rounded else ''
    return f'''<defs><radialGradient id="bg" cx="0.5" cy="0.42" r="0.75"><stop offset="0" stop-color="#1b2540"/><stop offset="1" stop-color="#0b0e15"/></radialGradient></defs>
  <rect width="{size}" height="{size}"{rr} fill="url(#bg)"/>'''

def svg(body, size=1024):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 1024 1024">{body}</svg>'

open('icon.svg', 'w').write(svg(bg() + mark()))                                # full square (iOS, desktop, store)
open('icon_fg.svg', 'w').write(svg(mark(r=205)))                               # Android adaptive foreground (safe zone)
open('maskable.svg', 'w').write(svg(bg() + mark(r=230)))                       # PWA maskable
open('favicon.svg', 'w').write(svg(bg(rounded=True) + mark(r=330, play=True)))  # small sizes
