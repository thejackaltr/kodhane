"""Kodhane v4.3.1 testleri (Playwright, headless Chromium; ağ yok, gerçek oyuncu kaydı yok).

  [text]    Yatırım Turu / Halka Arz onay metinleri + Yatırım sekmesi: {b}, {x} ve #prPer, oyunun ÜRETİMDE kullandığı çarpandan
            (Kodhane.globalMult, hisse sayısı değiştirilerek) sayısal olarak türetilir; Yatırımcı Güveni kapalı ve açık.
  [layout]  İzin bandı açıkken 390x844, 375x667, 360x640, 568x320, 1280x800: "Kod yaz" + altındaki ipucu satırı ve bant/alt
            çubuk düğmeleri aynı anda görünür ve en üstte (elementFromPoint, 5 nokta); uzun ekranda yerleşim değişmez.
  [newer]   İleri sürüm koruması: bilinenden yeni saveVersion'lı kayıt hiçbir yoldan geri yazılmaz (yerel kayıt bayt bayt
            aynı kalır, sahte Supabase'e sıfır yazma isteği); tek "Yenile" bandı; eski/güncel kayıtlar eskisi gibi.
Oyun http://kodhane.test/ altında Playwright route ile depo dosyalarından sunulur (sunucu/port yok). Supabase adresi
sahte (https://kodhane-test.supabase.co, route); güvenlik ağı: gerçek adlar 127.0.0.1:9'a (kapalı port) yönlenir.
    python3 tests/test_v431.py          (ekran görüntüleri: KODHANE_V431_SHOTS, varsayılan /workspace)
"""
import base64
import json
import mimetypes
import os
import re
import sys
import time
import urllib.parse

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fake_saves_v22 import RPC as SAVE_RPC, SaveStore, iso  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.environ.get('KODHANE_V431_SHOTS', '/workspace')
BASE = 'http://kodhane.test/'
FAKE = 'https://kodhane-test.supabase.co'
SAVE_KEY = 'kodhane_ajans_save_v2'
EPOCH_KEY = 'kodhane_save_epoch'
BACKUP_KEY = 'kodhane_ajans_save_backup'
AUTH_KEY = 'kodhane_auth_v1'
SAVES_PATH = '/rest/v1/kodhane_saves'
SAFETY = ('MAP analiz.teserix.com 127.0.0.1:9, MAP kodhane-api.teserix.com 127.0.0.1:9, MAP supabase.teserix.com 127.0.0.1:9, '
          'MAP kodhane.teserix.com 127.0.0.1:9, MAP thejackaltr.github.io 127.0.0.1:9, MAP cdn.jsdelivr.net 127.0.0.1:9, '
          'MAP acikofis.teserix.com 127.0.0.1:9, MAP *.supabase.co 127.0.0.1:9')
GAME = open(os.path.join(ROOT, 'game.js'), encoding='utf-8').read()
CLOUD = open(os.path.join(ROOT, 'cloud.js'), encoding='utf-8').read()
HTML = open(os.path.join(ROOT, 'index.html'), encoding='utf-8').read()
SDK_URL = re.search(r"sdk: '([^']+)'", CLOUD).group(1)
SDK_FILE = os.path.join(ROOT, 'tests', '.cache', os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(SDK_URL)))) + '.js')
SDK_BYTES = open(SDK_FILE, 'rb').read() if os.path.exists(SDK_FILE) else None  # test_cloud.py önbelleğe alır
results = []


def check(name, cond, info=''):
    results.append((name, bool(cond), info))
    print(('PASS' if cond else 'FAIL'), name, info if not cond or os.environ.get('VERBOSE') else '')


def note(msg):
    print('     ' + msg)


def trnum(s):  # "1.234,5" -> 1234.5
    return float(s.replace('.', '').replace(',', '.'))


def strip_tags(h):
    return re.sub(r'<[^>]+>', '', h.replace('<br>', '\n'))


# ---------------------------------------------------------------- onaylı metinler (istekteki gibi, birebir)
APPROVED = {
    'intro': "Şirketini yatırımcılara sun: paran, çalışanların ve geliştirmelerin sıfırlanır, karşılığında Halka Arz'a kadar geçerli <b>üretim bonusu</b> kazanırsın. Her <b>Yatırımcı Hissesi</b> tüm kazançlara <b id=\"prPer\">+%10</b> ekler. Başarımların, itibarın ve günlük serin korunur.",
    'label': 'Yatırımcı bonusu',
    'hint': "Başarımlarını, itibarını ve günlük serini korumak istiyorsan sıfırlamak yerine yatırım turuna çık. Yatırım turunda bunlar korunur, üstüne Halka Arz'a kadar geçerli bir üretim bonusu kazanırsın.",
    'prestige': "Yatırımcılar şirketine <b>{g} hisse</b> karşılığında yatırım yapacak. Paran, çalışanların ve geliştirmelerin sıfırlanır; karşılığında Halka Arz'a kadar tüm kazançlara <b>+%{b}</b> bonus alırsın. Başarımların, itibarın ve günlük serin korunur.",
    'ipo': "Kasa, çalışanlar, geliştirmeler ve yatırımcı hisselerin sıfırlanacak. Borsa Payı Ağacı, başarımların ve sıralamadaki puanın olduğu gibi kalır.<br>Şu anki +%{x} yatırımcı bonusun sıfırlanır, karşılığında <b>{n} Borsa Payı</b> kazanırsın.<br><small>Harcamadığın her Borsa Payı +%{u} üretim verir. İstersen payları hemen Borsa Payı Ağacı'nda kalıcı bonuslara harcayabilirsin.</small>",
    'newer': '✨ Yeni sürüm hazır, ilerlemen korunuyor. Devam etmek için yenile.',
    'newerShort': '✨ Yeni sürüm hazır, ilerlemen korunuyor.',
    'newerBtn': 'Yenile',
}

# ---------------------------------------------------------------- statik kontroller
check('[text] index.html: Yatırım Turu intro (approved copy, #prPer inside)', APPROVED['intro'] in HTML)
check('[text] index.html: label "Yatırımcı bonusu" (old "Kalıcı bonus" gone)', '<dt>Yatırımcı bonusu</dt><dd id="prBonus">' in HTML and 'Kalıcı bonus' not in HTML)
check('[text] old Halka Arz lines removed from game.js', 'Karşılığında kalıcı Borsa Payı kazanacaksın' not in GAME and 'Kazanacağın' not in GAME)
check('[text] untouched: achievements "kalıcı +%1", tree "Bu bonus artık kalıcı"', "kalıcı +%1 üretim" in GAME and 'Alındı! Bu bonus artık kalıcı.' in GAME)
check('[text] confirm texts come from the UI_TEXT table (approved copy verbatim)',
      json.dumps(APPROVED['prestige'], ensure_ascii=False) in GAME and json.dumps(APPROVED['ipo'], ensure_ascii=False) in GAME)
check('[newer] band copy in UI_TEXT (update.newerSave.*), no TODO marker left',
      all('"update.newerSave.%s": %s' % (k, json.dumps(APPROVED[v], ensure_ascii=False)) in GAME for k, v in (('text', 'newer'), ('textShort', 'newerShort'), ('btn', 'newerBtn')))
      and 'TODO(Yazı)' not in GAME)
check('[newer] no export/import path exists (no file input / FileReader / clipboard read)',
      not re.search(r'FileReader|type="file"|readText\(|importSave|exportSave', GAME + HTML + CLOUD))


def file_route(route):
    u = urllib.parse.urlsplit(route.request.url)
    path = u.path.lstrip('/') or 'index.html'
    fp = os.path.join(ROOT, path)
    if not os.path.isfile(fp):
        return route.fulfill(status=404, body='')
    route.fulfill(status=200, headers={'content-type': mimetypes.guess_type(fp)[0] or 'application/octet-stream', 'cache-control': 'no-store'},
                  body=open(fp, 'rb').read())


# ---------------------------------------------------------------- sahte Supabase (yalnızca test adresi; gerçek sunucuya asla)
def b64u(obj):
    return base64.urlsafe_b64encode(json.dumps(obj).encode()).rstrip(b'=').decode()


def session_obj(uid, email):
    now = int(time.time())
    tok = b64u({'alg': 'HS256', 'typ': 'JWT'}) + '.' + b64u({'sub': uid, 'email': email, 'role': 'authenticated', 'aud': 'authenticated',
                                                           'iat': now, 'exp': now + 3600, 'session_id': 's-' + uid}) + '.c2ln'
    user = {'id': uid, 'aud': 'authenticated', 'role': 'authenticated', 'email': email, 'email_confirmed_at': '2026-09-27T10:00:00Z',
            'app_metadata': {'provider': 'email', 'providers': ['email']}, 'user_metadata': {}, 'created_at': '2026-09-27T10:00:00Z'}
    return {'access_token': tok, 'refresh_token': 'rt-' + uid, 'token_type': 'bearer', 'expires_in': 3600, 'expires_at': now + 3600, 'user': user}


CORS = {'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': 'GET,POST,PATCH,DELETE,OPTIONS',
        'access-control-expose-headers': '*'}


class FakeSB:
    def __init__(self):
        self.rows = {}
        self.log = []          # (method, path)
        self.saves = SaveStore()
        self.saves.rows = self.rows

    def uid_of(self, req):
        try:
            pl = req.headers.get('authorization', '').split(' ', 1)[1].split('.')[1]
            pl += '=' * (-len(pl) % 4)
            d = json.loads(base64.urlsafe_b64decode(pl))
            return d.get('sub') if d.get('role') == 'authenticated' else None
        except Exception:
            return None

    def reply(self, route, status=200, body=None):
        route.fulfill(status=status, headers=dict(CORS, **{'content-type': 'application/json'}), body='' if body is None else json.dumps(body))

    def handle(self, route):
        req = route.request
        u = urllib.parse.urlparse(req.url)
        q = urllib.parse.parse_qs(u.query)
        if req.method == 'OPTIONS':
            return route.fulfill(status=204, headers=CORS, body='')
        self.log.append((req.method, u.path))
        uid = self.uid_of(req)
        if u.path == '/auth/v1/user':
            s = session_obj(uid, 'a@test.invalid') if uid else None
            return self.reply(route, 200, s['user']) if s else self.reply(route, 401, {'msg': 'invalid JWT'})
        if u.path.startswith('/auth/v1/'):
            return self.reply(route, 200, {})
        if u.path.startswith('/rest/v1/rpc/') and u.path.rsplit('/', 1)[1] in SAVE_RPC.values():
            st, body = self.saves.rpc(uid, u.path.rsplit('/', 1)[1], json.loads(req.post_data or '{}'))
            return self.reply(route, st, body)
        if u.path == SAVES_PATH and uid:
            if req.method == 'GET':
                rows = [dict(self.rows[uid], user_id=uid)] if uid in self.rows else []
                sel = (q.get('select') or ['*'])[0].split(',')
                if sel != ['*']:
                    rows = [{c.strip(): r.get(c.strip()) for c in sel} for r in rows]
                return self.reply(route, 200, rows)
            if req.method == 'POST':
                body = json.loads(req.post_data or '{}')
                self.last_post = body
                st, eb = self.saves.write(uid, body[0] if isinstance(body, list) else body)
                return self.reply(route, st, [eb] if st == 201 else eb)
            return self.reply(route, 403, {'code': '42501'})
        if u.path.startswith('/rest/v1/'):
            return self.reply(route, 200, [] if req.method == 'GET' else None)
        return self.reply(route, 404, {'message': 'not found'})

    def writes(self):
        """Kayıt yazma istekleri: kodhane_saves'e POST/PATCH/PUT/DELETE ve kayıt RPC'leri (sıfırla / geri yükle)."""
        return [(m, p) for m, p in self.log if (p == SAVES_PATH and m != 'GET') or p in ['/rest/v1/rpc/' + SAVE_RPC['reset'], '/rest/v1/rpc/' + SAVE_RPC['restore']]]


def mk_save(version=4, save_version=None, **kw):
    now = int(time.time() * 1000)
    d = {'money': 12345.0, 'runEarned': 5e6, 'totalEarned': 5e6, 'cycleEarned': 5e6, 'clicks': 77, 'clickEarned': 77, 'playTime': 900,
         'startedAt': now - 86400000, 'lastSaved': now,
         'gens': {'stajyer': 12, 'junior': 5, 'senior': 2, 'tasarimci': 0, 'pm': 0, 'ai': 0, 'sunucu': 0, 'ofis': 0},
         'upgrades': [], 'shares': 3, 'prestigeCount': 3, 'cycleRounds': 3, 'cycleStage': 5, 'stageBest': 5, 'stage': 3,
         'boostLeft': 0, 'eventsClicked': 0, 'offlineEarned': 0, 'buffs': [], 'achievements': [], 'reputation': 0,
         'tree': [], 'ipoShares': 0, 'ipoSharesEarned': 0, 'ipoCount': 0}
    if version is not None:
        d['version'] = version
    if save_version is not None:
        d['saveVersion'] = save_version
    d.update(kw)
    return d


def future_save():
    d = mk_save(version=5, save_version=5)
    d['futureOnlyField'] = {'kept': True, 'list': [1, 2, 3]}   # bu istemcinin bilmediği alan: aynen kalmalı
    d['epoch'] = 1
    return d


def seed_script(raw=None, tel='off', session=None):
    parts = ["(() => { if (sessionStorage.getItem('kh_seeded')) return; sessionStorage.setItem('kh_seeded','1');"]
    if tel is not None:
        parts.append("localStorage.setItem('kodhane_tel_notice', '1'); localStorage.setItem('kodhane_tel', %s);" % json.dumps(tel))
    if raw is not None:
        parts.append("localStorage.setItem(%s, %s);" % (json.dumps(SAVE_KEY), json.dumps(raw)))
    if session is not None:
        parts.append("localStorage.setItem(%s, %s);" % (json.dumps(AUTH_KEY), json.dumps(json.dumps(session))))
    parts.append('})();')
    return ''.join(parts)


PTS = """(sel) => {
  const pts = [[0.5, 0.5], [0.15, 0.2], [0.85, 0.2], [0.15, 0.8], [0.85, 0.8]];
  return Array.from(document.querySelectorAll(sel)).filter(el => el.offsetParent !== null || getComputedStyle(el).position === 'fixed').map(el => {
    const r = el.getBoundingClientRect(), bad = [];
    for (const [fx, fy] of pts) {
      const x = r.left + r.width * fx, y = r.top + r.height * fy, h = document.elementFromPoint(x, y);
      if (!h || !(h === el || el.contains(h))) bad.push([Math.round(x), Math.round(y), h ? (h.id || String(h.className) || h.tagName) : null]);
    }
    const inside = r.width > 0 && r.height > 0 && r.left >= -0.5 && r.top >= -0.5 && r.right <= innerWidth + 0.5 && r.bottom <= innerHeight + 0.5;
    return { name: el.id || el.dataset.test || el.dataset.view || el.className || el.tagName, inside, bad, r: [r.left, r.top, r.right, r.bottom].map(Math.round) };
  });
}"""


def bad_rows(rows):
    return [r for r in rows if not r['inside'] or r['bad']]


VP = {
    '390x844': dict(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True),
    '375x667': dict(viewport={'width': 375, 'height': 667}, is_mobile=True, has_touch=True),
    '360x640': dict(viewport={'width': 360, 'height': 640}, is_mobile=True, has_touch=True),
    '568x320': dict(viewport={'width': 568, 'height': 320}, is_mobile=True, has_touch=True),
    '1280x800': dict(viewport={'width': 1280, 'height': 800}),
}

with sync_playwright() as p:
    b = p.chromium.launch(args=['--host-resolver-rules=' + SAFETY])
    all_requests = []

    def new_ctx(vp='1280x800', init=None, fake=None, dsf=1):
        opts = dict(locale='tr-TR', service_workers='block', device_scale_factor=dsf)
        opts.update(VP[vp])
        ctx = b.new_context(**opts)
        ctx.add_init_script('window.KODHANE_QUIET = true;')
        if fake is not None:
            ctx.add_init_script('window.KODHANE_CLOUD_CONFIG = %s;' % json.dumps({'url': FAKE, 'key': 'sb_publishable_test_key'}))
            ctx.route(FAKE + '/**', fake.handle)
        if init:
            ctx.add_init_script(init)
        ctx.route('http://kodhane.test/**', file_route)
        ctx.route('https://cdn.jsdelivr.net/**', lambda r: r.fulfill(status=200, headers={'content-type': 'application/javascript', 'access-control-allow-origin': '*'}, body=SDK_BYTES)
                  if SDK_BYTES else r.abort('connectionrefused'))
        ctx.route(re.compile(r'^https?://(?!kodhane\.test/|kodhane-test\.supabase\.co/|cdn\.jsdelivr\.net/).*'), lambda r: r.abort('blockedbyclient'))
        ctx.on('request', lambda r: all_requests.append(r.url))
        return ctx

    def open_page(ctx, wait_band=False):
        pg = ctx.new_page()
        pg.errs = []
        pg.on('pageerror', lambda e: pg.errs.append(str(e)))
        pg.goto(BASE)
        pg.wait_for_selector('#clickBtn')
        if wait_band:
            pg.wait_for_selector('[data-test=tel-banner]')
        return pg

    # ============================================================ [text] Yatırım Turu / Halka Arz (Yatırımcı Güveni kapalı / açık)
    PROD = """(g) => {   // üretimde kullanılan çarpan: yalnızca hisse sayısı değişir, diğer her şey aynı
      const S = Kodhane.state, keep = S.shares;
      const m = (n) => { S.shares = n; return Kodhane.globalMult(); };
      const m0 = m(0), mNow = m(keep), m1 = m(1), mg = m(g); S.shares = keep;
      return { x: (mNow / m0 - 1) * 100, per: (m1 / m0 - 1) * 100, b: (mg / m0 - 1) * 100, shares: keep };
    }"""
    for tree_on in (False, True):
        tag = '[text][Yatırımcı Güveni %s]' % ('on' if tree_on else 'off')
        ctx = new_ctx('390x844', init=seed_script(json.dumps(mk_save(runEarned=1.6e9, tree=['yatirim_1', 'yatirim_2'] if tree_on else [],
                                                                         cycleEarned=8e14, totalEarned=9e14))))
        pg = open_page(ctx)
        ev = pg.evaluate
        check(tag + ' test save loaded (nonzero shares, tree as set)', ev('Kodhane.state.shares') == 3 and (ev("Kodhane.hasNode('yatirim_2')") == tree_on))
        ev("Kodhane.setView('prestige'); Kodhane.renderAll()")
        pg.wait_for_timeout(200)
        g = ev('Kodhane.sharesGain()')
        prod = ev(PROD, g)
        per_txt = pg.inner_text('#prPer')
        check(tag + ' #prPer = production per-share bonus (%s)' % per_txt, abs(trnum(per_txt.replace('+%', '')) - prod['per']) < 0.005, [per_txt, prod])
        check(tag + ' #prBonus = production investor bonus', abs(trnum(pg.inner_text('#prBonus').replace('+%', '')) - prod['x']) < 0.005, [pg.inner_text('#prBonus'), prod])
        check(tag + ' tree changes the per-share bonus (10 off / 12,5 on as the game computes it)', per_txt == ('+%12,5' if tree_on else '+%10'), per_txt)
        pg.click('#prestigeBtn')
        pg.wait_for_selector('#modal:not(.hidden)')
        txt = pg.inner_text('#modalText')
        m = re.search(r'Yatırımcılar şirketine ([\d.,]+) hisse karşılığında .*? tüm kazançlara \+%([\d.,]+) bonus alırsın\.', txt)
        check(tag + ' Yatırım Turu confirm: {g} = shares to gain, {b} = production bonus of those g shares',
              m and trnum(m.group(1)) == g and abs(trnum(m.group(2)) - prod['b']) < 0.005, [txt, g, prod])
        exp = strip_tags(APPROVED['prestige'].replace('{g}', ev('Kodhane.fmt(%d)' % g)).replace('{b}', ev('Kodhane.pctText(Kodhane.investorBonus(%d))' % g)))
        check(tag + ' Yatırım Turu confirm: exact approved text', txt.strip() == exp.strip(), [txt, exp])
        note('%s g=%d  {b}=%s  production b=%.4f%%  per-share=%.4f%%' % (tag, g, m.group(2) if m else None, prod['b'], prod['per']))
        if tree_on:
            pg.wait_for_timeout(300); ev("document.getElementById('toast').innerHTML = ''")
            pg.screenshot(path=os.path.join(SHOTS, 'kodhane-v431-yatirim-onay.png'))
        pg.click('#modalActions button:has-text("Vazgeç")')
        check(tag + ' cancel: nothing changed', ev('Kodhane.state.shares') == 3 and ev('Kodhane.state.prestigeCount') == 3)
        # Halka Arz
        n = ev('Kodhane.ipoGain()')
        pg.click('#ipoBtn')
        pg.wait_for_selector('#modal:not(.hidden)')
        txt = pg.inner_text('#modalText')
        m = re.search(r'Şu anki \+%([\d.,]+) yatırımcı bonusun sıfırlanır, karşılığında ([\d.,]+) Borsa Payı kazanırsın\.', txt)
        check(tag + ' Halka Arz confirm: {x} = current production investor bonus, {n} = ipoGain',
              m and abs(trnum(m.group(1)) - prod['x']) < 0.005 and trnum(m.group(2)) == n, [txt, prod, n])
        u = ev('Kodhane.CFG.halkaArz.unspentBonus * 100')
        exp = strip_tags(APPROVED['ipo'].replace('{x}', ev('Kodhane.pctText(Kodhane.investorBonus())')).replace('{n}', ev('Kodhane.fmt(%d)' % n))
                         .replace('{u}', ('%g' % u).replace('.', ',')))
        check(tag + ' Halka Arz confirm: exact approved text, old lines gone', txt.strip() == exp.strip() and 'Kazanacağın' not in txt
              and 'Karşılığında kalıcı' not in txt, [txt, exp])
        note('%s {x}=%s production x=%.4f%%  {n}=%s' % (tag, m.group(1) if m else None, prod['x'], m.group(2) if m else None))
        if tree_on:
            pg.wait_for_timeout(300); ev("document.getElementById('toast').innerHTML = ''")
            pg.screenshot(path=os.path.join(SHOTS, 'kodhane-v431-halkaarz-onay.png'))
        pg.click('#modalActions button:has-text("Vazgeç")')
        # sıfırlama penceresindeki ipucu
        ev("Kodhane.setView('upgrades'); Kodhane.selectTab('stats')")
        pg.click('#resetBtn')
        pg.wait_for_selector('#modal:not(.hidden)')
        check(tag + ' reset dialog: approved reset.prestigeHint', APPROVED['hint'] in pg.inner_text('#modal'), pg.inner_text('#modal')[:400])
        pg.click('#modalActions button:has-text("Vazgeç")')
        # Yatırım turu gerçekten yapılınca üretim bonusu metindeki kadar artar
        ev("Kodhane.setView('prestige')")
        before = ev(PROD, 0)
        pg.click('#prestigeBtn'); pg.click('#modalActions button:has-text("Anlaştık!")')
        after = ev(PROD, 0)
        check(tag + ' after the round the production bonus grew by exactly {b}', abs((after['x'] - before['x']) - prod['b']) < 1e-6 and after['shares'] == 3 + g, [before, after])
        check(tag + ' no page errors', not pg.errs, pg.errs)
        ctx.close()

    # ============================================================ [layout] bant açık: Kod yaz + ipucu + düğmeler
    rows_out = []
    tall_ref = {}
    for vname in ('390x844', '375x667', '360x640', '568x320', '1280x800'):
        tag = '[layout][%s]' % vname
        mobile = VP[vname].get('is_mobile', False)
        ctx = new_ctx(vname, init=seed_script(None, tel=None))
        pg = open_page(ctx, wait_band=True)
        pg.wait_for_timeout(400)
        ev = pg.evaluate
        both = ev(PTS, '#clickBtn, #panelKod .click-hint')
        band = ev("document.querySelector('[data-test=tel-banner]').getBoundingClientRect().toJSON()")
        check(tag + ' Kod yaz + hint line fully visible and on top together (band open, initial view)', len(both) == 2 and not bad_rows(both), both)
        btns = ev(PTS, '[data-test=tel-banner] button' + (', #bottomNav button' if mobile else ''))
        check(tag + ' band buttons%s visible and on top' % (' + bottom nav' if mobile else ''), len(btns) == (9 if mobile else 3) and not bad_rows(btns), bad_rows(btns) or len(btns))
        if mobile:   # başka görünüme geçip Kod'a dönünce de
            pg.click('#bottomNav button[data-view="ekip"]'); pg.wait_for_timeout(150)
            pg.click('#bottomNav button[data-view="kod"]'); pg.wait_for_timeout(250)
            both2 = ev(PTS, '#clickBtn, #panelKod .click-hint')
            check(tag + ' back to Kod view: Kod yaz + hint still clear of the band', len(both2) == 2 and not bad_rows(both2), both2)
        hint_b = both[1]['r'][3] if len(both) == 2 else None
        rows_out.append((vname, round(band['top']), hint_b, both[0]['r'] if both else None, ev('scrollY')))
        if vname == '360x640':
            pg.screenshot(path=os.path.join(SHOTS, 'kodhane-v431-360x640-band.png'))
        c0 = ev('Kodhane.state.clicks'); pg.click('#clickBtn')
        check(tag + ' real click on Kod yaz works with the band open', ev('Kodhane.state.clicks') == c0 + 1)
        # tall screens: button/hint position identical with and without the band
        if vname in ('390x844', '1280x800'):
            with_band = ev("[scrollY, document.getElementById('clickBtn').getBoundingClientRect().top, document.querySelector('#panelKod .click-hint').getBoundingClientRect().bottom]")
            pg.click('[data-test=tel-ok]'); pg.wait_for_timeout(300)
            without = ev("[scrollY, document.getElementById('clickBtn').getBoundingClientRect().top, document.querySelector('#panelKod .click-hint').getBoundingClientRect().bottom]")
            check(tag + ' tall screen: layout unchanged by the band (no scroll, same positions)', with_band == without and with_band[0] == 0, [with_band, without])
        else:
            pg.click('[data-test=tel-ok]'); pg.wait_for_timeout(300)
            st = ev("[document.documentElement.classList.contains('nb-open'), getComputedStyle(document.querySelector('.topbar')).position, document.getElementById('clickBtn').getBoundingClientRect().width]")
            check(tag + ' band answered: nb-open removed, sticky top bar and normal button size back', st[0] is False and st[1] == 'sticky' and st[2] >= 200, st)
        check(tag + ' no page errors', not pg.errs, pg.errs)
        ctx.close()
    note('layout (band open): viewport | band top | hint bottom | Kod yaz rect | scrollY')
    for r in rows_out:
        note('  %s | %s | %s | %s | %s' % r)

    # ============================================================ [newer] eski ve güncel biçimler eskisi gibi
    for label, d in (('legacy v2 (version 2, no saveVersion)', mk_save(version=2)), ('no version field at all', mk_save(version=None)),
                     ('v4.3.0 format (version 4, no saveVersion)', mk_save(version=4))):
        raw = json.dumps(d)
        ctx = new_ctx('1280x800', init=seed_script(raw))
        pg = open_page(ctx)
        ev = pg.evaluate
        ok = ev('!Kodhane.writesBlocked()') and ev('Kodhane.state.clicks') == 77 and ev('Kodhane.state.totalEarned') >= 5e6
        pg.click('#clickBtn'); ev('Kodhane.save()')
        now = json.loads(ev("localStorage.getItem('%s')" % SAVE_KEY))
        check('[newer][old] %s: loads as before, saves normally with saveVersion 4 / version 4' % label,
              ok and now['clicks'] == 78 and now['saveVersion'] == 4 and now['version'] == 4 and pg.is_hidden('#updateBar'), [ok, now.get('clicks'), now.get('saveVersion')])
        if label.startswith('legacy'):
            check('[newer][old] legacy v2 save migrated like before (cycleRounds from prestigeCount)', ev('Kodhane.loadedVersion') == 2 and now['cycleRounds'] == 3)
        check('[newer][old] %s: no page errors' % label, not pg.errs, pg.errs)
        ctx.close()

    # ============================================================ [newer] daha yeni kayıt (misafir): her yazma yolu tek tek
    FUT = json.dumps(future_save())
    same = lambda pg: pg.evaluate("localStorage.getItem('%s')" % SAVE_KEY) == FUT
    epoch0 = None
    ctx = new_ctx('1280x800', init=seed_script(FUT))
    pg = open_page(ctx)
    ev = pg.evaluate
    pg.wait_for_timeout(300)
    check('[newer][guest] future save detected: writesBlocked, futureSave.version 5', ev('Kodhane.writesBlocked()') and ev('Kodhane.futureSave.version') == 5)
    bars = ev("Array.from(document.querySelectorAll('.update-bar')).filter(e => !e.classList.contains('hidden')).map(e => [e.dataset.test, e.innerText])")
    check('[newer][guest] one refresh band shown (long text at 1280, "Yenile")', len(bars) == 1 and bars[0][0] == 'newer-save-band'
          and pg.inner_text('#updateText') == APPROVED['newer'] and pg.inner_text('#updateBtn') == APPROVED['newerBtn'], bars)
    check('[newer][guest] load: local save unchanged byte-for-byte', same(pg))
    for i in range(5):
        pg.click('#clickBtn')
    pg.wait_for_timeout(10800)    # AUTOSAVE_MS = 10 sn: en az bir otomatik kayıt aralığı
    check('[newer][guest] path autosave interval (10.8 s, state changed): unchanged', same(pg) and ev('Kodhane.state.clicks') >= 82)
    ev('Kodhane.save()')
    check('[newer][guest] path Kodhane.save() (manual API): unchanged', same(pg))
    ev("Kodhane.selectTab('stats')"); pg.click('#saveBtn')
    check('[newer][guest] path "Kaydet" button (manual save): unchanged', same(pg))
    ev("Object.defineProperty(document, 'hidden', {configurable: true, get: () => true}); document.dispatchEvent(new Event('visibilitychange'));")
    check('[newer][guest] path visibilitychange (hidden): unchanged', same(pg))
    ev("window.dispatchEvent(new Event('pagehide')); window.dispatchEvent(new Event('beforeunload'));")
    check('[newer][guest] path pagehide + beforeunload events: unchanged', same(pg))
    epoch0 = ev("localStorage.getItem('%s')" % EPOCH_KEY)
    pg.click('#resetBtn'); pg.wait_for_timeout(300)
    ev('Kodhane.openResetDialog()'); pg.wait_for_timeout(200)
    check('[newer][guest] path reset (Kaydı sıfırla): no dialog, band flashes, save + epoch unchanged', pg.is_hidden('#modal') and same(pg)
          and ev("localStorage.getItem('%s')" % EPOCH_KEY) == epoch0 and ev("document.getElementById('updateBar').classList.contains('ub-flash')"))
    ev("Kodhane.setView('prestige'); Kodhane.state.runEarned = 1.6e9; Kodhane.renderAll()")
    pc = ev('Kodhane.state.prestigeCount')
    pg.click('#prestigeBtn'); pg.wait_for_timeout(200)
    check('[newer][guest] path Yatırım Turu button: no dialog, no round, unchanged', pg.is_hidden('#modal') and ev('Kodhane.state.prestigeCount') == pc and same(pg))
    ev("Kodhane.state.cycleEarned = 8e14; Kodhane.state.totalEarned = 9e14; Kodhane.renderAll()")
    ic = ev('Kodhane.state.ipoCount')
    pg.click('#ipoBtn'); pg.wait_for_timeout(200)
    check('[newer][guest] path Halka Arz button: no dialog, no IPO, unchanged', pg.is_hidden('#modal') and ev('Kodhane.state.ipoCount') == ic and same(pg))
    ev("Kodhane.state.ipoShares = 5; Kodhane.renderAll()")
    pg.click('#treeGrid [data-node="kod_1"]'); pg.wait_for_timeout(200)
    check('[newer][guest] path Borsa Payı Ağacı purchase (calls save): unchanged', same(pg))
    ev("Kodhane.applySave(%s)" % json.dumps(mk_save(version=4, clicks=1)))
    check('[newer][guest] path applySave of an older save (cloud/tab/restore entry): unchanged', same(pg) and ev('Kodhane.writesBlocked()'))
    check('[newer][guest] no backup key written', ev("localStorage.getItem('%s')" % BACKUP_KEY) is None)
    check('[newer][guest] no page errors', not pg.errs, pg.errs)
    # gerçek yeniden yükleme (tarayıcının gerçek beforeunload/pagehide/visibilitychange olayları) + bant düğmesi
    with pg.expect_navigation():
        pg.click('#updateBtn')
    pg.wait_for_selector('#clickBtn'); pg.wait_for_timeout(300)
    check('[newer][guest] path "Yenile" (real reload: native beforeunload/pagehide): unchanged, still guarded after reload', same(pg) and ev('Kodhane.writesBlocked()'))
    pg.wait_for_timeout(10800)
    check('[newer][guest] after reload + autosave interval: unchanged', same(pg))
    ctx.close()

    # Geri al (sıfırlamadan sonra): yazma kapalıyken geri alma da yazmaz
    undo = json.dumps({'v': 1, 'at': int(time.time() * 1000), 'epoch': 1, 'backupId': None, 'save': json.dumps(mk_save(version=4, clicks=5))})
    ctx = new_ctx('1280x800', init=seed_script(FUT) + "(() => { if (!sessionStorage.getItem('kh_undo')) { sessionStorage.setItem('kh_undo','1'); sessionStorage.setItem('kodhane_reset_undo', %s); } })();" % json.dumps(undo))
    pg = open_page(ctx)
    pg.wait_for_timeout(300)
    shown = pg.is_visible('#undoBtn')
    if shown:
        pg.click('#undoBtn'); pg.wait_for_timeout(500)
    check('[newer][guest] path "Geri al" (undo after reset): no-op, unchanged', shown and same(pg) and pg.evaluate('Kodhane.state.clicks') != 5, [shown, pg.evaluate('Kodhane.state.clicks')])
    ctx.close()

    # başka sekme (daha yeni sürüm) yazınca bu sekme durur
    old_raw = json.dumps(mk_save(version=4))
    ctx = new_ctx('1280x800', init=seed_script(old_raw))
    a = open_page(ctx)
    check('[newer][tab] normal tab not guarded', a.evaluate('!Kodhane.writesBlocked()'))
    bpg = ctx.new_page(); bpg.goto('about:blank')
    a.evaluate("localStorage.setItem('%s', %s)" % (SAVE_KEY, json.dumps(FUT)))   # aynı sayfada 'storage' olayı olmaz: öteki sekmeden yaz
    a.evaluate("window.dispatchEvent(new StorageEvent('storage', { key: '%s', newValue: localStorage.getItem('%s') }))" % (SAVE_KEY, SAVE_KEY))
    a.wait_for_timeout(200)
    a.click('#clickBtn'); a.evaluate('Kodhane.save()'); a.wait_for_timeout(10800)
    check('[newer][tab] storage event with a newer save: tab stops writing (autosave + manual), band shown',
          a.evaluate("localStorage.getItem('%s')" % SAVE_KEY) == FUT and a.evaluate('Kodhane.writesBlocked()') and a.is_visible('[data-test=newer-save-band]'))
    ctx.close()
    ctx = new_ctx('1280x800', init=seed_script(old_raw))
    a = open_page(ctx)
    a.evaluate("localStorage.setItem('%s', %s); Kodhane.save()" % (SAVE_KEY, json.dumps(FUT)))
    check('[newer][tab] save() re-checks the stored save before writing (no storage event): not overwritten',
          a.evaluate("localStorage.getItem('%s')" % SAVE_KEY) == FUT and a.evaluate('Kodhane.writesBlocked()'))
    ctx.close()
    # yalnızca version (saveVersion yok) ya da yalnızca saveVersion yüksek
    for label, d in (('only version 5', mk_save(version=5)), ('only saveVersion 5', mk_save(version=4, save_version=5))):
        raw = json.dumps(d)
        ctx = new_ctx('1280x800', init=seed_script(raw))
        pg = open_page(ctx)
        pg.click('#clickBtn'); pg.evaluate('Kodhane.save()')
        check('[newer][%s] guarded, unchanged' % label, pg.evaluate('Kodhane.writesBlocked()') and pg.evaluate("localStorage.getItem('%s')" % SAVE_KEY) == raw)
        ctx.close()

    # ============================================================ [newer][cloud] sahte Supabase (route) ile
    if SDK_BYTES is None:
        check('[newer][cloud] supabase-js cache present (run tests/test_cloud.py once)', False, SDK_FILE)
    else:
        UID = '11111111-2222-3333-4444-555555555555'
        sess = session_obj(UID, 'a@test.invalid')

        def cloud_row(d, sv):
            return {'data': d, 'save_version': sv, 'updated_at': iso(), 'revision': 3, 'strict_revision': True, 'best_score': d['totalEarned'], 'best_stage': 0}

        # (c1) normal: kayıt yazılır, buluta save_version 4 + data.saveVersion 4 gider
        fake = FakeSB()
        fake.rows[UID] = cloud_row(mk_save(version=4, totalEarned=1e3, runEarned=1e3, cycleEarned=1e3), 4)
        ctx = new_ctx('1280x800', init=seed_script(json.dumps(mk_save(version=4)), session=sess), fake=fake)
        pg = open_page(ctx)
        try:
            pg.wait_for_function('Kodhane.cloud.state.reconciled && Kodhane.cloud.state.lastPushAt > 0', timeout=15000); ok = True
        except Exception:
            ok = False
        post = getattr(fake, 'last_post', None) or {}
        post = post[0] if isinstance(post, list) else post
        check('[newer][cloud] normal save: cloud write issued (mocked) with save_version 4, data.saveVersion 4, data.version 4',
              ok and post.get('save_version') == 4 and post.get('data', {}).get('saveVersion') == 4 and post.get('data', {}).get('version') == 4,
              [ok, {k: post.get(k) for k in ('save_version', 'revision')}])
        pg.click('#clickBtn'); pg.evaluate('Kodhane.save()')
        check('[newer][cloud] normal save: local save written as before', json.loads(pg.evaluate("localStorage.getItem('%s')" % SAVE_KEY))['clicks'] == 78)
        ctx.close()

        # (c2) yerel kayıt daha yeni, girişli
        fake = FakeSB()
        fake.rows[UID] = cloud_row(mk_save(version=4), 4)
        ctx = new_ctx('1280x800', init=seed_script(FUT, session=sess), fake=fake)
        pg = open_page(ctx)
        pg.wait_for_timeout(2500)
        for i in range(3):
            pg.click('#clickBtn')
        pg.evaluate('Kodhane.save(); Kodhane.cloud.reconcile()')
        # yazma yollarını koruma bayrağıyla sına: oturum hazır ve "eşitlenmiş" sayılsa bile push/flush yazmaz
        pg.evaluate('Kodhane.cloud.state.reconciled = true; Kodhane.cloud.push(true); Kodhane.cloud.push(false); Kodhane.cloud.flush()')
        pg.evaluate("Object.defineProperty(document, 'hidden', {configurable: true, get: () => true}); document.dispatchEvent(new Event('visibilitychange')); window.dispatchEvent(new Event('pagehide'));")
        pg.wait_for_timeout(10800)
        pg.evaluate("Kodhane.selectTab('stats')"); pg.click('#resetBtn'); pg.wait_for_timeout(300)
        pg.evaluate("Kodhane.cloud.resetSave().catch(() => {}); Kodhane.cloud.restoreSave({ backupId: 'x' }).catch(() => {})")
        pg.wait_for_timeout(800)
        check('[newer][cloud] local newer save + signed in: 0 write requests to kodhane_saves / save RPCs (push, flush, reconcile, autosave, pagehide, reset, restore)',
              fake.writes() == [], fake.writes())
        check('[newer][cloud] local newer save + signed in: local save unchanged, cloud row unchanged, band shown',
              same(pg) and fake.rows[UID]['revision'] == 3 and pg.is_visible('[data-test=newer-save-band]'))
        note('[newer][cloud] (c2) requests to fake Supabase: %s' % sorted(set(fake.log)))
        ctx.close()

        # (c3) buluttaki kayıt daha yeni (save_version 5), yerel kayıt güncel biçim
        fake = FakeSB()
        cloud_future = future_save(); cloud_future['totalEarned'] = 9e9; cloud_future['runEarned'] = 9e9
        fake.rows[UID] = cloud_row(cloud_future, 5)
        cloud_before = json.dumps(fake.rows[UID], sort_keys=True)
        local_raw = json.dumps(mk_save(version=4))
        ctx = new_ctx('1280x800', init=seed_script(local_raw, session=sess), fake=fake)
        pg = open_page(ctx)
        try:
            pg.wait_for_function('Kodhane.writesBlocked()', timeout=15000); ok = True
        except Exception:
            ok = False
        local_after_detect = pg.evaluate("localStorage.getItem('%s')" % SAVE_KEY)
        pg.click('#clickBtn')
        pg.evaluate('Kodhane.save(); Kodhane.cloud.state.reconciled = true; Kodhane.cloud.push(true); Kodhane.cloud.flush()')
        pg.evaluate("window.dispatchEvent(new Event('pagehide')); window.dispatchEvent(new Event('beforeunload'));")
        pg.wait_for_timeout(10800)
        check('[newer][cloud] cloud row newer (save_version 5): detected, band shown, cloud save NOT applied',
              ok and pg.is_visible('[data-test=newer-save-band]') and pg.evaluate('Kodhane.state.totalEarned') < 9e9)
        check('[newer][cloud] cloud row newer: 0 write requests, cloud row byte-identical', fake.writes() == [] and json.dumps(fake.rows[UID], sort_keys=True) == cloud_before, fake.writes())
        check('[newer][cloud] cloud row newer: nothing written locally from then on (save, autosave, pagehide)',
              pg.evaluate("localStorage.getItem('%s')" % SAVE_KEY) == local_after_detect and pg.evaluate("localStorage.getItem('%s')" % BACKUP_KEY) is None)
        ctx.close()

    # ============================================================ [newer][band] birleşik bant + izin bandı + dar ekran
    variants = []
    for vname in ('360x640', '568x320', '390x844', '1280x800'):
        for consent_open in (True, False):
            tag = '[newer][band][%s][consent %s]' % (vname, 'open' if consent_open else 'closed')
            ctx = new_ctx(vname, init=seed_script(json.dumps(mk_save(version=4)), tel=None if consent_open else 'off'))
            pg = open_page(ctx, wait_band=consent_open)
            ev = pg.evaluate
            ev("Kodhane.showUpdate({ postMessage: function () {} })")      # bekleyen servis çalışanı güncellemesi
            pg.wait_for_timeout(100)
            sw_txt = pg.inner_text('#updateText')
            ev("Kodhane.guardFuture({ version: 5 }, 'test')")               # daha yeni kayıt okundu
            pg.wait_for_timeout(300)
            vis_bars = ev("Array.from(document.querySelectorAll('.update-bar, [data-test=newer-save-band], [data-test=update-band]')).filter(e => !e.classList.contains('hidden') && e.offsetParent !== null || getComputedStyle(e).position === 'fixed' && !e.classList.contains('hidden')).length")
            txt = pg.inner_text('#updateText')
            check(tag + ' SW update text first, then ONE band with newerSave text (never both)', sw_txt == '✨ Yeni sürüm hazır.' and vis_bars == 1
                  and txt in (APPROVED['newer'], APPROVED['newerShort']), [sw_txt, vis_bars, txt])
            fits = ev("(() => { const s = document.getElementById('updateText'); return s.scrollWidth <= s.clientWidth + 1 && document.getElementById('updateBar').getBoundingClientRect().right <= innerWidth; })()")
            check(tag + ' band text fits (no clipping, inside the screen)', fits)
            rows = ev(PTS, '#updateBtn, #updateText' + (', [data-test=tel-banner] button' if consent_open else ''))
            check(tag + ' refresh band%s fully visible and on top' % (' + consent buttons' if consent_open else ''),
                  len(rows) == (5 if consent_open else 2) and not bad_rows(rows), bad_rows(rows) or len(rows))
            if consent_open:
                gap = ev("document.querySelector('[data-test=tel-banner]').getBoundingClientRect().top - document.getElementById('updateBar').getBoundingClientRect().bottom")
                check(tag + ' bands do not overlap (gap %d px)' % gap, gap >= 0, gap)
            variants.append((vname, 'open' if consent_open else 'closed', 'long' if txt == APPROVED['newer'] else 'short'))
            if consent_open and vname in ('360x640', '568x320'):
                ev("document.getElementById('toast').innerHTML = ''")
                pg.screenshot(path=os.path.join(SHOTS, 'kodhane-v431-newersave-%s.png' % vname))
            check(tag + ' no page errors', not pg.errs, pg.errs)
            ctx.close()
    note('newerSave text variant by viewport: %s' % variants)

    ext = sorted(set(u for u in all_requests if not (u.startswith(BASE) or u.startswith(FAKE) or u.startswith('https://cdn.jsdelivr.net/') or u.startswith('data:') or u.startswith('about:'))))
    check('[net] no request left the sandbox (only kodhane.test, fake Supabase, cached SDK)', not ext, ext)
    b.close()

passed = sum(1 for r in results if r[1])
print('\nSUMMARY: %d/%d passed' % (passed, len(results)))
sys.exit(0 if passed == len(results) else 1)
