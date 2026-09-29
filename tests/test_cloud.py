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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fake_saves_v22 import RPC as SAVE_RPC, SaveStore  # noqa: E402  (Backend v2.2 kayıt sözleşmesi taklidi)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = int(os.environ.get('KODHANE_CLOUD_TEST_PORT', '8766'))
BASE = 'http://127.0.0.1:%d' % PORT
URL = BASE + '/index.html'
SS = os.path.join(ROOT, 'screenshots') + os.sep
OUT_SHOTS = os.environ.get('KODHANE_V44_SHOTS', '/workspace')   # v4.4 ekran görüntüleri (repoya girmez)
os.makedirs(SS, exist_ok=True)
FAKE = 'https://kodhane-test.supabase.co'
PROD_URL = 'https://kodhane-api.teserix.com'
OLD_PROD_URL = 'https://supabase.teserix.com'  # eski adres: aynı Supabase, geçiş süresince çalışır
PAGES = 'https://thejackaltr.github.io/kodhane/'
SAVES_PATH = '/rest/v1/kodhane_saves'
PROFILES_PATH = '/rest/v1/kodhane_profiles'
RPC_PATH = '/rest/v1/rpc/kodhane_leaderboard'
RPC7_PATH = '/rest/v1/rpc/kodhane_leaderboard_v7'   # v4.4 Backend paket B
LEGACY_IDS = ['freelancer', 'ev_ofisi', 'butik_studyo', 'ajans', 'dev_ajans', 'global_holding', 'teknoloji_devi', 'yapay_zeka_lab', 'mars_ofisi']
REV_KEY = 'kodhane_cloud_rev_v1'
COUNT_PATH = '/rest/v1/rpc/kodhane_count_event'
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
        self.otp_fail = None  # v4.4: (status, body, extra headers) -> /otp hata yanıtı (gönderim hatası metinleri)
        self.down = False
        self.profiles = {}   # uid -> nickname
        self.others = []     # takma adlı diğer oyuncular: (nickname, score, stage)
        self.rpc_calls = []  # (authorization kullanıcı mı, p_limit, p_game)
        self.v7 = False      # v4.4: kodhane_leaderboard_v7 var mı (Backend paket B); yoksa PostgREST 404 PGRST202
        self.v7_calls = []   # (authorization kullanıcı mı, gövde)
        self.v7_fail = None  # (status, body): v7 başka bir hatayla döner
        self.stage_ids = {}  # takma ad -> v7 stage_id (yoksa eski sıradan türetilir)
        self.hidden = set()  # yöneticinin gizlediği uid'ler
        self.pending = set() # puanı makul bulunmayan (kontrol edilen) uid'ler
        self.events = []     # anonim haber sayacı çağrıları: (p_event, kullanıcı jetonu var mı)
        self.saves = SaveStore()  # v2.2: revision kuralı + reset_save/restore_save/list_save_backups
        self.saves.rows = self.rows

    @staticmethod
    def nick_key(n):
        return n.translate(str.maketrans('ÇĞİIÖŞÜı', 'çğiiöşüi')).lower()

    def board(self, me_uid, limit, game='kodhane'):
        if (game or 'kodhane').strip().lower() != 'kodhane':
            return []
        rows = [(n, sc, st, None) for n, sc, st in self.others]
        flagged = []
        for uid, nick in self.profiles.items():
            d = (self.rows.get(uid) or {}).get('data') or {}
            if uid in self.hidden or uid in self.pending:
                if uid == me_uid:
                    flagged.append({'rank': None, 'nickname': nick, 'score': None, 'stage': None, 'is_me': True,
                                    'status': 'hidden' if uid in self.hidden else 'pending'})
                continue
            if isinstance(d.get('totalEarned'), (int, float)) and d['totalEarned'] >= 0:
                rows.append((nick, float(d['totalEarned']), d.get('stage'), uid))
        rows.sort(key=lambda r: -r[1])
        out, rank = [], 0
        for i, r in enumerate(rows):
            if i == 0 or r[1] != rows[i - 1][1]:
                rank = i + 1
            if i < limit or (me_uid and r[3] == me_uid):
                out.append({'rank': rank, 'nickname': r[0], 'score': r[1], 'stage': r[2], 'is_me': bool(me_uid) and r[3] == me_uid, 'status': 'ok'})
        return out + flagged

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
            if self.otp_fail:
                st, eb, hd = self.otp_fail
                return self.reply(route, st, eb, hd)
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
        if u.path == RPC7_PATH and method == 'POST':
            body = json.loads(req.post_data or '{}')
            self.v7_calls.append((bool(claims), body))
            nf = {'code': 'PGRST202', 'message': 'Could not find the function public.kodhane_leaderboard_v7(%s) in the schema cache' % ', '.join(sorted(body)),
                  'details': 'Searched for the function public.kodhane_leaderboard_v7 with parameters %s' % ', '.join(sorted(body)), 'hint': None}
            if not self.v7 or set(body) - {'p_limit'}:      # v7 yalnız p_limit alır: p_game gönderilirse fonksiyon bulunamaz
                return self.reply(route, 404, nf)
            if self.v7_fail:
                return self.reply(route, *self.v7_fail)
            rows = self.board(claims['sub'] if claims else None, int(body.get('p_limit') or 50))
            for r in rows:
                if r['status'] != 'ok':
                    r['stage_id'] = None
                else:
                    st = r.get('stage')
                    r['stage_id'] = self.stage_ids.get(r['nickname']) or (LEGACY_IDS[st] if isinstance(st, int) and 0 <= st < len(LEGACY_IDS) else None)
            self.last_board = rows
            return self.reply(route, 200, rows)
        if u.path == RPC_PATH and method == 'POST':
            body = json.loads(req.post_data or '{}')
            self.rpc_calls.append((bool(claims), body.get('p_limit'), body.get('p_game')))
            self.last_board = self.board(claims['sub'] if claims else None, int(body.get('p_limit') or 50), body.get('p_game', 'kodhane'))
            return self.reply(route, 200, self.last_board)
        if u.path == COUNT_PATH and method == 'POST':
            body = json.loads(req.post_data or '{}')
            ok = body.get('p_event') in ('news_leaderboard_shown', 'news_leaderboard_click')
            self.events.append((body.get('p_event'), bool(claims)))
            return self.reply(route, 200, ok)
        if u.path.startswith('/rest/v1/rpc/') and u.path.rsplit('/', 1)[1] in SAVE_RPC.values() and method == 'POST':
            st, body = self.saves.rpc(claims['sub'] if claims else None, u.path.rsplit('/', 1)[1], json.loads(req.post_data or '{}'))
            return self.reply(route, st, body)
        if u.path == PROFILES_PATH:
            if not claims:
                return self.reply(route, 401, {'code': '42501', 'message': 'permission denied for table kodhane_profiles'})
            uid = claims['sub']
            if method == 'GET':
                rows = [{'nickname': self.profiles[uid], 'hidden': uid in self.hidden}] if uid in self.profiles else []
                return self.reply(route, 200, rows)
            if method == 'POST':
                body = json.loads(req.post_data or '{}')
                if body.get('user_id') != uid:
                    return self.reply(route, 403, {'code': '42501', 'message': 'new row violates row-level security policy'})
                nick = re.sub(' {2,}', ' ', (body.get('nickname') or '').strip())
                if len(nick) < 3:
                    return self.reply(route, 400, {'code': '23514', 'message': 'nickname_too_short'})
                if any(self.nick_key(n) == self.nick_key(nick) for o, n in self.profiles.items() if o != uid) or \
                        any(self.nick_key(n) == self.nick_key(nick) for n, _, _ in self.others):
                    return self.reply(route, 409, {'code': '23505', 'message': 'duplicate key value violates unique constraint "kodhane_profiles_nick_key_uniq"'})
                if uid in self.profiles and self.nick_key(self.profiles[uid]) != self.nick_key(nick):
                    self.hidden.discard(uid)  # yeni ad gizlemeyi kaldırır (sunucudaki tetikleyiciyle aynı)
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
                out = None
                for it in items:
                    st, eb = self.saves.write(uid, it)
                    if st != 201:
                        return self.reply(route, st, eb)
                    out = eb
                # v4.2: Prefer return=representation + select=revision -> sunucunun sakladığı revision
                prefer = (req.headers.get('prefer') or '')
                sel = (q.get('select') or [''])[0]
                if 'return=representation' in prefer and 'revision' in sel and out and 'revision' in out:
                    return self.reply(route, 201, [out])  # PostgREST: representation always an array; maybeSingle unwraps
                return route.fulfill(status=201, headers=CORS, body='')
            if method == 'DELETE':
                # v2.2: istemci DELETE'i yasak (delete policy ve DELETE yetkisi kaldırıldı)
                return self.reply(route, 403, {'code': '42501', 'message': 'permission denied for table kodhane_saves'})
        return self.reply(route, 404, {'message': 'not found'})

    def count(self, method, path):
        return sum(1 for m, p, _ in self.log if m == method and p == path)


def cfg_script(extra=None, quiet=True):
    cfg = {'url': FAKE, 'key': 'sb_publishable_test_key'}
    cfg.update(extra or {})
    # KODHANE_QUIET: v4 aşama tebrik penceresi ve haberler kapalı (yalnızca haber testlerinde açık)
    return ('window.KODHANE_QUIET = true; ' if quiet else '') + 'window.KODHANE_CLOUD_CONFIG = %s;' % json.dumps(cfg)


def local_save(total, started, clicks=10, money=100.0, last_saved=None):
    now = int(time.time() * 1000)
    return {'version': 2, 'money': money, 'runEarned': total, 'totalEarned': total, 'clicks': clicks, 'clickEarned': clicks,
            'playTime': 600, 'startedAt': started, 'lastSaved': last_saved or now,
            'gens': {'stajyer': 3, 'junior': 1, 'senior': 0, 'tasarimci': 0, 'pm': 0, 'ai': 0, 'sunucu': 0, 'ofis': 0},
            'upgrades': [], 'shares': 0, 'prestigeCount': 0, 'boostLeft': 0, 'eventsClicked': 0, 'offlineEarned': 0, 'stage': 0,
            'buffs': [], 'achievements': [], 'reputation': 0}


def seed_script(save=None, session=None, tel=None):
    parts = ["(() => { if (sessionStorage.getItem('kh_seeded')) return; sessionStorage.setItem('kh_seeded','1');"]
    if tel is not None:   # v4.3: isimsiz sayaç izni (anonim sayaç ve haber penceresi buna bağlı)
        parts.append("localStorage.setItem('kodhane_tel_notice', '1'); localStorage.setItem('kodhane_tel', %s);" % json.dumps(tel))
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


check('config: URL is Kodhane\'s own Supabase (kodhane-api.teserix.com)', re.search(r"url: '([^']+)'", CLOUD_JS).group(1) == PROD_URL)
check('config: namespaced table kodhane_saves', re.search(r"table: '([^']+)'", CLOUD_JS).group(1) == 'kodhane_saves')
check('config: embedded key is the publishable anon key (never service_role)', jwt_claims(PROD_KEY).get('role') == 'anon', jwt_claims(PROD_KEY).get('role'))
_conf = re.compile(CONF_RE)
check('config: is-configured accepts kodhane-api.teserix.com, the old supabase.teserix.com and *.supabase.co',
      bool(_conf.match(PROD_URL)) and bool(_conf.match(OLD_PROD_URL)) and bool(_conf.match('https://abcd1234.supabase.co')), CONF_RE)
check('config: is-configured rejects look-alikes',
      not any(_conf.match(u) for u in ('https://supabase.teserix.com.evil.io', 'https://evil.io/supabase.teserix.com', 'http://supabase.teserix.com',
                                         'https://xsupabase.teserix.com', 'https://supabase.teserix.com/',
                                         'https://kodhane-api.teserix.com.evil.io', 'http://kodhane-api.teserix.com', 'https://xkodhane-api.teserix.com',
                                         'https://kodhane-api.teserix.com/', 'https://kodhane.teserix.com')))

with sync_playwright() as p:
    b = p.chromium.launch()

    def new_ctx(fake, mobile=False, extra_cfg=None, init=None, sw='block', cdn='serve', quiet=True):
        opts = dict(locale='tr-TR', service_workers=sw)
        if mobile:
            opts.update(viewport={'width': 390, 'height': 844}, device_scale_factor=2, is_mobile=True, has_touch=True)
        else:
            opts.update(viewport={'width': 1280, 'height': 800})
        ctx = b.new_context(**opts)
        ctx.add_init_script(cfg_script(extra_cfg, quiet))
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
    check('first login: local save uploaded', row is not None and row['data']['clicks'] == 42 and row['data']['totalEarned'] >= 5000 and row['save_version'] == 5,
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

    # ------------------------------------------------------------ 3e) v4.4: giriş e-postası gönderim hataları (Yazı r1 "Kod gönderim hataları"; /otp sahte yanıtları)
    TXT = {'rateLimit': 'Çok fazla deneme oldu, birkaç dakika sonra tekrar dene.',
           'quotaFull': 'Şu an giriş e-postası gönderemiyoruz. Giriş yapmadan oynamaya devam et, oyun bu cihazda kaydediliyor. Sonra tekrar dene.',
           'sendError': 'Giriş e-postası şu an gönderilemedi. Biraz sonra tekrar dene.',
           'sendFail': 'Bağlantı gönderilemedi. Adresi kontrol edip tekrar dene.'}
    NET_T = 'Bulut hizmetine şu an ulaşılamıyor. Oyun bu cihazda kaydedilmeye devam ediyor.'
    OFF_T = 'İnternet bağlantısı yok. Çevrimiçi olunca tekrar dene.'
    RESEND_ERR = 'Kod tekrar gönderilemedi. Biraz sonra yeniden dene.'
    NEWAPI = {'x-supabase-api-version': '2024-01-01'}
    CASES = [
        ('429 over_email_send_rate_limit (old body)', (429, {'code': 429, 'error_code': 'over_email_send_rate_limit', 'msg': 'email rate limit exceeded'}, None), 'rateLimit'),
        ('429 over_request_rate_limit (new API body)', (429, {'code': 'over_request_rate_limit', 'message': 'Request rate limit reached'}, NEWAPI), 'rateLimit'),
        ('429 "For security purposes" cooldown', (429, {'code': 429, 'error_code': 'over_email_send_rate_limit', 'msg': 'For security purposes, you can only request this after 41 seconds.'}, None), 'rateLimit'),
        ('429 with no code/message', (429, {}, None), 'rateLimit'),
        ('500 unexpected_failure "Error sending magic link email" (SMTP/Resend)', (500, {'code': 500, 'error_code': 'unexpected_failure', 'msg': 'Error sending magic link email'}, None), 'quotaFull'),
        ('500 unexpected_failure "Error sending confirmation email" (new user)', (500, {'code': 500, 'error_code': 'unexpected_failure', 'msg': 'Error sending confirmation email'}, None), 'quotaFull'),
        ('500 unexpected_failure "Error sending magic link email" (new API body)', (500, {'code': 'unexpected_failure', 'message': 'Error sending magic link email'}, NEWAPI), 'quotaFull'),
        # supabase-js 2.117.2 turns every 5xx into AuthRetryableFetchError (status kept, error_code dropped): a 500 whose message is not
        # GoTrue's "Error sending ... email" cannot be told apart from any other server fault -> sendError
        ('500 unexpected_failure, generic message (not identifiable as SMTP)', (500, {'code': 'unexpected_failure', 'message': 'Internal server error'}, NEWAPI), 'sendError'),
        ('400 validation_failed invalid format', (400, {'code': 400, 'error_code': 'validation_failed', 'msg': 'Unable to validate email address: invalid format'}, None), 'sendFail'),
        ('400 email_address_invalid', (400, {'code': 400, 'error_code': 'email_address_invalid', 'msg': 'Email address "a@b.co" is invalid'}, None), 'sendFail'),
        ('400 email_address_not_authorized (server config, not the address)', (400, {'code': 400, 'error_code': 'email_address_not_authorized', 'msg': 'Email address not authorized'}, None), 'sendError'),
        ('422 otp_disabled', (422, {'code': 422, 'error_code': 'otp_disabled', 'msg': 'Signups not allowed for otp'}, None), 'sendError'),
        ('500 without code', (500, {'message': 'boom'}, None), 'sendError'),
        ('503 service unavailable (retryable)', (503, {'message': 'service unavailable'}, None), 'sendError'),
        ('400 validation_failed on another field (not email)', (400, {'code': 400, 'error_code': 'validation_failed', 'msg': 'Invalid redirect_to'}, None), 'sendError'),
    ]
    fake = FakeSupabase()
    ctx = new_ctx(fake, mobile=True)
    page, errs, perrs = open_page(ctx)
    page.tap('#accountBtn'); wait_until(page, '!!Kodhane.cloud.state.client')
    check('send errors: texts exposed as keys, exactly Yazı r1', page.evaluate('Kodhane.cloud.TEXT') == {'cloud.' + k: v for k, v in TXT.items()}, page.evaluate('Kodhane.cloud.TEXT'))

    def send_once(sel='#accSend'):
        page.evaluate("Kodhane.cloud.state.cooldownUntil = 0; Kodhane.cloud.state.status = 'guest'; document.getElementById('accMsg').textContent = ''")
        n0 = len(fake.otp)
        page.tap(sel)
        wait_until(page, "Kodhane.cloud.state.status === 'error' || Kodhane.cloud.state.status === 'guest' && document.getElementById('accMsg').textContent !== ''", 8000)
        return page.inner_text('#accMsg'), len(fake.otp) - n0

    for name, fail, key in CASES:
        fake.otp_fail = fail
        page.fill('#accEmail', 'hata@example.com')
        msg, n = send_once()
        check('send error [%s] -> %s' % (name, key), msg == TXT[key] and n == 1 and page.evaluate("Kodhane.cloud.state.status") == 'error'
              and page.is_visible('#accEmail'), [msg, n])
    # sendFail yalnızca adres hatasında: diğer hiçbir durumda "Adresi kontrol" çıkmadı
    check('send errors: sendFail only for the two invalid-address cases', sum(1 for _, _, k in CASES if k == 'sendFail') == 2)
    # ağ hatası (istek kurulamadı) ve çevrimdışı: eski metinler aynen
    fake.otp_fail = None; fake.down = True
    msg, n = send_once()
    check('send error [network failure] -> unchanged network text', msg == NET_T, msg)
    fake.down = False
    ctx.set_offline(True)
    msg, n = send_once()
    check('send error [offline] -> unchanged "İnternet bağlantısı yok" text, no request', msg == OFF_T and n == 0, [msg, n])
    ctx.set_offline(False)
    # tekrar gönderim (kod adımı): hız sınırı / kota yeni metinler; diğer hatada eski tekrar gönderim metni
    msg, n = send_once()
    ok = wait_until(page, "!document.getElementById('accCodeForm').classList.contains('hidden')")
    check('send errors: a normal send still works afterwards (code step)', ok and n == 1)
    for fail, want, name in [((429, {'code': 429, 'error_code': 'over_email_send_rate_limit', 'msg': 'email rate limit exceeded'}, None), TXT['rateLimit'], 'rateLimit'),
                             ((500, {'code': 500, 'error_code': 'unexpected_failure', 'msg': 'Error sending magic link email'}, None), TXT['quotaFull'], 'quotaFull'),
                             ((503, {'message': 'service unavailable'}, None), RESEND_ERR, 'other (resend text kept)')]:
        fake.otp_fail = fail
        msg, n = send_once('#accResend')
        check('resend error -> %s' % name, msg == want and n == 1 and page.is_visible('#accCode'), [msg, n])
    fake.otp_fail = None
    check('send errors: no uncaught page errors', not perrs, '; '.join(perrs))
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
    ctx = new_ctx(fake, init=seed_script(save=local_save(5000, started, clicks=42), session=session_obj(UID_B, EMAIL_B), tel='off'))
    page, errs, perrs = open_page(ctx)
    ok = wait_until(page, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0', 10000)
    st = page.evaluate('Kodhane.state')
    check('conflict (cloud ahead): cloud save applied', ok and st['clicks'] == 9999 and st['gens']['senior'] == 7 and st['totalEarned'] >= 1e7, f"clicks={st['clicks']}")
    bk = page.evaluate("localStorage.getItem('%s')" % BACKUP_KEY)
    bk = json.loads(bk) if bk else {}
    check('conflict (cloud ahead): local save backed up', bk.get('clicks') == 42 and abs(bk.get('totalEarned', 0) - 5000) < 5, json.dumps(bk)[:120])
    check('conflict (cloud ahead): local storage now has cloud save', json.loads(page.evaluate("localStorage.getItem('%s')" % SAVE_KEY))['clicks'] == 9999)
    check('conflict (cloud ahead): UI re-rendered', page.evaluate("document.querySelector('[data-gen=\"senior\"] .gen-owned').textContent.trim()") == '7')
    pref = page.evaluate("[localStorage.getItem('kodhane_tel_notice'), localStorage.getItem('kodhane_tel'), !!document.querySelector('[data-test=tel-banner]')]")
    check('[prefs] conflict (cloud ahead): cloud load keeps the counter choice (off), no band', pref == ['1', 'off', False], pref)
    check('conflict (cloud ahead): no errors', not perrs and not errs, '; '.join(perrs + errs))
    ctx.close()

    # ------------------------------------------------------------ 5) çakışma: yerel önde -> yerel kalır, bulut yedeklenir ve güncellenir
    fake = FakeSupabase()
    fake.rows[UID_B] = {'data': local_save(100, started - 9 * 86400000, clicks=3), 'save_version': 2, 'updated_at': '2026-09-27T20:00:00Z'}
    ctx = new_ctx(fake, init=seed_script(save=local_save(1e6, started, clicks=500), session=session_obj(UID_B, EMAIL_B), tel='on'))
    page, errs, perrs = open_page(ctx)
    ok = wait_until(page, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0', 10000)
    st = page.evaluate('Kodhane.state')
    bk = json.loads(page.evaluate("localStorage.getItem('%s')" % BACKUP_KEY) or '{}')
    check('conflict (local ahead): local kept', ok and st['clicks'] == 500)
    check('conflict (local ahead): cloud save backed up', bk.get('clicks') == 3 and bk.get('totalEarned') == 100, json.dumps(bk)[:120])
    check('conflict (local ahead): cloud overwritten with local', fake.rows[UID_B]['data']['clicks'] == 500)
    pref = page.evaluate("[localStorage.getItem('kodhane_tel_notice'), localStorage.getItem('kodhane_tel'), !!document.querySelector('[data-test=tel-banner]')]")
    check('[prefs] conflict (local ahead): merge/cloud write keeps the counter choice (on), no band', pref == ['1', 'on', False], pref)
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
    ctx = new_ctx(fake, extra_cfg={'pushDelayMs': 1500}, init=seed_script(save=local_save(2000, started, clicks=20), session=session_obj(UID_A, EMAIL_A), tel='off'))
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
    pref = page.evaluate("[localStorage.getItem('kodhane_tel_notice'), localStorage.getItem('kodhane_tel'), !!document.querySelector('[data-test=tel-banner]')]")
    check('[prefs] sign-out keeps the counter choice (off), no band', pref == ['1', 'off', False], pref)
    check('sign-out: no page/console errors', not perrs and not errs, '; '.join(perrs + errs))
    ctx.close()

    # ------------------------------------------------------------ 8) girişliyken sıfırlama: satır silinmez, kodhane_reset_save RPC'si (v2.2)
    fake = FakeSupabase()
    ctx = new_ctx(fake, init=seed_script(save=local_save(3000, started, clicks=30), session=session_obj(UID_A, EMAIL_A)))
    page, errs, perrs = open_page(ctx)
    wait_until(page, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0', 10000)
    check('reset: row exists before (with revision)', UID_A in fake.rows and fake.rows[UID_A]['revision'] >= 1)
    rev0 = fake.rows[UID_A]['revision']
    page.click('[data-tab="stats"]')
    page.click('#resetBtn')
    check('reset: dialog mentions the backup (signed in)', 'gün boyunca yedekte kalır' in page.inner_text('#modal'))
    with page.expect_navigation():
        page.hover('#resetHold'); page.mouse.down(); page.wait_for_timeout(2300); page.mouse.up()
    page.wait_for_selector('#clickBtn')
    wait_until(page, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0', 10000)
    row = fake.rows.get(UID_A, {})
    check('reset: no DELETE, kodhane_reset_save RPC (no params), fresh save uploaded',
          fake.count('DELETE', SAVES_PATH) == 0 and (SAVE_RPC['reset'], {}) in fake.saves.rpc_log and SAVE_RPC['reset'] == 'kodhane_reset_save'
          and row.get('data', {}).get('clicks') == 0 and row.get('revision', 0) >= rev0 + 2 and row.get('best_score', 0) >= 3000,
          json.dumps({k: row.get(k) for k in ('revision', 'best_score')}))
    check('reset: backup kept on server', len(fake.saves.backups) == 1 and fake.saves.backups[0]['payload']['clicks'] == 30)
    check('reset: no page errors', not perrs, '; '.join(perrs))
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
    check('sw: cache version bumped (v4.4)', any(re.match(r'kodhane-v4\.4-', k) for k in keys), str(keys))
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

    # ------------------------------------------------------------ 11) üretim yapılandırması: GitHub Pages yolu + kodhane-api.teserix.com (geçersiz kılma yok)
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
    check('prod: magic link request goes to kodhane-api.teserix.com/auth/v1/otp', ok and len(fake.otp) == 1, json.dumps(fake.otp))
    check('prod: magic-link redirect is exactly ' + PAGES, fake.otp and fake.otp[0]['redirect_to'] == PAGES, fake.otp and fake.otp[0]['redirect_to'])
    check('prod: no page/console errors', not perrs and not errs, '; '.join(perrs + errs))
    ctx.close()

    # ------------------------------------------------------------ 12) Sıralama: misafir (mobil), boş liste, çevrimdışı, hata
    NAMES = ['KodUstası', 'Zeynep Dev', 'mert_42', 'AyşeYazılım', 'deploy-cuma', 'Çaycı_Hüseyin', 'Selin K', 'burakbey', 'Pikselci', 'GeceMesaisi',
             'Elif_UX', 'Tolga-io', 'Kübra', 'Emre_Ops', 'Duygu PM', 'CanBackend']
    def others(n, top=4.2e12, f=1.2):
        return [((NAMES[i] if i < len(NAMES) else 'oyuncu%02d' % i), round(top / (f ** i), 2), max(0, 5 - i // 12)) for i in range(n)]
    fake = FakeSupabase()
    fake.others = others(60)
    ctx = new_ctx(fake, mobile=True)
    page, errs, perrs = open_page(ctx)
    page.tap('#bottomNav [data-view="siralama"]')
    ok = wait_until(page, "document.querySelectorAll('#lbList .lb-row').length === 50")
    check('lb guest: top 50 listed from RPC', ok, str(page.evaluate("document.querySelectorAll('#lbList .lb-row').length")))
    check('lb guest: no SDK download, anonymous RPC call only', len(ctx.cdn_hits) == 0 and fake.rpc_calls and fake.rpc_calls[-1] == (False, 50, 'kodhane')
          and all(p in (RPC_PATH, RPC7_PATH) for _, p, _ in fake.log), str(fake.log[:3]))
    first = page.locator('#lbList .lb-row').first
    check('lb guest: row shows medal, nickname, stage and game-formatted score', first.locator('.lb-rank').inner_text() == '🥇'
          and first.locator('.lb-name').inner_text() == 'KodUstası' and first.locator('.lb-stage').inner_text() == '🌐 Global Holding'
          and first.locator('.lb-score').inner_text() == page.evaluate('Kodhane.tl(4.2e12)'), first.inner_text().replace('\n', ' | '))
    check('lb guest: info note + CTA', page.inner_text('#lbInfo') == 'Puan, oyuna başladığından beri kazandığın toplam para. Yatırım turunda sıfırlanmaz.'
          and page.is_visible('#lbSignIn') and page.inner_text('#lbSignIn') == 'Giriş yap'
          and page.inner_text('#lbJoin').startswith('Listeye girmek için giriş yap. İlerlemen de buluta kaydolur.'))
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
    ok = wait_until(page, "document.getElementById('lbStatus').textContent.startsWith('Sıralama yüklenemedi. Bağlantını kontrol edip yenile.')")
    check('lb guest: service down -> exact error copy + "Yenile" button', ok and page.is_visible('#lbRetry') and page.inner_text('#lbRetry') == 'Yenile', page.inner_text('#lbStatus'))
    fake.down = False
    fake.others = []
    n0 = len(fake.rpc_calls)
    page.tap('#lbRetry')
    ok = wait_until(page, "document.getElementById('lbStatus').textContent === 'Liste henüz boş. Birinciliği kapmak için tek proje yeter.'")
    check('lb guest: "Yenile" in error state re-fetches; empty state copy', ok and len(fake.rpc_calls) == n0 + 1 and page.locator('#lbList .lb-row').count() == 0, page.inner_text('#lbStatus'))
    loading = page.evaluate("(() => { const L = Kodhane.leaderboard.state; L.view = null; Kodhane.leaderboard.refresh(); return document.getElementById('lbStatus').textContent; })()")
    check('lb guest: loading copy "Sıralama derleniyor…"', loading == 'Sıralama derleniyor…', loading)
    wait_until(page, "!Kodhane.leaderboard.state.loading")
    n0 = len(fake.rpc_calls)
    page.tap('#bottomNav [data-view="kod"]'); page.tap('#bottomNav [data-view="siralama"]'); page.wait_for_timeout(300)
    check('lb guest: results cached ~60 s (re-opening the tab does not re-fetch)', len(fake.rpc_calls) == n0, str(len(fake.rpc_calls) - n0))
    check('lb guest: no page errors', not perrs and not [e for e in errs if 'Failed to load resource' not in e and 'ERR_' not in e], '; '.join(perrs + errs))
    ctx.close()

    # ------------------------------------------------------------ 12b) Çok büyük puanlar (2^53 üstü, ~1e30, en büyük sonekin ötesi)
    # Sunucu puanı numeric döndürür: JSON'da uzun tam sayı olarak gelir (ör. 1234000000000000000000000000000).
    fake = FakeSupabase()
    fake.others = [('Holding X', 15 * 10 ** 39, 5), ('Trilyoner', 1234 * 10 ** 27, 5), ('IkiUzeri53', 2 ** 53 + 2, 4), ('<img src=x onerror="window.__xss=1">', 5.5e6, 12)]
    ctx = new_ctx(fake)
    page, errs, perrs = open_page(ctx)
    page.click('[data-tab="siralama"]')
    ok = wait_until(page, "document.querySelectorAll('#lbList .lb-row').length === 4")
    scores = page.evaluate("[...document.querySelectorAll('#lbList .lb-score')].map(e => e.textContent)")
    check('huge scores: parsed and formatted (1,5e40 / 1,23e30 / 9 Kat / 5,5 Mn)', ok and scores == ['1,5e40 TL', '1,23e30 TL', '9,01 Kat TL', '5,5 Mn TL'], str(scores))
    check('huge scores: ~1e30 parsed exactly as a JS number', page.evaluate("Kodhane.leaderboard.state.rows[1].score === 1.234e30 && Kodhane.leaderboard.state.rows[0].score === 1.5e40"))
    check('huge scores: order kept, no errors', page.evaluate("Kodhane.leaderboard.state.view.top.map(r => r.rank).join()") == '1,2,3,4' and not perrs, '; '.join(perrs))
    page.wait_for_timeout(200)
    check('nicknames rendered as text only (no HTML injection)', page.locator('#lbList .lb-name').nth(3).inner_text() == '<img src=x onerror="window.__xss=1">'
          and page.locator('#lbList img').count() == 0 and page.evaluate('window.__xss') is None)
    check('stage beyond the current 9 shown as "Aşama 13" (no fixed cap)', page.locator('#lbList .lb-stage').nth(3).inner_text() == 'Aşama 13')
    ctx.close()

    # ------------------------------------------------------------ 12c) v4.4: kodhane_leaderboard_v7 var -> stage_id ile aşama adı (Unicorn / Şirketler Grubu)
    fake = FakeSupabase()
    fake.v7 = True
    fake.others = [('Unicornçu', 3.1e11, 5), ('GrupBaşkanı', 2.2e13, 5), ('TeknoDev', 4.4e15, 6), ('GlobalH', 5e9, 5), ('Marslı', 8.2e17, 8),
                   ('GelecekSürüm', 1e9, 5), ('Freelancer1', 500, 0)]
    fake.others.sort(key=lambda r: -r[1])
    fake.stage_ids = {'Unicornçu': 'unicorn', 'GrupBaşkanı': 'sirketler_grubu', 'GelecekSürüm': 'uzay_istasyonu'}
    ctx = b.new_context(locale='tr-TR', service_workers='block', viewport={'width': 360, 'height': 640}, device_scale_factor=1, is_mobile=True, has_touch=True)
    ctx.add_init_script(cfg_script(None, True))
    ctx.add_init_script(seed_script(tel='off'))   # isimsiz sayaç bandı kapalı (ekran görüntüsü)
    ctx.route(FAKE + '/**', fake.handle)
    ctx.route('https://cdn.jsdelivr.net/**', lambda r: r.fulfill(status=200, headers={'content-type': 'application/javascript; charset=utf-8', 'access-control-allow-origin': '*'}, body=SDK_BYTES))
    page, errs, perrs = open_page(ctx)
    check('v7: client legacy stage ids = fake / Backend legacy mapping', page.evaluate('Kodhane.LEGACY_STAGE_IDS') == LEGACY_IDS, page.evaluate('Kodhane.LEGACY_STAGE_IDS'))
    page.tap('#bottomNav [data-view="siralama"]')
    ok = wait_until(page, "document.querySelectorAll('#lbList .lb-row').length === 7")
    lab = dict(zip(page.evaluate("[...document.querySelectorAll('#lbList .lb-name')].map(e => e.textContent)"),
                   page.evaluate("[...document.querySelectorAll('#lbList .lb-stage')].map(e => e.textContent)")))
    check('v7: Unicorn and Şirketler Grubu shown with their own names (stage_id), not Global Holding', ok and lab.get('Unicornçu') == '🦄 Unicorn'
          and lab.get('GrupBaşkanı') == '🏬 Şirketler Grubu', json.dumps(lab, ensure_ascii=False))
    check('v7: other ids rendered from stage_id (Teknoloji Devi, Global Holding, Mars Ofisi, Freelancer)', lab.get('TeknoDev') == '🛰️ Teknoloji Devi'
          and lab.get('GlobalH') == '🌐 Global Holding' and lab.get('Marslı') == '🔴 Mars Ofisi' and lab.get('Freelancer1') == '🏠 Freelancer', json.dumps(lab, ensure_ascii=False))
    check('v7: unknown stage_id (newer server) falls back to the legacy stage label', lab.get('GelecekSürüm') == '🌐 Global Holding', lab.get('GelecekSürüm'))
    check('v7: called once with exactly {p_limit: 50} (no p_game), v6 not called', fake.v7_calls == [(False, {'p_limit': 50})] and fake.rpc_calls == []
          and page.evaluate('Kodhane.leaderboard.v7.api') == 'v7', [fake.v7_calls, fake.rpc_calls])
    check('v7: 360px, no horizontal overflow', page.evaluate('document.documentElement.scrollWidth') <= 360)
    page.evaluate("document.querySelector('#lbList').scrollIntoView({block: 'start'}); window.scrollBy(0, -120)")
    page.wait_for_timeout(300)
    page.screenshot(path=os.path.join(OUT_SHOTS, 'kodhane-v44-siralama-v7-360x640.png'))
    check('v7: no page/console errors', not perrs and not errs, '; '.join(perrs + errs))
    ctx.close()

    # ------------------------------------------------------------ 12d) v4.4: v7 yok (404 PGRST202) -> v6 ve bugünkü görünüm; karar oturumda önbellekli
    fake = FakeSupabase()
    fake.others = [('Unicornçu', 3.1e11, 5), ('TeknoDev', 4.4e15, 6)]
    fake.others.sort(key=lambda r: -r[1])
    ctx = new_ctx(fake, mobile=True)
    page, errs, perrs = open_page(ctx)
    page.tap('#bottomNav [data-view="siralama"]')
    ok = wait_until(page, "document.querySelectorAll('#lbList .lb-row').length === 2")
    lab = page.evaluate("[...document.querySelectorAll('#lbList .lb-stage')].map(e => e.textContent)")
    check('v7 missing: falls back to v6 (p_game kodhane), current rendering (Unicorn player shows Global Holding)', ok and len(fake.v7_calls) == 1
          and fake.rpc_calls == [(False, 50, 'kodhane')] and lab == ['🛰️ Teknoloji Devi', '🌐 Global Holding'] and page.evaluate('Kodhane.leaderboard.v7.api') == 'v6', [fake.v7_calls, fake.rpc_calls, lab])
    for _ in range(2):
        page.tap('#lbRefresh'); wait_until(page, "!Kodhane.leaderboard.state.loading")
    check('v7 missing: fallback cached in this session (2 refreshes -> v6 only, no more 404s)', len(fake.v7_calls) == 1 and len(fake.rpc_calls) == 3, [len(fake.v7_calls), len(fake.rpc_calls)])
    ttl = page.evaluate('Kodhane.leaderboard.v7.missingUntil - Date.now()')
    check('v7 missing: cache is temporary (~10 min, in memory only, nothing in localStorage)', 9 * 60000 < ttl <= 10 * 60000
          and not page.evaluate("Object.keys(localStorage).some(k => /v7|leaderboard/i.test(k) || /v7/.test(localStorage.getItem(k) || ''))"), ttl)
    fake.v7 = True; fake.stage_ids = {'Unicornçu': 'unicorn'}
    page.evaluate('Kodhane.leaderboard.v7.missingUntil = Date.now() - 1')   # 10 dk doldu
    page.tap('#lbRefresh'); wait_until(page, "!Kodhane.leaderboard.state.loading")
    lab = page.evaluate("[...document.querySelectorAll('#lbList .lb-stage')].map(e => e.textContent)")
    check('v7 missing: after the cache expires v7 is tried again and used once available', len(fake.v7_calls) == 2 and len(fake.rpc_calls) == 3
          and lab == ['🛰️ Teknoloji Devi', '🦄 Unicorn'], [len(fake.v7_calls), lab])
    fake.v7_fail = (500, {'code': 'XX000', 'message': 'boom'})
    page.tap('#lbRefresh')
    ok = wait_until(page, "document.getElementById('lbStatus').textContent.startsWith('Sıralama yüklenemedi.')")
    check('v7 other error (500): normal error copy, no silent v6 fallback', ok and len(fake.rpc_calls) == 3 and len(fake.v7_calls) == 3, [len(fake.rpc_calls), len(fake.v7_calls)])
    fake.v7_fail = None
    check('v7 missing: no page errors (404/500 resource logs only)', not perrs and not [e for e in errs if 'Failed to load resource' not in e], '; '.join(perrs + errs))
    ctx.close()
    # girişli: SDK üzerinden v7 404 -> v6 (p_game ile); satır stage_id'siz -> eski görünüm
    fake = FakeSupabase()
    UID_7, EMAIL_7 = str(uuid.uuid5(uuid.NAMESPACE_DNS, 'v7@example.com')), 'v7@example.com'
    fake.others = [('Unicornçu', 3.1e11, 5)]
    ctx = new_ctx(fake, mobile=True, init=seed_script(save=local_save(1000, started, clicks=9), session=session_obj(UID_7, EMAIL_7)))
    page, errs, perrs = open_page(ctx)
    wait_until(page, 'Kodhane.cloud.state.reconciled', 10000)
    page.tap('#bottomNav [data-view="siralama"]')
    ok = wait_until(page, "!Kodhane.leaderboard.state.loading && document.querySelectorAll('#lbList .lb-row').length >= 1", 10000)
    check('v7 missing (signed in, SDK): v7 tried with the user token, then v6', ok and fake.v7_calls[:1] == [(True, {'p_limit': 50})] and fake.rpc_calls
          and fake.rpc_calls[-1] == (True, 50, 'kodhane') and page.evaluate('Kodhane.leaderboard.v7.api') == 'v6', [fake.v7_calls, fake.rpc_calls])
    fake.v7 = True; fake.stage_ids = {'Unicornçu': 'sirketler_grubu'}
    page.evaluate('Kodhane.leaderboard.v7.missingUntil = 0')
    page.tap('#lbRefresh'); wait_until(page, "!Kodhane.leaderboard.state.loading")
    check('v7 present (signed in, SDK): stage_id rendered (Şirketler Grubu)', page.locator('#lbList .lb-stage').first.inner_text() == '🏬 Şirketler Grubu'
          and fake.v7_calls[-1] == (True, {'p_limit': 50}), page.locator('#lbList .lb-stage').first.inner_text())
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
    check('lb signed-in: nickname form copy (question, placeholder, button, note)', ok and page.inner_text('.lb-label') == 'Listede hangi adla görünmek istersin?'
          and page.get_attribute('#lbNick', 'placeholder') == 'Takma ad' and page.inner_text('#lbNickSave') == 'Listeye gir'
          and page.inner_text('#lbNickHint') == '3-16 karakter. E-postan hiçbir yerde görünmez.', page.inner_text('#lbJoin').replace('\n', ' | '))
    check('lb signed-in: not on the board before joining', page.locator('.lb-row.me').count() == 0 and fake.rpc_calls and fake.rpc_calls[-1][0] is True)
    posts0 = fake.count('POST', PROFILES_PATH)
    for val, frag in (('ab', 'Takma ad 3-16 karakter olmalı.'), ('  a  ', 'Takma ad 3-16 karakter olmalı.'), ('ali.veli', 'Harf, rakam, boşluk, - ve _ kullanabilirsin.'),
                      ('Kodhane', 'Bu ad listeye uygun değil. Başka bir ad dene.')):
        page.fill('#lbNick', val); page.tap('#lbNickSave'); page.wait_for_timeout(150)
        check('lb form: %r -> exact message' % val, frag == page.inner_text('#lbNickMsg') and fake.count('POST', PROFILES_PATH) == posts0, page.inner_text('#lbNickMsg'))
    page.fill('#lbNick', 'kodustası'); page.tap('#lbNickSave')
    ok = wait_until(page, "document.getElementById('lbNickMsg') && document.getElementById('lbNickMsg').textContent === 'Bu ad kapılmış. Başka bir tane dene.'")
    check('lb form: taken nickname (case-insensitive, server 409) -> "Bu ad kapılmış. Başka bir tane dene."', ok and fake.count('POST', PROFILES_PATH) == posts0 + 1,
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
    check('lb join: "Sen: #61" + toast', page.inner_text('.lb-joined') == 'Sen: #61' and page.locator('.lb-top').count() == 0 and 'Sıralamaya katıldın' in page.inner_text('#toast'), page.inner_text('#lbJoin'))
    page.tap('#lbShare'); page.wait_for_timeout(150)
    shared = page.evaluate('window.__shared')
    check('lb share: text "Kodhane sıralamasında #61. sıradayım! Sen de ajansını kur: <link>"', shared and shared.get('text') == 'Kodhane sıralamasında #61. sıradayım! Sen de ajansını kur: ' + BASE + '/', json.dumps(shared, ensure_ascii=False))
    page.tap('#lbEdit')
    ok = wait_until(page, "!!document.getElementById('lbNick')")
    check('lb rename: form prefilled with current nickname, "Listeye gir"', ok and page.input_value('#lbNick') == 'Çağrı_01' and page.inner_text('#lbNickSave') == 'Listeye gir')
    page.fill('#lbNick', '  Çağrı   Yeni '); page.tap('#lbNickSave')
    ok = wait_until(page, "document.querySelector('#lbMe .lb-name') && document.querySelector('#lbMe .lb-name').textContent.includes('Çağrı Yeni')", 10000)
    check('lb rename: space allowed, repeated spaces collapsed, board refreshed', ok and fake.profiles[UID_L] == 'Çağrı Yeni', json.dumps(fake.profiles, ensure_ascii=False))
    # sunucu puanı makul bulmazsa: listede yok, kendi kutusunda "kontrol ediliyor" (neden söylenmez)
    fake.pending.add(UID_L)
    page.tap('#lbRefresh')
    ok = wait_until(page, "document.getElementById('lbJoin').textContent.includes('Puanın kontrol ediliyor. Kısa süre içinde listede görünürsün.')", 10000)
    check('lb pending: exact copy, no own row, no rank, no share', ok and page.locator('.lb-row.me').count() == 0 and page.locator('#lbShare').count() == 0
          and page.is_hidden('#lbMe') and 'Sen:' not in page.inner_text('#lbJoin'), page.inner_text('#lbJoin').replace('\n', ' | '))
    fake.pending.discard(UID_L)
    # yönetici takma adı gizlerse: listede yok, mesaj + form; aynı ad gizli kalır, yeni ad gizlemeyi kaldırır
    fake.hidden.add(UID_L)
    page.tap('#lbRefresh')
    ok = wait_until(page, "document.getElementById('lbJoin').textContent.includes('Takma adın listeden kaldırıldı. Yeni bir ad seçebilirsin.') && !!document.getElementById('lbNick')", 10000)
    check('lb hidden: exact copy + nickname form (empty), not listed', ok and page.input_value('#lbNick') == '' and page.locator('.lb-row.me').count() == 0
          and page.inner_text('#lbNickSave') == 'Listeye gir', page.inner_text('#lbJoin').replace('\n', ' | '))
    page.fill('#lbNick', 'ÇAĞRI YENİ'); page.tap('#lbNickSave')
    page.wait_for_timeout(600)
    check('lb hidden: same name (other case) keeps hidden', UID_L in fake.hidden and 'listeden kaldırıldı' in page.inner_text('#lbJoin'), page.inner_text('#lbJoin').replace('\n', ' | '))
    page.fill('#lbNick', 'Yeni-Ad_2'); page.tap('#lbNickSave')
    ok = wait_until(page, "document.querySelector('#lbMe .lb-name') && document.querySelector('#lbMe .lb-name').textContent.includes('Yeni-Ad_2')", 10000)
    check('lb hidden: new nickname clears hidden -> listed again', ok and UID_L not in fake.hidden and 'listeden kaldırıldı' not in page.inner_text('#lbJoin')
          and page.inner_text('.lb-joined') == 'Sen: #61', page.inner_text('#lbJoin').replace('\n', ' | '))
    # birinci olunca
    fake.others = others(3, top=1000, f=2)
    page.tap('#lbRefresh')
    ok = wait_until(page, "document.querySelector('.lb-joined') && document.querySelector('.lb-joined').textContent === 'Sen: #1'", 10000)
    check('lb #1: "Sen: #1" + "Zirvedesin. Logoyu büyütmenin tam zamanı."', ok and page.inner_text('.lb-top') == 'Zirvedesin. Logoyu büyütmenin tam zamanı.', page.inner_text('#lbJoin').replace('\n', ' | '))
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
    page.screenshot(path=SS + 'v3-siralama-mobile-2.png')
    ctx.close()

    # ------------------------------------------------------------ 15) v4 haberleri: bayrak kayıtta, cihazlar arasında birleşir; sayaç anonim
    def news_title(page):
        return page.evaluate("document.getElementById('modal').classList.contains('hidden') ? null : document.getElementById('modalTitle').textContent")
    UID_N = '55555555-5555-4555-8555-555555555555'
    # a) başka cihazda görülmüş (bulut önde) -> bu cihazda çıkmaz
    fake = FakeSupabase()
    cs = local_save(7777, started - 86400000, clicks=77); cs['newsSeen'] = ['siralama', 'acik_ofis']
    fake.rows[UID_N] = {'data': cs, 'save_version': 3, 'updated_at': '2099-01-01T00:00:00Z'}
    ctx = new_ctx(fake, quiet=False, init=seed_script(save=local_save(5000, started, clicks=42), session=session_obj(UID_N, 'news@example.com'), tel='on'))
    page, errs, perrs = open_page(ctx)
    ok = wait_until(page, 'Kodhane.cloud.state.reconciled', 8000)
    page.wait_for_timeout(5500)
    check('news: dismissed on another device (cloud ahead) -> not shown here', ok and news_title(page) is None and 'siralama' in page.evaluate('Kodhane.state.newsSeen') and not fake.events,
          '%s %s' % (news_title(page), fake.events))
    ctx.close()
    # b) bu cihazda görülmüş, bulut önde ama bayraksız -> birleşir, buluta da yazılır
    fake = FakeSupabase()
    fake.rows[UID_N] = {'data': local_save(7777, started - 86400000, clicks=77), 'save_version': 2, 'updated_at': '2099-01-01T00:00:00Z'}
    ls = local_save(5000, started, clicks=42); ls['newsSeen'] = ['siralama', 'acik_ofis']
    ctx = new_ctx(fake, quiet=False, init=seed_script(save=ls, session=session_obj(UID_N, 'news@example.com'), tel='on'))
    page, errs, perrs = open_page(ctx)
    ok = wait_until(page, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0', 8000)
    page.wait_for_timeout(5500)
    check('news: seen flag of this device survives loading the cloud save and is pushed back', ok and page.evaluate('Kodhane.state.clicks') == 77 and
          'siralama' in page.evaluate('Kodhane.state.newsSeen') and 'siralama' in (fake.rows[UID_N]['data'].get('newsSeen') or []) and news_title(page) is None,
          json.dumps(fake.rows[UID_N]['data'].get('newsSeen')))
    ctx.close()
    # c) yerel önde, bayrak yalnızca bulutta -> birleşir
    fake = FakeSupabase()
    cs = local_save(100, started - 9 * 86400000, clicks=3); cs['newsSeen'] = ['siralama', 'acik_ofis']
    fake.rows[UID_N] = {'data': cs, 'save_version': 3, 'updated_at': '2026-09-27T20:00:00Z'}
    ctx = new_ctx(fake, quiet=False, init=seed_script(save=local_save(1e6, started, clicks=500), session=session_obj(UID_N, 'news@example.com'), tel='on'))
    page, errs, perrs = open_page(ctx)
    ok = wait_until(page, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0', 8000)
    page.wait_for_timeout(5500)
    check('news: local save ahead keeps the cloud flag (no news, pushed with flag)', ok and page.evaluate('Kodhane.state.clicks') == 500 and news_title(page) is None and
          'siralama' in (fake.rows[UID_N]['data'].get('newsSeen') or []), json.dumps(fake.rows[UID_N]['data'].get('newsSeen')))
    ctx.close()
    # d) girişli oyuncu: haber bir kez, sayaç kullanıcı jetonu olmadan (anonim), bayrak buluta gider
    fake = FakeSupabase()
    ctx = new_ctx(fake, quiet=False, init=seed_script(save=local_save(5000, started, clicks=42), session=session_obj(UID_N, 'news@example.com'), tel='on'))
    page, errs, perrs = open_page(ctx)
    ok = wait_until(page, "!document.getElementById('modal').classList.contains('hidden') && document.getElementById('modalTitle').textContent === 'Yeni: Sıralama!'", 10000)
    page.click('#modalActions button:has-text("Sıralamaya bak")')
    page.wait_for_timeout(500)
    check('news (signed in): shown, both events counted anonymously (anon key only)', ok and fake.events == [('news_leaderboard_shown', False), ('news_leaderboard_click', False)], fake.events)
    page.evaluate("Object.defineProperty(document, 'hidden', {configurable: true, get: () => true}); document.dispatchEvent(new Event('visibilitychange'));")
    page.wait_for_timeout(1000)
    check('news (signed in): flag reaches the cloud save', ok and 'siralama' in (fake.rows.get(UID_N, {}).get('data', {}).get('newsSeen') or []),
          json.dumps(fake.rows.get(UID_N, {}).get('data', {}).get('newsSeen')))
    check('news (signed in): no page errors', not perrs, '; '.join(perrs))
    ctx.close()

    # ------------------------------------------------------------ 16) v4.4: bulut yazması 426 (PT426 save_version_too_old; Backend paket B sürüm koruması)
    fake = FakeSupabase()
    UID_O, EMAIL_O = str(uuid.uuid5(uuid.NAMESPACE_DNS, 'eski-sekme@example.com')), 'eski-sekme@example.com'
    ctx = b.new_context(locale='tr-TR', service_workers='block', viewport={'width': 360, 'height': 640}, device_scale_factor=1, is_mobile=True, has_touch=True)
    ctx.add_init_script(cfg_script(None, True))
    ctx.add_init_script(seed_script(save=local_save(5000, started, clicks=50), session=session_obj(UID_O, EMAIL_O), tel='off'))
    ctx.route(FAKE + '/**', fake.handle)
    ctx.route('https://cdn.jsdelivr.net/**', lambda r: r.fulfill(status=200, headers={'content-type': 'application/javascript; charset=utf-8', 'access-control-allow-origin': '*'}, body=SDK_BYTES))
    page, errs, perrs = open_page(ctx)
    ok = wait_until(page, 'Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0', 10000)
    check('426: signed in, first write ok (row v5)', ok and fake.rows[UID_O]['data'].get('saveVersion') == 5)
    # başka cihazda daha yeni sürüm (saveVersion 6) yazdı; sunucuda sürüm koruması açık
    fake.saves.version_guard = True
    newer = dict(fake.rows[UID_O]['data'], saveVersion=6, version=6, clicks=777, totalEarned=99999.0)
    fake.rows[UID_O] = dict(fake.rows[UID_O], data=newer, save_version=6, revision=fake.rows[UID_O]['revision'] + 1)
    row_before = json.dumps(fake.rows[UID_O], sort_keys=True)
    page.evaluate("Kodhane.state.clicks += 5; Kodhane.save()")
    local_before = page.evaluate("localStorage.getItem('%s')" % SAVE_KEY)
    posts0 = fake.count('POST', SAVES_PATH)
    r = page.evaluate('Kodhane.cloud.push(true)')
    page.wait_for_timeout(300)
    TT = {'title': 'Oyunun yeni sürümü var', 'text': 'Hesabına oyunun yeni sürümünden kayıt yapıldı, sayfayı yenileyince güncel kaydın yüklenecek.',
          'btn': 'Sayfayı yenile', 'textShort': 'Sayfayı yenile, güncel kaydın yüklenecek.'}
    check('426 texts: update.olderTab.* verbatim (Yazı eski-sekme r1)', all(page.evaluate("Kodhane.UI_TEXT['update.olderTab.%s']" % k) == v for k, v in TT.items())
          and page.evaluate("Object.keys(Kodhane.UI_TEXT).filter(k => /saveTooOld/.test(k)).length") == 0)
    check('426: push fails once (the 426 write), server row unchanged', r is False and fake.count('POST', SAVES_PATH) == posts0 + 1 and json.dumps(fake.rows[UID_O], sort_keys=True) == row_before,
          [r, fake.count('POST', SAVES_PATH) - posts0])
    check('426: recorded as PT426 / 426 / save_version_too_old', page.evaluate('Kodhane.cloud.state.lastTooOld') == {'code': 'PT426', 'message': 'save_version_too_old', 'status': 426,
          'details': 'sent saveVersion 5, stored saveVersion 6'}, page.evaluate('Kodhane.cloud.state.lastTooOld'))
    band = page.inner_text('#updateBar')
    check('426: olderTab band shown (title, short text at 360px, "Sayfayı yenile"), not the generic error', page.is_visible('#updateBar')
          and page.get_attribute('#updateBar', 'data-test') == 'older-tab-band' and page.inner_text('#updateBar .ub-title') == TT['title']
          and page.inner_text('#updateBar .ub-text') in (TT['text'], TT['textShort']) and page.inner_text('#updateBtn') == TT['btn']
          and 'tekrar denenecek' not in band and 'Buluta kaydedilemedi' not in band, band)
    check('426: account status = olderTab text (no generic "Buluta kaydedilemedi; tekrar denenecek")', page.evaluate('Kodhane.cloud.state.message') == TT['text']
          and 'tekrar denenecek' not in page.evaluate('Kodhane.cloud.state.message'), page.evaluate('Kodhane.cloud.state.message'))
    # tekrar yok: zamanlayıcı, elle push, flush (pagehide/visibilitychange), otomatik kayıt, sıralama yenileme
    for _ in range(5):
        page.tap('#clickBtn')
    page.evaluate("Kodhane.save(); Kodhane.cloud.push(true); Kodhane.cloud.push(false); Kodhane.cloud.flush(); window.dispatchEvent(new Event('pagehide')); document.dispatchEvent(new Event('visibilitychange'))")
    page.evaluate("Kodhane.cloud.state.pushTimer")
    page.tap('#bottomNav [data-view="siralama"]'); page.wait_for_timeout(1500)
    check('426: zero retries (no further save writes; no push timer)', fake.count('POST', SAVES_PATH) == posts0 + 1 and page.evaluate('Kodhane.cloud.state.pushTimer') is None,
          fake.count('POST', SAVES_PATH) - posts0)
    check('426: local save untouched (byte-equal after clicks, save(), pagehide, visibilitychange)', page.evaluate("localStorage.getItem('%s')" % SAVE_KEY) == local_before)
    check('426: writes blocked in this tab (reset / Yatırım Turu guarded like newerSave)', page.evaluate('Kodhane.writesBlocked()') is True)
    page.tap('#bottomNav [data-view="kod"]'); page.wait_for_timeout(200)
    page.screenshot(path=os.path.join(OUT_SHOTS, 'kodhane-v44-eski-sekme-360x640.png'))
    # aynı anda newerSave (daha yeni kayıt okundu) ve servis çalışanı güncellemesi: tek bant, olderTab metni
    page.evaluate("Kodhane.guardFuture({saveVersion: 6}, 'test'); Kodhane.showUpdate({postMessage() {}})")
    page.wait_for_timeout(150)
    check('overlap: olderTab + newerSave + SW update -> ONE band, olderTab text only', page.locator('.update-bar:not(.hidden)').count() == 1
          and page.get_attribute('#updateBar', 'data-test') == 'older-tab-band' and page.inner_text('#updateBar .ub-title') == TT['title']
          and 'ilerlemen korunuyor' not in page.inner_text('#updateBar') and 'Yeni sürüm hazır' not in page.inner_text('#updateBar'), page.inner_text('#updateBar'))
    page.set_viewport_size({'width': 1280, 'height': 800}); page.wait_for_timeout(200)
    check('426 band (wide screen): title + full text', page.inner_text('#updateBar .ub-text') == TT['text'], page.inner_text('#updateBar'))
    check('426: no page errors', not perrs, '; '.join(perrs))
    # "Sayfayı yenile" -> v4.4 yeniden açılır: buluttaki kayıt v6 -> newerSave bandı, yerel kayıt buluttan EZİLMEZ, yazma yok
    posts1 = fake.count('POST', SAVES_PATH)
    with page.expect_navigation(timeout=15000):
        page.click('#updateBtn')
    page.wait_for_selector('#clickBtn')
    ok = wait_until(page, "Kodhane.writesBlocked() && !document.getElementById('updateBar').classList.contains('hidden')", 10000)
    after = json.loads(page.evaluate("localStorage.getItem('%s')" % SAVE_KEY))
    lb = json.loads(local_before)
    check('426 -> reload (same v4.4 still served): cloud save is v6 -> newerSave band, the v6 cloud save is NOT applied, local progress kept, no writes',
          ok and page.get_attribute('#updateBar', 'data-test') == 'newer-save-band' and after['clicks'] == lb['clicks'] == 55 and page.evaluate('Kodhane.state.clicks') == 55
          and fake.count('POST', SAVES_PATH) == posts1 and json.dumps(fake.rows[UID_O], sort_keys=True) == row_before, [after['clicks'], page.get_attribute('#updateBar', 'data-test')])
    ctx.close()

    # ------------------------------------------------------------ 17) v4.4 açılışı: eski sekmenin yerel kaydı mı, buluttaki daha yeni kayıt mı? (cloud.js reconcile)
    def boot(local, cloud_row, rev=None):
        f = FakeSupabase()
        uid, email = str(uuid.uuid4()), 'boot@example.com'
        f.rows[uid] = cloud_row
        extra = '' if rev is None else "localStorage.setItem(%s, %s);" % (json.dumps(REV_KEY), json.dumps(json.dumps({'uid': uid, 'rev': rev})))
        c = new_ctx(f, init=seed_script(save=local, session=session_obj(uid, email)) + extra)
        pg, _, pe = open_page(c)
        wait_until(pg, 'Kodhane.cloud.state.reconciled && !Kodhane.cloud.state.reconciling', 10000)
        pg.wait_for_timeout(600)
        out = {'clicks': pg.evaluate('Kodhane.state.clicks'), 'local': json.loads(pg.evaluate("localStorage.getItem('%s')" % SAVE_KEY))['clicks'],
               'backup': json.loads(pg.evaluate("localStorage.getItem('%s') || 'null'" % BACKUP_KEY) or 'null'), 'row': f.rows[uid]['data'].get('clicks'),
               'toast': pg.inner_text('#toast'), 'modal': pg.is_visible('#modal'), 'perrs': pe}
        c.close()
        return out
    old_local = dict(local_save(5000, started, clicks=50), version=4, saveVersion=4)     # v4.3.1 sekmesinin son yerel kaydı
    def cloud_row(total, clicks, rev):
        d = dict(local_save(total, started, clicks=clicks), version=5, saveVersion=5)
        return {'data': d, 'save_version': 5, 'updated_at': '2026-09-29T18:00:00Z', 'revision': rev, 'strict_revision': True, 'best_score': total, 'best_stage': 0}
    o = boot(old_local, cloud_row(9000, 90, 4), rev=3)
    # reconcile() önce K.save() çağırır: yerel lastSaved = şimdi > bulutun updated_at -> needsBackup doğru, eski yerel kayıt yedeklenir
    check('boot A (server revision ahead of this device, cloud further): cloud save loaded, local save overwritten with it, old local copied to backup slot, no dialog',
          o['clicks'] == 90 and o['local'] == 90 and o['backup'] and o['backup']['clicks'] == 50 and not o['modal'] and not o['perrs']
          and 'başka bir cihazda ya da sekmede devam ettin' in o['toast'], {k: o[k] for k in ('clicks', 'local', 'toast')})
    o = boot(dict(old_local, totalEarned=20000.0, runEarned=20000.0), cloud_row(9000, 90, 4), rev=3)
    check('boot B (server revision ahead, this device further): cloud save STILL loaded (revision rule), old local copied to the local backup slot, no dialog',
          o['clicks'] == 90 and o['local'] == 90 and o['backup'] and o['backup']['clicks'] == 50 and not o['modal'], {k: o[k] for k in ('clicks', 'local', 'toast')})
    o = boot(dict(old_local, totalEarned=20000.0, runEarned=20000.0), cloud_row(9000, 90, 4), rev=None)
    check('boot C (no revision known on this device, this device further): local save wins and is written to the cloud',
          o['clicks'] == 50 and o['local'] == 50 and o['row'] == 50, {k: o[k] for k in ('clicks', 'local', 'row')})
    o = boot(old_local, cloud_row(9000, 90, 3), rev=3)
    check('boot D (same revision, cloud further): cloud save loaded (higher total earned)', o['clicks'] == 90 and o['local'] == 90, o)

    b.close()

server.shutdown()
passed = sum(r[1] for r in results)
print('\nSUMMARY: %d/%d passed' % (passed, len(results)))
sys.exit(0 if passed == len(results) else 1)
