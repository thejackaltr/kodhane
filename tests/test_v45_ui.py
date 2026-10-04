"""Kodhane v4.5 arayüz testi: F2 denge (itibar, avantaj paneli, 150+ kademe, Borsa dalı, Yörünge Üssü, E1 aralıkları, E2 büyük müşteri)
ve P7 "Kayıp bildir" (Hesap penceresi: misafir / girişli, form, hatalar, durumlar, kalan süre, telafi bildirimi, eski sekme).
Ağ yok: oyun Playwright route ile depo dosyalarından; Supabase/Umami sahte. Kayıp bildir RPC'leri Kodhane.lossReport.transport ile taklit edilir.
Ekran görüntüleri 360x640, 390x844, 568x320: KODHANE_V45_SHOTS (varsayılan /workspace/kodhane-v45-shots), adlar v45-<durum>-<görünüm>.png.
    python3 tests/test_v45_ui.py
"""
import json
import urllib.parse
import mimetypes
import os
import re
import sys
from urllib.parse import urlsplit

from playwright.sync_api import sync_playwright

ROOT = os.environ.get('KODHANE_ROOT') or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.environ.get('KODHANE_V45_SHOTS', '/workspace/kodhane-v45-shots')
os.makedirs(SHOTS, exist_ok=True)
BASE = 'https://kodhane.teserix.com/'
SAVE_KEY = 'kodhane_ajans_save_v2'
SAFETY = ('MAP analiz.teserix.com 127.0.0.1:9, MAP kodhane-api.teserix.com 127.0.0.1:9, MAP supabase.teserix.com 127.0.0.1:9, '
          'MAP kodhane.teserix.com 127.0.0.1:9, MAP thejackaltr.github.io 127.0.0.1:9, MAP cdn.jsdelivr.net 127.0.0.1:9, '
          'MAP acikofis.teserix.com 127.0.0.1:9, MAP *.supabase.co 127.0.0.1:9')
R3 = '/workspace/plans/kodhane-p7-kayip-bildir-yazi-r3.json'
results = []


def check(name, cond, info=''):
    results.append((name, bool(cond)))
    print(('PASS' if cond else 'FAIL'), name, info if not cond else '')


def file_route(root):
    def handler(route):
        path = urlsplit(route.request.url).path.lstrip('/') or 'index.html'
        fp = os.path.normpath(os.path.join(root, path))
        if not fp.startswith(root) or not os.path.isfile(fp):
            return route.fulfill(status=404, body='not found')
        route.fulfill(status=200, headers={'content-type': mimetypes.guess_type(fp)[0] or 'application/octet-stream', 'cache-control': 'no-store'},
                      body=open(fp, 'rb').read())
    return handler


# Canlı v6 benzeri sahte sunucu (karar 7): P7 durum RPC'si P7['mode'] = 'missing' ise PostgREST gibi 404 PGRST202 (bugünkü canlı),
# 'installed' ise anon anahtara 401 42501 (istemci notu bölüm 3). v7 sıralama yok (404 PGRST202), v6 sıralama 200.
P7 = {'mode': 'missing', 'calls': []}
PGRST202 = lambda fn, args: {'code': 'PGRST202', 'details': 'Searched for the function public.%s with parameter %s or with a single unnamed json/jsonb parameter, but no matches were found in the schema cache.' % (fn, args),
                             'hint': None, 'message': 'Could not find the function public.%s(%s) in the schema cache' % (fn, args)}


def supabase(route):
    cors = {'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*', 'content-type': 'application/json'}
    if route.request.method == 'OPTIONS':
        return route.fulfill(status=204, headers=cors, body='')
    path = urllib.parse.urlparse(route.request.url).path
    if path == '/rest/v1/rpc/kodhane_loss_report_status':
        P7['calls'].append({'body': route.request.post_data, 'auth': (route.request.headers.get('authorization') or '')[:7], 'apikey': bool(route.request.headers.get('apikey'))})
        if P7['mode'] == 'missing':
            return route.fulfill(status=404, headers=cors, body=json.dumps(PGRST202('kodhane_loss_report_status', 'p_limit')))
        return route.fulfill(status=401, headers=cors, body=json.dumps({'code': '42501', 'details': None, 'hint': None, 'message': 'permission denied for function kodhane_loss_report_status'}))
    if path == '/rest/v1/rpc/kodhane_leaderboard_v7':
        return route.fulfill(status=404, headers=cors, body=json.dumps(PGRST202('kodhane_leaderboard_v7', 'p_game, p_limit')))
    route.fulfill(status=200, headers=cors, body='[]')


NODES12 = ['kod_1', 'kod_2', 'kod_3', 'ekip_1', 'ekip_2', 'ekip_3', 'musteri_1', 'musteri_2', 'musteri_3', 'yatirim_1', 'yatirim_2', 'yatirim_3']


def save(**kw):
    d = {'version': 6, 'saveVersion': 6, 'money': 5e21, 'runEarned': 2e21, 'totalEarned': 3e21, 'cycleEarned': 2e21,
         'clicks': 10, 'clickEarned': 10, 'playTime': 9000, 'startedAt': 0, 'lastSaved': 0,
         'gens': {'stajyer': 160, 'junior': 120, 'senior': 40}, 'upgrades': ['stajyer_1', 'stajyer_2', 'stajyer_3', 'stajyer_4', 'stajyer_5'],
         'shares': 1200, 'prestigeCount': 9, 'cycleRounds': 10, 'stage': 7, 'stageBest': 7, 'cycleStage': 7,
         'stageId': 'asama_1e21', 'stageBestId': 'asama_1e21', 'cycleStageId': 'asama_1e21', 'achievements': [], 'reputation': 150,
         'tree': NODES12[:11], 'ipoShares': 9, 'ipoSharesEarned': 60, 'ipoCount': 5, 'ipoAt': 0,
         'newsSeen': ['yeni_asama', 'siralama', 'acik_ofis'], 'newsPending': []}
    d.update(kw)
    return d


VP = {
    '360x640': dict(viewport={'width': 360, 'height': 640}, is_mobile=True, has_touch=True),
    '390x844': dict(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True, device_scale_factor=2),
    '568x320': dict(viewport={'width': 568, 'height': 320}, is_mobile=True, has_touch=True),
}

OVERFLOW = """([sel, W]) => {
  const bad = [];
  for (const root of document.querySelectorAll(sel)) for (const el of [root, ...root.querySelectorAll('*')]) {
    if (el.offsetParent === null && getComputedStyle(el).position !== 'fixed') continue;
    if (el.closest('.tabs') || el.classList.contains('sr-only')) continue;
    const r = el.getBoundingClientRect(); if (!r.width && !r.height) continue;
    const cs = getComputedStyle(el);
    const self = el.scrollWidth > el.clientWidth + 1 && el.clientWidth > 0 && el.children.length === 0 && cs.textOverflow !== 'ellipsis';
    if (r.right > W + 0.5 || r.left < -0.5 || self) bad.push((el.id || el.className || el.tagName) + ':' + (el.textContent || '').trim().slice(0, 30));
  }
  return { doc: document.documentElement.scrollWidth, bad: bad.slice(0, 8), n: bad.length };
}"""

# Kayıp bildir RPC taklidi: window.__lr = { create: yanıt, status: yanıt, calls: [] }
STUB = """() => {
  window.__lr = { calls: [], create: { data: { id: 'r1', status: 'in_review', created_at: new Date().toISOString() }, error: null, status: 200 },
                  status: { data: [], error: null, status: 200 }, anon: { data: null, error: { message: 'permission denied for function kodhane_loss_report_status', code: '42501', details: null, hint: null }, status: 401 }, anonCalls: [] };
  window.__reconciles = 0;
  Kodhane.lossReport.transport = (name, args) => { __lr.calls.push([name, args]);
    return Promise.resolve(JSON.parse(JSON.stringify(name === 'kodhane_loss_report_create' ? __lr.create : __lr.status))); };
  // misafir yoklaması (karar 7): varsayılan "kurulu" (anon 401 42501)
  Kodhane.lossReport.anonTransport = (name, args) => { __lr.anonCalls.push([name, args]); return Promise.resolve(JSON.parse(JSON.stringify(__lr.anon))); };
  Kodhane.cloud.reconcile = () => { __reconciles++; return Promise.resolve(); };
}"""
SIGN_IN = """() => { Kodhane.cloud.state.user = { id: '11111111-2222-4333-8444-555555555555', email: 'oyuncu@ornek.com' };
  Kodhane.cloud.state.status = 'saved'; Kodhane.cloud.open(); Kodhane.onCloudRender(); }"""
ERR = lambda st, msg, det=None, code=None: {'data': None, 'error': {'message': msg, 'details': det, 'code': code or ('PT%d' % st), 'hint': None}, 'status': st}

CONSOLE = []

with sync_playwright() as p:
    b = p.chromium.launch(args=['--host-resolver-rules=' + SAFETY])

    def new_page(vp, sv=None):
        opts = dict(locale='tr-TR', service_workers='block', timezone_id='Europe/Istanbul')
        opts.update(VP[vp])
        ctx = b.new_context(**opts)
        ctx.add_init_script('window.KODHANE_QUIET = true;')
        ctx.add_init_script("(() => { if (sessionStorage.getItem('kh_seeded')) return; sessionStorage.setItem('kh_seeded','1');"
                            "localStorage.setItem('kodhane_tel_notice', '1'); localStorage.setItem('kodhane_tel', 'off');"
                            "localStorage.setItem(%s, %s); })();" % (json.dumps(SAVE_KEY), json.dumps(json.dumps(sv or save()))))
        ctx.route(re.compile(r'^https?://(?!kodhane\.teserix\.com/|analiz\.teserix\.com/|kodhane-api\.teserix\.com/|supabase\.teserix\.com/).*'), lambda r: r.abort('blockedbyclient'))
        ctx.route('https://kodhane.teserix.com/**', file_route(ROOT))
        ctx.route('https://analiz.teserix.com/**', lambda r: r.fulfill(status=404, body=''))
        ctx.route('https://kodhane-api.teserix.com/**', supabase)
        ctx.route('https://supabase.teserix.com/**', supabase)
        pg = ctx.new_page()
        errs = []
        CONSOLE.clear()  # yalnız oyunun kendi konsol çıktısı; test düzeneğinin engellediği SW / dış kaynak satırları sayılmaz
        pg.on('pageerror', lambda e: errs.append(str(e)))
        pg.on('console', lambda m: CONSOLE.append('%s: %s' % (m.type, m.text)) if m.type in ('error', 'warning') and 'blocked by Playwright' not in m.text and 'ERR_BLOCKED_BY_CLIENT' not in m.text else None)
        pg.goto(BASE)
        pg.wait_for_selector('#clickBtn')
        pg.wait_for_timeout(400)
        pg.evaluate("document.querySelectorAll('#modal:not(.hidden) .ghost, #modal:not(.hidden) .primary').forEach(b => b.click()); Kodhane.hideStageUp && Kodhane.hideStageUp()")
        return ctx, pg, errs

    def overflow(pg, vp, sel, label):
        W = VP[vp]['viewport']['width']
        r = pg.evaluate(OVERFLOW, [sel, W])
        check('[%s] %s: no horizontal overflow (scrollWidth %d / %d)' % (vp, label, r['doc'], W), r['doc'] <= W and r['n'] == 0, r)

    def shot(pg, name, vp, full=False):
        pg.wait_for_timeout(200)
        pg.screenshot(path=os.path.join(SHOTS, 'v45-%s-%s.png' % (name, vp)), full_page=full)

    def toasts(pg):
        return pg.evaluate("[...document.querySelectorAll('#toast .toast-item')].map(t => t.textContent)")

    # ================================================================ A) denge arayüzü (360x640 ayrıntılı)
    ctx, pg, errs = new_page('360x640')
    ev = pg.evaluate
    check('version 4.5.0, preset F2, save version 6', ev('Kodhane.VERSION') == '4.5.0' and ev('Kodhane.V45.name') == 'F2' and ev('Kodhane.SAVE_VERSION') == 6)
    check('reputation 150 kept (not clamped to 100)', ev('Kodhane.state.reputation') == 150)
    check('rep chip: "⭐ İtibar 150 · müşteri ödemeleri +%100" (bonus capped)', pg.inner_text('#repChip') == '⭐ İtibar 150 · müşteri ödemeleri +%100', pg.inner_text('#repChip'))
    ev("Kodhane.selectTab('stats')"); pg.wait_for_timeout(150)
    stats = pg.inner_text('#statsList')
    rows = ev("[...document.querySelectorAll('#statsList > div')].map(d => [d.querySelector('dt').textContent, d.querySelector('dd').textContent])")
    check('stats: İtibar 150 (no "/ 100")', ['İtibar', '150'] in rows, [r for r in rows if r[0] == 'İtibar'])
    VT = ev('Kodhane.V45_TEXT')
    PERK_NAMES = {VT['rep.perk.' + e]: e for e in ('E1', 'E2', 'E3', 'E4')}
    perks = {PERK_NAMES[r[0]]: r[1] for r in rows if r[0] in PERK_NAMES}
    check('advantage panel: E1 ✓, E2 ✓, E4 150 / 500 (Yazı names); E3 off (karar 3) -> not listed', perks == {'E1': '✓', 'E2': '✓', 'E4': '150 / 500'}
          and [r[0] for r in rows if r[0] in PERK_NAMES] == [VT['rep.perk.E1'], VT['rep.perk.E2'], VT['rep.perk.E4']], [perks, rows])
    check('E3 off: no [rep.perk.E3] anywhere in the page', '[rep.perk.E3]' not in ev('document.body.innerText'))
    ev("Kodhane.state.reputation = 1e6; Kodhane.selectTab('upgrades'); Kodhane.selectTab('stats')"); pg.wait_for_timeout(150)
    check('E3 off even at 1e6 reputation: repPerk(E3) false, row absent', ev("Kodhane.repPerk('E3')") is False and '[rep.perk.E3]' not in pg.inner_text('#statsList'))
    ev("Kodhane.state.reputation = 150; Kodhane.selectTab('upgrades'); Kodhane.selectTab('stats')"); pg.wait_for_timeout(150)
    overflow(pg, '360x640', '#tab-stats', 'stats + advantage panel')
    ev("document.getElementById('tab-stats').scrollIntoView(); window.scrollBy(0, 330)")
    shot(pg, 'avantaj-paneli', '360x640')
    # kademeler
    ev("Kodhane.selectTab('upgrades')"); pg.wait_for_timeout(150)
    ids = ev("Kodhane.availableUpgrades().map(u => u.id)")
    check('150 tier (stajyer_6) offered at 160 Stajyer; 200 tier not yet; junior 150 tier not at 120', 'stajyer_6' in ids and 'stajyer_7' not in ids and 'junior_6' not in ids, [i for i in ids if i.startswith(('stajyer', 'junior'))])
    upg_txt = pg.inner_text('#upgList')
    check('upgrade list shows the 150 tier (Yazı: Kendi Kupası) with "x1,25"', 'Kendi Kupası' in upg_txt and 'Stajyer üretimi x1,25' in upg_txt, upg_txt[:300])
    # Borsa dalı
    ev("Kodhane.setView ? Kodhane.setView('prestige') : Kodhane.selectTab('prestige')"); pg.wait_for_timeout(250)
    check('tree: 15 nodes, Borsa branch with 3 nodes, costs 4 / 5 / 5', ev("document.querySelectorAll('#treeGrid .tree-node').length") == 15
          and ev("[...document.querySelectorAll('#treeGrid [data-branch=borsa] .tn-cost')].map(e => e.textContent).join('|')") == '4 🪙|5 🪙|5 🪙')
    check('Borsa locked with 11 old nodes: Yazı lock text, disabled', ev("document.querySelector('[data-node=borsa_1]').disabled") is True
          and ev("document.querySelector('[data-node=borsa_1] .tn-state').textContent") == VT['tree.borsa.lockedFull'])
    ev("Kodhane.state.tree = %s; Kodhane.state.ipoShares = 20; Kodhane.renderAll()" % json.dumps(NODES12))
    pg.wait_for_timeout(150)
    check('12 old nodes: borsa_1 buyable (4 Borsa Payı)', ev("document.querySelector('[data-node=borsa_1]').disabled") is False)
    pg.click('[data-node=borsa_1]'); pg.wait_for_timeout(150)
    check('buy borsa_1 via UI: owned, 16 Borsa Payı left, price growth excess x0,8', ev("Kodhane.hasNode('borsa_1')") and ev('Kodhane.state.ipoShares') == 16 and abs(ev('Kodhane.growthF()') - 0.8 * 0.14 / 0.15) < 1e-12)
    overflow(pg, '360x640', '#treeGrid', 'tree with Borsa branch')
    ev("document.querySelector('#treeGrid [data-branch=borsa]').scrollIntoView({block: 'center'})")
    shot(pg, 'borsa-dali', '360x640')
    # Yörünge Üssü
    ev("Kodhane.showStageUp(Kodhane.stageRank('asama_1e21'))"); pg.wait_for_timeout(300)
    check('stage-up card: 🌌 Yörünge Üssü (Yazı r1), message from Yazı metinler r1', pg.inner_text('#suTitle') == 'Yörünge Üssü' and pg.inner_text('#suIcon') == '🌌' and pg.inner_text('#suMsg') == VT['stage.asama_1e21.msg'])
    shot(pg, 'yorunge-ussu', '360x640')
    ev("Kodhane.hideStageUp()")
    # E1 aralıkları (Math.random sabit 0,5): teklif (60..180) -> 120 sn, kart (150..270) -> 210 sn
    def gaps(rep):
        return ev("""(rep) => { const r = Math.random; Math.random = () => 0.5; Kodhane.state.reputation = rep; Kodhane.state.tree = [];
          const t = Date.now(); Kodhane.scheduleOffer(false); const o = (Kodhane.offerNextAt - t) / 1000; Kodhane.scheduleEvent(false); const e = (Kodhane.eventNextAt - t) / 1000;
          Math.random = r; return [o, e]; }""", rep)
    g0, g1 = gaps(24), gaps(25)
    check('E1: offer gap 120 s -> 96 s, event card gap 210 s -> 168 s (/1,25) at 25 reputation', abs(g0[0] - 120) < 1 and abs(g0[1] - 210) < 1 and abs(g1[0] - 96) < 1 and abs(g1[1] - 168) < 1, [g0, g1])
    # E2 büyük müşteri
    big = ev("""() => { const r = Math.random; Math.random = () => 0.05; Kodhane.state.reputation = 100; Kodhane.spawnOffer('cash'); const o = Kodhane.offer;
      const out = [o.big, document.getElementById('coText').textContent]; Math.random = r; return out; }""")
    check('E2 (100): big customer offer x3 with the 💎 prefix (Yazı)', big[0] is True and big[1].startswith('💎 Büyük müşteri: '), big)
    nb = ev("""() => { const r = Math.random; Math.random = () => 0.05; Kodhane.state.reputation = 99; Kodhane.spawnOffer('cash'); const o = Kodhane.offer.big; Math.random = r; return o; }""")
    check('below E2: no big customer', nb is False)
    check('balance UI: no page errors', not errs, errs)
    ctx.close()

    # ================================================================ B) P7 Kayıp bildir (360x640 ayrıntılı)
    LT = json.load(open(R3, encoding='utf-8'))['LOSS_TEXT'] if os.path.exists(R3) else None
    ctx, pg, errs = new_page('360x640', save(reputation=10, tree=[]))
    ev = pg.evaluate
    T = LT or ev('Kodhane.lossReport.TEXT')
    ev(STUB)
    pg.click('#accountBtn'); pg.wait_for_selector('#accountPanel:not(.hidden)'); pg.wait_for_timeout(200)
    check('guest: installed server proven by the anon probe (401 42501) -> one probe {p_limit: 1}', ev('__lr.anonCalls') == [['kodhane_loss_report_status', {'p_limit': 1}]], ev('__lr.anonCalls'))
    check('guest: "Kayıp bildir" section visible in the account window (title + button, Yazı r3)', pg.is_visible('#lossSection') and pg.inner_text('#lossTitle') == T['lossReport.title'] and pg.inner_text('#lossOpen') == T['lossReport.open'])
    check('privacy details slot present and empty (account.privacyDetails, text not in code)', ev("(() => { const e = document.getElementById('accPrivacyDetails'); return !!e && e.dataset.textKey === 'account.privacyDetails' && e.textContent === ''; })()"))
    overflow(pg, '360x640', '#accountPanel', 'account (guest)')
    ev("document.getElementById('lossSection').scrollIntoView({block: 'center'})"); shot(pg, 'kayip-misafir', '360x640')
    pg.click('#lossOpen'); pg.wait_for_timeout(100)
    check('guest -> needLogin text + "Giriş yap" button, no form, no RPC', pg.inner_text('#lossNotice') == T['lossReport.needLogin'] and pg.is_visible('#lossLogin')
          and pg.inner_text('#lossLogin') == T['lossReport.needLogin.button'] and not pg.is_visible('#lossForm') and ev('__lr.calls.length') == 0)
    shot(pg, 'kayip-giris-gerekli', '360x640')
    pg.click('#lossLogin'); pg.wait_for_timeout(250)
    check('"Giriş yap" -> e-mail field focused (login flow)', ev("document.activeElement && document.activeElement.id") == 'accEmail')
    # girişli
    ev(SIGN_IN); pg.wait_for_timeout(250)
    check('signed in: status RPC called with {p_limit: 10} only', ev('__lr.calls') == [['kodhane_loss_report_status', {'p_limit': 10}]], ev('__lr.calls'))
    check('signed in, no reports: no status box, open button', not pg.is_visible('#lossStatus') and pg.is_visible('#lossOpen'))
    pg.click('#lossOpen'); pg.wait_for_timeout(100)
    form = ev("""() => ({ items: [...document.querySelectorAll('#lossItems input')].map(i => i.type + ':' + i.value + ':' + i.parentNode.textContent),
      since: [...document.querySelectorAll('#lossSince input')].map(i => i.type + ':' + i.value + ':' + i.parentNode.textContent),
      max: document.getElementById('lossDesc').maxLength, ph: document.getElementById('lossDesc').placeholder, counter: document.getElementById('lossCounter').textContent })""")
    check('form: 5 checkboxes (Yazı item names), 5 radios (since options), textarea max 280, counter "0 / 280"',
          form['items'] == ['checkbox:%s:%s' % (k, T['lossReport.items.' + k]) for k in ['yatirim_turu', 'halka_arz', 'borsa_payi', 'agac', 'diger']]
          and form['since'] == ['radio:%s:%s' % (k, T['lossReport.since.' + k]) for k in ['bugun', 'dun', 'son_7_gun', 'son_30_gun', 'bilmiyorum']]
          and form['max'] == 280 and form['ph'] == T['lossReport.description.placeholder'] and form['counter'] == '0 / 280', form)
    overflow(pg, '360x640', '#accountPanel', 'account (form open)')
    ev("document.getElementById('lossForm').scrollIntoView({block: 'start'})"); shot(pg, 'kayip-form', '360x640')
    pg.click('#lossSubmit'); pg.wait_for_timeout(100)
    check('submit without a selection -> itemsRequired, nothing sent', pg.inner_text('#lossError') == T['lossReport.error.itemsRequired'] and len(ev('__lr.calls')) == 1)
    pg.check('#lossItems input[value=borsa_payi]'); pg.check('#lossItems input[value=agac]')
    pg.fill('#lossDesc', 'bana yaz: ali@ornek.com')
    pg.click('#lossSubmit'); pg.wait_for_timeout(100)
    check('description with @ / e-mail -> error.description, nothing sent', pg.inner_text('#lossError') == T['lossReport.error.description'] and len(ev('__lr.calls')) == 1)
    pg.fill('#lossDesc', 'Halka Arz yaptım, sayfayı yenileyince Borsa Paylarım gitti.')
    check('counter counts characters', pg.inner_text('#lossCounter') == '%d / 280' % len('Halka Arz yaptım, sayfayı yenileyince Borsa Paylarım gitti.'))
    pg.check('#lossSince input[value=dun]')
    pg.click('#lossSubmit'); pg.wait_for_timeout(250)
    call = ev('__lr.calls[1]')
    exp_since = ev("(() => { const d = new Date(); d.setHours(0, 0, 0, 0); d.setDate(d.getDate() - 1); return d.toISOString(); })()")
    check('create RPC body: items, lost_since = local start of yesterday (UTC ISO), description, client version 4.5.0',
          call[0] == 'kodhane_loss_report_create' and call[1] == {'p_lost_items': ['borsa_payi', 'agac'], 'p_lost_since': exp_since,
          'p_description': 'Halka Arz yaptım, sayfayı yenileyince Borsa Paylarım gitti.', 'p_client_version': '4.5.0'}, call)
    check('success -> lossReport.sent, form closed, status refreshed', pg.inner_text('#lossNotice') == T['lossReport.sent'] and not pg.is_visible('#lossForm') and ev('__lr.calls[2][0]') == 'kodhane_loss_report_status')
    shot(pg, 'kayip-gonderildi', '360x640')

    def attempt(resp, since='bugun'):
        ev("(r) => { __lr.create = r; __lr.calls = []; Kodhane.lossReport.state.notice = null; Kodhane.lossReport.state.rows = []; Kodhane.lossReport.setRetry(null); }", resp)
        pg.click('#lossOpen'); pg.wait_for_timeout(80)
        if not pg.is_checked('#lossItems input[value=diger]'):
            pg.check('#lossItems input[value=diger]')
        pg.check('#lossSince input[value=%s]' % since)
        pg.click('#lossSubmit'); pg.wait_for_timeout(200)
        return {'notice': pg.inner_text('#lossNotice') if pg.is_visible('#lossNotice') else '', 'error': pg.inner_text('#lossError') if pg.is_visible('#lossError') else '',
                'form': pg.is_visible('#lossForm'), 'login': pg.is_visible('#lossLogin'), 'calls': [c[0] for c in ev('__lr.calls')],
                'openDisabled': ev("document.getElementById('lossOpen').disabled")}

    r = attempt(ERR(400, 'loss_report_invalid', 'lost_items', '22023'))
    check('400 lost_items -> itemsRequired on the form', r['error'] == T['lossReport.error.itemsRequired'] and r['form'], r)
    pg.click('#lossCancel')
    r = attempt(ERR(400, 'loss_report_invalid', 'description', '22023'))
    check('400 description -> error.description (lossReport.error.description)', r['error'] == T['lossReport.error.description'] and r['form'], r)
    pg.click('#lossCancel')
    r = attempt(ERR(400, 'loss_report_invalid', 'lost_since', '22023'))
    check('400 lost_since -> lossReport.error.lostSince (Yazı metinler r1)', r['error'] == 'Oyunun en son ne zaman doğru olduğunu yeniden seç.', r)
    pg.click('#lossCancel')
    r = attempt(ERR(401, 'permission denied for function kodhane_loss_report_create', None, '42501'))
    check('401 -> needLogin + "Giriş yap"', r['notice'] == T['lossReport.needLogin'] and r['login'] and not r['form'], r)
    r = attempt(ERR(403, 'not_authenticated', None, '42501'))
    check('403 not_authenticated -> needLogin + "Giriş yap"', r['notice'] == T['lossReport.needLogin'] and r['login'], r)
    r = attempt(ERR(403, 'permission denied for table x', None, '42501'))
    check('403 other -> generic error (not login)', r['error'] == T['lossReport.error.generic'] and not r['login'], r)
    pg.click('#lossCancel')
    r = attempt(ERR(404, 'no_cloud_save', None, 'PT404'))
    check('404 no_cloud_save -> noCloudSave text', r['notice'] == T['lossReport.noCloudSave'] and not r['form'], r)
    r = attempt(ERR(404, 'Could not find the function public.kodhane_loss_report_create', None, 'PGRST202'))
    check('404 other -> generic error', r['error'] == T['lossReport.error.generic'], r)
    pg.click('#lossCancel')
    r = attempt(ERR(409, 'loss_report_open', None, 'PT409'))
    check('409 loss_report_open -> limit.open, status refreshed', r['notice'] == T['lossReport.limit.open'] and r['calls'] == ['kodhane_loss_report_create', 'kodhane_loss_report_status'], r)
    ev("window.__lr.status = { data: [{ id: 'r9', created_at: '2026-10-04T08:00:00Z', lost_items: ['diger'], lost_since: null, status: 'in_review', status_changed_at: null, reason: null, applied_at: null, review_reason: null }], error: null, status: 200 }")
    r = attempt(ERR(409, 'stale_revision', 'sent revision 3, server revision 4', 'PT409'))
    check('409 stale_revision -> save re-fetched (reconcile), current status shown, the same write NOT retried',
          ev('__reconciles') == 1 and r['calls'] == ['kodhane_loss_report_create', 'kodhane_loss_report_status'] and pg.is_visible('#lossStatus')
          and pg.inner_text('#lossStatus .loss-status-text') == T['lossReport.status.in_review.text'] and not r['form'], [r, ev('__reconciles')])
    ev("window.__lr.status = { data: [], error: null, status: 200 }")
    det = ev("new Date(Date.now() + 90 * 60000 - 30000).toISOString().replace(/\\.\\d+Z$/, 'Z')")
    r = attempt(ERR(429, 'loss_report_daily_limit', det, 'PT429'))
    check('429 PT429 loss_report_daily_limit: time from details (UTC ISO) -> limit.tooMany "1 saat 30 dakika" (fmtDur, rounded up), button disabled', r['notice'] == T['lossReport.limit.tooMany'].replace('{sure}', '1 saat 30 dakika') and r['openDisabled'], r)
    ev("document.getElementById('lossSection').scrollIntoView({block: 'center'})"); shot(pg, 'kayip-429', '360x640')
    r = attempt(ERR(429, 'loss_report_monthly_limit', None, 'PT429'))
    check('429 PT429 loss_report_monthly_limit without details -> safe default 24 h ("1 gün"), limit.tooMany', r['notice'] == T['lossReport.limit.tooMany'].replace('{sure}', '1 gün'), r)
    det2 = ev("new Date(Date.now() + 3 * 86400000 + 30000).toISOString().replace(/\\.\\d+Z$/, 'Z')")
    r = attempt(ERR(429, 'loss_report_monthly_limit', det2, 'PT429'))
    check('429 monthly with details (3 days) -> limit.tooMany "3 gün 1 dakika"', r['notice'] == T['lossReport.limit.tooMany'].replace('{sure}', '3 gün 1 dakika'), r)
    r = attempt(ERR(429, 'loss_report_daily_limit', '2026-10-45T08:00:00Z', 'PT429'))
    check('429 daily with broken ISO details -> default 24 h ("1 gün"), limit.tooMany, no crash', r['notice'] == T['lossReport.limit.tooMany'].replace('{sure}', '1 gün'), r)
    r = attempt(ERR(429, 'too_many', ev("new Date(Date.now() + 5 * 60000).toISOString().replace(/\\.\\d+Z$/, 'Z')"), 'PT429'))
    check('429 unknown message with a time -> limit.tooMany', r['notice'] == T['lossReport.limit.tooMany'].replace('{sure}', '5 dakika'), r)
    ev("Kodhane.lossReport.setRetry({ at: Date.now() + 600, key: 'lossReport.limit.daily' })")
    pg.wait_for_timeout(800); ev("Kodhane.lossReport.render()")
    check('retry time passed -> text removed, button enabled again', not pg.is_visible('#lossNotice') and not ev("document.getElementById('lossOpen').disabled"))
    check('retry wait survives reload (localStorage), cleared when expired', ev("localStorage.getItem('kodhane_loss_retry_v1')") is None)

    # durumlar
    def status_of(row):
        ev("(row) => { __lr.status = { data: [row], error: null, status: 200 }; Kodhane.lossReport.state.notice = null; return Kodhane.lossReport.refresh(); }", row)
        pg.wait_for_timeout(120)
        return [pg.inner_text('#lossStatus .loss-status-label'), pg.inner_text('#lossStatus .loss-status-text'), pg.is_visible('#lossStatus')]
    base = {'id': 'r2', 'created_at': '2026-10-04T08:00:00Z', 'lost_items': ['agac'], 'lost_since': None, 'status_changed_at': None, 'reason': None, 'applied_at': None, 'review_reason': None}
    check('in_review + review_reason null -> İnceleniyor / in_review.text', status_of(dict(base, status='in_review')) == [T['lossReport.status.in_review.label'], T['lossReport.status.in_review.text'], True])
    check('in_review + no_cloud_save -> in_review.text', status_of(dict(base, status='in_review', review_reason='no_cloud_save'))[1] == T['lossReport.status.in_review.text'])
    check('in_review + save_changed -> in_review.save_changed', status_of(dict(base, status='in_review', review_reason='save_changed'))[1] == T['lossReport.status.in_review.save_changed'])
    pg.click('#lossOpen'); pg.wait_for_timeout(80)
    check('open report -> "Kayıp bildir" shows limit.open instead of the form', pg.inner_text('#lossNotice') == T['lossReport.limit.open'] and not pg.is_visible('#lossForm'))
    check('approved -> Kabul edildi / approved.text', status_of(dict(base, status='approved')) == [T['lossReport.status.approved.label'], T['lossReport.status.approved.text'], True])
    for code in ['kayip_bulunamadi', 'zaten_telafi_edildi', 'kural_disi', 'diger']:
        check('rejected %s -> reject.%s' % (code, code), status_of(dict(base, status='rejected', reason=code)) == [T['lossReport.status.rejected.label'], T['lossReport.reject.' + code], True])
    check('rejected UNKNOWN code -> reject.generic', status_of(dict(base, status='rejected', reason='yeni_bir_kod'))[1] == T['lossReport.reject.generic'])
    check('rejected EMPTY code ("" and null) -> reject.generic', status_of(dict(base, status='rejected', reason=''))[1] == T['lossReport.reject.generic']
          and status_of(dict(base, status='rejected', reason=None))[1] == T['lossReport.reject.generic'])
    ev("document.getElementById('lossSection').scrollIntoView({block: 'center'})"); shot(pg, 'kayip-reddedildi', '360x640')
    old = dict(base, id='old1', status='applied', applied_at='2026-01-01T00:00:00Z')
    check('applied before this tab opened -> applied.text, no toast', status_of(old)[1] == T['lossReport.status.applied.text'] and T['lossReport.applied.toast'] not in toasts(pg))
    fresh_applied = dict(base, id='new1', status='applied', applied_at=ev("new Date(Date.now() + 1000).toISOString()"))
    st = status_of(fresh_applied)
    check('applied while this tab is open -> applied.text + toast "Telafin yüklendi, sayfayı yenile."', st[0] == T['lossReport.status.applied.label'] and T['lossReport.applied.toast'] in toasts(pg), [st, toasts(pg)])
    status_of(fresh_applied)
    check('the toast is shown once per report', toasts(pg).count(T['lossReport.applied.toast']) == 1, toasts(pg))
    ev("Kodhane.adoptSave(JSON.parse(Kodhane.serialize()), 'sync')"); pg.wait_for_timeout(150)
    check('old tab 409 after the restore (adoptSave sync) -> applied.staleTab instead of reset.otherDeviceSync', T['lossReport.applied.staleTab'] in toasts(pg)
          and not any('başka bir cihazda' in t for t in toasts(pg)), toasts(pg))
    ev("Kodhane.adoptSave(JSON.parse(Kodhane.serialize()), 'sync')"); pg.wait_for_timeout(150)
    check('a later unrelated 409 -> the usual otherDeviceSync text', any('başka bir cihazda' in t for t in toasts(pg)), toasts(pg))
    # eski sekme: applied_revision kesin kuralı (Backend 1cd221d). beforeStale({sent}) -> adoptSave('sync') mesajı
    def stale_msg(rows, sent):
        ev("document.querySelectorAll('#toast > *').forEach((t) => t.remove())")
        ev("([rows, sent]) => { __lr.status = { data: rows, error: null, status: 200 }; return Kodhane.lossReport.beforeStale({ sent: sent }); }", [rows, sent])
        verdict = ev('Kodhane.lossReport.state.staleVerdict')
        ev("Kodhane.adoptSave(JSON.parse(Kodhane.serialize()), 'sync')"); pg.wait_for_timeout(120)
        ts = toasts(pg)
        return ('staleTab' if T['lossReport.applied.staleTab'] in ts else 'sync' if any('başka bir cihazda' in t for t in ts) else 'none'), verdict
    arow = lambda rev, **kw: dict(base, id='ar%s' % rev, status='applied', applied_at='2026-01-02T00:00:00Z', applied_revision=rev, **kw)
    check('stale tab: sent == applied_revision -> staleTab (no heuristic needed: restore was before this tab opened)', stale_msg([arow(7)], 7) == ('staleTab', 'staleTab'))
    check('stale tab: sent < applied_revision -> staleTab', stale_msg([arow(7)], 4) == ('staleTab', 'staleTab'))
    check('stale tab: sent > applied_revision -> reset.otherDeviceSync', stale_msg([arow(7)], 8) == ('sync', 'sync'))
    check('stale tab: applied_revision null -> old heuristic (restore before tab opened -> otherDeviceSync)', stale_msg([arow(None)], 5) == ('sync', None))
    nofield = dict(base, id='nf1', status='applied', applied_at='2026-01-03T00:00:00Z')
    check('stale tab: applied_revision field missing -> old heuristic (otherDeviceSync here)', stale_msg([nofield], 5) == ('sync', None))
    fresh2 = dict(base, id='nf2', status='applied', applied_at=ev("new Date(Date.now() + 1000).toISOString()"))
    check('stale tab: field missing + restore while tab open -> old heuristic still gives staleTab', stale_msg([fresh2], 5) == ('staleTab', None))
    check('stale tab: non-applied status (approved, value present) -> ignored -> otherDeviceSync', stale_msg([dict(base, id='ap1', status='approved', applied_revision=9)], 5) == ('sync', 'sync'))
    fresh3 = dict(base, id='nf3', status='applied', applied_at=ev("new Date(Date.now() + 1000).toISOString()"), applied_revision=6)
    check('stale tab: exact field overrides the heuristic (restore while tab open but sent > applied_revision -> otherDeviceSync)', stale_msg([fresh3], 7) == ('sync', 'sync'))
    check('stale tab: status RPC fails (503) -> no verdict (old rows not used), heuristic, no crash', (lambda: (ev("__lr.status = { data: null, error: { message: 'x' }, status: 503 }"), ev("Kodhane.lossReport.beforeStale({ sent: 3 }).then(() => Kodhane.lossReport.state.staleVerdict)"))[1])() is None)
    info = ev("""() => { const LR = Kodhane.lossReport, orig = LR.beforeStale; let got = 'none';
      LR.beforeStale = (i) => { got = i; return Promise.resolve(); };
      const C = Kodhane.cloud.state, u = C.user;
      try { Kodhane.cloud.handleStale({ code: 'PT409', message: 'stale_revision', details: 'sent revision 12, server revision 13', status: 409 }); } catch (e) { got = 'throw ' + e; }
      C.user = null;   // sahte oturumun istemcisi yok: handleStale'in ardından gelen reconcile çalışmasın
      return new Promise((r) => setTimeout(r, 50)).then(() => { C.user = u; LR.beforeStale = orig; return got; }); }""")
    check('cloud.handleStale passes the sent revision from the 409 details to beforeStale({ sent })', info == {'sent': 12}, info)
    ev("__lr.status = { data: null, error: { message: 'Could not find the function public.kodhane_loss_report_status', code: 'PGRST202' }, status: 404 }; Kodhane.lossReport.refresh()")
    pg.wait_for_timeout(150)
    check('server without P7 (status 404 PGRST202) -> section hidden for signed-in players', not pg.is_visible('#lossSection'))
    check('P7 UI: no page errors', not errs, errs)
    ctx.close()

    # ================================================================ C) üç görünüm: taşma + ekran görüntüleri
    for vp in ('360x640', '390x844', '568x320'):
        ctx, pg, errs = new_page(vp, save(tree=NODES12 + ['borsa_1'], ipoShares=12))
        ev = pg.evaluate
        ev(STUB)
        overflow(pg, vp, 'main, .app, body', 'main view')
        shot(pg, 'ana', vp)
        ev("Kodhane.setView ? Kodhane.setView('prestige') : Kodhane.selectTab('prestige')"); pg.wait_for_timeout(250)
        overflow(pg, vp, '#treeGrid', 'tree with Borsa branch')
        ev("document.querySelector('#treeGrid [data-branch=borsa]').scrollIntoView({block: 'center'})"); shot(pg, 'borsa-dali', vp)
        ev("Kodhane.selectTab('stats')"); pg.wait_for_timeout(150)
        overflow(pg, vp, '#tab-stats', 'stats + advantage panel')
        ev("[...document.querySelectorAll('#statsList dt')].find(d => d.textContent === Kodhane.V45_TEXT['rep.perk.E1']).scrollIntoView({block: 'center'})"); shot(pg, 'avantaj-paneli', vp)
        ev("Kodhane.showStageUp(Kodhane.stageRank('asama_1e21'))"); pg.wait_for_timeout(300)
        shot(pg, 'yorunge-ussu', vp); ev("Kodhane.hideStageUp()")
        pg.click('#accountBtn'); pg.wait_for_selector('#accountPanel:not(.hidden)'); pg.wait_for_timeout(200)
        overflow(pg, vp, '#accountPanel', 'account (guest)')
        ev("document.getElementById('lossSection').scrollIntoView({block: 'center'})"); shot(pg, 'kayip-misafir', vp)
        ev(SIGN_IN); pg.wait_for_timeout(200)
        pg.click('#lossOpen'); pg.wait_for_timeout(120)
        overflow(pg, vp, '#accountPanel', 'account (signed in, form open)')
        reach = ev("""() => { const card = document.querySelector('#accountPanel .account-card'); const out = [];
          for (const id of ['lossSubmit', 'lossCancel', 'lossDesc']) { const e = document.getElementById(id); e.scrollIntoView({ block: 'nearest' });
            const r = e.getBoundingClientRect(), C = card.getBoundingClientRect(); const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
            out.push(r.top >= Math.max(0, C.top) - 0.5 && r.bottom <= Math.min(innerHeight, C.bottom) + 0.5 && !!hit && (hit === e || e.contains(hit))); }
          return out; }""")
        check('[%s] form controls reachable inside the account card (submit, cancel, textarea)' % vp, all(reach), reach)
        ev("document.getElementById('lossForm').scrollIntoView({block: 'start'})"); shot(pg, 'kayip-form', vp)
        pg.click('#lossCancel')
        ev("(row) => { __lr.status = { data: [row], error: null, status: 200 }; return Kodhane.lossReport.refresh(); }",
           {'id': 'r3', 'created_at': '2026-10-04T08:00:00Z', 'lost_items': ['agac'], 'lost_since': None, 'status': 'rejected', 'status_changed_at': None, 'reason': 'kayip_bulunamadi', 'applied_at': None, 'review_reason': None})
        pg.wait_for_timeout(150)
        overflow(pg, vp, '#accountPanel', 'account (status rejected)')
        ev("document.getElementById('lossSection').scrollIntoView({block: 'center'})"); shot(pg, 'kayip-durum', vp)
        ev("Kodhane.lossReport.setRetry({ at: Date.now() + 23 * 3600000 + 59 * 60000, key: 'lossReport.limit.daily' })"); pg.wait_for_timeout(100)
        overflow(pg, vp, '#accountPanel', 'account (429 wait)')
        ev("document.getElementById('lossSection').scrollIntoView({block: 'center'})"); shot(pg, 'kayip-429', vp)
        check('[%s] no page errors' % vp, not errs, errs)
        ctx.close()
        # kayıp-gizli: canlı v6 benzeri sunucu (P7 RPC'si yok), taklit yok, gerçek misafir yoklaması
        P7['mode'] = 'missing'; P7['calls'].clear()
        ctx, pg, errs = new_page(vp)
        ev = pg.evaluate
        pg.click('#accountBtn'); pg.wait_for_selector('#accountPanel:not(.hidden)'); pg.wait_for_timeout(400)
        check('[%s] live-like server without P7: section hidden in the account window' % vp, not pg.is_visible('#lossSection') and len(P7['calls']) == 1, P7['calls'])
        overflow(pg, vp, '#accountPanel', 'account (P7 hidden)')
        shot(pg, 'kayip-gizli', vp)
        ctx.close()

    # ================================================================ D) karar 7: otomatik gizleme (360x640)
    def opened(pg, stub=True, pre=None):
        if stub:
            pg.evaluate(STUB)
        if pre:
            pg.evaluate(pre)
        pg.click('#accountBtn'); pg.wait_for_selector('#accountPanel:not(.hidden)'); pg.wait_for_timeout(250)

    def reopen(pg):
        pg.evaluate('Kodhane.cloud.close()'); pg.wait_for_timeout(600)
        pg.click('#accountBtn'); pg.wait_for_selector('#accountPanel:not(.hidden)'); pg.wait_for_timeout(250)

    NOT_FOUND = "{ data: null, error: { message: 'Could not find the function public.kodhane_loss_report_status(p_limit) in the schema cache', code: 'PGRST202', details: null, hint: null }, status: 404 }"
    E503 = "{ data: null, error: { message: 'service unavailable' }, status: 503 }"
    AVAIL = "sessionStorage.getItem('kodhane_loss_avail_v1')"

    # D1 misafir, 404 -> gizli, hata yok, oturum boyunca önbellek
    ctx, pg, errs = new_page('360x640')
    ev = pg.evaluate
    opened(pg, pre='__lr.anon = ' + NOT_FOUND)
    check('D1 guest, status RPC 404 PGRST202 -> section hidden, cached "no"', not pg.is_visible('#lossSection') and ev(AVAIL) == 'no' and len(ev('__lr.anonCalls')) == 1)
    check('D1 404 is not shown as an error (no notice / error text in the account window)', ev("!document.getElementById('lossNotice') || document.getElementById('lossNotice').textContent === ''")
          and 'Bir sorun' not in pg.inner_text('#accountPanel'))
    reopen(pg); ev('Kodhane.lossReport.refresh()'); pg.wait_for_timeout(150)
    check('D1 cached for the session: reopen + refresh -> no new request', len(ev('__lr.anonCalls')) == 1 and not pg.is_visible('#lossSection'), ev('__lr.anonCalls'))
    pg.reload(); pg.wait_for_selector('#clickBtn'); pg.wait_for_timeout(300)
    pg.evaluate("document.querySelectorAll('#modal:not(.hidden) .ghost, #modal:not(.hidden) .primary').forEach(b => b.click()); Kodhane.hideStageUp && Kodhane.hideStageUp()")
    opened(pg)
    check('D1 after reload (same session): still hidden, zero requests (sessionStorage)', not pg.is_visible('#lossSection') and ev('__lr.anonCalls') == [])
    ev(SIGN_IN); pg.wait_for_timeout(250)
    check('D1 signing in later in the same session: still hidden, no status request', not pg.is_visible('#lossSection') and ev('__lr.calls') == [])
    check('D1 console clean (no error / warning) and no page errors', not CONSOLE and not errs, CONSOLE + errs)
    ctx.close()
    # D2 misafir 401 / 200 -> görünür
    for label, resp in (('401 42501', None), ('200', '{ data: [], error: null, status: 200 }')):
        ctx, pg, errs = new_page('360x640')
        opened(pg, pre=('__lr.anon = ' + resp) if resp else None)
        check('D2 guest, probe %s -> section visible, cached "yes"' % label, pg.is_visible('#lossSection') and pg.evaluate(AVAIL) == 'yes')
        ctx.close()
    # D3 misafir 5xx -> gizli ama önbelleğe alınmaz; sonraki açılışta yeniden denenir
    ctx, pg, errs = new_page('360x640')
    ev = pg.evaluate
    opened(pg, pre='__lr.anon = ' + E503)
    check('D3 guest, probe 503 -> not proven: hidden, NOT cached', not pg.is_visible('#lossSection') and ev(AVAIL) is None)
    ev("__lr.anon = { data: null, error: { message: 'Failed to fetch' }, status: 0 }"); reopen(pg)
    check('D3 guest, network error -> still unknown, retried (2 requests), not cached', len(ev('__lr.anonCalls')) == 2 and ev(AVAIL) is None and not pg.is_visible('#lossSection'), [ev('__lr.anonCalls'), ev(AVAIL), ev('Kodhane.lossReport.state.avail'), ev("document.getElementById('accountPanel').className")])
    ev("__lr.anon = { data: null, error: { message: 'permission denied for function kodhane_loss_report_status', code: '42501' }, status: 401 }"); reopen(pg)
    check('D3 next open, server answers 401 -> section visible (temporary error did not hide it permanently)', pg.is_visible('#lossSection') and ev(AVAIL) == 'yes' and len(ev('__lr.anonCalls')) == 3)
    ctx.close()
    # D4 girişli: 200 -> görünür; sonra 5xx / ağ hatası -> görünür kalır
    ctx, pg, errs = new_page('360x640')
    ev = pg.evaluate
    ev(STUB); ev(SIGN_IN); pg.wait_for_timeout(250)
    check('D4 signed in, status 200 -> visible', pg.is_visible('#lossSection') and ev(AVAIL) == 'yes')
    ev('__lr.status = ' + E503 + '; Kodhane.lossReport.refresh()'); pg.wait_for_timeout(150)
    check('D4 then status 503 -> NOT hidden, decision stays "yes"', pg.is_visible('#lossSection') and ev(AVAIL) == 'yes')
    ev("__lr.status = { data: null, error: { message: 'Failed to fetch' }, status: 0 }; Kodhane.lossReport.refresh()"); pg.wait_for_timeout(150)
    check('D4 then network error -> NOT hidden', pg.is_visible('#lossSection'))
    pg.click('#lossOpen'); pg.wait_for_timeout(80)
    ev("__lr.create = " + E503); pg.check('#lossItems input[value=diger]'); pg.click('#lossSubmit'); pg.wait_for_timeout(200)
    check('D4 create 503 -> usual generic error shown, section stays', pg.is_visible('#lossSection') and pg.inner_text('#lossError') == ev("Kodhane.lossReport.text('lossReport.error.generic')"))
    ctx.close()
    # D5 girişli, ilk yanıt 5xx -> gizli (kanıt yok), önbellek yok; sonra 200 -> görünür
    ctx, pg, errs = new_page('360x640')
    ev = pg.evaluate
    ev(STUB); ev('__lr.status = ' + E503); ev(SIGN_IN); pg.wait_for_timeout(250)
    check('D5 signed in, first status 503 -> hidden until proven, not cached', not pg.is_visible('#lossSection') and ev(AVAIL) is None)
    ev('__lr.status = { data: [], error: null, status: 200 }; Kodhane.lossReport.refresh()'); pg.wait_for_timeout(150)
    check('D5 retry 200 -> visible', pg.is_visible('#lossSection') and ev(AVAIL) == 'yes')
    ctx.close()
    # D6 girişli, 404 -> gizli, oturum boyunca istek yok
    ctx, pg, errs = new_page('360x640')
    ev = pg.evaluate
    ev(STUB); ev('__lr.status = ' + NOT_FOUND); ev(SIGN_IN); pg.wait_for_timeout(250)
    n = len(ev('__lr.calls'))
    check('D6 signed in, status 404 PGRST202 -> hidden, cached "no"', not pg.is_visible('#lossSection') and ev(AVAIL) == 'no' and n == 1)
    reopen(pg); ev('Kodhane.lossReport.refresh(); Kodhane.cloud.handleStale && 0'); pg.wait_for_timeout(150)
    check('D6 no further status requests in the session (reopen + refresh + beforeStale)', len(ev('__lr.calls')) == 1 and ev('Kodhane.lossReport.beforeStale().then(() => __lr.calls.length)') == 1)
    check('D6 console clean, no page errors', not CONSOLE and not errs, CONSOLE + errs)
    ctx.close()
    # D7 CFG.enabled = false -> gizli, istek yok (misafir + girişli)
    ctx, pg, errs = new_page('360x640')
    ev = pg.evaluate
    opened(pg, pre='Kodhane.lossReport.CFG.enabled = false; Kodhane.lossReport.render()')
    check('D7 enabled=false, guest: hidden, no probe', not pg.is_visible('#lossSection') and ev('__lr.anonCalls') == [])
    ev(SIGN_IN); pg.wait_for_timeout(250)
    check('D7 enabled=false, signed in: hidden, no status request', not pg.is_visible('#lossSection') and ev('__lr.calls') == [])
    ctx.close()
    # D8 canlı v6 benzeri sahte sunucu, taklit yok: gerçek anon yoklaması (fetch, herkese açık anahtar)
    P7['mode'] = 'missing'; P7['calls'].clear()
    ctx, pg, errs = new_page('360x640')
    ev = pg.evaluate
    opened(pg, stub=False)
    check('D8 live v6-like server (no P7 RPC): section hidden', not pg.is_visible('#lossSection') and ev(AVAIL) == 'no')
    check('D8 probe: one POST with the public key (apikey + Bearer), body {"p_limit":1}', len(P7['calls']) == 1 and P7['calls'][0]['apikey'] and P7['calls'][0]['auth'] == 'Bearer ' and json.loads(P7['calls'][0]['body']) == {'p_limit': 1}, P7['calls'])
    reopen(pg); pg.reload(); pg.wait_for_selector('#clickBtn'); pg.wait_for_timeout(300)
    pg.evaluate("document.querySelectorAll('#modal:not(.hidden) .ghost, #modal:not(.hidden) .primary').forEach(b => b.click()); Kodhane.hideStageUp && Kodhane.hideStageUp()")
    opened(pg, stub=False)
    check('D8 reopen + reload in the same session: no new request', len(P7['calls']) == 1, P7['calls'])
    other = [c for c in CONSOLE if 'Failed to load resource' not in c]
    check('D8 no page errors, no console errors from the game (only the browser\'s own 404 network line, once)', not errs and not other and len([c for c in CONSOLE if 'status of 404' in c]) <= 1, CONSOLE + errs)
    ctx.close()
    P7['mode'] = 'installed'; P7['calls'].clear()
    ctx, pg, errs = new_page('360x640')
    opened(pg, stub=False)
    check('D8 same server with P7 installed (anon 401 42501) -> section visible', pg.is_visible('#lossSection') and pg.evaluate(AVAIL) == 'yes' and len(P7['calls']) == 1)
    ctx.close()
    P7['mode'] = 'missing'
    b.close()

n_ok = sum(1 for _, ok in results if ok)
print('\nSUMMARY: %d/%d passed' % (n_ok, len(results)))
sys.exit(0 if n_ok == len(results) else 1)
