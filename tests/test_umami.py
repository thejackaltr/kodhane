"""Umami (analiz.teserix.com) duman testi: betik etiketi, servis çalışanı kuralı ve olay kancaları.

Gerçek Umami'ye bağlanmaz: analiz.teserix.com istekleri Playwright ile ya engellenir (Umami yok -> oyun yine çalışır,
track sessizce hiçbir şey yapmaz) ya da sahte bir script.js ile yanıtlanır (window.umami.track çağrıları kaydedilir).
    python3 tests/test_umami.py
"""
import functools
import os
import re
import sys
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = int(os.environ.get('KODHANE_TEST_PORT', '8771'))
URL = 'http://127.0.0.1:%d/index.html' % PORT
WEBSITE_ID = '6a036eb3-5974-482f-bcce-dbdf0a383f36'
results = []


def check(name, cond, info=''):
    results.append((name, bool(cond), info))
    print(('PASS' if cond else 'FAIL'), name, info)


# ---------------------------------------------------------------- statik kontroller
html = open(os.path.join(ROOT, 'index.html'), encoding='utf-8').read()
tags = re.findall(r'<script[^>]*analiz\.teserix\.com[^>]*></script>', html)
check('index.html: exactly one Umami script', len(tags) == 1, str(tags))
tag = tags[0] if tags else ''
# async (not defer): Kodhane boots on DOMContentLoaded; a deferred tracker on a slow host would delay the game
check('script: src + async (does not block DOMContentLoaded)', 'src="https://analiz.teserix.com/script.js"' in tag and re.search(r'\sasync[\s>]', tag) and not re.search(r'\sdefer[\s>]', tag))
check('script: Kodhane website id', 'data-website-id="%s"' % WEBSITE_ID in tag)
check('script: data-domains without localhost', 'data-domains="kodhane.teserix.com,thejackaltr.github.io"' in tag and 'localhost' not in tag)
check('script: no other game ids', '5ebd71d2-4e8f-4822-a110-1f2c7d56f94e' not in html and '04257fdf-e069-4ecb-9b6a-196aa1e83242' not in html)
check('script: placed after the game scripts, before </body>', html.index('leaderboard.js') < html.index(tag) < html.index('</body>'))
sw = open(os.path.join(ROOT, 'sw.js'), encoding='utf-8').read()
check('sw.js: analiz.teserix.com is never cached/intercepted', "url.hostname === 'analiz.teserix.com') return;" in sw and 'analiz' not in sw.split('var ASSETS')[1].split(';')[0])
src = ''.join(open(os.path.join(ROOT, f), encoding='utf-8').read() for f in ('game.js', 'cloud.js', 'leaderboard.js'))
names = sorted(set(re.findall(r"\btrack\('([a-z_]+)'\)", src)))
check('events wired', names == sorted(['acikofis_news_click', 'cloud_save', 'game_start', 'login_success', 'reset_or_prestige', 'share_click']), str(names))
check('track calls pass event names only (no second argument)', not re.search(r"\btrack\('[a-z_]+'\s*,", src))


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(('127.0.0.1', PORT), functools.partial(QuietHandler, directory=ROOT))
threading.Thread(target=server.serve_forever, daemon=True).start()

FAKE_UMAMI = "window.__umamiCalls = []; window.umami = { track: function () { window.__umamiCalls.push(Array.prototype.slice.call(arguments)); } };"
QUIET = "window.KODHANE_QUIET = true;"


def block_backends(ctx):
    for h in ('https://kodhane-api.teserix.com/**', 'https://supabase.teserix.com/**', 'https://cdn.jsdelivr.net/**'):
        ctx.route(h, lambda r: r.abort('connectionrefused'))


with sync_playwright() as p:
    b = p.chromium.launch()

    # ---- 1) Umami yüklenemiyor (engelli / çevrimdışı): oyun çalışır, track sessiz
    ctx = b.new_context(); ctx.add_init_script(QUIET); block_backends(ctx)
    hits = []
    ctx.route('https://analiz.teserix.com/**', lambda r: (hits.append(r.request.url), r.abort('blockedbyclient')))
    page = ctx.new_page(); perr = []
    page.on('pageerror', lambda e: perr.append(str(e)))
    page.goto(URL); page.wait_for_selector('#clickBtn'); page.wait_for_timeout(300)
    page.click('#clickBtn')
    check('no umami: script was requested (and blocked)', any(u.endswith('/script.js') for u in hits), str(hits))
    check('no umami: window.umami undefined', page.evaluate('typeof window.umami') == 'undefined')
    check('no umami: game still works', page.evaluate('Kodhane.state.clicks') == 1)
    check('no umami: game_start recorded locally', page.evaluate("Kodhane.tracked.indexOf('game_start') !== -1"))
    page.evaluate("Kodhane.shareText('x')")
    check('no umami: share path does not throw', not perr and page.evaluate("Kodhane.tracked.slice(-1)[0]") == 'share_click', '; '.join(perr))
    ctx.close()

    # ---- 2) sahte Umami: çağrılar yalnızca olay adıyla window.umami.track'e gider
    ctx = b.new_context(); ctx.add_init_script(QUIET); block_backends(ctx)
    ctx.route('https://analiz.teserix.com/script.js', lambda r: r.fulfill(status=200, content_type='application/javascript', body=FAKE_UMAMI))
    page = ctx.new_page(); perr = []
    page.on('pageerror', lambda e: perr.append(str(e)))
    page.goto(URL); page.wait_for_selector('#clickBtn')
    page.wait_for_function('window.__umamiCalls && window.__umamiCalls.length > 0')
    calls = page.evaluate('window.__umamiCalls')
    check('fake umami: game_start sent', ['game_start'] in calls, str(calls))
    page.evaluate("Kodhane.shareText('x')")
    page.evaluate("Kodhane.track('login_success')")
    calls = page.evaluate('window.__umamiCalls')
    check('fake umami: share_click sent', ['share_click'] in calls, str(calls))
    check('fake umami: every call is a single event name string', all(len(c) == 1 and isinstance(c[0], str) for c in calls), str(calls))
    # Yatırım Turu -> reset_or_prestige
    page.evaluate("Kodhane.state.runEarned = 1e9; Kodhane.renderAll()")
    page.click('button[data-tab="prestige"]') if page.is_visible('button[data-tab="prestige"]') else None
    page.evaluate("document.getElementById('prestigeBtn').disabled = false; document.getElementById('prestigeBtn').click()")
    page.click('.modal-actions button.primary')
    page.wait_for_timeout(100)
    calls = page.evaluate('window.__umamiCalls')
    check('fake umami: prestige -> reset_or_prestige', ['reset_or_prestige'] in calls and page.evaluate('Kodhane.state.prestigeCount') == 1, str(calls))
    check('fake umami: no page errors', not perr, '; '.join(perr))
    ctx.close()

    # ---- 3) asılı kalan Umami: betik isteği biz bırakana kadar yanıtlanmaz. Oyun beklemeden açılmalı; game_start
    #          kuyrukta bekler, betik gelince gönderilir.
    ctx = b.new_context(); ctx.add_init_script(QUIET); block_backends(ctx)
    held = []
    ctx.route('https://analiz.teserix.com/script.js', lambda r: held.append(r))
    page = ctx.new_page()
    page.goto(URL, wait_until='commit')
    page.wait_for_function("window.Kodhane && Kodhane.tracked && Kodhane.tracked.indexOf('game_start') !== -1", timeout=10000)
    check('hanging umami: game boots while the tracker request is still pending', len(held) == 1 and page.evaluate("typeof window.umami") == 'undefined')
    page.click('#clickBtn')
    check('hanging umami: game playable', page.evaluate('Kodhane.state.clicks') == 1)
    check('hanging umami: game_start queued meanwhile', page.evaluate('Kodhane.umamiQueue()') == ['game_start'])
    held[0].fulfill(status=200, content_type='application/javascript', body=FAKE_UMAMI)
    page.wait_for_function('window.__umamiCalls && window.__umamiCalls.length > 0', timeout=10000)
    check('hanging umami: queued game_start flushed once the tracker loads', page.evaluate('window.__umamiCalls') == [['game_start']] and page.evaluate('Kodhane.umamiQueue()') == [])
    ctx.close()
    b.close()

server.shutdown()
passed = sum(r[1] for r in results)
print('\nSUMMARY: %d/%d passed' % (passed, len(results)))
sys.exit(0 if passed == len(results) else 1)
