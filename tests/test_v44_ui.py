"""Kodhane v4.4 arayüz testleri (Playwright, headless Chromium; ağ yok, gerçek oyuncu kaydı / sunucu yok).

  [dialog]   Yatırım Turu ve Halka Arz onay pencereleri Yazı r3 metniyle birebir (yer tutucular oyundan), Halka Arz sonrası
             pencere; Halka Arz'dan sonra hisseler yerinde, bekleme başlar.
  [wait]     12 saat bekleme: düğme "Halka arz et (s:dd:ss)" ve kapalı, ⏳ satırı + açıklama, tur şartı satırının ALTINDA ayrı
             satır; bekleme bitince tek seferlik "🔔 Halka Arz yeniden açık." ve düğme açılır; hızlandırıcı satırı.
  [narrow]   Çok büyük sayılarla 360x640, 375x667, 568x320, 390x844, 1280x800: yatay taşma yok (sayfa ve Halka Arz bölümü /
             onay penceresi içindeki her öğe ölçülür).
  [net]      İki yeni olay (ipo_complete, tree_full): "Tamam" demeden ve "Kapat" dedikten sonra Umami'ye ve anonim sayaca 0 istek;
             "Tamam" sonrası sahte Umami'ye giden alanlar tam olarak beklenen kümeler.
  [net3]     v4.4.1: reset_or_prestige üçe ayrıldı: investment_round (yalnız stage_id), ipo_complete, hard_reset (yalnız ad). Hepsi UI'dan
             (Yatırım Turu, Halka Arz, "Kaydı sıfırla" basılı tutma); "Tamam" öncesi ve "Kapat" sonrası 0 istek; "Tamam" sonrası
             sahte Umami'de üçü ayrı adla, birer kez, beklenen alanlarla; reset_or_prestige hiç gitmez.
  [guard]    v4.3.1 istemcisi (e37018c, git show) v5 kaydını görünce hiçbir şey yazmaz (yerel kayıt bayt bayt aynı).
Oyun https://kodhane.teserix.com/ altında Playwright route ile depo dosyalarından sunulur; Umami/Supabase sahte (route);
güvenlik ağı: gerçek adlar --host-resolver-rules ile 127.0.0.1:9'a (kapalı port) yönlenir.
    python3 tests/test_v44_ui.py         (ekran görüntüleri: KODHANE_V44_SHOTS, varsayılan /workspace)
"""
import json
import mimetypes
import os
import re
import subprocess
import sys
import time
from urllib.parse import urlsplit

from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.environ.get('KODHANE_V44_SHOTS', '/workspace')
BASE = 'https://kodhane.teserix.com/'
SAVE_KEY = 'kodhane_ajans_save_v2'
COUNT_PATH = '/rest/v1/rpc/kodhane_count_event'
SAFETY = ('MAP analiz.teserix.com 127.0.0.1:9, MAP kodhane-api.teserix.com 127.0.0.1:9, MAP supabase.teserix.com 127.0.0.1:9, '
          'MAP kodhane.teserix.com 127.0.0.1:9, MAP thejackaltr.github.io 127.0.0.1:9, MAP cdn.jsdelivr.net 127.0.0.1:9, '
          'MAP acikofis.teserix.com 127.0.0.1:9, MAP *.supabase.co 127.0.0.1:9')
R3 = {
    'prestige': "Yatırımcılar şirketine <b>{g} hisse</b> karşılığında yatırım yapacak. Paran, çalışanların ve geliştirmelerin sıfırlanır; karşılığında tüm kazançlara <b>+%{b}</b> bonus alırsın. Bu bonus Halka Arz'da da silinmez. Başarımların, itibarın ve günlük serin korunur.",
    'ipo': "Kasa, çalışanlar ve geliştirmeler sıfırlanacak. Yatırımcı hisselerin korunur, bu turda biriken <b>{p} hisse</b> de eklenir. Borsa Payı Ağacı, başarımların ve sıralamadaki puanın da kalır.<br>Kazanacağın: <b>{n} Borsa Payı</b>. Sonraki Yatırım Turlarında hisselerin %{z} fazla gelir.<br><small>Harcamadığın her Borsa Payı +%{u} üretim verir. Sonraki Halka Arz için en az {h} beklemen gerekir.</small>",
    'ipoBonus': "Yatırımcı bonusun +%{y} olur.",
    'done': "Artık halka açık bir şirketsin. Hisselerin yerinde duruyor. Borsa Payların: <b>{x}</b>",
    'waitNote': "İki Halka Arz arasında en az 12 saat olmalı.",
    'reopened': "🔔 Halka Arz yeniden açık.",
    'accelNote': "Kazandığın her Borsa Payı yeni hisseleri +%10 artırır, harcasan da sayılır. En fazla 5 kat.",
}
results = []


def check(name, cond, info=''):
    results.append((name, bool(cond), info))
    print(('PASS' if cond else 'FAIL'), name, info if not cond or os.environ.get('VERBOSE') else '')


def note(msg):
    print('     ' + msg)


def strip_tags(h):
    return re.sub(r'<[^>]+>', '', h.replace('<br>', '\n'))


def norm(t):
    return re.sub(r'\s+', ' ', t).strip()


# ---------------------------------------------------------------- v4.3.1 dosyaları (koruma testi için, git show e37018c)
V431 = os.path.join(ROOT, 'tests', '.cache', 'v431')
try:
    os.makedirs(V431, exist_ok=True)
    for f in ('index.html', 'game.js', 'cloud.js', 'leaderboard.js', 'style.css', 'sw.js', 'manifest.webmanifest', 'icon.svg'):
        with open(os.path.join(V431, f), 'wb') as fh:
            fh.write(subprocess.check_output(['git', 'show', 'e37018c:' + f], cwd=ROOT))
    HAVE_V431 = "VERSION = '4.3.1'" in open(os.path.join(V431, 'game.js'), encoding='utf-8').read()
except Exception as e:  # noqa: BLE001
    HAVE_V431 = False
    note('v4.3.1 files unavailable: %s' % e)


def file_route(root):
    def handler(route):
        path = urlsplit(route.request.url).path.lstrip('/') or 'index.html'
        fp = os.path.normpath(os.path.join(root, path))
        if not fp.startswith(root) or not os.path.isfile(fp):
            return route.fulfill(status=404, body='not found')
        route.fulfill(status=200, headers={'content-type': mimetypes.guess_type(fp)[0] or 'application/octet-stream', 'cache-control': 'no-store'},
                      body=open(fp, 'rb').read())
    return handler


FAKE_UMAMI = r"""(function () {
  var s = document.currentScript, website = s && s.getAttribute('data-website-id'), hook = s && s.getAttribute('data-before-send');
  function disabled() { try { return !!localStorage.getItem('umami.disabled'); } catch (e) { return false; } }
  function base() { return { website: website, hostname: location.hostname, url: location.pathname, title: document.title }; }
  function send(type, payload) {
    if (disabled()) return;
    var fn = hook && window[hook];
    if (typeof fn === 'function') { payload = fn(type, payload); if (!payload) return; }
    fetch('https://analiz.teserix.com/api/send', { method: 'POST', keepalive: true, headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ type: type, payload: payload }) }).catch(function () {});
  }
  window.umami = { track: function (name, data) { var p = base(); if (typeof name === 'string') { p.name = name; if (data) p.data = data; } send('event', p); } };
  if (document.readyState === 'complete') send('event', base()); else window.addEventListener('load', function () { send('event', base()); });
})();"""


class Net:
    def __init__(self):
        self.reqs = []
        self.sent = []

    def on_request(self, req):
        self.reqs.append((req.method, req.url))

    def umami(self, route):
        path = urlsplit(route.request.url).path
        if path == '/script.js':
            return route.fulfill(status=200, headers={'content-type': 'application/javascript', 'access-control-allow-origin': '*'}, body=FAKE_UMAMI)
        if path == '/api/send':
            try:
                self.sent.append(json.loads(route.request.post_data or '{}'))
            except Exception:  # noqa: BLE001
                pass
            return route.fulfill(status=200, headers={'content-type': 'application/json', 'access-control-allow-origin': '*', 'access-control-allow-headers': '*'}, body='{"ok":true}')
        route.fulfill(status=404, body='')

    @staticmethod
    def supabase(route):
        cors = {'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*', 'content-type': 'application/json'}
        if route.request.method == 'OPTIONS':
            return route.fulfill(status=204, headers=cors, body='')
        route.fulfill(status=200, headers=cors, body='null' if urlsplit(route.request.url).path == COUNT_PATH else '[]')

    def counts(self):
        u = [x for x in self.reqs if urlsplit(x[1]).hostname == 'analiz.teserix.com']
        return {'umami': len(u), 'counter': sum(1 for x in self.reqs if urlsplit(x[1]).path == COUNT_PATH)}

    def events(self, name):
        return [x['payload'] for x in self.sent if x.get('payload', {}).get('name') == name]


NOW_MS = int(time.time() * 1000)
HOUR = 3600 * 1000
TREE11 = ['kod_1', 'kod_2', 'kod_3', 'ekip_1', 'ekip_2', 'ekip_3', 'musteri_1', 'musteri_2', 'musteri_3', 'yatirim_1', 'yatirim_2']


def mk44(**kw):
    d = {'version': 5, 'saveVersion': 5, 'money': 0, 'runEarned': 4e12, 'totalEarned': 9e15, 'cycleEarned': 5e12, 'clicks': 10, 'clickEarned': 10,
         'playTime': 9000, 'startedAt': NOW_MS - 50 * HOUR, 'startedVersion': '4.4.0', 'lastSaved': NOW_MS,
         'gens': {'stajyer': 10}, 'upgrades': [], 'shares': 120, 'prestigeCount': 9, 'cycleRounds': 3,
         'stage': 5, 'stageBest': 5, 'cycleStage': 5, 'stageId': 'unicorn', 'stageBestId': 'unicorn', 'cycleStageId': 'unicorn',
         'achievements': [], 'reputation': 0, 'tree': [], 'ipoShares': 0, 'ipoSharesEarned': 0, 'ipoCount': 0, 'ipoAt': 0,
         'newsSeen': ['yeni_asama', 'siralama', 'acik_ofis'], 'newsPending': []}
    d.update(kw)
    return d


def seed(save, tel='off'):
    parts = ["(() => { if (sessionStorage.getItem('kh_seeded')) return; sessionStorage.setItem('kh_seeded','1');"]
    if tel is not None:
        parts.append("localStorage.setItem('kodhane_tel_notice', '1'); localStorage.setItem('kodhane_tel', %s);" % json.dumps(tel))
    if save is not None:
        parts.append("localStorage.setItem(%s, %s);" % (json.dumps(SAVE_KEY), json.dumps(json.dumps(save))))
    parts.append('})();')
    return ''.join(parts)


VP = {
    '360x640': dict(viewport={'width': 360, 'height': 640}, is_mobile=True, has_touch=True),
    '375x667': dict(viewport={'width': 375, 'height': 667}, is_mobile=True, has_touch=True),
    '568x320': dict(viewport={'width': 568, 'height': 320}, is_mobile=True, has_touch=True),
    '390x844': dict(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True),
    '1280x800': dict(viewport={'width': 1280, 'height': 800}),
}

OVERFLOW = """(sel) => {
  const W = innerWidth, out = [];
  const doc = document.documentElement.scrollWidth;
  for (const root of document.querySelectorAll(sel)) {
    if (root.offsetParent === null && getComputedStyle(root).position !== 'fixed') continue;
    for (const el of [root, ...root.querySelectorAll('*')]) {
      if (el.offsetParent === null && getComputedStyle(el).position !== 'fixed') continue;
      if (el.closest('.tabs')) continue;   // sekme çubuğu tasarım gereği yatay kaydırılır (v4.4 öncesi de)
      const r = el.getBoundingClientRect();
      if (r.width === 0 && r.height === 0) continue;
      const cs = getComputedStyle(el);
      const clip = el.scrollWidth > el.clientWidth + 1 && el.clientWidth > 0 && cs.overflowX !== 'visible' ? 'scroll' : null;
      const self = el.scrollWidth > el.clientWidth + 1 && el.clientWidth > 0 && el.children.length === 0 ? 'text' : null;
      if (r.right > W + 0.5 || r.left < -0.5 || clip || self)
        out.push({ el: el.id || el.className || el.tagName, r: [Math.round(r.left), Math.round(r.right)], sw: el.scrollWidth, cw: el.clientWidth, why: clip || self || 'offscreen', t: (el.innerText || '').slice(0, 40) });
    }
  }
  return { doc, W, bad: out.slice(0, 12), n: out.length };
}"""

with sync_playwright() as p:
    b = p.chromium.launch(args=['--host-resolver-rules=' + SAFETY])

    def new_ctx(vp='1280x800', init=None, net=None, root=ROOT, dsf=1):
        net = net or Net()
        opts = dict(locale='tr-TR', service_workers='block', device_scale_factor=dsf)
        opts.update(VP[vp])
        ctx = b.new_context(**opts)
        ctx.add_init_script('window.KODHANE_QUIET = true;')
        if init:
            ctx.add_init_script(init)
        ctx.route(re.compile(r'^https?://(?!kodhane\.teserix\.com/|analiz\.teserix\.com/|kodhane-api\.teserix\.com/|supabase\.teserix\.com/).*'), lambda r: r.abort('blockedbyclient'))
        ctx.route('https://kodhane.teserix.com/**', file_route(root))
        ctx.route('https://analiz.teserix.com/**', net.umami)
        ctx.route('https://kodhane-api.teserix.com/**', net.supabase)
        ctx.route('https://supabase.teserix.com/**', net.supabase)
        ctx.on('request', net.on_request)
        ctx.net = net
        return ctx

    def open_page(ctx):
        pg = ctx.new_page()
        pg.errs = []
        pg.on('pageerror', lambda e: pg.errs.append(str(e)))
        pg.goto(BASE)
        pg.wait_for_selector('#clickBtn')
        return pg

    def to_ipo(pg):
        pg.evaluate("Kodhane.setView('prestige'); Kodhane.renderAll()")
        pg.wait_for_timeout(150)
        pg.evaluate("document.getElementById('ipoSection').scrollIntoView({ block: 'start' })")
        pg.wait_for_timeout(150)

    def clear_toasts(pg):
        pg.evaluate("document.getElementById('toast').innerHTML = ''")

    # ============================================================ [dialog]
    ctx = new_ctx('390x844', init=seed(mk44()))
    pg = open_page(ctx)
    ev = pg.evaluate
    check('[dialog] v5 save loaded: Unicorn, 120 shares, 3 rounds, IPO open', ev("Kodhane.STAGES[Kodhane.state.cycleStage].id") == 'unicorn' and ev('Kodhane.state.shares') == 120 and ev('Kodhane.ipoUnlocked()'))
    ev("Kodhane.setView('prestige'); Kodhane.renderAll()")
    g = ev('Kodhane.sharesGain()')
    pg.click('#prestigeBtn'); pg.wait_for_selector('#modal:not(.hidden)')
    txt = pg.inner_text('#modalText')
    exp = strip_tags(R3['prestige'].replace('{g}', ev('Kodhane.fmt(%d)' % g)).replace('{b}', ev('Kodhane.pctText(Kodhane.investorBonus(%d))' % g)))
    check('[dialog] Yatırım Turu confirm = Yazı r3 exactly', norm(txt) == norm(exp), [txt, exp])
    pg.click('#modalActions button:has-text("Vazgeç")')
    to_ipo(pg)
    pnd, n = ev('Kodhane.ipoPendingShares()'), ev('Kodhane.ipoGain()')
    check('[dialog] Unicorn first IPO pays 3, pending shares = sharesGain', n == 3 and pnd == g and pnd >= 1, [n, pnd, g])
    check('[dialog] accelerator row +%0 and note (r3)', pg.inner_text('#ipoAccel') == '+%0' and pg.inner_text('#ipoAccelNote') == R3['accelNote'], [pg.inner_text('#ipoAccel'), pg.inner_text('#ipoAccelNote')])
    pg.click('#ipoBtn'); pg.wait_for_selector('#modal:not(.hidden)')
    txt = pg.inner_text('#modalText')
    head, rest = R3['ipo'].split('<br>', 1)
    full = head + '<br>' + R3['ipoBonus'] + ' ' + rest
    exp = strip_tags(full.replace('{p}', ev('Kodhane.fmt(%d)' % pnd)).replace('{n}', str(n)).replace('{y}', ev('Kodhane.pctText(Kodhane.investorBonus(%d))' % (120 + pnd)))
                     .replace('{z}', ev('Kodhane.num(%d)' % (n * 10))).replace('{u}', '1').replace('{h}', '12 saat'))
    check('[dialog] Halka Arz confirm = Yazı r3 exactly (p >= 1, bonus line, z incl. this IPO)', norm(txt) == norm(exp), [txt, exp])
    check('[dialog] no "kalıcı" in the Halka Arz confirm', 'kalıcı' not in txt.lower())
    clear_toasts(pg); pg.wait_for_timeout(250)
    pg.screenshot(path=os.path.join(SHOTS, 'kodhane-v44-halkaarz-onay.png'))
    pg.click('#modalActions button:has-text("Halka arz et")')
    pg.wait_for_selector('#modalTitle:has-text("Borsa zili")')
    done = pg.inner_text('#modalText')
    check('[dialog] after-IPO modal = r3', norm(done) == norm(strip_tags(R3['done'].replace('{x}', '3'))), done)
    st = ev('Kodhane.state')
    check('[dialog] after IPO: shares kept + pending, 3 pays, ipoAt ~ now, rounds 0', st['shares'] == 120 + pnd and st['ipoShares'] == 3 and st['ipoCount'] == 1 and abs(st['ipoAt'] - ev('Date.now()')) < 10000 and st['cycleRounds'] == 0, {k: st[k] for k in ('shares', 'ipoShares', 'ipoCount', 'ipoAt', 'cycleRounds')})
    pg.click('#modalActions button:has-text("Tamam")')
    to_ipo(pg); pg.wait_for_timeout(300)
    lbl = pg.inner_text('#ipoBtn')
    check('[wait] right after IPO: button "Halka arz et (11:59:5x / 12:00:00)", disabled', re.fullmatch(r'Halka arz et \((11:59:5\d|12:00:00)\)', lbl) is not None and pg.is_disabled('#ipoBtn'), lbl)
    both = ev("""(() => { const a = document.getElementById('ipoLock'), w = document.getElementById('ipoWait'), t = document.getElementById('ipoWaitText');
      const ra = a.getBoundingClientRect(), rw = w.getBoundingClientRect();
      return { lock: a.offsetParent !== null, wait: w.offsetParent !== null, lockTxt: a.textContent, waitTxt: t.textContent, note: document.getElementById('ipoWaitNote').textContent,
               below: rw.top >= ra.bottom - 0.5, lockLines: Math.round(ra.height / parseFloat(getComputedStyle(a).lineHeight || 20)) }; })()""")
    check('[wait] rounds lock and cooldown together: 🔒 line kept, ⏳ line separately BELOW it', both['lock'] and both['wait'] and both['below'] and both['lockTxt'].startswith('🔒 3 yatırım turundan sonra açılır. (0/3)')
          and re.fullmatch(r'⏳ Sonraki Halka Arz için (11:59:5\d|12:00:00) kaldı\.', both['waitTxt']) is not None and both['note'] == R3['waitNote'], both)
    check('[wait] accelerator row after 3 pays: +%30', pg.inner_text('#ipoAccel') == '+%30', pg.inner_text('#ipoAccel'))
    check('[dialog] no page errors', not pg.errs, pg.errs)
    ctx.close()

    # ============================================================ [wait] yalnızca bekleme (tur şartı tamam)
    ctx = new_ctx('360x640', init=seed(mk44(ipoCount=1, ipoShares=5, ipoSharesEarned=5, ipoAt=NOW_MS - HOUR, cycleStageId='teknoloji_devi', stageBestId='teknoloji_devi', stageId='teknoloji_devi',
                                           runEarned=2e15, cycleEarned=3e15)))
    pg = open_page(ctx)
    ev = pg.evaluate
    to_ipo(pg); pg.wait_for_timeout(300)
    lbl = pg.inner_text('#ipoBtn')
    m = re.fullmatch(r'Halka arz et \((\d+):(\d\d):(\d\d)\)', lbl)
    left = (int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))) if m else None
    check('[wait] 1 h after the last IPO: button shows ~11:00:00 left, disabled', m and 10 * 3600 + 3590 <= left <= 11 * 3600 and pg.is_disabled('#ipoBtn'), [lbl, left])
    check('[wait] only cooldown: 🔒 line hidden, ⏳ line + note shown, section not blurred', pg.is_hidden('#ipoLock') and pg.is_visible('#ipoWaitText') and pg.inner_text('#ipoWaitNote') == R3['waitNote']
          and not ev("document.getElementById('ipoSection').classList.contains('locked')"), [pg.is_hidden('#ipoLock'), pg.inner_text('#ipoWaitText')])
    check('[wait] ⏳ text format', re.fullmatch(r'⏳ Sonraki Halka Arz için \d+:\d\d:\d\d kaldı\.', pg.inner_text('#ipoWaitText')) is not None, pg.inner_text('#ipoWaitText'))
    check('[wait] gain shown (TD -> 5) while waiting', pg.inner_text('#ipoGain') == '5 Borsa Payı', pg.inner_text('#ipoGain'))
    pg.click('#ipoBtn', force=True); pg.wait_for_timeout(200)
    check('[wait] clicking the disabled button: no dialog, no IPO', pg.is_hidden('#modal') and ev('Kodhane.state.ipoCount') == 1)
    ev("Kodhane.state.ipoSharesEarned = 14; Kodhane.renderAll()")
    check('[wait] accelerator row: 14 pays -> +%140', pg.inner_text('#ipoAccel') == '+%140', pg.inner_text('#ipoAccel'))
    ev("Kodhane.state.ipoSharesEarned = 40; Kodhane.renderAll()")
    check('[wait] accelerator row at cap: +%400 (en fazla)', pg.inner_text('#ipoAccel') == '+%400 (en fazla)', pg.inner_text('#ipoAccel'))
    ev("Kodhane.state.ipoSharesEarned = 5; Kodhane.renderAll()")
    clear_toasts(pg); pg.wait_for_timeout(200)
    pg.screenshot(path=os.path.join(SHOTS, 'kodhane-v44-bekleme-dugme.png'))
    rows = ev(OVERFLOW, '#ipoSection')
    check('[wait][360x640] no horizontal overflow in the Halka Arz section', rows['doc'] <= rows['W'] and rows['n'] == 0, rows)
    # bekleme biter: tek seferlik bildirim, düğme açılır
    ev("Kodhane.state.ipoAt = Date.now() - 12 * 3600 * 1000 + 1500; Kodhane.renderAll()")
    pg.wait_for_function("!document.getElementById('ipoBtn').disabled", timeout=6000)
    pg.wait_for_timeout(300)
    toasts = ev("Array.from(document.querySelectorAll('#toast > *')).map(e => e.textContent)")
    check('[wait] cooldown ends: button enabled "Halka arz et", ⏳ hidden, one "🔔 Halka Arz yeniden açık." toast', pg.inner_text('#ipoBtn') == 'Halka arz et' and pg.is_hidden('#ipoWait')
          and sum(1 for t in toasts if R3['reopened'] in t) == 1, [pg.inner_text('#ipoBtn'), toasts])
    pg.wait_for_timeout(1200)
    toasts2 = ev("Array.from(document.querySelectorAll('#toast > *')).map(e => e.textContent)")
    check('[wait] reopened toast only once', sum(1 for t in toasts2 if R3['reopened'] in t) <= 1, toasts2)
    check('[wait] no page errors', not pg.errs, pg.errs)
    ctx.close()

    # ============================================================ [narrow] büyük sayılar
    BIG = dict(runEarned=3e24, totalEarned=9.87e30, cycleEarned=9.87e30, money=5.5e23, shares=7.5e20, ipoShares=123456789, ipoSharesEarned=123456789, ipoCount=99999,
               stageId='mars_ofisi', stageBestId='mars_ofisi', cycleStageId='mars_ofisi', tree=TREE11, cycleRounds=2, prestigeCount=123456)
    measures = {}
    for vname in ('360x640', '375x667', '568x320', '390x844', '1280x800'):
        for mode in ('wait', 'dialog'):
            s = mk44(**BIG)
            if mode == 'wait':
                s['ipoAt'] = NOW_MS - 1000          # bekleme + tur şartı birlikte (en uzun durum)
            else:
                s['cycleRounds'] = 3
            ctx = new_ctx(vname, init=seed(s))
            pg = open_page(ctx)
            to_ipo(pg); pg.wait_for_timeout(250)
            r1 = pg.evaluate(OVERFLOW, '#ipoSection, .panel-prestige, #view-prestige, main')
            r2 = None
            if mode == 'dialog':
                pg.click('#ipoBtn'); pg.wait_for_selector('#modal:not(.hidden)'); pg.wait_for_timeout(250)
                r2 = pg.evaluate(OVERFLOW, '#modal')
            ok = r1['doc'] <= r1['W'] and r1['n'] == 0 and (r2 is None or r2['n'] == 0)
            measures['%s/%s' % (vname, mode)] = {'doc': r1['doc'], 'W': r1['W'], 'bad': r1['n'] + (r2['n'] if r2 else 0)}
            check('[narrow][%s][%s] huge numbers: no horizontal overflow (page width %d / %d)' % (vname, mode, r1['doc'], r1['W']), ok, [r1, r2])
            if mode == 'wait' and vname in ('360x640', '568x320'):
                # ekran görüntüsü: tur şartı tamam (bulanıklık yok) ki büyük sayılar okunabilsin; taşma yeniden ölçülür
                pg.evaluate("Kodhane.state.cycleRounds = 3; Kodhane.renderAll(); var w = document.getElementById('ipoWait'), hb = document.querySelector('header.topbar').getBoundingClientRect().bottom; window.scrollBy(0, w.getBoundingClientRect().top - hb - 8)")
                clear_toasts(pg); pg.wait_for_timeout(250)
                r3 = pg.evaluate(OVERFLOW, '#ipoSection, .panel-prestige, #view-prestige, main')
                check('[narrow][%s][wait, unblurred] huge numbers: no horizontal overflow' % vname, r3['doc'] <= r3['W'] and r3['n'] == 0, r3)
                pg.screenshot(path=os.path.join(SHOTS, 'kodhane-v44-buyuk-sayi-%s.png' % vname))
            if mode == 'wait':
                note('[narrow][%s] button "%s", gain "%s", shares "%s", bonus "%s"' % (vname, pg.inner_text('#ipoBtn'), pg.inner_text('#ipoGain'), pg.inner_text('#ipoShares'), pg.inner_text('#ipoBonus')))
            check('[narrow][%s][%s] no page errors' % (vname, mode), not pg.errs, pg.errs)
            ctx.close()
    note('narrow measurements: ' + json.dumps(measures))

    # ============================================================ [net] iki olay, izin kapısı
    def play_events(pg):
        """Halka Arz (UI) + ağacın son düğümü (UI)."""
        to_ipo(pg)
        pg.click('#ipoBtn'); pg.wait_for_selector('#modal:not(.hidden)')
        pg.click('#modalActions button:has-text("Halka arz et")')
        pg.wait_for_selector('#modalTitle:has-text("Borsa zili")')
        pg.click('#modalActions button:has-text("Tamam")')
        pg.wait_for_timeout(200)
        # Halka Arz'dan sonra bölüm 3 tur boyunca kilitli ve bulanık (v4.0'dan beri, ağaç da); alım için turlar tamamlanmış sayılır
        pg.evaluate("Kodhane.state.cycleRounds = 3; Kodhane.renderAll()")
        to_ipo(pg)
        pg.click('.tree-node[data-node="yatirim_3"]')
        pg.wait_for_timeout(600)
        return pg.evaluate('Kodhane.state.tree.length'), pg.evaluate('Kodhane.state.ipoCount')

    NETSAVE = dict(tree=TREE11, ipoShares=4, ipoSharesEarned=38, ipoCount=2, ipoAt=NOW_MS - 13 * HOUR, stageId='teknoloji_devi', stageBestId='teknoloji_devi',
                   cycleStageId='teknoloji_devi', runEarned=2e15, cycleEarned=3e15)
    # (a) bildirim yanıtlanmadan
    ctx = new_ctx('1280x800', init=seed(mk44(**NETSAVE), tel=None))
    pg = open_page(ctx)
    pg.wait_for_selector('[data-test=tel-banner]')
    tl, ic = play_events(pg)
    log = pg.evaluate('Kodhane.trackLog')
    check('[net][before Tamam] both events happened (tree 12, IPO 3) and were dropped ("off")', tl == 12 and ic == 3 and ['ipo_complete', 'off'] in [x[:2] for x in log] and ['tree_full', 'off'] in [x[:2] for x in log], [tl, ic, log])
    pg.reload(); pg.wait_for_selector('#clickBtn'); pg.wait_for_timeout(500)
    c = ctx.net.counts()
    check('[net][before Tamam] incl. reload: 0 Umami requests, 0 counter requests', c['umami'] == 0 and c['counter'] == 0, c)
    check('[net][before Tamam] nothing queued', pg.evaluate('Kodhane.umamiQueue().length') == 0)
    # (b) Kapat
    pg.click('[data-test=tel-off]'); pg.wait_for_timeout(200)
    ctx.close()
    ctx = new_ctx('1280x800', init=seed(mk44(**NETSAVE), tel='off'))
    pg = open_page(ctx)
    tl, ic = play_events(pg)
    pg.reload(); pg.wait_for_selector('#clickBtn'); pg.wait_for_timeout(500)
    c = ctx.net.counts()
    check('[net][after Kapat] both events happened, 0 Umami requests, 0 counter requests (incl. reload)', tl == 12 and ic == 3 and c['umami'] == 0 and c['counter'] == 0, [tl, ic, c])
    check('[net] no page errors (before Tamam / Kapat)', not pg.errs, pg.errs)
    ctx.close()
    # (c) Tamam -> sahte Umami, alanlar birebir
    ctx = new_ctx('1280x800', init=seed(mk44(**NETSAVE), tel=None))
    pg = open_page(ctx)
    pg.wait_for_selector('[data-test=tel-banner]')
    pg.click('[data-test=tel-ok]')
    pg.wait_for_function("typeof window.umami === 'object'", timeout=8000)
    play_events(pg)
    pg.wait_for_timeout(800)
    ipo_ev, tree_ev = ctx.net.events('ipo_complete'), ctx.net.events('tree_full')
    check('[net][Tamam] ipo_complete once, data exactly {stage_id, pays, ipo_number} = teknoloji_devi / 5 / 3',
          len(ipo_ev) == 1 and ipo_ev[0].get('data') == {'stage_id': 'teknoloji_devi', 'pays': 5, 'ipo_number': 3}, ipo_ev)
    check('[net][Tamam] tree_full once, data exactly {hours_since_start: 50, ipo_number: 3, started_v44: yes}',
          len(tree_ev) == 1 and tree_ev[0].get('data') == {'hours_since_start': 50, 'ipo_number': 3, 'started_v44': 'yes'}, tree_ev)
    allkeys = sorted(set(k for x in ipo_ev + tree_ev for k in x.keys()))
    check('[net][Tamam] event payloads carry only the standard fields + name + data', allkeys == sorted(['website', 'hostname', 'url', 'title', 'name', 'data']), allkeys)
    check('[net][Tamam] v4.4.1: Halka Arz no longer sends reset_or_prestige (split into investment_round / ipo_complete / hard_reset)',
          not any(x.get('payload', {}).get('name') == 'reset_or_prestige' for x in ctx.net.sent), [x.get('payload', {}).get('name') for x in ctx.net.sent])
    check('[net][Tamam] no page errors', not pg.errs, pg.errs)
    ctx.close()
    # (d) eski kayıt (startedVersion yok, startedAt yok): süre alanı yok, started_v44 no
    old = mk44(**NETSAVE)
    for k in ('startedVersion', 'startedAt', 'stageId', 'stageBestId', 'cycleStageId', 'ipoAt'):
        old.pop(k, None)
    old.update(version=4, saveVersion=4, stage=6, stageBest=6, cycleStage=6)
    ctx = new_ctx('1280x800', init=seed(old, tel='on'))
    pg = open_page(ctx)
    pg.wait_for_function("typeof window.umami === 'object'", timeout=8000)
    check('[net][old save] legacy stage 6 = Teknoloji Devi, no ipoAt -> IPO open', pg.evaluate("Kodhane.STAGES[Kodhane.state.cycleStage].id") == 'teknoloji_devi' and pg.evaluate('Kodhane.ipoUnlocked()'))
    play_events(pg)
    pg.wait_for_timeout(800)
    tree_ev = ctx.net.events('tree_full')
    check('[net][old save] tree_full data exactly {ipo_number: 3, started_v44: no} (no hours when startedAt unknown)',
          len(tree_ev) == 1 and tree_ev[0].get('data') == {'ipo_number': 3, 'started_v44': 'no'}, tree_ev)
    check('[net][old save] no page errors', not pg.errs, pg.errs)
    ctx.close()

    # ============================================================ [net3] v4.4.1: reset_or_prestige -> investment_round / ipo_complete / hard_reset
    # beforeunload'da trackLog sessionStorage'a yazılır: "Kaydı sıfırla" sayfayı yeniden açtığı için son çağrı oradan okunur
    KEEP_LOG = "window.addEventListener('beforeunload', function () { try { sessionStorage.setItem('kh_tl', JSON.stringify(window.Kodhane ? Kodhane.trackLog : [])); } catch (e) {} });"

    def round_ui(pg):
        pg.evaluate("Kodhane.setView('prestige'); Kodhane.renderAll()"); pg.wait_for_timeout(150)
        st = pg.evaluate("Kodhane.STAGES[Kodhane.stageIndex(Kodhane.state.runEarned)].id")
        pg.click('#prestigeBtn'); pg.wait_for_selector('#modal:not(.hidden)')
        pg.click('#modalActions button:has-text("Anlaştık!")'); pg.wait_for_timeout(300)
        return st

    def ipo_ui(pg):
        to_ipo(pg)
        pg.click('#ipoBtn'); pg.wait_for_selector('#modal:not(.hidden)')
        pg.click('#modalActions button:has-text("Halka arz et")')
        pg.wait_for_selector('#modalTitle:has-text("Borsa zili")')
        pg.click('#modalActions button:has-text("Tamam")'); pg.wait_for_timeout(200)

    def hard_reset_ui(pg):
        if pg.evaluate("document.getElementById('tab-stats').classList.contains('hidden')"):
            pg.evaluate("Kodhane.selectTab('stats')")
        pg.click('#resetBtn'); pg.wait_for_selector('#resetHold'); pg.wait_for_timeout(400)
        with pg.expect_navigation(timeout=20000):
            pg.hover('#resetHold'); pg.mouse.down(); pg.wait_for_timeout(2300); pg.mouse.up()
        pg.wait_for_selector('#clickBtn'); pg.wait_for_timeout(500)

    def three_events(pg):
        st = round_ui(pg)
        rounds = pg.evaluate('[Kodhane.state.prestigeCount, Kodhane.state.cycleRounds]')
        ipo_ui(pg)
        ic = pg.evaluate('Kodhane.state.ipoCount')
        before = pg.evaluate('Kodhane.trackLog')
        hard_reset_ui(pg)
        last = json.loads(pg.evaluate("sessionStorage.getItem('kh_tl') || '[]'"))
        fresh = pg.evaluate('[Kodhane.state.prestigeCount, Kodhane.state.ipoCount, Kodhane.state.totalEarned]')
        return st, rounds, ic, before, last, fresh

    N3SAVE = dict(NETSAVE)
    names3 = ['investment_round', 'ipo_complete', 'hard_reset']
    # (a) bildirim yanıtlanmadan: üç olay da olur, üçü de atılır ("off"); yeniden açılış dahil 0 istek
    ctx = new_ctx('1280x800', init=seed(mk44(**N3SAVE), tel=None) + KEEP_LOG)
    pg = open_page(ctx)
    pg.wait_for_selector('[data-test=tel-banner]')
    st, rounds, ic, before, last, fresh = three_events(pg)
    calls = [x[:2] for x in last]
    check('[net3][before Tamam] Yatırım Turu + Halka Arz + Kaydı sıfırla happened (rounds 10/4, IPO 3, then fresh save)',
          st == 'teknoloji_devi' and rounds == [10, 4] and ic == 3 and fresh[0] == 0 and fresh[1] == 0, [st, rounds, ic, fresh])
    check('[net3][before Tamam] the three events were called by name and dropped ("off"), no reset_or_prestige',
          all([n, 'off'] in calls for n in names3) and not any(x[0] == 'reset_or_prestige' for x in last), calls)
    c = ctx.net.counts()
    check('[net3][before Tamam] 0 Umami requests, 0 counter requests (incl. the reset reload)', c['umami'] == 0 and c['counter'] == 0, c)
    check('[net3][before Tamam] nothing queued', pg.evaluate('Kodhane.umamiQueue().length') == 0)
    check('[net3][before Tamam] no page errors', not pg.errs, pg.errs)
    ctx.close()
    # (b) Kapat: yine 0 istek
    ctx = new_ctx('1280x800', init=seed(mk44(**N3SAVE), tel='off') + KEEP_LOG)
    pg = open_page(ctx)
    st, rounds, ic, before, last, fresh = three_events(pg)
    c = ctx.net.counts()
    check('[net3][after Kapat] three events happened and dropped, 0 Umami / 0 counter requests',
          all([n, 'off'] in [x[:2] for x in last] for n in names3) and c['umami'] == 0 and c['counter'] == 0, [c, [x[:2] for x in last]])
    ctx.close()
    # (c) Tamam: sahte Umami'ye üç ayrı ad, birer kez, alanlar birebir
    ctx = new_ctx('1280x800', init=seed(mk44(**N3SAVE), tel=None) + KEEP_LOG)
    pg = open_page(ctx)
    pg.wait_for_selector('[data-test=tel-banner]')
    c0 = ctx.net.counts()
    check('[net3][Tamam] before clicking Tamam: 0 Umami requests', c0['umami'] == 0, c0)
    pg.click('[data-test=tel-ok]')
    pg.wait_for_function("typeof window.umami === 'object'", timeout=8000)
    st, rounds, ic, before, last, fresh = three_events(pg)
    pg.wait_for_timeout(800)
    ev_r, ev_i, ev_h = ctx.net.events('investment_round'), ctx.net.events('ipo_complete'), ctx.net.events('hard_reset')
    check('[net3][Tamam] investment_round once, data exactly {stage_id} = teknoloji_devi', len(ev_r) == 1 and ev_r[0].get('data') == {'stage_id': 'teknoloji_devi'}, ev_r)
    check('[net3][Tamam] ipo_complete once, data exactly {stage_id, pays, ipo_number} = teknoloji_devi / 5 / 3',
          len(ev_i) == 1 and ev_i[0].get('data') == {'stage_id': 'teknoloji_devi', 'pays': 5, 'ipo_number': 3}, ev_i)
    check('[net3][Tamam] hard_reset once, name only (no data)', len(ev_h) == 1 and 'data' not in ev_h[0], ev_h)
    names_sent = [x.get('payload', {}).get('name') for x in ctx.net.sent if x.get('payload', {}).get('name')]
    check('[net3][Tamam] reset_or_prestige never sent; events seen by name', 'reset_or_prestige' not in names_sent and all(n in names_sent for n in names3), names_sent)
    keys3 = sorted(set(k for x in ev_r + ev_i + ev_h for k in x.keys()))
    check('[net3][Tamam] payloads: only standard fields + name (+ data)', keys3 == sorted(['website', 'hostname', 'url', 'title', 'name', 'data']), keys3)
    blob = json.dumps(ev_r + ev_i + ev_h)
    check('[net3][Tamam] no personal data in the three payloads (no email / nick / id / save fields)',
          not re.search(r'@|nick|email|user|uid|totalEarned|money|"id"', blob), blob[:300])
    check('[net3][Tamam] no page errors', not pg.errs, pg.errs)
    note('[net3] sent names: ' + json.dumps(names_sent))
    ctx.close()

    # ============================================================ [guard] v4.3.1 istemcisi v5 kaydını yazmaz
    if HAVE_V431:
        raw = json.dumps(mk44())
        ctx = new_ctx('1280x800', init=seed(mk44()), root=V431)
        pg = open_page(ctx)
        pg.wait_for_timeout(500)
        ver = pg.evaluate('Kodhane.VERSION')
        blocked = pg.evaluate('Kodhane.writesBlocked()')
        before = pg.evaluate('localStorage.getItem(%s)' % json.dumps(SAVE_KEY))
        for _ in range(5):
            pg.click('#clickBtn')
        pg.evaluate("Kodhane.save(); window.dispatchEvent(new Event('pagehide')); document.dispatchEvent(new Event('visibilitychange'))")
        pg.wait_for_timeout(11000)   # otomatik kayıt aralığı (10 sn) geçer
        after = pg.evaluate('localStorage.getItem(%s)' % json.dumps(SAVE_KEY))
        check('[guard] v4.3.1 (%s) sees the v5 save as newer: writes blocked, band shown' % ver, ver == '4.3.1' and blocked and pg.is_visible('[data-test=newer-save-band]'), [ver, blocked])
        check('[guard] v4.3.1: local v5 save byte-identical after clicks, save(), pagehide, visibilitychange, autosave', before == after and json.loads(after) == json.loads(raw), [before == after])
        ctx.close()
    else:
        check('[guard] v4.3.1 files available (git show e37018c)', False)

    b.close()

fails = [r for r in results if not r[1]]
print('\nSUMMARY: %d/%d passed' % (len(results) - len(fails), len(results)))
sys.exit(1 if fails else 0)
