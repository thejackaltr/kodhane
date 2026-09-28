"""v4.3 isimsiz sayaç: izin bandı, Gizlilik bölümü ve ağ kanıtı ([privacy-net]).

Oyun gerçek üretim adresleriyle açılır ama her istek yerelde karşılanır:
  - https://kodhane.teserix.com/          (kök yol)   -> depo dosyaları (Playwright route)
  - https://thejackaltr.github.io/kodhane/ (alt yol)  -> depo dosyaları (GitHub Pages benzeri)
  - https://analiz.teserix.com/**   -> sahte Umami (gerçek izleyici gibi: yüklenince pageview, pushState/replaceState/popstate
                                       pageview, umami.disabled ve data-before-send'e uyar, POST /api/send)
  - https://kodhane-api.teserix.com/** -> sahte Supabase (anonim sayaç RPC'si /rest/v1/rpc/kodhane_count_event sayılır)
Güvenlik ağı: Chromium --host-resolver-rules bu adları 127.0.0.1:9'a (kapalı port) yönlendirir; route kaçsa bile dışarı çıkılmaz.
Tüm istekler context.on('request') ile kaydedilir.
    python3 tests/test_privacy.py
"""
import json
import mimetypes
import os
import re
import sys
import time
from urllib.parse import urlsplit

from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.environ.get('KODHANE_CONSENT_SHOTS', '/workspace/consent-screens')
os.makedirs(SHOTS, exist_ok=True)
WEBSITE_ID = '6a036eb3-5974-482f-bcce-dbdf0a383f36'
COUNT_PATH = '/rest/v1/rpc/kodhane_count_event'
BASES = [('root', 'https://kodhane.teserix.com/'), ('subpath', 'https://thejackaltr.github.io/kodhane/')]
results = []


def check(name, cond, info=''):
    results.append((name, bool(cond), info))
    print(('PASS' if cond else 'FAIL'), name, info if not cond or os.environ.get('VERBOSE') else '')


def note(msg):
    print('     ' + msg)


# ---------------------------------------------------------------- statik kontroller
html = open(os.path.join(ROOT, 'index.html'), encoding='utf-8').read()
game = open(os.path.join(ROOT, 'game.js'), encoding='utf-8').read()
check('index.html: no static Umami tag (loaded only after consent)', 'analiz.teserix.com/script.js' not in html and not re.search(r'<script[^>]*data-website-id', html))
check('game.js: Umami loader with website id, domains, before-send, DNT, exclude search/hash',
      "UMAMI_WEBSITE_ID = '%s'" % WEBSITE_ID in game and "UMAMI_DOMAINS = 'kodhane.teserix.com,thejackaltr.github.io'" in game
      and all(a in game for a in ("'data-before-send'", "'data-do-not-track', 'true'", "'data-exclude-search', 'true'", "'data-exclude-hash', 'true'")))
check('game.js: GATE_SUPABASE_COUNTER = true', re.search(r'var GATE_SUPABASE_COUNTER = true;', game))
check('game.js: no other game website ids', '5ebd71d2-4e8f-4822-a110-1f2c7d56f94e' not in game + html and '04257fdf-e069-4ecb-9b6a-196aa1e83242' not in game + html)
sw = open(os.path.join(ROOT, 'sw.js'), encoding='utf-8').read()
check('sw.js: analiz.teserix.com is never cached/intercepted', "url.hostname === 'analiz.teserix.com') return;" in sw and 'analiz' not in sw.split('var ASSETS')[1].split(';')[0])
src = ''.join(open(os.path.join(ROOT, f), encoding='utf-8').read() for f in ('game.js', 'cloud.js', 'leaderboard.js'))
names = sorted(set(re.findall(r"\btrack\('([a-z_]+)'\)", src)))
check('Umami events wired (unchanged list)', names == sorted(['acikofis_news_click', 'cloud_save', 'game_start', 'login_success', 'reset_or_prestige', 'share_click']), str(names))
check('track calls pass event names only (no second argument)', not re.search(r"\btrack\('[a-z_]+'\s*,", src))
check('leaderboard.js countEvent is gated by Kodhane.counterAllowed', "if (typeof K.counterAllowed !== 'function' || !K.counterAllowed()) return;" in src)

FAKE_REAL = r"""(function () {
  var s = document.currentScript;
  var website = s && s.getAttribute('data-website-id');
  var hook = s && s.getAttribute('data-before-send');
  function disabled() { try { return !!localStorage.getItem('umami.disabled'); } catch (e) { return false; } }
  function base() { return { website: website, hostname: location.hostname, url: location.pathname, title: document.title }; }
  function send(type, payload) {
    if (disabled()) return;
    var fn = hook && window[hook];
    if (typeof fn === 'function') { payload = fn(type, payload); if (!payload) return; }
    fetch('https://analiz.teserix.com/api/send', { method: 'POST', keepalive: true, headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ type: type, payload: payload }) }).catch(function () {});
  }
  function pageview() { send('event', base()); }
  var push = history.pushState, rep = history.replaceState;
  history.pushState = function () { var r = push.apply(this, arguments); pageview(); return r; };
  history.replaceState = function () { var r = rep.apply(this, arguments); pageview(); return r; };
  window.addEventListener('popstate', pageview);
  window.umami = { track: function (name, data) { var p = base(); if (typeof name === 'string') { p.name = name; if (data) p.data = data; } send('event', p); } };
  if (document.readyState === 'complete') pageview(); else window.addEventListener('load', pageview);
})();"""


def file_route(prefix):
    def handler(route):
        path = urlsplit(route.request.url).path
        if not path.startswith(prefix):
            return route.fulfill(status=404, body='not found')
        rel = path[len(prefix):] or 'index.html'
        if rel.endswith('/'):
            rel += 'index.html'
        fp = os.path.normpath(os.path.join(ROOT, rel))
        if not fp.startswith(ROOT) or not os.path.isfile(fp):
            return route.fulfill(status=404, body='not found')
        ct = mimetypes.guess_type(fp)[0] or 'application/octet-stream'
        if fp.endswith('.webmanifest'):
            ct = 'application/manifest+json'
        with open(fp, 'rb') as f:
            route.fulfill(status=200, headers={'content-type': ct, 'cache-control': 'no-store'}, body=f.read())
    return handler


class Net:
    """Tüm istekleri kaydeder; Umami ve Supabase sahtelerini yönetir."""

    def __init__(self, umami='fake'):
        self.reqs = []
        self.umami = umami      # 'fake' | 'fail' | 'hold'
        self.held = []

    def on_request(self, req):
        self.reqs.append((req.method, req.url))

    def umami_handler(self, route):
        path = urlsplit(route.request.url).path
        if path == '/script.js':
            if self.umami == 'fail':
                return route.abort('connectionrefused')
            if self.umami == 'hold':
                self.held.append(route)
                return
            return route.fulfill(status=200, headers={'content-type': 'application/javascript', 'access-control-allow-origin': '*'}, body=FAKE_REAL)
        if path == '/api/send':
            return route.fulfill(status=200, headers={'content-type': 'application/json', 'access-control-allow-origin': '*',
                                                      'access-control-allow-headers': '*'}, body='{"ok":true}')
        route.fulfill(status=404, body='')

    @staticmethod
    def supabase_handler(route):
        cors = {'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*', 'content-type': 'application/json'}
        if route.request.method == 'OPTIONS':
            return route.fulfill(status=204, headers=cors, body='')
        path = urlsplit(route.request.url).path
        if path == COUNT_PATH:
            return route.fulfill(status=200, headers=cors, body='null')
        route.fulfill(status=200, headers=cors, body='[]')

    def counts(self):
        u = [x for x in self.reqs if urlsplit(x[1]).hostname == 'analiz.teserix.com']
        return {
            'umami': len(u),
            'umami_script': sum(1 for x in u if urlsplit(x[1]).path == '/script.js'),
            'umami_send': sum(1 for x in u if urlsplit(x[1]).path == '/api/send' and x[0] == 'POST'),
            'counter': sum(1 for x in self.reqs if urlsplit(x[1]).path == COUNT_PATH and x[0] == 'POST'),
        }

    def external(self, game_host):
        allowed = {game_host, 'analiz.teserix.com', 'kodhane-api.teserix.com'}
        return sorted(set(urlsplit(u).hostname for _, u in self.reqs if urlsplit(u).scheme in ('http', 'https') and urlsplit(u).hostname not in allowed))


SAFETY = ('MAP analiz.teserix.com 127.0.0.1:9, MAP kodhane-api.teserix.com 127.0.0.1:9, MAP supabase.teserix.com 127.0.0.1:9, '
          'MAP kodhane.teserix.com 127.0.0.1:9, MAP thejackaltr.github.io 127.0.0.1:9, MAP cdn.jsdelivr.net 127.0.0.1:9, '
          'MAP acikofis.teserix.com 127.0.0.1:9')

VIEWPORTS = [
    ('1280x800', dict(viewport={'width': 1280, 'height': 800})),
    ('375x667', dict(viewport={'width': 375, 'height': 667}, device_scale_factor=2, is_mobile=True, has_touch=True)),
    ('390x844', dict(viewport={'width': 390, 'height': 844}, device_scale_factor=2, is_mobile=True, has_touch=True)),
    ('667x375', dict(viewport={'width': 667, 'height': 375}, device_scale_factor=2, is_mobile=True, has_touch=True)),
]

INTERACT = """async () => {
  const b = document.getElementById('clickBtn');
  for (let i = 0; i < 3; i++) b.click();
  Kodhane.shareText('x');
  Kodhane.track('login_success'); Kodhane.track('cloud_save'); Kodhane.track('reset_or_prestige'); Kodhane.track('acikofis_news_click');
  Kodhane.countEvent('news_leaderboard_shown'); Kodhane.countEvent('news_acikofis_click');
  const p0 = location.pathname;
  history.pushState({}, '', p0 + '?nav=1'); history.replaceState({}, '', p0 + '?nav=2');
  await new Promise(r => { window.addEventListener('popstate', r, { once: true }); history.back(); setTimeout(r, 800); });
  history.replaceState(null, '', p0);
  await new Promise(r => setTimeout(r, 400));
  return location.pathname;
}"""


with sync_playwright() as p:
    b = p.chromium.launch(args=['--host-resolver-rules=' + SAFETY])

    def new_ctx(base, net, vp=None, init=None, quiet=False):
        opts = dict(locale='tr-TR', service_workers='block')
        opts.update(vp or dict(viewport={'width': 1280, 'height': 800}))
        ctx = b.new_context(**opts)
        host = urlsplit(base).hostname
        prefix = urlsplit(base).path
        ctx.route('https://%s/**' % host, file_route(prefix))
        ctx.route('https://analiz.teserix.com/**', net.umami_handler)
        ctx.route('https://kodhane-api.teserix.com/**', net.supabase_handler)
        ctx.route('https://supabase.teserix.com/**', net.supabase_handler)
        ctx.route('https://cdn.jsdelivr.net/**', lambda r: r.abort('connectionrefused'))
        ctx.route('https://acikofis.teserix.com/**', lambda r: r.fulfill(status=200, headers={'content-type': 'text/html'}, body='<title>Açık Ofis</title>'))
        ctx.on('request', net.on_request)
        if quiet:
            ctx.add_init_script('window.KODHANE_QUIET = true;')
        if init:
            ctx.add_init_script(init)
        return ctx

    def open_page(ctx, base, wait_until='load'):
        pg = ctx.new_page()
        pg.errs = []
        pg.on('pageerror', lambda e: pg.errs.append(str(e)))
        pg.on('console', lambda m: pg.errs.append(m.text) if m.type == 'error' and 'ERR_CONNECTION_REFUSED' not in m.text and 'net::' not in m.text else None)
        pg.goto(base, wait_until=wait_until)
        pg.wait_for_selector('#clickBtn')
        return pg

    def tel_state(pg):
        return pg.evaluate("""() => ({ notice: localStorage.getItem('kodhane_tel_notice'), pref: localStorage.getItem('kodhane_tel'),
            off: localStorage.getItem('umami.disabled'), band: !!document.querySelector('[data-test=tel-banner]'),
            script: !!document.querySelector('script[data-test=umami-script]') || !!document.querySelector('script[src*="analiz.teserix.com"]'),
            umami: typeof window.umami })""")

    def stats_tab(pg, mobile):
        if mobile:
            pg.click('#bottomNav button[data-view="upgrades"]')
        pg.click('.tabs button[data-tab="stats"]')
        pg.wait_for_selector('#telBtn', state='visible')

    # ================================================================ 1) [privacy-net] kök yol ve alt yol
    for label, base in BASES:
        host = urlsplit(base).hostname
        tag = '[privacy-net][%s]' % label

        # (a) bildirim yanıtlanmadan: hiçbir şey gitmez (yeniden yüklemede de)
        net = Net()
        ctx = new_ctx(base, net)
        pg = open_page(ctx, base)
        pg.wait_for_selector('[data-test=tel-banner]')
        check(tag + ' page served under the right path', pg.evaluate('location.pathname') == urlsplit(base).path and pg.evaluate("Kodhane.tel.hostOk()") is True, pg.evaluate('location.href'))
        pg.evaluate(INTERACT)
        pg.wait_for_timeout(4800)  # haber süresi (4 sn) geçer; bant varken haber açılmaz
        check(tag + ' (a) before the notice: no news over the band', pg.is_hidden('#modal') and pg.evaluate('Kodhane.newsSession.shown') == 0)
        pg.reload(); pg.wait_for_selector('[data-test=tel-banner]')
        pg.evaluate(INTERACT)
        pg.wait_for_timeout(600)
        c = net.counts(); st = tel_state(pg)
        check(tag + ' (a) before "Tamam" incl. reload: 0 Umami requests, 0 counter RPCs', c['umami'] == 0 and c['counter'] == 0, c)
        note('%s (a) counts: %s' % (tag, json.dumps(c)))
        check(tag + ' (a) no tracker script tag, window.umami undefined, notice still pending', not st['script'] and st['umami'] == 'undefined' and st['notice'] is None and st['band'], st)
        check(tag + ' (a) events dropped (not queued for later)', pg.evaluate('Kodhane.umamiQueue().length') == 0 and pg.evaluate('Kodhane.tracked.length') == 0)
        check(tag + ' (a) only game host requested', net.external(host) == [], net.external(host))
        check(tag + ' (a) no page errors', not pg.errs, pg.errs)

        # (b) Kapat -> hiçbir şey gitmez (haber gösterilse de, yeniden yüklemede de)
        pg.click('[data-test=tel-off]')
        pg.wait_for_timeout(300)
        st = tel_state(pg)
        check(tag + ' (b) "Kapat": band gone, pref off, umami.disabled set', not st['band'] and st['notice'] == '1' and st['pref'] == 'off' and st['off'], st)
        pg.evaluate(INTERACT)
        # haber artık açılabilir; gösterim/tıklama sayacı da kapalı olmalı
        try:
            pg.wait_for_function("!document.getElementById('modal').classList.contains('hidden')", timeout=6000)
            pg.click('#modalActions .btn.primary')
            news_seen = True
        except Exception:
            news_seen = False
        pg.wait_for_timeout(500)
        pg.goto(base); pg.wait_for_selector('#clickBtn')
        pg.evaluate(INTERACT)
        pg.wait_for_timeout(600)
        c = net.counts(); st = tel_state(pg)
        check(tag + ' (b) after "Kapat" incl. news shown/clicked + reload: 0 Umami requests, 0 counter RPCs', c['umami'] == 0 and c['counter'] == 0 and news_seen, [c, news_seen])
        note('%s (b) counts: %s (news shown+clicked while off: %s)' % (tag, json.dumps(c), news_seen))
        check(tag + ' (b) after reload: no band, no tracker script', not st['band'] and not st['script'] and st['umami'] == 'undefined', st)
        check(tag + ' (b) no page errors', not pg.errs, pg.errs)
        ctx.close()

        # (+) pozitif kontrol: Tamam -> betik, pageview, olaylar, sayaç RPC'si
        net = Net()
        ctx = new_ctx(base, net)
        pg = open_page(ctx, base)
        pg.wait_for_selector('[data-test=tel-banner]')
        check(tag + ' band accept button label is exactly "Tamam"', pg.inner_text('[data-test=tel-ok]').strip() == 'Tamam', pg.inner_text('[data-test=tel-ok]'))
        pg.click('[data-test=tel-ok]')
        pg.wait_for_function("typeof window.umami === 'object'", timeout=8000)
        pg.evaluate(INTERACT)
        try:
            pg.wait_for_function("!document.getElementById('modal').classList.contains('hidden')", timeout=6000)
            pg.click('#modalActions .btn.primary')
        except Exception:
            pass
        pg.wait_for_timeout(800)
        c_on = net.counts()
        sattr = pg.evaluate("(() => { const s = document.querySelector('script[data-test=umami-script]'); return s && { src: s.src, id: s.getAttribute('data-website-id'), domains: s.getAttribute('data-domains'), async: s.async }; })()")
        check(tag + ' (+) after "Tamam": tracker loaded (1 script), pageviews + events sent, counter RPCs sent',
              c_on['umami_script'] == 1 and c_on['umami_send'] >= 8 and c_on['counter'] >= 3, c_on)
        note('%s (+) counts after Tamam: %s' % (tag, json.dumps(c_on)))
        check(tag + ' (+) script attributes', sattr and sattr['src'] == 'https://analiz.teserix.com/script.js' and sattr['id'] == WEBSITE_ID
              and sattr['domains'] == 'kodhane.teserix.com,thejackaltr.github.io' and sattr['async'], sattr)

        # (c) İstatistik > Gizlilik'ten kapat (gerçek tık)
        stats_tab(pg, False)
        check(tag + ' (c) toggle label while on', pg.inner_text('#telBtn').strip().startswith('📊'), pg.inner_text('#telBtn'))
        pg.click('#telBtn'); pg.wait_for_timeout(300)
        st = tel_state(pg)
        check(tag + ' (c) switched off in İstatistik > Gizlilik: pref off, umami.disabled set', st['pref'] == 'off' and st['off'], st)
        c0 = net.counts()
        pg.evaluate(INTERACT)
        pg.wait_for_timeout(600)
        c1 = net.counts()
        check(tag + ' (c) after switching off: 0 new Umami requests, 0 new counter RPCs (events + pushState/replaceState/popstate)',
              c1['umami'] == c0['umami'] and c1['counter'] == c0['counter'], [c0, c1])
        note('%s (c) new requests after switch-off: umami=%d counter=%d' % (tag, c1['umami'] - c0['umami'], c1['counter'] - c0['counter']))

        # (d) kapalıyken yeniden yükleme
        pg.reload(); pg.wait_for_selector('#clickBtn')
        pg.evaluate(INTERACT)
        pg.wait_for_timeout(600)
        c2 = net.counts(); st = tel_state(pg)
        check(tag + ' (d) reload while off: 0 new Umami requests, 0 new counter RPCs, no script, no band',
              c2['umami'] == c0['umami'] and c2['counter'] == c0['counter'] and not st['script'] and not st['band'], [c0, c2, st])
        note('%s (d) new requests after reload while off: umami=%d counter=%d' % (tag, c2['umami'] - c0['umami'], c2['counter'] - c0['counter']))

        # yeniden aç -> kaldığı yerden sürer
        stats_tab(pg, False)
        pg.click('#telBtn')
        pg.wait_for_function("typeof window.umami === 'object'", timeout=8000)
        pg.evaluate(INTERACT)
        pg.wait_for_timeout(600)
        c3 = net.counts()
        check(tag + ' re-enable resumes (script loaded again, sends + counter RPC)', c3['umami_script'] == c2['umami_script'] + 1 and c3['umami_send'] > c2['umami_send'] and c3['counter'] > c2['counter'], [c2, c3])
        check(tag + ' only game host + intercepted mocks requested', net.external(host) == [], net.external(host))
        check(tag + ' no page errors', not pg.errs, pg.errs)
        ctx.close()

    # ================================================================ 2) Umami başarısız / 5 sn asılı: oyun çalışır
    base = BASES[0][1]
    for mode in ('fail', 'hold'):
        net = Net(umami=mode)
        ctx = new_ctx(base, net, quiet=True, init="localStorage.setItem('kodhane_tel_notice','1'); localStorage.setItem('kodhane_tel','on');")
        t0 = time.time()
        pg = open_page(ctx, base, wait_until='domcontentloaded')  # asılı async betik 'load'u geciktirir; oyun DOMContentLoaded'da açılır
        boot = time.time() - t0
        pg.click('#clickBtn'); pg.click('#clickBtn')
        pg.evaluate("Kodhane.shareText('x'); Kodhane.track('login_success')")
        if mode == 'hold':
            pg.wait_for_timeout(5000)
            check('umami hanging 5 s: game booted and playable meanwhile', boot < 5 and len(net.held) == 1 and pg.evaluate('Kodhane.state.clicks') == 2, [boot, len(net.held)])
            check('umami hanging: events queued (bounded) while loading', 0 < len(pg.evaluate('Kodhane.umamiQueue()')) <= 20, pg.evaluate('Kodhane.umamiQueue()'))
            net.held[0].abort('timedout')
            pg.wait_for_timeout(500)
            check('umami hanging then failing: queue cleared, game still works', pg.evaluate('Kodhane.umamiQueue().length') == 0 and (pg.click('#clickBtn') or pg.evaluate('Kodhane.state.clicks') == 3))
        else:
            pg.wait_for_timeout(500)
            check('umami failing: game works, track never throws, nothing queued', pg.evaluate('Kodhane.state.clicks') == 2 and pg.evaluate('Kodhane.umamiQueue().length') == 0
                  and pg.evaluate('typeof window.umami') == 'undefined')
        check('umami %s: no page errors' % mode, not pg.errs, pg.errs)
        ctx.close()

    # ================================================================ 3) yerleşim: bant yanıtlanmamışken hiçbir düğme örtülmez
    VIS = """(sel) => {
      const out = [];
      const els = typeof sel === 'string' ? Array.from(document.querySelectorAll(sel)) : sel;
      for (const el of els) {
        if (!el || el.offsetParent === null && getComputedStyle(el).position !== 'fixed') continue;
        const pos = getComputedStyle(el).position;
        if (pos !== 'fixed') el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
        const r = el.getBoundingClientRect();
        const vw = innerWidth, vh = innerHeight;
        const inside = r.width > 0 && r.height > 0 && r.left >= -0.5 && r.top >= -0.5 && r.right <= vw + 0.5 && r.bottom <= vh + 0.5;
        const pts = [[0.5, 0.5], [0.15, 0.2], [0.85, 0.2], [0.15, 0.8], [0.85, 0.8]];
        const bad = [];
        for (const [fx, fy] of pts) {
          const x = r.left + r.width * fx, y = r.top + r.height * fy;
          const hit = document.elementFromPoint(x, y);
          if (!hit || !(hit === el || el.contains(hit))) bad.push([Math.round(x), Math.round(y), hit ? (hit.id || hit.className || hit.tagName) : null]);
        }
        const name = el.id || el.dataset.test || el.dataset.view || el.dataset.tab || el.dataset.gen || el.dataset.upg || el.dataset.choice || el.textContent.trim().slice(0, 18);
        out.push({ name, inside, bad, r: [Math.round(r.left), Math.round(r.top), Math.round(r.right), Math.round(r.bottom)] });
      }
      return out;
    }"""

    def vis(pg, sel):
        return pg.evaluate(VIS, sel)

    def all_ok(rows):
        return [r for r in rows if not r['inside'] or r['bad']]

    for vname, vp in VIEWPORTS:
        mobile = vp.get('is_mobile', False)
        net = Net()
        ctx = new_ctx(base, net, vp=vp, quiet=True)
        pg = open_page(ctx, base)
        pg.wait_for_selector('[data-test=tel-banner]')
        pg.evaluate("Kodhane.state.money = 1e15; Kodhane.renderAll()")
        pg.wait_for_timeout(300)
        tagv = '[layout][%s]' % vname
        space = pg.evaluate("parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--nb-space')) || 0")
        band = pg.evaluate("document.querySelector('[data-test=tel-banner]').getBoundingClientRect().toJSON()")
        checked = []
        rows = vis(pg, '[data-test=tel-banner] button')
        checked += rows
        check(tagv + ' band buttons (Tamam, Kapat, Ayrıntılar) fully visible and on top', len(rows) == 3 and not all_ok(rows), rows)
        rows = vis(pg, '#accountBtn')
        checked += rows
        views = [('kod', '#clickBtn'), ('ekip', '.qty button, #genList .gen:not(.hidden)'), ('upgrades', '#upgList .upg, .tabs button')] if mobile else \
            [(None, '#clickBtn, .qty button, #genList .gen:not(.hidden), #upgList .upg, .tabs button')]
        for view, sel in views:
            if view:
                pg.click('#bottomNav button[data-view="%s"]' % view)
                pg.wait_for_timeout(250)
            rows = vis(pg, sel)
            checked += rows
            check(tagv + ' %s: %d targets fully visible, not under the band/nav' % (view or 'desktop', len(rows)), rows and not all_ok(rows), all_ok(rows) or len(rows))
        if mobile:
            rows = vis(pg, '#bottomNav button')
            checked += rows
            check(tagv + ' bottom nav: 6 buttons visible and on top', len(rows) == 6 and not all_ok(rows), all_ok(rows))
            pg.click('#bottomNav button[data-view="upgrades"]'); pg.wait_for_timeout(200)
        pg.click('.tabs button[data-tab="stats"]'); pg.wait_for_timeout(250)
        rows = vis(pg, '#telBtn, #telDetailsBtn, #soundBtn, #vibBtn, #resetBtn')
        checked += rows
        check(tagv + ' İstatistik > Gizlilik + settings buttons visible (guest, band unanswered)', len(rows) >= 4 and not all_ok(rows), all_ok(rows) or rows)
        # olay kartı, müşteri teklifi, geri al çubuğu
        if mobile:
            pg.click('#bottomNav button[data-view="kod"]'); pg.wait_for_timeout(200)
        pg.evaluate("Kodhane.spawnEvent()")
        pg.wait_for_timeout(450)
        rows = vis(pg, '#evChoices .ev-choice, #evLater')
        checked += rows
        check(tagv + ' event card choices + Sonra visible above the band', len(rows) >= 2 and not all_ok(rows), all_ok(rows) or rows)
        pg.click('#evLater'); pg.wait_for_timeout(300)
        check(tagv + ' event card: real click on Sonra works', pg.evaluate('Kodhane.eventState.visible') is False)
        pg.evaluate("Kodhane.spawnOffer()")
        pg.wait_for_timeout(400)
        rows = vis(pg, '#clientOffer')
        checked += rows
        check(tagv + ' client offer visible above the band', len(rows) == 1 and not all_ok(rows), rows)
        pg.click('#clientOffer'); pg.wait_for_timeout(200)
        pg.evaluate("(() => { const u = document.getElementById('undoBar'); u.classList.remove('hidden'); document.getElementById('undoText').textContent = 'Kayıt sıfırlandı.'; document.getElementById('undoBtn').textContent = 'Geri al (10)'; })()")
        pg.wait_for_timeout(200)
        rows = vis(pg, '#undoBtn')
        checked += rows
        check(tagv + ' undo bar button visible above the band', len(rows) == 1 and not all_ok(rows), rows)
        pg.locator('#undoBtn').click(trial=True)
        pg.evaluate("document.getElementById('undoBar').classList.add('hidden')")
        # gerçek tıklar
        c0 = pg.evaluate('Kodhane.state.clicks')
        pg.click('#clickBtn')
        check(tagv + ' real click on the code button', pg.evaluate('Kodhane.state.clicks') == c0 + 1)
        if mobile:
            pg.click('#bottomNav button[data-view="ekip"]'); pg.wait_for_timeout(200)
        g0 = pg.evaluate("document.querySelector('#genList .gen .gen-owned').textContent")
        pg.click('#genList .gen >> nth=0')
        check(tagv + ' real click on the first team buy button', pg.evaluate("document.querySelector('#genList .gen .gen-owned').textContent") != g0)
        if mobile:
            pg.click('#bottomNav button[data-view="upgrades"]'); pg.wait_for_timeout(200)
        n0 = pg.evaluate('Kodhane.state.upgrades.length')
        pg.click('.tabs button[data-tab="upgrades"]'); pg.click('#upgList .upg:not([disabled]) >> nth=0')
        check(tagv + ' real click on an upgrade button', pg.evaluate('Kodhane.state.upgrades.length') == n0 + 1)
        # Ayrıntılar bildirimi yanıtlamaz
        pg.click('[data-test=tel-details]')
        pg.wait_for_selector('.tel-details')
        check(tagv + ' details open from the band without answering the notice', pg.evaluate("localStorage.getItem('kodhane_tel_notice')") is None and pg.is_visible('[data-test=tel-details-close]'))
        pg.click('[data-test=tel-details-close]'); pg.wait_for_timeout(200)
        check(tagv + ' details closed, band still there', pg.is_hidden('#modal') and pg.is_visible('[data-test=tel-banner]'))
        page_w = pg.evaluate('document.documentElement.scrollWidth')
        check(tagv + ' no horizontal overflow with the band', page_w <= vp['viewport']['width'], page_w)
        pg.click('[data-test=tel-ok]'); pg.wait_for_timeout(300)
        check(tagv + ' real click on Tamam answers and removes the band + reserved space', not tel_state(pg)['band'] and tel_state(pg)['pref'] == 'on'
              and pg.evaluate("getComputedStyle(document.documentElement).getPropertyValue('--nb-space').trim()") in ('', '0px'))
        note('%s band rect=%s reserved=%spx, %d targets checked' % (tagv, {k: round(band[k]) for k in ('left', 'top', 'right', 'bottom')}, space, len(checked)))
        check(tagv + ' no page errors', not pg.errs, pg.errs)
        ctx.close()

    # ================================================================ 4) Gizlilik bölümü misafirken görünür + ekran görüntüleri
    for vname, vp in (VIEWPORTS[0], VIEWPORTS[2]):
        mobile = vp.get('is_mobile', False)
        net = Net()
        ctx = new_ctx(base, net, vp=vp, quiet=True)
        pg = open_page(ctx, base)
        pg.wait_for_selector('[data-test=tel-banner]')
        pg.wait_for_timeout(500)
        pg.screenshot(path=os.path.join(SHOTS, 'kodhane-band-%s.png' % vname))
        pg.click('[data-test=tel-details]'); pg.wait_for_selector('.tel-details'); pg.wait_for_timeout(400)
        pg.screenshot(path=os.path.join(SHOTS, 'kodhane-details-%s.png' % vname))
        dtext = pg.inner_text('#modal')
        pg.click('[data-test=tel-details-close]')
        check('[guest][%s] signed out (guest)' % vname, pg.evaluate("!(Kodhane.cloud && Kodhane.cloud.state && Kodhane.cloud.state.user)"))
        stats_tab(pg, mobile)
        pg.evaluate("document.getElementById('privacyBox').scrollIntoView({ block: 'center' })")
        pg.wait_for_timeout(300)
        box = pg.inner_text('#privacyBox')
        check('[guest][%s] Gizlilik section visible without login' % vname, pg.is_visible('#privacyBox') and pg.is_visible('#telBtn') and 'Gizlilik' in box, box)
        pg.screenshot(path=os.path.join(SHOTS, 'kodhane-privacy-guest-%s.png' % vname))
        pg.click('#telDetailsBtn'); pg.wait_for_selector('.tel-details')
        check('[guest][%s] details open from Gizlilik (same text), notice still pending' % vname, pg.inner_text('#modal') == dtext and pg.evaluate("localStorage.getItem('kodhane_tel_notice')") is None)
        pg.click('[data-test=tel-details-close]')
        check('[guest][%s] toggle shows "Kapalı" while the notice is unanswered (nothing runs yet)' % vname,
              pg.inner_text('#telBtn').strip() == '📊 İsimsiz sayaç: Kapalı' and pg.get_attribute('#telBtn', 'aria-pressed') == 'false', pg.inner_text('#telBtn'))
        check('[guest][%s] no requests to Umami/counter before any answer' % vname, net.counts()['umami'] == 0 and net.counts()['counter'] == 0, net.counts())
        pg.click('#telBtn'); pg.wait_for_timeout(400)
        st = tel_state(pg)
        check('[guest][%s] switching on in Gizlilik = explicit opt-in: answers the notice, band gone, tracker loads' % vname,
              st['pref'] == 'on' and st['notice'] == '1' and not st['band'] and st['script'] and pg.inner_text('#telBtn').strip() == '📊 İsimsiz sayaç: Açık', st)
        pg.click('#telBtn'); pg.wait_for_timeout(400)
        st = tel_state(pg)
        check('[guest][%s] switching off again in Gizlilik: pref off, umami.disabled' % vname, st['pref'] == 'off' and st['off'] and pg.inner_text('#telBtn').strip() == '📊 İsimsiz sayaç: Kapalı', st)
        pg.wait_for_timeout(2600)
        pg.evaluate("document.getElementById('privacyBox').scrollIntoView({ block: 'center' })")
        pg.screenshot(path=os.path.join(SHOTS, 'kodhane-privacy-guest-off-%s.png' % vname))
        ctx.close()

    # ================================================================ 5) [prefs] Yatırım turu ve Halka Arz (gerçek arayüz)
    for pref in ('off', 'on'):
        net = Net()
        ctx = new_ctx(base, net, quiet=True, init="if (!sessionStorage.getItem('s')) { sessionStorage.setItem('s','1'); localStorage.setItem('kodhane_tel_notice','1'); localStorage.setItem('kodhane_tel','%s'); }" % pref)
        pg = open_page(ctx, base)
        pg.evaluate("Kodhane.state.runEarned = 1e9; Kodhane.state.totalEarned = 1e9; Kodhane.renderAll()")
        pg.click('.tabs button[data-tab="prestige"]')
        pg.click('#prestigeBtn'); pg.click('#modalActions button:has-text("Anlaştık!")')
        pg.wait_for_timeout(200)
        st = tel_state(pg)
        check('[prefs] prestige (Yatırım turu via UI) keeps the choice (%s), no band' % pref, pg.evaluate('Kodhane.state.prestigeCount') == 1 and st['pref'] == pref and st['notice'] == '1' and not st['band'], st)
        pg.evaluate("Kodhane.state.cycleRounds = 3; Kodhane.state.cycleStage = 5; Kodhane.state.cycleEarned = 8e14; Kodhane.state.totalEarned = 9e14; Kodhane.state.runEarned = 1e9; Kodhane.renderAll()")
        pg.click('#ipoBtn'); pg.click('#modalActions button:has-text("Halka arz et")')
        pg.wait_for_timeout(200)
        pg.reload(); pg.wait_for_selector('#clickBtn')
        st = tel_state(pg)
        check('[prefs] Halka Arz via UI + reload keeps the choice (%s), no band' % pref, pg.evaluate('Kodhane.state.ipoCount') == 1 and st['pref'] == pref and not st['band'], st)
        c = net.counts()
        if pref == 'off':
            check('[prefs] off: prestige/IPO sent nothing (reset_or_prestige dropped)', c['umami'] == 0 and c['counter'] == 0, c)
        else:
            check('[prefs] on: prestige/IPO reset_or_prestige reached Umami', c['umami_send'] >= 3, c)
        ctx.close()
    b.close()

passed = sum(r[1] for r in results)
print('\nSUMMARY: %d/%d passed' % (passed, len(results)))
sys.exit(0 if passed == len(results) else 1)
