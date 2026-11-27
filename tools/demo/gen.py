import os, random, subprocess, json
from PIL import Image, ImageDraw, ImageFilter, ImageFont
from catalog import MOVIES, SHOWS, ALBUMS, WANTED, WANTED_TV
R = '/home/claude/demo'
IMG = f'{R}/img'; MEDIA = '/tmp/demo/media'
os.makedirs(IMG, exist_ok=True)
F = '/usr/share/fonts/opentype/inter/'
def font(sz, w='Bold'): return ImageFont.truetype(F + f'InterDisplay-{w}.otf', sz)
def hx(h): h = h.lstrip('#'); return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))
def mix(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def scene(w, h, c1, c2, sun, seed, text=None, sub=None):
    rnd = random.Random(seed)
    a, b = hx(c1), hx(c2)
    im = Image.new('RGB', (w, h))
    d = ImageDraw.Draw(im)
    for y in range(h):  # sky: light near the horizon, dark at the top
        t = y / h
        d.line([(0, y), (w, y)], fill=mix(b, a, min(1, t * 1.4)) if t < .62 else mix(a, b, (t - .62) / .38 * .9))
    # glow + sun / moon
    sx, sy = int(sun[0] * w), int(sun[1] * h)
    r = int(min(w, h) * .16)
    glow = Image.new('L', (w, h), 0)
    ImageDraw.Draw(glow).ellipse([sx - r * 3, sy - r * 3, sx + r * 3, sy + r * 3], fill=120)
    glow = glow.filter(ImageFilter.GaussianBlur(r * 1.2))
    im = Image.composite(Image.new('RGB', (w, h), mix(a, (255, 255, 255), .5)), im, glow)
    d = ImageDraw.Draw(im)
    d.ellipse([sx - r, sy - r, sx + r, sy + r], fill=mix(a, (255, 255, 255), .55))
    # layered hills, darker towards the front
    for k in range(4):
        base = h * (.55 + k * .1)
        col = mix(b, (0, 0, 0), .15 + k * .2) if k else mix(a, b, .55)
        pts = [(0, h)]
        x = 0
        amp = h * (.08 - k * .012)
        ph = rnd.random() * 6
        import math
        while x <= w:
            y = base - amp * (math.sin(x / w * (3 + k) * 3.1 + ph) * .6 + math.sin(x / w * 11 + ph * 2) * .25 + rnd.random() * .15)
            pts.append((x, y)); x += max(4, w // 120)
        pts.append((w, h))
        d.polygon(pts, fill=col)
    # stars in a dark sky
    if sum(b) < 200:
        for _ in range(int(w * h / 9000)):
            x, y = rnd.randrange(w), rnd.randrange(int(h * .45))
            d.point((x, y), fill=mix(b, (255, 255, 255), .5 + rnd.random() * .5))
    # grain
    noise = Image.effect_noise((w, h), 22).convert('RGB')
    im = Image.blend(im, noise, .045)
    if text:
        d = ImageDraw.Draw(im)
        shade = Image.new('L', (w, h), 0)
        ImageDraw.Draw(shade).rectangle([0, int(h * .66), w, h], fill=200)
        shade = shade.filter(ImageFilter.GaussianBlur(h * .08))
        im = Image.composite(Image.new('RGB', (w, h), (8, 8, 12)), im, shade)
        d = ImageDraw.Draw(im)
        size = int(w * .13)
        words = text.upper().split()
        lines, cur = [], ''
        for wd in words:
            t = (cur + ' ' + wd).strip()
            if d.textlength(t, font=font(size)) > w * .86 and cur:
                lines.append(cur); cur = wd
            else: cur = t
        lines.append(cur)
        y = h * .80 - len(lines) * size * .55
        for ln in lines:
            tw = d.textlength(ln, font=font(size))
            d.text(((w - tw) / 2, y), ln, font=font(size), fill=(250, 246, 240))
            y += size * 1.05
        if sub:
            f2 = font(int(w * .042), 'Medium')
            tw = d.textlength(sub, font=f2)
            d.text(((w - tw) / 2, h * .93), sub, font=f2, fill=mix(a, (255, 255, 255), .4))
    return im

def cover(c1, c2, seed, artist, album):
    rnd = random.Random(seed)
    w = h = 600
    a, b = hx(c1), hx(c2)
    im = Image.new('RGB', (w, h), b)
    d = ImageDraw.Draw(im)
    for i in range(7):  # soft circles
        r = rnd.randint(80, 260); x, y = rnd.randint(0, w), rnd.randint(0, h)
        lay = Image.new('L', (w, h), 0)
        ImageDraw.Draw(lay).ellipse([x - r, y - r, x + r, y + r], fill=rnd.randint(90, 200))
        lay = lay.filter(ImageFilter.GaussianBlur(40))
        im = Image.composite(Image.new('RGB', (w, h), mix(a, b, rnd.random() * .5)), im, lay)
    d = ImageDraw.Draw(im)
    for k in range(18):  # thin lines
        y = 380 + k * 9
        d.line([(60, y), (540, y)], fill=mix(a, b, k / 18), width=2)
    d.text((60, 70), album.upper(), font=font(64), fill=(255, 255, 255))
    d.text((62, 150), artist, font=font(30, 'Medium'), fill=mix(a, (255, 255, 255), .5))
    return Image.blend(im, Image.effect_noise((w, h), 20).convert('RGB'), .04)

def video(src_img, out, secs=40):
    # a still picture for the whole running time: tiny file, realistic duration
    os.makedirs(os.path.dirname(out), exist_ok=True)
    if os.path.exists(out) and os.path.getsize(out) > 0 and float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', out], capture_output=True, text=True).stdout or 0) > secs - 5: return
    subprocess.run(['ffmpeg', '-y', '-hide_banner', '-loglevel', 'error', '-loop', '1', '-framerate', '1', '-i', src_img,
                    '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo',
                    '-vf', 'scale=1280:720,format=yuv420p', '-r', '1', '-g', '600', '-x264-params', 'scenecut=0',
                    '-t', str(secs), '-c:v', 'libx264', '-preset', 'ultrafast', '-tune', 'stillimage', '-crf', '28', '-c:a', 'aac', '-b:a', '32k',
                    '-metadata:s:a:0', 'language=eng', out], check=True)

for m in MOVIES:
    scene(500, 750, *m['c'], m['sun'], m['id'], m['title'], str(m['year'])).save(f"{IMG}/p{m['id']}.jpg", quality=90)
    bd = scene(1280, 720, *m['c'], m['sun'], m['id'] + 1)
    bd.save(f"{IMG}/b{m['id']}.jpg", quality=88)
    folder = f"{MEDIA}/Movies/{m['title']} ({m['year']})"
    video(f"{IMG}/b{m['id']}.jpg", f"{folder}/{m['title'].replace(' ', '.').replace('&', 'and')}.{m['year']}.1080p.WEB-DL.mkv", (96 + (m['id'] % 7) * 6) * 60)
for s in SHOWS:
    scene(500, 750, *s['c'], s['sun'], s['id'], s['title'], str(s['year'])).save(f"{IMG}/p{s['id']}.jpg", quality=90)
    scene(1280, 720, *s['c'], s['sun'], s['id'] + 1).save(f"{IMG}/b{s['id']}.jpg", quality=88)
    for se, eps in s['seasons'].items():
        for i, name in enumerate(eps, 1):
            st = scene(640, 360, *s['c'], (0.2 + (i * .13) % .6, .25 + (i % 3) * .08), s['id'] * 100 + se * 10 + i)
            st.save(f"{IMG}/s{s['id']}_{se}_{i}.jpg", quality=85)
            video(f"{IMG}/s{s['id']}_{se}_{i}.jpg", f"{MEDIA}/TV/{s['title']}/Season {se}/{s['title'].replace(' ', '.')}.S{se:02d}E{i:02d}.1080p.mkv", 44 * 60)
for w in WANTED + WANTED_TV:  # posters only: not in the library
    scene(500, 750, *w['c'], w['sun'], w['id'], w['title'], str(w['year'])).save(f"{IMG}/p{w['id']}.jpg", quality=90)
    scene(1280, 720, *w['c'], w['sun'], w['id'] + 1).save(f"{IMG}/b{w['id']}.jpg", quality=88)
for al in ALBUMS:
    folder = f"{MEDIA}/Music/{al['artist']}/{al['album']}"
    os.makedirs(folder, exist_ok=True)
    cover(*al['c'], hash(al['album']) & 0xffff, al['artist'], al['album']).save(f"{folder}/cover.jpg", quality=90)
    for i, t in enumerate(al['tracks'], 1):
        out = f"{folder}/{i:02d} - {t}.mp3"
        if os.path.exists(out): continue
        f = 220 + i * 55
        subprocess.run(['ffmpeg', '-y', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', f'sine=frequency={f}:duration={150 + i * 17}',
                        '-af', 'volume=0.05', '-c:a', 'libmp3lame', '-b:a', '64k',
                        '-metadata', f'title={t}', '-metadata', f"artist={al['artist']}", '-metadata', f"album_artist={al['artist']}",
                        '-metadata', f"album={al['album']}", '-metadata', f'track={i}', '-metadata', f"date={al['year']}", '-metadata', f"genre={al['genre']}", out], check=True)
print('ok')
