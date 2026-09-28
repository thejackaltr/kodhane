"""Kodhane v4.2 "Kaydı sıfırla" arayüz testleri (Playwright, headless Chromium). Supabase SAHTE: gerçek supabase-js,
REST/Auth uç noktaları route ile taklit edilir; kayıt tablosu ve RPC'ler Backend v2.2 sözleşmesine göre
(tests/fake_saves_v22.py; RPC adları cloud.js'teki RPC sabitinden). Ayrıca cloud.js'teki sahte sunucu taşıyıcısı (transport 'mock', localStorage +
BroadcastChannel) iki sekmeyle denenir. Gerçek sunucuya istek gitmez.
    python3 tests/test_reset_ui.py
Kapsam: basılı tutma onayı (fare, dokunma, Space/Enter; erken bırakma iptal; Space kod yazmaz; 44px; uzun basış menüsü),
metinler ({s}/{d}, misafir yedek/geri yükleme metni görmez), Yatırım turuna git, misafir Geri al (sayfa yenilendikten
sonra yerel kopyadan) ve süre dolunca kaybolması, girişli Geri al (kodhane_restore_save), Yedekten geri yükle, iki sekme / iki
cihaz: bayat yazma reddedilir, güncel kayıt + otherDevice (ve tersi).
Ekran görüntüsü: screenshots/v42-reset-dialog-mobile.png
"""
import functools
import json
import os
import re
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fake_saves_v22 import RPC, SaveStore  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = int(os.environ.get('KODHANE_RESET_PORT', '8768'))
URL = 'http://127.0.0.1:%d/index.html' % PORT
FAKE = 'https://kodhane-reset.supabase.co'
SAVE_KEY = 'kodhane_ajans_save_v2'
AUTH_KEY = 'kodhane_auth_v1'
SS = os.path.join(ROOT, 'screenshots') + os.sep
COPY = json.load(open(os.path.join(ROOT, 'tests', 'fixtures', 'kodhane-reset-copy.json'), encoding='utf-8'))
TEXT_SYNC = 'Oyuna başka bir cihazda ya da sekmede devam ettin. Güncel kayıt yüklendi.'  # geçici (copy dosyasında yok)
CLOUD_JS = open(os.path.join(ROOT, 'cloud.js'), encoding='utf-8').read()
SDK_URL = re.search(r"sdk: '([^']+)'", CLOUD_JS).group(1)
CACHE = os.path.join(ROOT, 'tests', '.cache')
os.makedirs(CACHE, exist_ok=True)
SDK_FILE = os.path.join(CACHE, os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(SDK_URL)))) + '.js')
if not os.path.exists(SDK_FILE):
    with urllib.request.urlopen(SDK_URL, timeout=60) as r:
        open(SDK_FILE, 'wb').write(r.read())
SDK_BYTES = open(SDK_FILE, 'rb').read()
RESTORE_SENTENCE = 'Yanlışlıkla olduysa yedeği geri yükleyebilirsin.'
GUEST_OTHER = 'Kaydın başka bir cihazda sıfırlandı. Bu cihazda da oyun baştan başlıyor.'
SIGNED_ONLY = [COPY['reset.backup'].split('{d}')[0], COPY['reset.restoreTitle'], COPY['reset.restoreBody'], COPY['reset.restoreDone'], RESTORE_SENTENCE]


class Quiet(SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(('127.0.0.1', PORT), functools.partial(Quiet, directory=ROOT))
threading.Thread(target=server.serve_forever, daemon=True).start()
results = []


def check(name, cond, info=''):
    results.append((name, bool(cond)))
    print(('PASS' if cond else 'FAIL'), name, '' if cond else info)


import base64  # noqa: E402
import uuid  # noqa: E402


def b64u(o):
    return base64.urlsafe_b64encode(json.dumps(o).encode()).rstrip(b'=').decode()


def session_obj(uid, email):
    now = int(time.time())
    tok = b64u({'alg': 'HS256', 'typ': 'JWT'}) + '.' + b64u({'sub': uid, 'email': email, 'role': 'authenticated', 'aud': 'authenticated',
                                                            'iat': now, 'exp': now + 3600, 'session_id': 's-' + uid}) + '.c2ln'
    user = {'id': uid, 'aud': 'authenticated', 'role': 'authenticated', 'email': email, 'email_confirmed_at': '2026-09-27T10:00:00Z',
            'app_metadata': {'provider': 'email'}, 'user_metadata': {}, 'created_at': '2026-09-27T10:00:00Z'}
    return {'access_token': tok, 'refresh_token': 'rt-' + uid, 'token_type': 'bearer', 'expires_in': 3600, 'expires_at': now + 3600, 'user': user}


def claims_of(h):
    try:
        pl = h.split(' ', 1)[1].split('.')[1]
        pl += '=' * (-len(pl) % 4)
        d = json.loads(base64.urlsafe_b64decode(pl))
        return d if d.get('role') == 'authenticated' else None
    except Exception:
        return None


CORS = {'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': 'GET,POST,PATCH,DELETE,OPTIONS',
        'access-control-expose-headers': '*'}


class FakeSB:
    def __init__(self):
        self.rows = {}
        self.saves = SaveStore()
        self.saves.rows = self.rows
        self.log = []
        self.stale = []   # 409 yanıtları: (uid, message)
        self.last_post = None  # (Prefer, select) of the last save POST

    def reply(self, route, status, body=None):
        route.fulfill(status=status, headers=dict(CORS, **{'content-type': 'application/json'}), body='' if body is None else json.dumps(body))

    def handle(self, route):
        req = route.request
        u = urllib.parse.urlparse(req.url)
        if req.method == 'OPTIONS':
            return route.fulfill(status=204, headers=CORS, body='')
        self.log.append((req.method, u.path))
        c = claims_of(req.headers.get('authorization', ''))
        uid = c['sub'] if c else None
        if u.path == '/auth/v1/user':
            return self.reply(route, 200, session_obj(uid, c.get('email'))['user']) if c else self.reply(route, 401, {'msg': 'invalid JWT'})
        if u.path in ('/auth/v1/logout', '/auth/v1/token'):
            return self.reply(route, 400, {'error': 'invalid_grant'})
        if u.path.startswith('/rest/v1/rpc/'):
            name = u.path.rsplit('/', 1)[1]
            if name == 'kodhane_leaderboard':
                return self.reply(route, 200, [])
            if name == 'kodhane_count_event':
                return self.reply(route, 200, True)
            st, body = self.saves.rpc(uid, name, json.loads(req.post_data or '{}'))
            return self.reply(route, st, body)
        if u.path == '/rest/v1/kodhane_profiles':
            return self.reply(route, 200, [])
        if u.path == '/rest/v1/kodhane_saves':
            if not uid:
                return self.reply(route, 401, {'message': 'JWT required'})
            if req.method == 'GET':
                q = urllib.parse.parse_qs(u.query)
                sel = (q.get('select') or ['*'])[0].split(',')
                rows = [dict(self.rows[uid], user_id=uid)] if uid in self.rows else []
                if sel != ['*']:
                    rows = [{k.strip(): r.get(k.strip()) for k in sel} for r in rows]
                return self.reply(route, 200, rows)
            if req.method == 'POST':
                body = json.loads(req.post_data or '{}')
                q = urllib.parse.parse_qs(u.query)
                out = None
                for it in (body if isinstance(body, list) else [body]):
                    st, eb = self.saves.write(uid, it)
                    if st != 201:
                        if st == 409:
                            self.stale.append((uid, eb['message']))
                        return self.reply(route, st, eb)
                    out = eb
                prefer = (req.headers.get('prefer') or '')
                sel = (q.get('select') or [''])[0]
                self.last_post = (prefer, sel)
                if 'return=representation' in prefer and 'revision' in sel and out and 'revision' in out:
                    return self.reply(route, 201, [out])  # PostgREST: representation always an array; maybeSingle unwraps
                return route.fulfill(status=201, headers=CORS, body='')
            if req.method == 'DELETE':
                return self.reply(route, 403, {'code': '42501', 'message': 'permission denied for table kodhane_saves'})
        return self.reply(route, 404, {'message': 'not found'})


def seed_save(clicks=40, total=4000.0):
    now = int(time.time() * 1000)
    yday = time.strftime('%Y-%m-%d', time.localtime(time.time() - 86400))  # dün tamamlanmış: seri 4 yüklemede korunur
    return {'version': 4, 'money': 250.0, 'runEarned': total, 'totalEarned': total, 'cycleEarned': total, 'clicks': clicks, 'clickEarned': clicks,
            'playTime': 900, 'startedAt': now - 86400000, 'lastSaved': now,
            'gens': {'stajyer': 4, 'junior': 1}, 'upgrades': [], 'shares': 3, 'prestigeCount': 1, 'cycleRounds': 1, 'achievements': ['tik_1'],
            'reputation': 12, 'daily': {'date': None, 'tasks': [], 'streak': 4, 'best': 6, 'lastComplete': yday, 'allDone': False, 'daysCompleted': 5},
            'newsSeen': ['siralama', 'acik_ofis', 'yeni_asama']}


# yüklemede açılan başarımlar (tik_1 tohumda; diğerleri 4000 ₺ / görev / seri / yatırımdan otomatik açılır)
PRE_ACH = {'tik_1', 'kazanc_1k', 'seri_3', 'yatirim_1'}

UID, EMAIL = str(uuid.uuid5(uuid.NAMESPACE_DNS, 'reset@example.com')), 'reset@example.com'

with sync_playwright() as p:
    b = p.chromium.launch()

    def new_ctx(fake=None, save=None, signed=False, transport=None, undo=None, mobile=False):
        opts = dict(locale='tr-TR', service_workers='block')
        opts.update(dict(viewport={'width': 390, 'height': 844}, device_scale_factor=2, is_mobile=True, has_touch=True) if mobile
                    else dict(viewport={'width': 1280, 'height': 800}))
        ctx = b.new_context(**opts)
        cfg = {'url': FAKE, 'key': 'sb_publishable_test_key'}
        if transport:
            cfg['transport'] = transport
        init = 'window.KODHANE_QUIET = true; window.KODHANE_CLOUD_CONFIG = %s;' % json.dumps(cfg)
        if undo is not None:
            init += 'window.KODHANE_CFG_OVERRIDE = { reset: { undoSeconds: %d } };' % undo
        seed = ["(() => { if (localStorage.getItem('kh_seeded')) return; localStorage.setItem('kh_seeded','1');"]
        if save is not None:
            seed.append('localStorage.setItem(%s, %s);' % (json.dumps(SAVE_KEY), json.dumps(json.dumps(save))))
        if signed:
            seed.append('localStorage.setItem(%s, %s);' % (json.dumps(AUTH_KEY), json.dumps(json.dumps(session_obj(UID, EMAIL)))))
        seed.append('})();')
        ctx.add_init_script(init + ''.join(seed))
        f = fake or FakeSB()
        ctx.route(FAKE + '/**', f.handle)
        ctx.route('https://supabase.teserix.com/**', lambda r: r.abort('connectionrefused'))
        ctx.route('https://cdn.jsdelivr.net/**', lambda r: r.fulfill(status=200, headers={'content-type': 'application/javascript', 'access-control-allow-origin': '*'}, body=SDK_BYTES))
        return ctx

    def open_page(ctx):
        pg = ctx.new_page()
        pg.errs = []
        pg.toasts = []
        pg.on('console', lambda m: pg.errs.append(m.text) if m.type == 'error' and 'status of 409' not in m.text and 'ERR_CONNECTION_REFUSED' not in m.text else None)
        pg.on('pageerror', lambda e: pg.errs.append(str(e)))
        pg.goto(URL)
        pg.wait_for_selector('#clickBtn')
        pg.evaluate("""() => { window.__toasts = []; new MutationObserver(ms => ms.forEach(m => m.addedNodes.forEach(n => window.__toasts.push(n.textContent))))
                           .observe(document.getElementById('toast'), { childList: true }); }""")
        return pg

    def toasts(pg):
        return pg.evaluate('window.__toasts || []')

    def ev(pg, js):
        return pg.evaluate(js)

    def wait_js(pg, js, ms=10000):
        try:
            pg.wait_for_function(js, timeout=ms)
            return True
        except Exception:
            return False

    def open_dialog(pg):
        if ev(pg, "document.getElementById('tab-stats').classList.contains('hidden')"):
            ev(pg, "Kodhane.selectTab('stats')")
        pg.click('#resetBtn')
        pg.wait_for_selector('#resetHold')
        pg.wait_for_timeout(400)  # açılış animasyonu bitsin (düğme yerinde dursun)

    def mouse_hold(pg, ms):
        pg.hover('#resetHold')
        pg.mouse.down()
        pg.wait_for_timeout(ms)
        pg.mouse.up()

    def hold_reset(pg):
        try:
            with pg.expect_navigation(timeout=20000):
                mouse_hold(pg, 2300)
        except Exception:
            print('hold_reset: no reload; lastResetError=%r toasts=%r' % (ev(pg, 'Kodhane.lastResetError'), toasts(pg)))
            raise
        pg.wait_for_selector('#clickBtn')
        pg.evaluate("""() => { window.__toasts = []; new MutationObserver(ms => ms.forEach(m => m.addedNodes.forEach(n => window.__toasts.push(n.textContent))))
                           .observe(document.getElementById('toast'), { childList: true }); }""")

    # ================================================================ 1) misafir: pencere, metinler, basılı tutma
    ctx = new_ctx(save=seed_save())
    pg = open_page(ctx)
    open_dialog(pg)
    txt = pg.inner_text('#modal')
    check('guest dialog: title/body/lists/hint from copy', COPY['reset.title'] in txt and COPY['reset.body'] in txt and COPY['reset.deleteTitle'] in txt
          and all(x in txt for x in COPY['reset.deleteList'] + COPY['reset.keepList']) and COPY['reset.prestigeHint'] in txt, txt)
    check('guest dialog: prestige button + cancel + hold button', pg.inner_text('#resetPrestige') == COPY['reset.prestigeBtn'] and
          COPY['reset.cancel'] in pg.inner_text('#modalActions') and pg.inner_text('#resetHold') == COPY['reset.hold'])
    check('guest dialog: no backup/restore texts', not any(x in txt for x in SIGNED_ONLY) and pg.is_hidden('#restoreBox'), txt)
    pg.wait_for_timeout(400)  # açılış animasyonu (pop, scale) bitsin
    bb = pg.locator('#resetHold').bounding_box()
    check('hold button: >= 44px touch target', bb['height'] >= 44 and bb['width'] >= 44, bb)
    css = ev(pg, "(() => { const s = getComputedStyle(document.getElementById('resetHold')); return [s.userSelect || s.webkitUserSelect, s.touchAction, s.webkitTouchCallout || '']; })()")
    check('hold button: no text selection / touch-action none / no callout', css[0] == 'none' and css[1] == 'none', css)
    check('hold button: long-press context menu prevented', ev(pg, "(() => { const e = new MouseEvent('contextmenu', {bubbles:true, cancelable:true}); document.getElementById('resetHold').dispatchEvent(e); return e.defaultPrevented; })()"))
    check('hold button is red (danger)', 'danger' in pg.get_attribute('#resetHold', 'class'))
    # tek tık / kısa basış iptal
    pg.click('#resetHold'); pg.wait_for_timeout(300)
    check('single click does nothing', not pg.is_hidden('#modal') and ev(pg, 'Kodhane.state.clicks') == 40)
    pg.hover('#resetHold'); pg.mouse.down(); pg.wait_for_timeout(700)
    mid = ev(pg, "[document.querySelector('#resetHold .hold-label').textContent, document.querySelector('#resetHold .hold-fill').style.transform]")
    pg.mouse.up(); pg.wait_for_timeout(1800)
    after = ev(pg, "[document.querySelector('#resetHold .hold-label').textContent, document.querySelector('#resetHold .hold-fill').style.transform]")
    m = re.match(r'scaleX\(([\d.]+)\)', mid[1] or '')
    check('while holding: holding text + partial fill, no numeric countdown', mid[0] == COPY['reset.holding'] and m and 0.1 < float(m.group(1)) < 0.9 and not re.search(r'\d', mid[0]), mid)
    check('early release cancels (label back, fill 0, no reset)', after[0] == COPY['reset.hold'] and after[1] == 'scaleX(0)' and ev(pg, 'Kodhane.state.clicks') == 40
          and not pg.is_hidden('#modal'), after)
    # klavye: Space basılı tutma kod yazmaz; erken bırakma iptal
    pg.focus('#resetHold')
    c0 = ev(pg, 'Kodhane.state.clicks')
    pg.keyboard.down(' '); pg.wait_for_timeout(600)
    kmid = ev(pg, "document.querySelector('#resetHold .hold-label').textContent")
    pg.keyboard.up(' '); pg.wait_for_timeout(300)
    check('Space hold starts the fill and does not write code (global Space handler)', kmid == COPY['reset.holding'] and ev(pg, 'Kodhane.state.clicks') == c0, kmid)
    check('Space early release cancels', ev(pg, "document.querySelector('#resetHold .hold-label').textContent") == COPY['reset.hold'] and not pg.is_hidden('#modal'))
    pg.focus('#resetHold'); pg.keyboard.down('Enter'); pg.wait_for_timeout(500); pg.keyboard.up('Enter'); pg.wait_for_timeout(200)
    check('Enter early release cancels (no native click reset)', not pg.is_hidden('#modal') and ev(pg, 'Kodhane.state.clicks') == c0)
    # Yatırım turuna git
    pg.click('#resetPrestige'); pg.wait_for_timeout(200)
    check('prestige button closes dialog and opens the investment round tab', pg.is_hidden('#modal') and not pg.is_hidden('#tab-prestige') and ev(pg, 'Kodhane.activeTab()') == 'prestige')
    # Space basılı tutarak tam sıfırlama
    open_dialog(pg)
    pg.focus('#resetHold')
    with pg.expect_navigation(timeout=20000):
        pg.keyboard.down(' '); pg.wait_for_timeout(2300); pg.keyboard.up(' ')
    pg.wait_for_selector('#clickBtn')
    st = ev(pg, 'Kodhane.state')
    check('keyboard (Space) hold resets the save', st['clicks'] == 0 and st['achievements'] == [] and st['reputation'] == 0 and st['daily']['streak'] == 0 and st['shares'] == 0)
    check('settings kept after reset (separate key)', ev(pg, "localStorage.getItem('kodhane_ayarlar_v1') === null || typeof JSON.parse(localStorage.getItem('kodhane_ayarlar_v1')).sound === 'boolean'"))
    # misafir Geri al (sayfa yeniden açıldı; yerel kopyadan)
    check('guest: undo bar after reload with done text and countdown from config',
          not pg.is_hidden('#undoBar') and pg.inner_text('#undoText') == COPY['reset.done'] and re.fullmatch(r'Geri al \((10|9)\)', pg.inner_text('#undoBtn')), pg.inner_text('#undoBtn'))
    check('guest: undo bar has no backup/restore text', not any(x in pg.inner_text('#undoBar') for x in SIGNED_ONLY))
    pg.evaluate("""() => { window.__toasts = []; new MutationObserver(ms => ms.forEach(m => m.addedNodes.forEach(n => window.__toasts.push(n.textContent))))
                       .observe(document.getElementById('toast'), { childList: true }); }""")
    pg.click('#undoBtn'); pg.wait_for_timeout(400)
    st = ev(pg, 'Kodhane.state')
    check('guest undo restores the pre-reset save from the local snapshot', st['clicks'] == 40 and PRE_ACH <= set(st['achievements']) and st['reputation'] == 12
          and st['daily']['streak'] == 4 and st['shares'] == 3 and ev(pg, 'Kodhane.lastUndo') == 'local', json.dumps({k: st[k] for k in ('clicks', 'reputation', 'shares', 'achievements')} | {'streak': st['daily']['streak']}))
    check('guest undo: toast undoDone, bar hidden, snapshot cleared', any(COPY['reset.undoDone'] in t for t in toasts(pg)) and pg.is_hidden('#undoBar')
          and ev(pg, "sessionStorage.getItem('kodhane_reset_undo')") is None, toasts(pg))
    ev(pg, 'Kodhane.save()')
    check('guest undo persisted in localStorage (new epoch)', json.loads(ev(pg, "localStorage.getItem('%s')" % SAVE_KEY))['clicks'] == 40
          and ev(pg, "Number(localStorage.getItem('kodhane_save_epoch'))") == ev(pg, 'Kodhane.meta.epoch'))
    pg.reload(); pg.wait_for_selector('#clickBtn')
    check('guest undo survives reload; no second undo bar', ev(pg, 'Kodhane.state.clicks') == 40 and pg.is_hidden('#undoBar'))
    check('guest: no page errors', not pg.errs, pg.errs)
    ctx.close()

    # ================================================================ 2) misafir: Geri al {s} sn sonra kaybolur ({s} ayardan)
    ctx = new_ctx(save=seed_save(), undo=2)
    pg = open_page(ctx)
    open_dialog(pg)
    hold_reset(pg)
    check('undo label uses config seconds ({s} = 2)', pg.inner_text('#undoBtn') in ('Geri al (2)', 'Geri al (1)'), pg.inner_text('#undoBtn'))
    pg.wait_for_timeout(2600)
    check('undo gone after {s} seconds (bar hidden, snapshot cleared)', pg.is_hidden('#undoBar') and ev(pg, "sessionStorage.getItem('kodhane_reset_undo')") is None)
    pg.reload(); pg.wait_for_selector('#clickBtn')
    check('no undo after expiry + reload', pg.is_hidden('#undoBar') and ev(pg, 'Kodhane.state.clicks') == 0)
    ctx.close()

    # ================================================================ 3) misafir: iki sekme (aynı depolama)
    ctx = new_ctx(save=seed_save())
    A = open_page(ctx); B = open_page(ctx)
    check('two tabs loaded the same save', ev(A, 'Kodhane.state.clicks') == 40 and ev(B, 'Kodhane.state.clicks') == 40)
    open_dialog(A); hold_reset(A)
    wait_js(B, "Kodhane.lastAdopt === 'otherDevice'", 5000)
    ev(B, 'Kodhane.state.clicks += 99; Kodhane.save()')  # B'nin (artık güncel) yazması
    st_b = ev(B, 'Kodhane.state')
    check('tab A reset -> tab B stale write rejected, B loads the current save', st_b['clicks'] == 99 and not (PRE_ACH & set(st_b['achievements']) - {'tik_1'}) and st_b['reputation'] == 0 and ev(B, 'Kodhane.lastAdopt') == 'otherDevice',
          ev(B, 'Kodhane.lastAdopt'))
    check('tab B shows guest otherDevice text (no restore sentence)', any(GUEST_OTHER in t and RESTORE_SENTENCE not in t for t in toasts(B)), toasts(B))
    check('reset not overwritten by tab B (no pre-reset data in storage)', json.loads(ev(A, "localStorage.getItem('%s')" % SAVE_KEY))['totalEarned'] < 4000)
    # v4.2 tek yazan sekme: son etkileşilen (A) yazar, B duraklar; B gerçek girdiyle yazıcı olur ve A'nın kaydını devralır
    check('single writer: last-interacted tab A writes, B paused', ev(A, 'Kodhane.tabGate.isWriter()') is True and ev(B, 'Kodhane.tabGate.isWriter()') is False)
    ev(B, 'Kodhane.earn(1e6); Kodhane.save()')
    check('background tab B does not write localStorage', json.loads(ev(A, "localStorage.getItem('%s')" % SAVE_KEY))['totalEarned'] < 4000)
    B.mouse.click(3, 3)
    wait_js(B, 'Kodhane.tabGate.isWriter()', 3000)
    check('B becomes writer on real input and takes over the stored save (unsaved background progress dropped)',
          ev(B, 'Kodhane.tabGate.isWriter()') is True and ev(A, 'Kodhane.tabGate.isWriter()') is False and ev(B, 'Kodhane.state.totalEarned') < 4000)
    # tersi: B sıfırlar, A bayat
    ev(A, 'Kodhane.state.clicks = 7; Kodhane.save()'); ev(B, 'Kodhane.state.clicks = 7; Kodhane.save()')
    ev(A, "Kodhane.earn(5000); Kodhane.save()")
    B.reload(); B.wait_for_selector('#clickBtn')
    B.evaluate("""() => { window.__toasts = []; new MutationObserver(ms => ms.forEach(m => m.addedNodes.forEach(n => window.__toasts.push(n.textContent))))
                       .observe(document.getElementById('toast'), { childList: true }); }""")
    A.evaluate("() => { window.__toasts = []; }")
    open_dialog(B); hold_reset(B)
    wait_js(A, "Kodhane.state.totalEarned === 0", 5000)
    check('reverse: tab B reset -> tab A stale, loads current + guest otherDevice', ev(A, 'Kodhane.state.totalEarned') == 0 and any(GUEST_OTHER in t for t in toasts(A)), toasts(A))
    check('reverse: tab A undo bar (from its earlier reset) is gone', A.is_hidden('#undoBar'))
    check('two guest tabs: no page errors', not A.errs and not B.errs, A.errs + B.errs)
    ctx.close()

    # ================================================================ 4) girişli (gerçek Supabase taşıyıcısı + v2.2 sahte sunucu)
    fake = FakeSB()
    ctx = new_ctx(fake, save=seed_save(clicks=30, total=3000.0), signed=True)
    pg = open_page(ctx)
    check('signed in: reconciled, first write carries revision 1', wait_js(pg, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0') and fake.rows[UID]['revision'] == 1)
    check('push uses Prefer return=representation + select=revision; local revision = server returned',
          fake.last_post is not None and 'return=representation' in fake.last_post[0] and fake.last_post[1] == 'revision'
          and ev(pg, 'Kodhane.cloud.state.rev') == fake.rows[UID]['revision'], [fake.last_post, ev(pg, 'Kodhane.cloud.state.rev')])
    ev(pg, "Kodhane.selectTab('stats')"); pg.wait_for_timeout(500)
    check('signed in, no backup yet: restore row hidden (list RPC called)', pg.is_hidden('#restoreBox') and any(n == RPC['listBackups'] for n, _ in fake.saves.rpc_log))
    open_dialog(pg)
    txt = pg.inner_text('#modal')
    check('signed-in dialog shows backup text with {d} from config (30)', COPY['reset.backup'].replace('{d}', '30') in txt, txt)
    hold_reset(pg)
    check('signed-in reset: kodhane_reset_save RPC (constant, no params), no DELETE', RPC['reset'] == 'kodhane_reset_save' and (RPC['reset'], {}) in fake.saves.rpc_log and ('DELETE', '/rest/v1/kodhane_saves') not in fake.log)
    wait_js(pg, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0')
    row = fake.rows[UID]
    check('signed-in reset: row kept (fresh data, revision advanced, best_score kept, backup on server)',
          row['data']['clicks'] == 0 and row['revision'] >= 3 and row['best_score'] >= 3000 and fake.saves.backups[0]['reason'] == 'reset', json.dumps({k: row[k] for k in ('revision', 'best_score')}))
    check('signed-in: undo bar visible', not pg.is_hidden('#undoBar') and pg.inner_text('#undoText') == COPY['reset.done'])
    pg.click('#undoBtn')
    wait_js(pg, "Kodhane.lastUndo", 8000)
    st = ev(pg, 'Kodhane.state')
    check('signed-in undo uses kodhane_restore_save RPC with the backup id', ev(pg, 'Kodhane.lastUndo') == 'cloud' and RPC['restore'] == 'kodhane_restore_save' and (RPC['restore'], {'p_backup_id': fake.saves.backups[0]['id']}) in fake.saves.rpc_log)
    check('signed-in undo restores the save (achievements, reputation, streak back)', st['clicks'] == 30 and PRE_ACH <= set(st['achievements']) and st['reputation'] == 12 and st['daily']['streak'] == 4,
          json.dumps({k: st[k] for k in ('clicks', 'reputation', 'achievements')} | {'streak': st['daily']['streak']}))
    check('signed-in undo: server row = restored payload', fake.rows[UID]['data']['clicks'] == 30)
    pg.wait_for_timeout(300)
    check('signed-in undo: toast undoDone', any(COPY['reset.undoDone'] in t for t in toasts(pg)), toasts(pg))
    ev(pg, 'Kodhane.state.clicks += 1'); ok = ev(pg, 'Kodhane.cloud.push(true)')
    check('after undo writes continue (revision in sync)', ok is True and fake.rows[UID]['data']['clicks'] == 31)
    ev(pg, "Kodhane.selectTab('stats')"); pg.wait_for_timeout(500)
    check('after undo no restore box (newest backup is the restore point)', pg.is_hidden('#restoreBox'))
    check('signed-in: no page errors', not pg.errs, pg.errs)
    ctx.close()

    # ================================================================ 5) girişli: Geri al süresi dolar -> Yedekten geri yükle
    fake = FakeSB()
    ctx = new_ctx(fake, save=seed_save(clicks=25, total=2500.0), signed=True, undo=2)
    pg = open_page(ctx)
    wait_js(pg, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0')
    open_dialog(pg); hold_reset(pg)
    pg.wait_for_timeout(2600)
    check('signed-in undo gone after {s}', pg.is_hidden('#undoBar'))
    wait_js(pg, 'Kodhane.cloud.state.reconciled')
    ev(pg, "Kodhane.selectTab('stats')")
    wait_js(pg, "!document.getElementById('restoreBox').classList.contains('hidden')", 5000)
    box = pg.inner_text('#restoreBox')
    check('restore box (signed in): title, body, backup note, button', COPY['reset.restoreTitle'] in box and COPY['reset.restoreBody'] in box
          and COPY['reset.backup'].replace('{d}', '30') in box and COPY['reset.restoreBtn'] in box, box)
    pg.click('#restoreBtn'); pg.wait_for_timeout(200)
    check('restore confirm dialog', pg.inner_text('#modalTitle') == COPY['reset.restoreTitle'] and COPY['reset.restoreBody'] in pg.inner_text('#modal'))
    pg.click('#modalActions .btn.primary')
    wait_js(pg, 'Kodhane.state.clicks === 25', 8000)
    pg.wait_for_timeout(300)
    check('restore from backup: state back + toast restoreDone', ev(pg, 'Kodhane.state.clicks') == 25 and any(COPY['reset.restoreDone'] in t for t in toasts(pg)), toasts(pg))
    ctx.close()

    # ================================================================ 6) iki cihaz (ayrı depolama, aynı sunucu): bayat yazma 409 -> güncel kayıt + otherDevice
    fake = FakeSB()
    ctxA = new_ctx(fake, save=seed_save(clicks=50, total=5000.0), signed=True)
    A = open_page(ctxA)
    wait_js(A, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0')
    ctxB = new_ctx(fake, signed=True)
    B = open_page(ctxB)
    wait_js(B, 'Kodhane.cloud.state.reconciled && Kodhane.state.clicks === 50')
    check('device B loaded the cloud save', ev(B, 'Kodhane.state.clicks') == 50)
    open_dialog(A); hold_reset(A)
    wait_js(A, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0')
    n409 = len(fake.stale)
    ev(B, 'Kodhane.state.clicks += 5'); ev(B, 'Kodhane.cloud.push(true)')
    wait_js(B, "Kodhane.state.clicks === 0", 8000)
    check('device B stale write rejected by server (409 PT409 stale_revision)', len(fake.stale) > n409 and fake.stale[-1][1] == 'stale_revision', fake.stale)
    check('device B loads current (reset) save', ev(B, 'Kodhane.state.clicks') == 0 and ev(B, 'Kodhane.state.achievements') == [])
    B.wait_for_timeout(300)
    check('device B shows otherDevice with restore sentence (signed in)', any(COPY['reset.otherDevice'] in t for t in toasts(B)), toasts(B))
    check('reset-caused 409 -> kind reset (startedAt newer)', ev(B, 'Kodhane.lastAdoptKind') == 'reset', ev(B, 'Kodhane.lastAdoptKind'))
    check('server row not overwritten by B', fake.rows[UID]['data']['clicks'] == 0)
    # 409 -> kayıt bir kez yüklendi, gerçek girdiye kadar push yok
    check('after 409: B held (loaded once, no push until real input)', ev(B, 'Kodhane.cloud.state.held') is True)
    n_post = sum(1 for m, pth in fake.log if m == 'POST' and pth == '/rest/v1/kodhane_saves')
    r = ev(B, 'Kodhane.state.clicks = 3; Kodhane.cloud.push(true)')
    check('held: push refused, no request sent', r is False and sum(1 for m, pth in fake.log if m == 'POST' and pth == '/rest/v1/kodhane_saves') == n_post)
    B.mouse.click(3, 3)
    check('real input releases the hold', ev(B, 'Kodhane.cloud.state.held') is False)
    ev(B, 'Kodhane.state.clicks = 3'); ok = ev(B, 'Kodhane.cloud.push(true)')
    check('device B writes again after reconcile + input', ok is True and fake.rows[UID]['data']['clicks'] == 3)
    # tersi
    A.wait_for_timeout(200)
    open_dialog(B); hold_reset(B)
    wait_js(B, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0')
    A.evaluate("() => { window.__toasts = []; }")
    ev(A, 'Kodhane.state.clicks = 77; Kodhane.earn(1e6)'); ev(A, 'Kodhane.cloud.push(true)')
    wait_js(A, "Kodhane.state.clicks === 0", 8000)
    A.wait_for_timeout(300)
    check('reverse: device A stale -> current save + otherDevice', ev(A, 'Kodhane.state.clicks') == 0 and any(COPY['reset.otherDevice'] in t for t in toasts(A))
          and fake.rows[UID]['data']['clicks'] == 0, toasts(A))
    # eşzamanlı oyun (sıfırlama yok): A ilerleme yazar, B bayat -> genel senkron metni (geçici otherDeviceSync)
    A.mouse.click(3, 3)
    ev(A, 'Kodhane.state.clicks = 11'); ok = ev(A, 'Kodhane.cloud.push(true)')
    check('A (current after reload of the row) writes progress', ok is True and fake.rows[UID]['data']['clicks'] == 11)
    B.evaluate("() => { window.__toasts = []; }")
    ev(B, 'Kodhane.state.clicks = 12; Kodhane.cloud.push(true)')
    wait_js(B, "Kodhane.lastAdoptKind === 'sync'", 8000)
    B.wait_for_timeout(300)
    check('concurrent-play 409 -> generic sync text (not the reset text)', ev(B, 'Kodhane.lastAdoptKind') == 'sync' and ev(B, 'Kodhane.state.clicks') == 11
          and any(TEXT_SYNC in t for t in toasts(B)) and not any(COPY['reset.otherDevice'] in t for t in toasts(B)), [ev(B, 'Kodhane.lastAdoptKind'), toasts(B)])
    check('server kept A progress (no overwrite by stale B)', fake.rows[UID]['data']['clicks'] == 11)
    check('best_score never decreased on the server across resets / stale loads', fake.rows[UID]['best_score'] >= 5000, fake.rows[UID].get('best_score'))
    check('two devices: no page errors', not A.errs and not B.errs, A.errs + B.errs)
    ctxA.close(); ctxB.close()

    # ================================================================ 7) iki sekme, girişli, sahte sunucu taşıyıcısı (transport 'mock')
    fake = FakeSB()
    ctx = new_ctx(fake, save=seed_save(clicks=60, total=6000.0), signed=True, transport='mock', undo=30)  # yük altında 10 sn yetmeyebilir
    A = open_page(ctx)
    wait_js(A, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0')
    B = open_page(ctx)
    wait_js(B, 'Kodhane.cloud.state.reconciled')
    mockrow = lambda pg: ev(pg, "(JSON.parse(localStorage.getItem('kodhane_save_mock_v1')).rows['kodhane:%s'] || {})" % UID)
    check('mock transport: writes go to the mock (not the REST table)', mockrow(A).get('revision', 0) >= 1 and UID not in fake.rows)
    open_dialog(A); hold_reset(A)
    wait_js(B, "Kodhane.state.clicks === 0", 8000)
    B.wait_for_timeout(300)
    check('mock: tab A reset -> tab B loads current + otherDevice (with restore sentence)', ev(B, 'Kodhane.state.clicks') == 0 and any(COPY['reset.otherDevice'] in t for t in toasts(B)), toasts(B))
    wait_js(A, 'Kodhane.cloud.state.reconciled')
    old = ev(B, 'Kodhane.cloud.state.rev')
    r = ev(B, """(async () => { const m = Kodhane.cloud.mock(); const x = await m.upsert(%s, { user_id: %s, data: { totalEarned: 6000 }, revision: %d }); return x; })()"""
           % (json.dumps(UID), json.dumps(UID), old - 1))
    check('mock: stale write rejected with the real shape (409 PT409 stale_revision)', r['status'] == 409 and r['error']['code'] == 'PT409' and r['error']['message'] == 'stale_revision', r)
    check('mock: reset not overwritten', mockrow(A)['data']['totalEarned'] < 6000)
    A.click('#undoBtn')
    wait_js(A, "Kodhane.lastUndo", 8000)
    check('mock: signed-in undo via kodhane_restore_save', ev(A, 'Kodhane.lastUndo') == 'cloud' and ev(A, 'Kodhane.state.clicks') == 60)
    wait_js(B, "Kodhane.state.clicks === 60", 8000)
    check('mock: tab B follows the undo', ev(B, 'Kodhane.state.clicks') == 60)
    check('mock tabs: no page errors', not A.errs and not B.errs, A.errs + B.errs)
    ctx.close()

    # ================================================================ 8) mobil: dokunarak basılı tutma + ekran görüntüsü
    ctx = new_ctx(save=seed_save(), mobile=True)
    pg = open_page(ctx)
    ev(pg, "Kodhane.setView('prestige'); Kodhane.selectTab('stats', true)")
    pg.click('#resetBtn'); pg.wait_for_selector('#resetHold')
    pg.screenshot(path=SS + 'v42-reset-dialog-mobile.png')
    pg.locator('#resetHold').scroll_into_view_if_needed()
    bb = pg.locator('#resetHold').bounding_box()
    x, y = bb['x'] + bb['width'] / 2, bb['y'] + bb['height'] / 2
    cdp = ctx.new_cdp_session(pg)
    cdp.send('Input.dispatchTouchEvent', {'type': 'touchStart', 'touchPoints': [{'x': x, 'y': y}]})
    pg.wait_for_timeout(600)
    cdp.send('Input.dispatchTouchEvent', {'type': 'touchEnd', 'touchPoints': []})
    pg.wait_for_timeout(300)
    check('mobile: short touch cancels', ev(pg, 'Kodhane.state.clicks') == 40 and not pg.is_hidden('#modal'))
    with pg.expect_navigation(timeout=20000):
        cdp.send('Input.dispatchTouchEvent', {'type': 'touchStart', 'touchPoints': [{'x': x, 'y': y}]})
        pg.wait_for_timeout(2400)
        cdp.send('Input.dispatchTouchEvent', {'type': 'touchEnd', 'touchPoints': []})
    pg.wait_for_selector('#clickBtn')
    check('mobile: touch hold resets', ev(pg, 'Kodhane.state.clicks') == 0 and not pg.is_hidden('#undoBar'))
    ub = pg.locator('#undoBtn').bounding_box()
    check('mobile: undo button >= 44px', ub['height'] >= 44, ub)
    check('mobile: no page errors', not pg.errs, pg.errs)
    ctx.close()
    b.close()

server.shutdown()
ok = sum(1 for _, c in results if c)
print('\nSUMMARY: %d/%d passed' % (ok, len(results)))
sys.exit(0 if ok == len(results) else 1)
