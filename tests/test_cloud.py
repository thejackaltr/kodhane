"""Kodhane v3 bulut kaydı testleri (Playwright, headless Chromium, Supabase SAHTE).

Gerçek supabase-js (sabitlenmiş jsDelivr sürümü, SRI dahil) kullanılır; Supabase'in REST ve
Auth uç noktaları Playwright route ile taklit edilir. Gerçek e-posta gönderilmez, gerçek
projeye istek atılmaz.
    python3 tests/test_cloud.py
"""
import base64
import functools
import json
import os
import re
import sys
import threading
import time
import urllib.parse
import urllib.request
import uuid
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = int(os.environ.get('KODHANE_CLOUD_TEST_PORT', '8766'))
BASE = 'http://127.0.0.1:%d' % PORT
URL = BASE + '/index.html'
SS = os.path.join(ROOT, 'screenshots') + os.sep
os.makedirs(SS, exist_ok=True)
FAKE = 'https://kodhane-test.supabase.co'
PROD_URL = 'https://supabase.teserix.com'
PAGES = 'https://thejackaltr.github.io/kodhane/'
SAVES_PATH = '/rest/v1/kodhane_saves'
PROFILES_PATH = '/rest/v1/kodhane_profiles'
RPC_PATH = '/rest/v1/rpc/kodhane_leaderboard'
STORAGE_KEY = 'kodhane_auth_v1'
BACKUP_KEY = 'kodhane_ajans_save_backup'
SAVE_KEY = 'kodhane_ajans_save_v2'

CLOUD_JS = open(os.path.join(ROOT, 'cloud.js'), encoding='utf-8').read()
SDK_URL = re.search(r"sdk: '([^']+)'", CLOUD_JS).group(1)
PROD_KEY = re.search(r"key: '([^']+)'", CLOUD_JS).group(1)
CONF_RE = re.search(r"var configured = /(.+?)/\.test\(CFG\.url\)", CLOUD_JS).group(1).replace('\\/', '/')
CACHE = os.path.join(ROOT, 'tests', '.cache')
os.makedirs(CACHE, exist_ok=True)
SDK_FILE = os.path.join(CACHE, os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(SDK_URL)))) + '.js')
if not os.path.exists(SDK_FILE):
    with urllib.request.urlopen(SDK_URL, timeout=60) as r:
        open(SDK_FILE, 'wb').write(r.read())
SDK_BYTES = open(SDK_FILE, 'rb').read()


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(('127.0.0.1', PORT), functools.partial(QuietHandler, directory=ROOT))
threading.Thread(target=server.serve_forever, daemon=True).start()

results = []


def check(name, cond, info=''):
    results.append((name, bool(cond), info))
    print(('PASS' if cond else 'FAIL'), name, info)


def b64u(obj):
    return base64.urlsafe_b64encode(json.dumps(obj).encode()).rstrip(b'=').decode()


def make_token(uid, email):
    now = int(time.time())
    return b64u({'alg': 'HS256', 'typ': 'JWT'}) + '.' + b64u({'sub': uid, 'email': email, 'role': 'authenticated', 'aud': 'authenticated', 'iat': now, 'exp': now + 3600, 'session_id': 's-' + uid}) + '.c2ln'


def user_obj(uid, email):
    return {'id': uid, 'aud': 'authenticated', 'role': 'authenticated', 'email': email, 'email_confirmed_at': '2026-09-27T10:00:00Z',
            'app_metadata': {'provider': 'email', 'providers': ['email']}, 'user_metadata': {}, 'created_at': '2026-09-27T10:00:00Z'}


def session_obj(uid, email):
    now = int(time.time())
    return {'access_token': make_token(uid, email), 'refresh_token': 'rt-' + uid, 'token_type': 'bearer', 'expires_in': 3600,
            'expires_at': now + 3600, 'user': user_obj(uid, email)}


def token_user(auth_header):
    try:
        tok = auth_header.split(' ', 1)[1]
        pl = tok.split('.')[1]
        pl += '=' * (-len(pl) % 4)
        d = json.loads(base64.urlsafe_b64decode(pl))
        if d.get('role') != 'authenticated':
            return None
        return d
    except Exception:
        return None


CORS = {'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': 'GET,POST,PATCH,DELETE,OPTIONS',
        'access-control-expose-headers': '*'}


class FakeSupabase:
    """Supabase REST + Auth taklidi; RLS kuralı (auth.uid() = user_id) burada da uygulanır."""

    def __init__(self):
        self.rows = {}
        self.log = []
        self.otp = []
        self.verify = []
        self.valid_code = '123456'
        self.down = False
        self.profiles = {}   # uid -> nickname
        self.others = []     # takma adlı diğer oyuncular: (nickname, score, stage)
        self.rpc_calls = []  # (authorization kullanıcı mı, p_limit)

    @staticmethod
    def nick_key(n):
        return n.translate(str.maketrans('ÇĞİIÖŞÜı', 'çğiiöşüi')).lower()

    def board(self, me_uid, limit):
        rows = [(n, sc, st, None) for n, sc, st in self.others]
        for uid, nick in self.profiles.items():
            d = (self.rows.get(uid) or {}).get('data') or {}
            if isinstance(d.get('totalEarned'), (int, float)) and d['totalEarned'] >= 0:
                rows.append((nick, float(d['totalEarned']), d.get('stage'), uid))
        rows.sort(key=lambda r: -r[1])
        out, rank = [], 0
        for i, r in enumerate(rows):
            if i == 0 or r[1] != rows[i - 1][1]:
                rank = i + 1
            if i < limit or (me_uid and r[3] == me_uid):
                out.append({'rank': rank, 'nickname': r[0], 'score': r[1], 'stage': r[2], 'is_me': bool(me_uid) and r[3] == me_uid})
        return out

    def reply(self, route, status=200, body=None, headers=None):
        h = dict(CORS)
        h['content-type'] = 'application/json'
        if headers:
            h.update(headers)
        route.fulfill(status=status, headers=h, body='' if body is None else json.dumps(body))

    def handle(self, route):
        req = route.request
        u = urllib.parse.urlparse(req.url)
        q = urllib.parse.parse_qs(u.query)
        method = req.method
        if method == 'OPTIONS':
            return route.fulfill(status=204, headers=CORS, body='')
        self.log.append((method, u.path, u.query))
        if self.down:
            return route.abort('connectionrefused')
        auth = req.headers.get('authorization', '')
        claims = token_user(auth)
        if u.path == '/auth/v1/otp':
            body = json.loads(req.post_data or '{}')
            self.otp.append({'email': body.get('email'), 'redirect_to': (q.get('redirect_to') or [None])[0], 'create_user': body.get('create_user')})
            return self.reply(route, 200, {})
        if u.path == '/auth/v1/verify' and method == 'POST':
            body = json.loads(req.post_data or '{}')
            self.verify.append({k: body.get(k) for k in ('email', 'token', 'type')})
            email = body.get('email')
            if body.get('token') == self.valid_code and any(o['email'] == email for o in self.otp):
                uid = str(uuid.uuid5(uuid.NAMESPACE_DNS, email))
                return self.reply(route, 200, session_obj(uid, email))
            return self.reply(route, 403, {'code': 403, 'error_code': 'otp_expired', 'msg': 'Token has expired or is invalid'})
        if u.path == '/auth/v1/user':
            if not claims:
                return self.reply(route, 401, {'code': 401, 'msg': 'invalid JWT'})
            return self.reply(route, 200, user_obj(claims['sub'], claims.get('email')))
        if u.path == '/auth/v1/logout':
            return route.fulfill(status=204, headers=CORS, body='')
        if u.path == '/auth/v1/token':
            return self.reply(route, 400, {'error': 'invalid_grant'})
        if u.path == RPC_PATH and method == 'POST':
            body = json.loads(req.post_data or '{}')
            self.rpc_calls.append((bool(claims), body.get('p_limit')))
            self.last_board = self.board(claims['sub'] if claims else None, int(body.get('p_limit') or 50))
            return self.reply(route, 200, self.last_board)
        if u.path == PROFILES_PATH:
            if not claims:
                return self.reply(route, 401, {'code': '42501', 'message': 'permission denied for table kodhane_profiles'})
            uid = claims['sub']
            if method == 'GET':
                rows = [{'nickname': self.profiles[uid]}] if uid in self.profiles else []
                return self.reply(route, 200, rows)
            if method == 'POST':
                body = json.loads(req.post_data or '{}')
                if body.get('user_id') != uid:
                    return self.reply(route, 403, {'code': '42501', 'message': 'new row violates row-level security policy'})
                nick = (body.get('nickname') or '').strip()
                if len(nick) < 3:
                    return self.reply(route, 400, {'code': '23514', 'message': 'nickname_too_short'})
                if any(self.nick_key(n) == self.nick_key(nick) for o, n in self.profiles.items() if o != uid) or \
                        any(self.nick_key(n) == self.nick_key(nick) for n, _, _ in self.others):
                    return self.reply(route, 409, {'code': '23505', 'message': 'duplicate key value violates unique constraint "kodhane_profiles_nick_key_uniq"'})
                self.profiles[uid] = nick
                return route.fulfill(status=201, headers=CORS, body='')
        if u.path == SAVES_PATH:
            if not claims:
                return self.reply(route, 401, {'message': 'JWT required'})
            uid = claims['sub']
            if method == 'GET':
                want = (q.get('user_id') or [''])[0].replace('eq.', '')
                rows = [dict(self.rows[k], user_id=k) for k in self.rows if k == uid and (not want or want == k)]
                sel = (q.get('select') or ['*'])[0].split(',')
                if sel != ['*']:
                    rows = [{c: r.get(c) for c in sel} for r in rows]
                return self.reply(route, 200, rows)
            if method == 'POST':
                body = json.loads(req.post_data or '{}')
                items = body if isinstance(body, list) else [body]
                for it in items:
                    if it.get('user_id') != uid:
                        return self.reply(route, 403, {'code': '42501', 'message': 'new row violates row-level security policy'})
                    self.rows[uid] = {'data': it['data'], 'save_version': it.get('save_version'), 'updated_at': it.get('updated_at') or time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
                return route.fulfill(status=201, headers=CORS, body='')
            if method == 'DELETE':
                want = (q.get('user_id') or [''])[0].replace('eq.', '')
                if want == uid:
                    self.rows.pop(uid, None)
                return route.fulfill(status=204, headers=CORS, body='')
        return self.reply(route, 404, {'message': 'not found'})

    def count(self, method, path):
        return sum(1 for m, p, _ in self.log if m == method and p == path)


def cfg_script(extra=None):
    cfg = {'url': FAKE, 'key': 'sb_publishable_test_key'}
    cfg.update(extra or {})
    return 'window.KODHANE_CLOUD_CONFIG = %s;' % json.dumps(cfg)


def local_save(total, started, clicks=10, money=100.0, last_saved=None):
    now = int(time.time() * 1000)
    return {'version': 2, 'money': money, 'runEarned': total, 'totalEarned': total, 'clicks': clicks, 'clickEarned': clicks,
            'playTime': 600, 'startedAt': started, 'lastSaved': last_saved or now,
            'gens': {'stajyer': 3, 'junior': 1, 'senior': 0, 'tasarimci': 0, 'pm': 0, 'ai': 0, 'sunucu': 0, 'ofis': 0},
            'upgrades': [], 'shares': 0, 'prestigeCount': 0, 'boostLeft': 0, 'eventsClicked': 0, 'offlineEarned': 0, 'stage': 0,
            'buffs': [], 'achievements': [], 'reputation': 0}


def seed_script(save=None, session=None):
    parts = ["(() => { if (sessionStorage.getItem('kh_seeded')) return; sessionStorage.setItem('kh_seeded','1');"]
    if save is not None:
        parts.append("localStorage.setItem(%s, %s);" % (json.dumps(SAVE_KEY), json.dumps(json.dumps(save))))
    if session is not None:
        parts.append("localStorage.setItem(%s, %s);" % (json.dumps(STORAGE_KEY), json.dumps(json.dumps(session))))
    parts.append('})();')
    return ''.join(parts)


# ------------------------------------------------------------ 0) üretim yapılandırması (statik)
def jwt_claims(tok):
    try:
        pl = tok.split('.')[1]
        pl += '=' * (-len(pl) % 4)
        return json.loads(base64.urlsafe_b64decode(pl))
    except Exception:
        return {}


check('config: URL is shared Teserix Supabase', re.search(r"url: '([^']+)'", CLOUD_JS).group(1) == PROD_URL)
check('config: namespaced table kodhane_saves', re.search(r"table: '([^']+)'", CLOUD_JS).group(1) == 'kodhane_saves')
check('config: embedded key is the publishable anon key (never service_role)', jwt_claims(PROD_KEY).get('role') == 'anon', jwt_claims(PROD_KEY).get('role'))
_conf = re.compile(CONF_RE)
check('config: is-configured accepts supabase.teserix.com and *.supabase.co',
      bool(_conf.match(PROD_URL)) and bool(_conf.match('https://abcd1234.supabase.co')), CONF_RE)
check('config: is-configured rejects look-alikes',
      not any(_conf.match(u) for u in ('https://supabase.teserix.com.evil.io', 'https://evil.io/supabase.teserix.com', 'http://supabase.teserix.com',
                                         'https://xsupabase.teserix.com', 'https://supabase.teserix.com/')))

with sync_playwright() as p:
    b = p.chromium.launch()

    def new_ctx(fake, mobile=False, extra_cfg=None, init=None, sw='block', cdn='serve'):
        opts = dict(locale='tr-TR', service_workers=sw)
        if mobile:
            opts.update(viewport={'width': 390, 'height': 844}, device_scale_factor=2, is_mobile=True, has_touch=True)
        else:
            opts.update(viewport={'width': 1280, 'height': 800})
        ctx = b.new_context(**opts)
        ctx.add_init_script(cfg_script(extra_cfg))
        if init:
            ctx.add_init_script(init)
        ctx.route(FAKE + '/**', fake.handle)
        cdn_hits = []

        def cdn_handler(route):
            cdn_hits.append(route.request.url)
            if cdn == 'fail':
                return route.abort('failed')
            route.fulfill(status=200, headers={'content-type': 'application/javascript; charset=utf-8', 'access-control-allow-origin': '*'}, body=SDK_BYTES)
        ctx.route('https://cdn.jsdelivr.net/**', cdn_handler)
        ctx.cdn_hits = cdn_hits
        return ctx

    def open_page(ctx, url=URL):
        page = ctx.new_page()
        errs, perrs = [], []
        page.on('console', lambda m: errs.append(m.text) if m.type == 'error' else None)
        page.on('pageerror', lambda e: perrs.append(str(e)))
        page.goto(url)
        page.wait_for_selector('#clickBtn')
        return page, errs, perrs

    def wait_until(page, js, timeout=8000):
        try:
            page.wait_for_function(js, timeout=timeout)
            return True
        except Exception:
            return False

    # ------------------------------------------------------------ 1) misafir oyun
    fake = FakeSupabase()
    ctx = new_ctx(fake, mobile=True)
    page, errs, perrs = open_page(ctx)
    ev = page.evaluate
    ev('Kodhane.rng = () => 0.99')
    for _ in range(5):
        page.tap('#clickBtn')
    page.wait_for_timeout(600)
    check('guest: game plays', ev('Kodhane.state.clicks') == 5)
    check('guest: SDK not downloaded until needed', len(ctx.cdn_hits) == 0 and not ev('!!window.supabase'), str(ctx.cdn_hits))
    check('guest: no Supabase requests', len(fake.log) == 0, str(fake.log))
    check('guest: account button visible in header (mobile)', page.is_visible('#accountBtn') and page.locator('#accountBtn').bounding_box()['height'] >= 44)
    ev('Kodhane.save()')
    check('guest: local save written', json.loads(ev("localStorage.getItem('%s')" % SAVE_KEY))['clicks'] == 5)
    page.tap('#accountBtn')
    page.wait_for_selector('#accountPanel:not(.hidden)')
    check('guest: account panel opens', page.is_visible('#accEmail') and page.is_visible('#accSend'))
    check('guest: Turkish UI text', page.inner_text('#accSend') == 'Giriş bağlantısı gönder' and 'Hesap' in page.inner_text('#accTitle'), page.inner_text('#accSend'))
    ok = wait_until(page, '!!window.supabase && !!Kodhane.cloud.state.client')
    check('guest: SDK lazy-loaded on panel open (SRI ok)', ok and len(ctx.cdn_hits) == 1, str(ctx.cdn_hits))
    page.fill('#accEmail', 'yanlis-adres')
    page.tap('#accSend')
    page.wait_for_timeout(200)
    check('guest: invalid email rejected', 'Geçerli bir e-posta' in page.inner_text('#accMsg') and len(fake.otp) == 0)
    page.screenshot(path=SS + 'v3-hesap-mobile.png')
    page.fill('#accEmail', 'oyuncu@example.com')
    page.tap('#accSend')
    ok = wait_until(page, "document.getElementById('accMsg').textContent.includes('gönderildi')")
    check('guest: magic link requested via mocked /otp', ok and len(fake.otp) == 1 and fake.otp[0]['email'] == 'oyuncu@example.com', json.dumps(fake.otp))
    check('guest: redirect goes back to game path', fake.otp and fake.otp[0]['redirect_to'] == BASE + '/', fake.otp and fake.otp[0]['redirect_to'])
    check('guest: send button cools down', page.is_disabled('#accSend'))
    page.tap('#accClose')
    check('guest: panel closes', page.is_hidden('#accountPanel'))
    check('guest: no page/console errors', not perrs and not errs, '; '.join(perrs + errs))
    ctx.close()

    # ------------------------------------------------------------ 2) CDN erişilemezse oyun çalışmaya devam eder
    fake = FakeSupabase()
    ctx = new_ctx(fake, cdn='fail')
    page, errs, perrs = open_page(ctx)
    page.click('#accountBtn')
    ok = wait_until(page, "document.getElementById('accMsg').textContent.includes('ulaşılamıyor')")
    check('cdn down: friendly message', ok, page.inner_text('#accMsg'))
    page.click('#accClose')
    c0 = page.evaluate('Kodhane.state.clicks')
    page.click('#clickBtn')
    check('cdn down: game still works', page.evaluate('Kodhane.state.clicks') == c0 + 1)
    check('cdn down: no uncaught errors', not perrs, '; '.join(perrs))
    ctx.close()

    # ------------------------------------------------------------ 3) giriş bağlantısından dönüş + ilk girişte yerel kaydı yükleme
    fake = FakeSupabase()
    UID_A, EMAIL_A = '11111111-1111-4111-8111-111111111111', 'a@example.com'
    started = int(time.time() * 1000) - 86400000
    ctx = new_ctx(fake, init=seed_script(save=local_save(5000, started, clicks=42)))
    s = session_obj(UID_A, EMAIL_A)
    frag = urllib.parse.urlencode({'access_token': s['access_token'], 'expires_at': s['expires_at'], 'expires_in': 3600,
                                   'refresh_token': s['refresh_token'], 'token_type': 'bearer', 'type': 'magiclink'})
    page, errs, perrs = open_page(ctx, BASE + '/#' + frag)
    ok = wait_until(page, 'Kodhane.cloud.state.user && Kodhane.cloud.state.lastPushAt > 0', 10000)
    check('login: session detected from magic-link URL', ok and page.evaluate('Kodhane.cloud.state.user.email') == EMAIL_A)
    check('login: URL cleaned', page.url == BASE + '/', page.url)
    check('login: session persisted', page.evaluate("!!localStorage.getItem('%s')" % STORAGE_KEY))
    row = fake.rows.get(UID_A)
    check('first login: local save uploaded', row is not None and row['data']['clicks'] == 42 and row['data']['totalEarned'] >= 5000 and row['save_version'] == 2,
          json.dumps(row)[:200] if row else 'no row')
    check('first login: no backup needed', page.evaluate("localStorage.getItem('%s')" % BACKUP_KEY) is None)
    check('login: header shows signed-in state', 'signed' in page.get_attribute('#accountBtn', 'class'))
    page.click('#accountBtn')
    page.wait_for_timeout(200)
    sync_txt = page.inner_text('#accSync')
    check('login: panel shows email + "Buluta kaydedildi" with time', page.inner_text('#accEmailShown') == EMAIL_A and re.search(r'Buluta kaydedildi · \d\d:\d\d', sync_txt), sync_txt)
    check('login: guest form hidden', page.is_hidden('#accEmail') and page.is_visible('#accSignOut'))
    page.screenshot(path=SS + 'v3-hesap-signed-desktop.png')
    page.click('#accClose')
    check('login: no page/console errors', not perrs and not errs, '; '.join(perrs + errs))
    ctx.close()

    # ------------------------------------------------------------ 3b) süresi dolmuş giriş bağlantısı
    fake = FakeSupabase()
    ctx = new_ctx(fake, mobile=True)
    page, errs, perrs = open_page(ctx, BASE + '/#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired')
    ok = wait_until(page, "document.getElementById('toast').textContent.includes('Giriş bağlantısı')", 10000)
    check('expired link: friendly toast, URL cleaned, guest', ok and page.url == BASE + '/' and not page.evaluate('!!Kodhane.cloud.state.user'), page.url)
    page.tap('#accountBtn')
    check('expired link: panel explains', 'süresi dolmuş' in page.inner_text('#accMsg'), page.inner_text('#accMsg'))
    check('expired link: no uncaught errors', not perrs, '; '.join(perrs))
    ctx.close()

    # ------------------------------------------------------------ 3c) e-postadaki 6 haneli kodla giriş (iPhone ana ekran uygulaması için)
    fake = FakeSupabase()
    EMAIL_C = 'kod@example.com'
    UID_C = str(uuid.uuid5(uuid.NAMESPACE_DNS, EMAIL_C))
    ctx = new_ctx(fake, mobile=True, init=seed_script(save=local_save(8000, started, clicks=64)))
    page, errs, perrs = open_page(ctx)
    page.tap('#accountBtn'); wait_until(page, '!!Kodhane.cloud.state.client')
    page.fill('#accEmail', EMAIL_C); page.tap('#accSend')
    ok = wait_until(page, "!document.getElementById('accCodeForm').classList.contains('hidden')")
    check('otp: code step shown after sending', ok and page.is_visible('#accCode') and page.is_hidden('#accEmail') and len(fake.otp) == 1)
    check('otp: Turkish label + buttons', page.inner_text('label[for=accCode]') == 'E-postadaki 6 haneli kodu gir' and page.inner_text('#accVerify') == 'Giriş yap'
          and page.is_visible('#accChange') and page.inner_text('#accChange') == 'E-postayı değiştir', page.inner_text('label[for=accCode]'))
    check('otp: numeric keyboard + one-time-code autofill', page.get_attribute('#accCode', 'inputmode') == 'numeric' and page.get_attribute('#accCode', 'autocomplete') == 'one-time-code'
          and page.get_attribute('#accCode', 'maxlength') == '6')
    check('otp: info mentions email', EMAIL_C in page.inner_text('#accCodeInfo'), page.inner_text('#accCodeInfo'))
    check('otp: resend on 60s cooldown with countdown', page.is_disabled('#accResend') and re.search(r'Kodu tekrar gönder \((5\d|60) sn\)', page.inner_text('#accResend')), page.inner_text('#accResend'))
    check('otp: magic-link redirect still sent', fake.otp[0]['redirect_to'] == BASE + '/', fake.otp[0]['redirect_to'])
    page.screenshot(path=SS + 'v3-hesap-kod-mobile.png')
    # uygulama kapanıp açılsa da kod adımı hatırlanır
    check('otp: pending email remembered', EMAIL_C in (page.evaluate("localStorage.getItem('kodhane_auth_pending')") or ''))
    page.reload(); page.wait_for_selector('#clickBtn'); page.tap('#accountBtn')
    ok = wait_until(page, "!!Kodhane.cloud.state.client && !document.getElementById('accCodeForm').classList.contains('hidden')")
    check('otp: code step restored after app reload', ok and EMAIL_C in page.inner_text('#accCodeInfo'))
    page.fill('#accCode', '12a'); page.tap('#accVerify'); page.wait_for_timeout(200)
    check('otp: non-6-digit code rejected locally', 'Kod 6 haneli olmalı' in page.inner_text('#accMsg') and len(fake.verify) == 0, page.inner_text('#accMsg'))
    page.fill('#accCode', '000000')  # 6 hane dolunca otomatik denenir
    ok = wait_until(page, "document.getElementById('accMsg').textContent.includes('Kod hatalı')")
    check('otp: wrong/expired code -> Turkish error, still guest', ok and len(fake.verify) == 1 and not page.evaluate('!!Kodhane.cloud.state.user')
          and 'süresi dolmuş' in page.inner_text('#accMsg'), page.inner_text('#accMsg'))
    page.evaluate('Kodhane.cloud.state.cooldownUntil = 0')
    ok = wait_until(page, "!document.getElementById('accResend').disabled", 3000)
    page.tap('#accResend')
    ok = ok and wait_until(page, "document.getElementById('accMsg').textContent.includes('Yeni bir kod')")
    check('otp: resend sends again to same email, cooldown restarts', ok and len(fake.otp) == 2 and fake.otp[1]['email'] == EMAIL_C and page.is_disabled('#accResend'), json.dumps(fake.otp))
    page.fill('#accCode', '123456')
    ok = wait_until(page, 'Kodhane.cloud.state.user && Kodhane.cloud.state.lastPushAt > 0', 10000)
    check('otp: correct code signs in', ok and page.evaluate('Kodhane.cloud.state.user.email') == EMAIL_C)
    check('otp: verifyOtp called with type=email', fake.verify[-1] == {'email': EMAIL_C, 'token': '123456', 'type': 'email'}, json.dumps(fake.verify))
    row = fake.rows.get(UID_C)
    check('otp: same post-login flow (local save uploaded)', row is not None and row['data']['clicks'] == 64, json.dumps(row)[:120] if row else 'no row')
    check('otp: session persisted, pending cleared, signed-in panel', page.evaluate("!!localStorage.getItem('%s') && !localStorage.getItem('kodhane_auth_pending')" % STORAGE_KEY)
          and page.is_visible('#accSignOut') and page.is_hidden('#accCodeForm'))
    check('otp: no page/console errors', not perrs and not [e for e in errs if '403' not in e], '; '.join(perrs + errs))
    ctx.close()

    # 3d) "E-postayı değiştir" e-posta adımına döner
    fake = FakeSupabase()
    ctx = new_ctx(fake, mobile=True)
    page, errs, perrs = open_page(ctx)
    page.tap('#accountBtn'); wait_until(page, '!!Kodhane.cloud.state.client')
    page.fill('#accEmail', 'ilk@example.com'); page.tap('#accSend')
    wait_until(page, "!document.getElementById('accCodeForm').classList.contains('hidden')")
    page.tap('#accChange'); page.wait_for_timeout(150)
    check('otp: change email -> back to email form, pending cleared', page.is_visible('#accEmail') and page.is_hidden('#accCodeForm')
          and page.evaluate("localStorage.getItem('kodhane_auth_pending')") is None)
    ctx.close()

    # mobil girişli görünüm ekran görüntüsü
    fake = FakeSupabase()
    ctx = new_ctx(fake, mobile=True, init=seed_script(save=local_save(5000, started, clicks=42), session=session_obj(UID_A, 'aryen@example.com')))
    page, errs, perrs = open_page(ctx)
    ok = wait_until(page, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0', 10000)
    page.evaluate("document.getElementById('toast').innerHTML=''")
    page.tap('#accountBtn'); page.wait_for_timeout(300)
    check('mobile signed-in panel fits 390px', ok and page.evaluate('document.documentElement.scrollWidth') <= 390 and page.is_visible('#accSignOut'))
    page.screenshot(path=SS + 'v3-hesap-signed-mobile.png')
    ctx.close()

    # ------------------------------------------------------------ 4) çakışma: bulut önde -> bulut yüklenir, yerel yedeklenir
    fake = FakeSupabase()
    UID_B, EMAIL_B = '22222222-2222-4222-8222-222222222222', 'b@example.com'
    cloud_save = local_save(1e7, started - 5 * 86400000, clicks=9999, money=12345.0)
    cloud_save['gens']['senior'] = 7
    fake.rows[UID_B] = {'data': cloud_save, 'save_version': 2, 'updated_at': '2026-09-27T08:00:00Z'}
    ctx = new_ctx(fake, init=seed_script(save=local_save(5000, started, clicks=42), session=session_obj(UID_B, EMAIL_B)))
    page, errs, perrs = open_page(ctx)
    ok = wait_until(page, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0', 10000)
    st = page.evaluate('Kodhane.state')
    check('conflict (cloud ahead): cloud save applied', ok and st['clicks'] == 9999 and st['gens']['senior'] == 7 and st['totalEarned'] >= 1e7, f"clicks={st['clicks']}")
    bk = page.evaluate("localStorage.getItem('%s')" % BACKUP_KEY)
    bk = json.loads(bk) if bk else {}
    check('conflict (cloud ahead): local save backed up', bk.get('clicks') == 42 and abs(bk.get('totalEarned', 0) - 5000) < 5, json.dumps(bk)[:120])
    check('conflict (cloud ahead): local storage now has cloud save', json.loads(page.evaluate("localStorage.getItem('%s')" % SAVE_KEY))['clicks'] == 9999)
    check('conflict (cloud ahead): UI re-rendered', page.evaluate("document.querySelector('[data-gen=\"senior\"] .gen-owned').textContent.trim()") == '7')
    check('conflict (cloud ahead): no errors', not perrs and not errs, '; '.join(perrs + errs))
    ctx.close()

    # ------------------------------------------------------------ 5) çakışma: yerel önde -> yerel kalır, bulut yedeklenir ve güncellenir
    fake = FakeSupabase()
    fake.rows[UID_B] = {'data': local_save(100, started - 9 * 86400000, clicks=3), 'save_version': 2, 'updated_at': '2026-09-27T20:00:00Z'}
    ctx = new_ctx(fake, init=seed_script(save=local_save(1e6, started, clicks=500), session=session_obj(UID_B, EMAIL_B)))
    page, errs, perrs = open_page(ctx)
    ok = wait_until(page, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0', 10000)
    st = page.evaluate('Kodhane.state')
    bk = json.loads(page.evaluate("localStorage.getItem('%s')" % BACKUP_KEY) or '{}')
    check('conflict (local ahead): local kept', ok and st['clicks'] == 500)
    check('conflict (local ahead): cloud save backed up', bk.get('clicks') == 3 and bk.get('totalEarned') == 100, json.dumps(bk)[:120])
    check('conflict (local ahead): cloud overwritten with local', fake.rows[UID_B]['data']['clicks'] == 500)
    ctx.close()

    # ------------------------------------------------------------ 6) eşit kazanç -> daha yeni updated_at kazanır
    old_ms = int(time.time() * 1000) - 3600 * 1000
    # Üretimsiz (gens=0) iki kayıt, ömür boyu kazanç eşit; karar updated_at / lastSaved'a göre verilir.
    ls = local_save(7777, started, clicks=11, last_saved=old_ms)
    ls['gens'] = {k: 0 for k in ls['gens']}
    fake = FakeSupabase()
    fake.rows[UID_B] = {'data': local_save(7777, started - 86400000, clicks=77), 'save_version': 2, 'updated_at': '2099-01-01T00:00:00Z'}
    fake.rows[UID_B]['data']['gens'] = {k: 0 for k in ls['gens']}
    ctx = new_ctx(fake, init=seed_script(save=ls, session=session_obj(UID_B, EMAIL_B)))
    page, errs, perrs = open_page(ctx)
    ok = wait_until(page, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0', 10000)
    check('tie on earnings: newer updated_at (cloud) wins', ok and page.evaluate('Kodhane.state.clicks') == 77, str(page.evaluate('Kodhane.state.clicks')))
    check('tie on earnings: other save backed up', json.loads(page.evaluate("localStorage.getItem('%s')" % BACKUP_KEY) or '{}').get('clicks') == 11)
    ctx.close()
    fake = FakeSupabase()
    fake.rows[UID_B] = {'data': local_save(7777, started - 86400000, clicks=77), 'save_version': 2, 'updated_at': '2020-01-01T00:00:00Z'}
    fake.rows[UID_B]['data']['gens'] = {k: 0 for k in ls['gens']}
    ctx = new_ctx(fake, init=seed_script(save=ls, session=session_obj(UID_B, EMAIL_B)))
    page, errs, perrs = open_page(ctx)
    ok = wait_until(page, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0', 10000)
    check('tie on earnings: newer local wins over old cloud', ok and page.evaluate('Kodhane.state.clicks') == 11 and fake.rows[UID_B]['data']['clicks'] == 11)
    ctx.close()

    # ------------------------------------------------------------ 7) gecikmeli yükleme, sekme gizlenince hemen yükleme, çıkış
    fake = FakeSupabase()
    ctx = new_ctx(fake, extra_cfg={'pushDelayMs': 1500}, init=seed_script(save=local_save(2000, started, clicks=20), session=session_obj(UID_A, EMAIL_A)))
    page, errs, perrs = open_page(ctx)
    ev = page.evaluate
    wait_until(page, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0', 10000)
    posts0 = fake.count('POST', SAVES_PATH)
    ev('Kodhane.rng = () => 0.99')
    for _ in range(3):
        page.click('#clickBtn')
    ev('Kodhane.save()')
    page.wait_for_timeout(400)
    check('debounce: not pushed immediately', fake.count('POST', SAVES_PATH) == posts0)
    page.wait_for_timeout(1800)
    check('debounce: pushed after delay', fake.count('POST', SAVES_PATH) == posts0 + 1 and fake.rows[UID_A]['data']['clicks'] == 23,
          f"posts={fake.count('POST', SAVES_PATH) - posts0} clicks={fake.rows[UID_A]['data']['clicks']}")
    # hiç değişiklik yoksa tekrar yüklenmez (üretim yok: gens=0 değil, ama sig değişmezse atlanır)
    ev("Kodhane.cloud.config.pushDelayMs = 600000")
    page.click('#clickBtn')
    ev("Object.defineProperty(document, 'hidden', {configurable: true, get: () => true}); document.dispatchEvent(new Event('visibilitychange'));")
    page.wait_for_timeout(600)
    check('visibilitychange: immediate flush', fake.rows[UID_A]['data']['clicks'] == 24, str(fake.rows[UID_A]['data']['clicks']))
    ev("Object.defineProperty(document, 'hidden', {configurable: true, get: () => false});")
    page.click('#clickBtn')
    ev("window.dispatchEvent(new Event('pagehide'))")
    page.wait_for_timeout(600)
    check('pagehide: immediate flush', fake.rows[UID_A]['data']['clicks'] == 25, str(fake.rows[UID_A]['data']['clicks']))
    # çıkış
    page.click('#accountBtn')
    page.click('#accSignOut')
    ok = wait_until(page, "!Kodhane.cloud.state.user && !document.getElementById('accEmail').closest('.hidden')")
    check('sign-out: back to guest UI', ok and page.is_visible('#accEmail') and 'signed' not in page.get_attribute('#accountBtn', 'class'))
    check('sign-out: session removed', ev("localStorage.getItem('%s')" % STORAGE_KEY) is None)
    check('sign-out: message shown', 'Çıkış yapıldı' in page.inner_text('#accMsg'), page.inner_text('#accMsg'))
    page.click('#accClose')
    posts1 = fake.count('POST', SAVES_PATH)
    for _ in range(2):
        page.click('#clickBtn')
    ev('Kodhane.save()')
    ev("Object.defineProperty(document, 'hidden', {configurable: true, get: () => true}); document.dispatchEvent(new Event('visibilitychange'));")
    page.wait_for_timeout(800)
    check('sign-out: local progress kept, no more cloud writes', ev('Kodhane.state.clicks') == 27 and fake.count('POST', SAVES_PATH) == posts1
          and json.loads(ev("localStorage.getItem('%s')" % SAVE_KEY))['clicks'] == 27)
    check('sign-out: no page/console errors', not perrs and not errs, '; '.join(perrs + errs))
    ctx.close()

    # ------------------------------------------------------------ 8) girişliyken sıfırlama buluttaki satırı da siler
    fake = FakeSupabase()
    ctx = new_ctx(fake, init=seed_script(save=local_save(3000, started, clicks=30), session=session_obj(UID_A, EMAIL_A)))
    page, errs, perrs = open_page(ctx)
    wait_until(page, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0', 10000)
    check('reset: row exists before', UID_A in fake.rows)
    page.click('[data-tab="stats"]')
    page.click('#resetBtn')
    check('reset: dialog mentions cloud', 'buluttaki kaydın da silinecek' in page.inner_text('#modal'))
    page.click('#modalActions .btn.danger')
    page.wait_for_timeout(2500)
    page.wait_for_selector('#clickBtn')
    wait_until(page, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0', 10000)
    check('reset: cloud row deleted then fresh save uploaded', fake.count('DELETE', SAVES_PATH) == 1 and fake.rows.get(UID_A, {}).get('data', {}).get('clicks') == 0,
          str(fake.rows.get(UID_A, {}).get('data', {}).get('clicks')))
    ctx.close()

    # ------------------------------------------------------------ 9) Supabase erişilemez (girişli) -> oyun devam eder
    fake = FakeSupabase()
    fake.down = True
    ctx = new_ctx(fake, init=seed_script(save=local_save(3000, started, clicks=30), session=session_obj(UID_A, EMAIL_A)))
    page, errs, perrs = open_page(ctx)
    ok = wait_until(page, "Kodhane.cloud.state.status === 'error'", 10000)
    page.click('#clickBtn')
    check('supabase down: game works, error status, no uncaught errors', ok and page.evaluate('Kodhane.state.clicks') == 31 and not perrs, '; '.join(perrs))
    page.click('#accountBtn')
    check('supabase down: friendly message in panel', 'ulaşılamıyor' in page.inner_text('#accSync') or 'ulaşılamadı' in page.inner_text('#accSync'), page.inner_text('#accSync'))
    ctx.close()

    # ------------------------------------------------------------ 10) çevrimdışı + servis çalışanı: dış isteklere dokunulmaz
    fake = FakeSupabase()
    ctx = new_ctx(fake, sw='allow', init=seed_script(save=local_save(3000, started, clicks=30), session=session_obj(UID_A, EMAIL_A)))
    page, errs, perrs = open_page(ctx)
    wait_until(page, 'Kodhane.cloud.state.reconciled', 10000)
    page.evaluate("navigator.serviceWorker.ready.then(() => true)")
    page.reload(); page.wait_for_selector('#clickBtn')
    wait_until(page, '!!navigator.serviceWorker.controller', 5000)
    keys = page.evaluate("caches.keys()")
    cached = page.evaluate("caches.keys().then(ks => Promise.all(ks.map(k => caches.open(k).then(c => c.keys())))).then(a => a.flat().map(r => r.url))")
    check('sw: cache version bumped (v3.x)', any(re.match(r'kodhane-v3(\.\d+)?-', k) for k in keys), str(keys))
    check('sw: cloud.js cached for offline', any(u.endswith('/cloud.js') for u in cached))
    check('sw: never caches Supabase/CDN', not any(('supabase' in u) or ('jsdelivr' in u) for u in cached), str([u for u in cached if 'http' in u and BASE not in u]))
    ctx.set_offline(True)
    hits_before = len(ctx.cdn_hits)
    page.reload(); page.wait_for_selector('#clickBtn', timeout=10000)
    c0 = page.evaluate('Kodhane.state.clicks'); page.click('#clickBtn')
    page.wait_for_timeout(500)
    check('offline (signed in): play works, SDK not requested, no uncaught errors',
          page.evaluate('Kodhane.state.clicks') == c0 + 1 and len(ctx.cdn_hits) == hits_before and not perrs, '; '.join(perrs))
    ctx.set_offline(False)
    ctx.close()

    # ------------------------------------------------------------ 11) üretim yapılandırması: GitHub Pages yolu + supabase.teserix.com (geçersiz kılma yok)
    fake = FakeSupabase()
    ctx = b.new_context(locale='tr-TR', service_workers='block', viewport={'width': 1280, 'height': 800})
    served = []

    def pages_handler(route):
        path = urllib.parse.urlparse(route.request.url).path[len('/kodhane/'):] or 'index.html'
        fp = os.path.normpath(os.path.join(ROOT, path))
        if not fp.startswith(ROOT) or not os.path.isfile(fp):
            return route.fulfill(status=404, body='')
        served.append(path)
        ctype = {'.html': 'text/html', '.js': 'application/javascript', '.css': 'text/css', '.svg': 'image/svg+xml',
                 '.png': 'image/png', '.webmanifest': 'application/manifest+json'}.get(os.path.splitext(fp)[1], 'application/octet-stream')
        route.fulfill(status=200, headers={'content-type': ctype + ('; charset=utf-8' if ctype.startswith(('text', 'application/j')) else '')},
                      body=open(fp, 'rb').read())
    ctx.route(PAGES + '**', pages_handler)
    ctx.route(PROD_URL + '/**', fake.handle)
    prod_cdn = []
    ctx.route('https://cdn.jsdelivr.net/**', lambda r: (prod_cdn.append(r.request.url), r.fulfill(status=200, headers={'content-type': 'application/javascript; charset=utf-8', 'access-control-allow-origin': '*'}, body=SDK_BYTES)))
    page, errs, perrs = open_page(ctx, PAGES)
    check('prod: configured without test override', page.evaluate('Kodhane.cloud.isConfigured() && !window.KODHANE_CLOUD_CONFIG'))
    check('prod: runtime config URL + table', page.evaluate('Kodhane.cloud.config.url') == PROD_URL and page.evaluate('Kodhane.cloud.config.table') == 'kodhane_saves')
    check('prod: guest makes no Supabase requests', len(fake.log) == 0, str(fake.log))
    page.click('#accountBtn')
    wait_until(page, '!!Kodhane.cloud.state.client')
    page.fill('#accEmail', 'oyuncu@example.com')
    page.click('#accSend')
    ok = wait_until(page, "document.getElementById('accMsg').textContent.includes('gönderildi')")
    check('prod: magic link request goes to supabase.teserix.com/auth/v1/otp', ok and len(fake.otp) == 1, json.dumps(fake.otp))
    check('prod: magic-link redirect is exactly ' + PAGES, fake.otp and fake.otp[0]['redirect_to'] == PAGES, fake.otp and fake.otp[0]['redirect_to'])
    check('prod: no page/console errors', not perrs and not errs, '; '.join(perrs + errs))
    ctx.close()

    # ------------------------------------------------------------ 12) Sıralama: misafir (mobil), boş liste, çevrimdışı, hata
    NAMES = ['KodUstası', 'Zeynep.dev', 'mert_42', 'AyşeYazılım', 'deployCuma', 'Çaycı_Hüseyin', 'Selin.K', 'burakbey', 'Pikselci', 'GeceMesaisi',
             'Elif_UX', 'Tolga.io', 'Kübra', 'Emre_Ops', 'Duygu.pm', 'CanBackend']
    def others(n, top=4.2e12, f=1.2):
        return [((NAMES[i] if i < len(NAMES) else 'oyuncu%02d' % i), round(top / (f ** i), 2), max(0, 5 - i // 12)) for i in range(n)]
    fake = FakeSupabase()
    fake.others = others(60)
    ctx = new_ctx(fake, mobile=True)
    page, errs, perrs = open_page(ctx)
    page.tap('#bottomNav [data-view="siralama"]')
    ok = wait_until(page, "document.querySelectorAll('#lbList .lb-row').length === 50")
    check('lb guest: top 50 listed from RPC', ok, str(page.evaluate("document.querySelectorAll('#lbList .lb-row').length")))
    check('lb guest: no SDK download, anonymous RPC call only', len(ctx.cdn_hits) == 0 and fake.rpc_calls and fake.rpc_calls[-1] == (False, 50)
          and all(p in (RPC_PATH,) for _, p, _ in fake.log), str(fake.log[:3]))
    first = page.locator('#lbList .lb-row').first
    check('lb guest: row shows medal, nickname, stage and game-formatted score', first.locator('.lb-rank').inner_text() == '🥇'
          and first.locator('.lb-name').inner_text() == 'KodUstası' and first.locator('.lb-stage').inner_text() == '🌐 Global Holding'
          and first.locator('.lb-score').inner_text() == page.evaluate('Kodhane.tl(4.2e12)'), first.inner_text().replace('\n', ' | '))
    check('lb guest: info note + CTA', page.inner_text('#lbInfo') == 'Puan, oyuna başladığından beri kazandığın toplam para. Yatırım turunda sıfırlanmaz.'
          and page.is_visible('#lbSignIn') and 'takma ad' in page.inner_text('#lbJoin'))
    check('lb guest: no highlighted own row, nothing pinned', page.locator('.lb-row.me').count() == 0 and page.is_hidden('#lbMe'))
    check('lb guest: fits 390px', page.evaluate('document.documentElement.scrollWidth') <= 390)
    page.tap('#lbSignIn')
    check('lb guest: CTA opens sign-in panel', page.is_visible('#accountPanel') and page.is_visible('#accEmail'))
    page.tap('#accClose')
    n0 = len(fake.rpc_calls)
    page.tap('#lbRefresh')
    ok = wait_until(page, "!document.getElementById('lbRefresh').disabled")
    check('lb guest: refresh button re-fetches', ok and len(fake.rpc_calls) == n0 + 1, str(len(fake.rpc_calls) - n0))
    ctx.set_offline(True)
    page.tap('#lbRefresh'); page.wait_for_timeout(200)
    check('lb guest: offline message', page.inner_text('#lbStatus').strip() == '📡 Sıralama için internet bağlantısı gerekli', page.inner_text('#lbStatus'))
    ctx.set_offline(False)
    ok = wait_until(page, "document.getElementById('lbStatus').textContent === ''")
    check('lb guest: back online -> auto refresh, message cleared', ok, page.inner_text('#lbStatus'))
    fake.down = True
    page.tap('#lbRefresh')
    ok = wait_until(page, "document.getElementById('lbStatus').textContent.includes('yüklenemedi')")
    check('lb guest: service down -> friendly error', ok, page.inner_text('#lbStatus'))
    fake.down = False
    fake.others = []
    page.tap('#lbRefresh')
    ok = wait_until(page, "document.getElementById('lbStatus').textContent.includes('İlk sen ol')")
    check('lb guest: empty state', ok and page.locator('#lbList .lb-row').count() == 0, page.inner_text('#lbStatus'))
    check('lb guest: no page errors', not perrs and not [e for e in errs if 'Failed to load resource' not in e and 'ERR_' not in e], '; '.join(perrs + errs))
    ctx.close()

    # ------------------------------------------------------------ 12b) Çok büyük puanlar (2^53 üstü, ~1e30, en büyük sonekin ötesi)
    # Sunucu puanı numeric döndürür: JSON'da uzun tam sayı olarak gelir (ör. 1234000000000000000000000000000).
    fake = FakeSupabase()
    fake.others = [('Holding.X', 15 * 10 ** 39, 5), ('Trilyoner', 1234 * 10 ** 27, 5), ('IkiUzeri53', 2 ** 53 + 2, 4), ('Normal', 5.5e6, 3)]
    ctx = new_ctx(fake)
    page, errs, perrs = open_page(ctx)
    page.click('[data-tab="siralama"]')
    ok = wait_until(page, "document.querySelectorAll('#lbList .lb-row').length === 4")
    scores = page.evaluate("[...document.querySelectorAll('#lbList .lb-score')].map(e => e.textContent)")
    check('huge scores: parsed and formatted (1,5e40 / 1,23 Non / 9 Kat / 5,5 Mn)', ok and scores == ['1,5e40 TL', '1,23 Non TL', '9,01 Kat TL', '5,5 Mn TL'], str(scores))
    check('huge scores: ~1e30 parsed exactly as a JS number', page.evaluate("Kodhane.leaderboard.state.rows[1].score === 1.234e30 && Kodhane.leaderboard.state.rows[0].score === 1.5e40"))
    check('huge scores: order kept, no errors', page.evaluate("Kodhane.leaderboard.state.view.top.map(r => r.rank).join()") == '1,2,3,4' and not perrs, '; '.join(perrs))
    ctx.close()

    # ------------------------------------------------------------ 13) Sıralama: girişli ama takma adı yok -> form, doğrulama, alınmış ad, katılım, sabitlenmiş satır
    fake = FakeSupabase()
    fake.others = others(60)
    UID_L, EMAIL_L = '33333333-3333-4333-8333-333333333333', 'lb@example.com'
    ctx = new_ctx(fake, mobile=True, init=seed_script(save=local_save(123456, started, clicks=99), session=session_obj(UID_L, EMAIL_L))
                  + "navigator.share = (d) => { window.__shared = d; return Promise.resolve(); };")
    page, errs, perrs = open_page(ctx)
    wait_until(page, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0', 10000)
    page.evaluate("document.getElementById('toast').innerHTML=''")
    page.tap('#bottomNav [data-view="siralama"]')
    ok = wait_until(page, "!!document.getElementById('lbNick')")
    check('lb signed-in: nickname form shown (no nickname yet)', ok and 'takma adını seç' in page.inner_text('#lbJoin') and page.inner_text('#lbNickSave') == 'Katıl'
          and 'E-posta adresin kimseye gösterilmez' in page.inner_text('#lbJoin'))
    check('lb signed-in: not on the board before joining', page.locator('.lb-row.me').count() == 0 and fake.rpc_calls and fake.rpc_calls[-1][0] is True)
    posts0 = fake.count('POST', PROFILES_PATH)
    for val, frag in (('ab', 'en az 3'), ('ali veli', 'harf, rakam'), ('Kodhane', 'uygun değil')):
        page.fill('#lbNick', val); page.tap('#lbNickSave'); page.wait_for_timeout(150)
        check('lb form: %r -> Turkish message' % val, frag in page.inner_text('#lbNickMsg') and fake.count('POST', PROFILES_PATH) == posts0, page.inner_text('#lbNickMsg'))
    page.fill('#lbNick', 'kodustası'); page.tap('#lbNickSave')
    ok = wait_until(page, "document.getElementById('lbNickMsg') && document.getElementById('lbNickMsg').textContent.includes('başka bir oyuncuda')")
    check('lb form: taken nickname (case-insensitive, server 409) -> "başka bir oyuncuda"', ok and fake.count('POST', PROFILES_PATH) == posts0 + 1,
          page.inner_text('#lbJoin').replace('\n', ' | '))
    check('lb form: typed value kept after error', page.input_value('#lbNick') == 'kodustası')
    page.fill('#lbNick', 'Çağrı_01'); page.tap('#lbNickSave')
    ok = wait_until(page, "document.querySelectorAll('#lbMe .lb-row.me').length === 1", 10000)
    check('lb join: profile saved for own user', fake.profiles.get(UID_L) == 'Çağrı_01', json.dumps(fake.profiles, ensure_ascii=False))
    check('lb join: own row pinned below top 50 with rank + "sen"', ok and page.locator('#lbList .lb-row').count() == 50
          and page.locator('#lbMe .lb-rank').inner_text() == '#61' and 'Çağrı_01' in page.locator('#lbMe .lb-name').inner_text()
          and 'sen' in page.locator('#lbMe .lb-you').inner_text(), page.inner_text('#lbMe').replace('\n', ' | '))
    me_row = [r for r in fake.last_board if r['is_me']]
    check('lb join: own score = cloud save totalEarned (>= local 123.456), game formatting', me_row and me_row[0]['score'] >= 123456
          and page.locator('#lbMe .lb-score').inner_text() == page.evaluate('Kodhane.tl(%r)' % me_row[0]['score']), json.dumps(me_row))
    check('lb join: joined text + toast', 'Çağrı_01' in page.inner_text('.lb-joined') and 'olarak görünüyorsun' in page.inner_text('.lb-joined') and 'Sıralamaya katıldın' in page.inner_text('#toast'))
    page.tap('#lbShare'); page.wait_for_timeout(150)
    shared = page.evaluate('window.__shared')
    check('lb share: text "Kodhane sıralamasında #61. sıradayım! Sen de ajansını kur: <link>"', shared and shared.get('text') == 'Kodhane sıralamasında #61. sıradayım! Sen de ajansını kur: ' + BASE + '/', json.dumps(shared, ensure_ascii=False))
    page.tap('#lbEdit')
    ok = wait_until(page, "!!document.getElementById('lbNick')")
    check('lb rename: form prefilled with current nickname, "Kaydet"', ok and page.input_value('#lbNick') == 'Çağrı_01' and page.inner_text('#lbNickSave') == 'Kaydet')
    page.fill('#lbNick', 'Çağrı.Yeni'); page.tap('#lbNickSave')
    ok = wait_until(page, "document.querySelector('#lbMe .lb-name') && document.querySelector('#lbMe .lb-name').textContent.includes('Çağrı.Yeni')", 10000)
    check('lb rename: saved and board refreshed', ok and fake.profiles[UID_L] == 'Çağrı.Yeni')
    check('lb signed-in: fits 390px, no page errors', page.evaluate('document.documentElement.scrollWidth') <= 390 and not perrs, '; '.join(perrs))
    ctx.close()

    # ------------------------------------------------------------ 14) Ekran görüntüsü: girişli, takma adlı, ilk 50 içinde (yerel sahte veri; üretime dokunmaz)
    fake = FakeSupabase()
    fake.others = others(14, top=1.5e10, f=1.7)
    UID_S = '44444444-4444-4444-8444-444444444444'
    sshot = local_save(2.35e9, started, clicks=4200)
    sshot['stage'] = 4
    fake.profiles[UID_S] = 'Aryen'
    ctx = new_ctx(fake, mobile=True, init=seed_script(save=sshot, session=session_obj(UID_S, 'aryen@example.com')))
    page, errs, perrs = open_page(ctx)
    wait_until(page, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0', 10000)
    page.tap('#bottomNav [data-view="siralama"]')
    ok = wait_until(page, "document.querySelectorAll('#lbList .lb-row.me').length === 1", 10000)
    me_rank = page.evaluate("document.querySelector('#lbList .lb-row.me .lb-rank').textContent")
    check('lb in top list: own row highlighted in place, not pinned', ok and page.is_hidden('#lbMe') and me_rank.startswith('#'), me_rank)
    page.evaluate("document.getElementById('toast').innerHTML=''"); page.wait_for_timeout(300)
    page.screenshot(path=SS + 'v3-siralama-mobile.png')
    ctx.close()

    b.close()

server.shutdown()
passed = sum(r[1] for r in results)
print('\nSUMMARY: %d/%d passed' % (passed, len(results)))
sys.exit(0 if passed == len(results) else 1)
