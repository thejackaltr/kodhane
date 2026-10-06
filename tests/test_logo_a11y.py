"""Kodhane logo erişilebilir adı testi (görsel dal, PR #6).

400 px'in altında "Kodhane / Ajans Tycoon" başlığı gizlenir (theme.css, style.css long-num ile aynı display:none). Logo kalır;
erişilebilir adı "Kodhane" olmalı: <span class="logo" role="img" aria-label="Kodhane">&lt;/&gt;</span>.
  - index.html: logo satırı birebir bu; <title>Kodhane: Ajans Tycoon</title>, <h1>Kodhane</h1>, <small>Ajans Tycoon</small> aynen.
  - Headless Chromium, 360x640 ve 1280x800: logo role=img, adı "Kodhane", görünür; belge başlığı aynı;
    erişilebilirlik ağacında (CDP Accessibility.getFullAXTree) yok sayılmamış "Kodhane" adlı img düğümü var;
    360 px'te h1 gizli olduğundan "Kodhane" adı ağaçta yalnız logodan gelir; logonun "</>" yazısı ağaçta yalnız bu img düğümünün
    içinde durur (Chromium img'nin alt metnini ağaçta tutar, okunan ad aria-label'dır), logonun dışında ayrı metin olarak yer almaz.
Ağ yok: oyun Playwright route ile depo dosyalarından; depo dışı her istek kesilir.
    python3 tests/test_logo_a11y.py
"""
import json
import mimetypes
import os
import re
import sys
from urllib.parse import urlsplit

from playwright.sync_api import sync_playwright

ROOT = os.environ.get('KODHANE_ROOT') or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = 'https://kodhane.teserix.com/'
LOGO = '<span class="logo" role="img" aria-label="Kodhane">&lt;/&gt;</span>'
TITLE = '<title>Kodhane: Ajans Tycoon</title>'
SAFETY = ('MAP analiz.teserix.com 127.0.0.1:9, MAP kodhane-api.teserix.com 127.0.0.1:9, MAP supabase.teserix.com 127.0.0.1:9, '
          'MAP kodhane.teserix.com 127.0.0.1:9, MAP thejackaltr.github.io 127.0.0.1:9, MAP cdn.jsdelivr.net 127.0.0.1:9, '
          'MAP acikofis.teserix.com 127.0.0.1:9, MAP *.supabase.co 127.0.0.1:9')
results = []


def check(name, cond, info=''):
    results.append((name, bool(cond)))
    print(('PASS' if cond else 'FAIL'), name, '' if cond else info)


def file_route(route):
    path = urlsplit(route.request.url).path.lstrip('/') or 'index.html'
    fp = os.path.normpath(os.path.join(ROOT, path))
    if not fp.startswith(ROOT) or not os.path.isfile(fp):
        return route.fulfill(status=404, body='not found')
    route.fulfill(status=200, headers={'content-type': mimetypes.guess_type(fp)[0] or 'application/octet-stream', 'cache-control': 'no-store'},
                  body=open(fp, 'rb').read())


# 1) index.html metni
html = open(os.path.join(ROOT, 'index.html'), encoding='utf-8').read()
logo_lines = [l.strip() for l in html.splitlines() if 'class="logo"' in l]
check('index.html: tek logo satırı, birebir role="img" aria-label="Kodhane"', logo_lines == [LOGO], logo_lines)
check('index.html: <title>Kodhane: Ajans Tycoon</title> aynen (bir kez)', html.count(TITLE) == 1 and len(re.findall(r'<title>', html)) == 1)
check('index.html: başlık metinleri aynen (<h1>Kodhane</h1>, <small>Ajans Tycoon</small>)', '<h1>Kodhane</h1>' in html and '<small>Ajans Tycoon</small>' in html)

# 2) tarayıcı: erişilebilir ad ve erişilebilirlik ağacı
VP = {'360x640': dict(viewport={'width': 360, 'height': 640}, is_mobile=True, has_touch=True, device_scale_factor=2),
      '1280x800': dict(viewport={'width': 1280, 'height': 800})}
with sync_playwright() as p:
    b = p.chromium.launch(args=['--host-resolver-rules=' + SAFETY])
    for key, vp in VP.items():
        ctx = b.new_context(locale='tr-TR', service_workers='block', **vp)
        ctx.add_init_script("window.KODHANE_QUIET = true; try { localStorage.setItem('kodhane_tel_notice', '1'); localStorage.setItem('kodhane_tel', 'off'); } catch (e) {}")
        ctx.route(re.compile(r'^https?://(?!kodhane\.teserix\.com/).*'), lambda r: r.abort('blockedbyclient'))
        ctx.route(BASE + '**', file_route)
        pg = ctx.new_page()
        errors = []
        pg.on('pageerror', lambda e: errors.append(str(e)[:200]))
        pg.goto(BASE)
        pg.wait_for_timeout(800)
        check('[%s] belge başlığı "Kodhane: Ajans Tycoon"' % key, pg.title() == 'Kodhane: Ajans Tycoon', pg.title())
        logo = pg.get_by_role('img', name='Kodhane', exact=True)
        check('[%s] role=img adı "Kodhane" olan tek öğe logo ve görünür' % key,
              logo.count() == 1 and logo.first.is_visible() and logo.first.evaluate("e => e.classList.contains('logo')"))
        h1_visible = pg.locator('.brand h1').is_visible()
        if key == '360x640':
            check('[360x640] başlık (h1) 400 px altında gizli', not h1_visible)
        else:
            check('[1280x800] başlık (h1) görünür', h1_visible)
        cdp = ctx.new_cdp_session(pg)
        nodes = cdp.send('Accessibility.getFullAXTree')['nodes']

        byid = {n['nodeId']: n for n in nodes}

        def val(n, k):
            return ((n.get(k) or {}).get('value') or '')
        IMG = ('img', 'image')   # Playwright/ARIA "img", Chromium CDP "image"
        named = [(val(n, 'role'), val(n, 'name')) for n in nodes if not n.get('ignored') and val(n, 'name').strip() == 'Kodhane']
        check('[%s] erişilebilirlik ağacında "Kodhane" adlı img düğümü var' % key, any(r in IMG for r, _ in named), named)
        if key == '360x640':
            check('[360x640] ağaçta "Kodhane" adı yalnız logodan (img) geliyor', named and all(r in IMG for r, _ in named), named)

        def under_logo(n):
            q = byid.get(n.get('parentId'))
            while q:
                if val(q, 'role') in IMG and val(q, 'name') == 'Kodhane':
                    return True
                q = byid.get(q.get('parentId'))
            return False
        stray = [val(n, 'name') for n in nodes if not n.get('ignored') and val(n, 'role') == 'StaticText' and val(n, 'name').strip() == '</>' and not under_logo(n)]
        check('[%s] logonun "</>" yazısı logo dışında ayrı metin olarak yer almıyor' % key, not stray, stray)
        snap = pg.locator('.brand').aria_snapshot()
        check('[%s] .brand aria görüntüsünde img "Kodhane"' % key, 'img "Kodhane"' in snap, snap)
        check('[%s] sayfa hatası yok' % key, not errors, errors)
        ctx.close()
    b.close()

ok = sum(1 for _, c in results if c)
print('\nSUMMARY: %d/%d passed' % (ok, len(results)))
sys.exit(0 if ok == len(results) else 1)
