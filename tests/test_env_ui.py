"""Hosta göre ortam (dev dalı) arayüz/ağ testi (Playwright, headless Chromium; ağ yok, gerçek sunucu yok).

  [live]   kodhane.teserix.com ve thejackaltr.github.io/kodhane/: bugünkü davranış. configured() true, adres kodhane-api.teserix.com;
           izin açıkken Umami betiği analiz.teserix.com/script.js (aynı website id / data-domains); misafir Sıralama ve anonim sayaç
           canlı adrese (burada sahte route) gider; TEST işareti yok.
  [dev]    kodhane-dev.teserix.com: configured() false; izin açık olsa da Umami, Supabase (canlı ya da başka), jsDelivr isteği 0;
           sayfa çalışır (tık, Sıralama sekmesi, giriş denemesi); köşede küçük, tıklanamaz "TEST" işareti (360x640 ve 1280x800).
  [local]  localhost / 127.0.0.1 (bilinmeyen host): configured() false, aynı istekler 0, TEST işareti yok.
Oyun her host altında Playwright route ile depo dosyalarından sunulur; Umami/Supabase sahte (route);
güvenlik ağı: gerçek adlar --host-resolver-rules ile 127.0.0.1:9'a (kapalı port) yönlenir.
    python3 tests/test_env_ui.py         (ekran görüntüleri yalnız KODHANE_ENV_SHOTS verilirse, depo dışına)
"""
import json
import mimetypes
import os
import re
import sys
from urllib.parse import urlsplit

from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.environ.get('KODHANE_ENV_SHOTS', '')
LIVE_API = 'kodhane-api.teserix.com'
TRACKED = {'analiz.teserix.com', LIVE_API, 'supabase.teserix.com', 'cdn.jsdelivr.net'}
SAFETY = ('MAP analiz.teserix.com 127.0.0.1:9, MAP kodhane-api.teserix.com 127.0.0.1:9, MAP supabase.teserix.com 127.0.0.1:9, '
          'MAP kodhane.teserix.com 127.0.0.1:9, MAP kodhane-dev.teserix.com 127.0.0.1:9, MAP thejackaltr.github.io 127.0.0.1:9, '
          'MAP cdn.jsdelivr.net 127.0.0.1:9, MAP acikofis.teserix.com 127.0.0.1:9, MAP *.supabase.co 127.0.0.1:9, MAP localhost 127.0.0.1:9')
HOSTS = [  # (etiket, adres, ortam)
    ('live kodhane.teserix.com', 'https://kodhane.teserix.com/', 'live'),
    ('live thejackaltr.github.io', 'https://thejackaltr.github.io/kodhane/', 'live'),
    ('dev kodhane-dev.teserix.com', 'https://kodhane-dev.teserix.com/', 'dev'),
    ('local localhost', 'http://localhost:8790/', 'local'),
    ('local 127.0.0.1', 'http://127.0.0.1:8790/', 'local'),
]
CONSENT = "try { localStorage.setItem('kodhane_tel_notice', '1'); localStorage.setItem('kodhane_tel', 'on'); } catch (e) {}"
FAKE_UMAMI = "window.umami = { track: function () { fetch('https://analiz.teserix.com/api/send', { method: 'POST', body: '{}' }).catch(function () {}); } };"
results = []


def check(name, cond, info=''):
    results.append((name, bool(cond), info))
    print(('PASS' if cond else 'FAIL'), name, info if not cond or os.environ.get('VERBOSE') else '')


def file_route(prefix):
    def handler(route):
        path = urlsplit(route.request.url).path
        path = path[len(prefix):] if path.startswith(prefix) else path.lstrip('/')
        fp = os.path.normpath(os.path.join(ROOT, path or 'index.html'))
        if not fp.startswith(ROOT) or not os.path.isfile(fp):
            return route.fulfill(status=404, body='not found')
        route.fulfill(status=200, headers={'content-type': mimetypes.guess_type(fp)[0] or 'application/octet-stream', 'cache-control': 'no-store'},
                      body=open(fp, 'rb').read())
    return handler


def fake_umami(route):
    if urlsplit(route.request.url).path == '/script.js':
        return route.fulfill(status=200, headers={'content-type': 'application/javascript', 'access-control-allow-origin': '*'}, body=FAKE_UMAMI)
    route.fulfill(status=200, headers={'content-type': 'application/json', 'access-control-allow-origin': '*'}, body='{}')


def fake_supabase(route):
    cors = {'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*', 'content-type': 'application/json'}
    if route.request.method == 'OPTIONS':
        return route.fulfill(status=204, headers=cors, body='')
    route.fulfill(status=200, headers=cors, body='null' if urlsplit(route.request.url).path.endswith('kodhane_count_event') else '[]')


with sync_playwright() as p:
    b = p.chromium.launch(args=['--host-resolver-rules=' + SAFETY])
    table = []
    for tag, url, kind in HOSTS:
        parts = urlsplit(url)
        for vp in ([(360, 640), (1280, 800)] if kind == 'dev' else [(1280, 800)]):
            t = '[%s %dx%d]' % (tag, vp[0], vp[1])
            ctx = b.new_context(locale='tr-TR', service_workers='block', viewport={'width': vp[0], 'height': vp[1]})
            ctx.add_init_script('window.KODHANE_QUIET = true;')
            ctx.add_init_script(CONSENT)
            reqs = []
            ctx.on('request', lambda r, reqs=reqs: reqs.append((r.method, r.url)))
            page_origin = '%s://%s/' % (parts.scheme, parts.netloc)
            ctx.route(re.compile(r'^https?://(?!' + re.escape(parts.netloc) + r'/|analiz\.teserix\.com/|kodhane-api\.teserix\.com/|supabase\.teserix\.com/|cdn\.jsdelivr\.net/).*'),
                      lambda r: r.abort('blockedbyclient'))
            ctx.route(page_origin + '**', file_route(parts.path))
            ctx.route('https://analiz.teserix.com/**', fake_umami)
            ctx.route('https://kodhane-api.teserix.com/**', fake_supabase)
            ctx.route('https://supabase.teserix.com/**', fake_supabase)
            ctx.route('https://cdn.jsdelivr.net/**', lambda r: r.abort('connectionrefused'))
            pg = ctx.new_page()
            errs = []
            pg.on('pageerror', lambda e, errs=errs: errs.append(str(e)))
            pg.goto(url)
            pg.wait_for_selector('#clickBtn')
            pg.wait_for_timeout(400)
            ev = pg.evaluate
            env = ev('Kodhane.ENV')
            conf = ev('Kodhane.cloud.isConfigured()')
            c0 = ev('Kodhane.state.clicks')
            pg.click('#clickBtn'); pg.click('#clickBtn')
            clicks_ok = ev('Kodhane.state.clicks') == c0 + 2
            ev("Kodhane.track('share_click'); Kodhane.countEvent('news_show')")
            if vp[0] >= 1000:
                pg.click('[data-tab="siralama"]')
            else:
                pg.click('#bottomNav [data-view="siralama"]')
            pg.wait_for_timeout(600)
            lb_status = pg.inner_text('#lbStatus')
            badge = ev("""(() => { const e = document.getElementById('envBadge'); if (!e) return null; const r = e.getBoundingClientRect(), cs = getComputedStyle(e);
              const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
              return { text: e.textContent, x: r.left, y: r.top, w: r.width, h: r.height, pe: cs.pointerEvents, pos: cs.position, visible: r.width > 0 && cs.visibility !== 'hidden' && cs.display !== 'none',
                       hitIsBadge: hit === e, aria: e.getAttribute('aria-hidden'), count: document.querySelectorAll('.env-badge').length }; })()""")
            if kind != 'live':
                pg.click('#accountBtn'); pg.wait_for_selector('#accountPanel:not(.hidden)')
                acc_msg = pg.inner_text('#accMsg')   # panel açılınca (mevcut metin); ardından gönderme denemesi de istek atmamalı
                pg.fill('#accEmail', 'oyuncu@example.com'); pg.click('#accSend'); pg.wait_for_timeout(300)
                pg.click('#accClose')
            if SHOTS and kind == 'dev':
                pg.screenshot(path=os.path.join(SHOTS, 'kodhane-env-dev-%dx%d.png' % vp))
            umami = [u for m, u in reqs if urlsplit(u).hostname == 'analiz.teserix.com']
            sb = [u for m, u in reqs if urlsplit(u).hostname in (LIVE_API, 'supabase.teserix.com') or (urlsplit(u).hostname or '').endswith('.supabase.co')]
            other = sorted(set(urlsplit(u).hostname for m, u in reqs if urlsplit(u).scheme in ('http', 'https') and urlsplit(u).netloc != parts.netloc))
            script = ev("(() => { const s = document.querySelector('script[data-test=umami-script]'); return s ? { src: s.src, id: s.getAttribute('data-website-id'), domains: s.getAttribute('data-domains') } : null; })()")
            check(t + ' ENV ' + kind, env['name'] == kind and env['live'] == (kind == 'live') and env['badge'] == (kind == 'dev'), env)
            check(t + ' page works (2 clicks counted, no page errors)', clicks_ok and not errs, errs)
            if kind == 'live':
                check(t + ' configured() true, live Supabase address', conf is True and ev('Kodhane.cloud.config.url') == 'https://' + LIVE_API)
                check(t + ' Umami: same script (src / website id / domains) loaded with consent', script == {'src': 'https://analiz.teserix.com/script.js', 'id': '6a036eb3-5974-482f-bcce-dbdf0a383f36',
                      'domains': 'kodhane.teserix.com,thejackaltr.github.io'} and any(urlsplit(u).path == '/script.js' for u in umami), script)
                check(t + ' Supabase: guest leaderboard + counter go to kodhane-api.teserix.com (as before)',
                      any('/rest/v1/rpc/kodhane_leaderboard' in u for u in sb) and any(u.endswith('/rest/v1/rpc/kodhane_count_event') for u in sb)
                      and all(urlsplit(u).hostname == LIVE_API for u in sb), sb)
                check(t + ' no TEST badge', badge is None, badge)
            else:
                check(t + ' configured() false, empty address/key', conf is False and ev('Kodhane.cloud.config.url') == '' and ev('Kodhane.cloud.config.key') == '')
                check(t + ' consent on, Sıralama, counter, login attempt: Umami 0, Supabase 0, other hosts 0', not umami and not sb and not other and script is None,
                      {'umami': umami, 'sb': sb, 'other': other})
                check(t + ' Sıralama: "kullanılamıyor", account panel: "yapılandırılmamış" (existing copy)', 'Sıralama bu sürümde kullanılamıyor.' in lb_status and 'Bulut kaydı bu sürümde yapılandırılmamış' in acc_msg,
                      [lb_status, acc_msg])
                if kind == 'dev':
                    check(t + ' TEST badge: one, visible, text TEST, fixed in the top-left corner, small', badge and badge['count'] == 1 and badge['visible'] and badge['text'] == 'TEST' and
                          badge['pos'] == 'fixed' and badge['x'] <= 12 and badge['y'] <= 12 and badge['w'] <= 40 and badge['h'] <= 18, badge)
                    check(t + ' TEST badge: not clickable (pointer-events none, clicks pass through), aria-hidden', badge and badge['pe'] == 'none' and not badge['hitIsBadge'] and
                          badge['aria'] == 'true', badge)
                else:
                    check(t + ' no TEST badge', badge is None, badge)
            table.append((tag, vp, conf, len(umami), len(sb), bool(badge)))
            ctx.close()
    b.close()

print('\nhost | viewport | configured | umami istek | supabase istek | TEST')
for tag, vp, conf, nu, ns, bd in table:
    print('%s | %dx%d | %s | %d | %d | %s' % (tag, vp[0], vp[1], conf, nu, ns, 'var' if bd else 'yok'))
fails = [r for r in results if not r[1]]
print('\nSUMMARY: %d/%d passed' % (len(results) - len(fails), len(results)))
sys.exit(1 if fails else 0)
