import asyncio, os, sys
from playwright.async_api import async_playwright
U = 'http://127.0.0.1:8097/'
IMG = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'img')
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out')
os.makedirs(OUT, exist_ok=True)
only = sys.argv[1:]
async def tmdb_route(route):
    name = route.request.url.rsplit('/', 1)[-1]
    f = f'{IMG}/{name}'
    if os.path.exists(f): await route.fulfill(path=f, content_type='image/jpeg')
    else: await route.fulfill(status=404, body='')
async def login(b, user, w=1440, h=900):
    ctx = await b.new_context(viewport={'width': w, 'height': h}, device_scale_factor=1)
    await ctx.route('https://image.tmdb.org/**', tmdb_route)
    pg = await ctx.new_page()
    await pg.goto(U); await pg.wait_for_selector('#smkv-login.show form')
    await pg.fill('#smkv-login [name=username]', user); await pg.fill('#smkv-login [name=password]', 'demo-pass-1'); await pg.click('#smkv-login button')
    await pg.wait_for_selector('#smkv-nav a'); await pg.wait_for_timeout(1200)
    for _ in range(4):
        if await pg.locator('#smkv-detail.show').count(): await pg.keyboard.press('Escape'); await pg.wait_for_timeout(300)
    await pg.evaluate("document.querySelectorAll('#smkv-annbar,#smkv-secbar').forEach(e=>e.hidden=true)")
    return pg
def want(n): return not only or n in only
async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch(executable_path='/usr/bin/google-chrome', args=['--autoplay-policy=no-user-gesture-required'])
        # friends online, one of them watching
        theo = await login(b, 'theo', 1000, 700)
        await theo.goto(U + '#/lib/main'); await theo.wait_for_timeout(800)
        await theo.locator('.smkv-card', has_text='Paper Lanterns').first.click(); await theo.wait_for_timeout(800)
        import re as _re
        await theo.locator('#smkv-detail button', has_text=_re.compile('Play|Resume')).first.click(); await theo.wait_for_timeout(3000)
        ploy = await login(b, 'ploy', 1000, 700)
        pg = await login(b, 'mira')
        if want('home'):
            await pg.goto(U + '#/'); await pg.wait_for_timeout(2500)
            await pg.mouse.move(1400, 880)
            await pg.screenshot(path=f'{OUT}/home.png')
        if want('movie'):
            await pg.goto(U + '#/lib/main'); await pg.wait_for_timeout(1500)
            await pg.locator('.smkv-card', has_text='Low Orbit').first.click(); await pg.wait_for_timeout(1500)
            await pg.screenshot(path=f'{OUT}/movie.png')
            await pg.keyboard.press('Escape'); await pg.wait_for_timeout(400)
        if want('show'):
            await pg.goto(U + '#/lib/tv-shows'); await pg.wait_for_timeout(1500)
            await pg.locator('.smkv-card', has_text='Harbor Lights').first.click(); await pg.wait_for_timeout(1500)
            await pg.screenshot(path=f'{OUT}/show.png')
            await pg.keyboard.press('Escape'); await pg.wait_for_timeout(400)
        if want('music'):
            await pg.goto(U + '#/lib/music'); await pg.wait_for_timeout(1500)
            await pg.locator('.smkv-card', has_text='Afterglow').first.click(); await pg.wait_for_timeout(1500)
            await pg.screenshot(path=f'{OUT}/music1.png')
            btn = pg.locator('button', has_text='Play').first
            await btn.click(); await pg.wait_for_timeout(2500)
            await pg.mouse.move(700, 450)
            await pg.screenshot(path=f'{OUT}/music.png')
            await pg.evaluate("document.querySelector('audio') && document.querySelectorAll('audio').forEach(a=>a.pause())")
        if want('player'):
            await pg.goto(U + '#/lib/main'); await pg.wait_for_timeout(1000)
            await pg.locator('.smkv-card', has_text='Neon Tide').first.click(); await pg.wait_for_timeout(1000)
            await pg.locator('#smkv-detail button', has_text='Resume').first.click(); await pg.wait_for_timeout(9000)
            await pg.mouse.move(700, 500); await pg.wait_for_timeout(300); await pg.mouse.move(720, 520); await pg.wait_for_timeout(500)
            await pg.screenshot(path=f'{OUT}/player.png')
            await pg.keyboard.press('Escape'); await pg.wait_for_timeout(800)
        if want('admin'):
            await pg.goto(U + 'admin'); await pg.wait_for_timeout(2000)
            await pg.evaluate("window.scrollTo(0, document.querySelector('#roles').closest('section').getBoundingClientRect().top + scrollY - 80)"); await pg.wait_for_timeout(400)
            await pg.screenshot(path=f'{OUT}/admin.png')
            await pg.evaluate("window.scrollTo(0,0)"); await pg.wait_for_timeout(400)
            await pg.screenshot(path=f'{OUT}/admin-top.png')
        await b.close()
asyncio.run(main())
