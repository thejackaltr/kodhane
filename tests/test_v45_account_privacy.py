"""Kodhane v4.5 "Hesap ve bulut kaydı hakkında" (Yazı kodhane-hesap-bilgilendirme-yazi-r18.json): varsayılan KAPALI; kapalıyken DOM'da
görünmez, açıkça açılınca 360x640 / 390x844 / 568x320'de taşmadan sığar. Metinler (12 paragraf, KOSULLU) r18 ile birebir; her bayrak
açık/kapalı, beklenen metin r18'deki "yer" tariflerinden testte bağımsız kurulur (kimliğe göre; sıra numarasına dayanmaz).
Ekran görüntüleri: KODHANE_V45_SHOTS (varsayılan /workspace/kodhane-v45-shots), v45-hesap-bilgi-<durum>-<görünüm>.png
    python3 tests/test_v45_account_privacy.py
"""
import json
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
results = []
MEAS = {}


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


def supabase(route):
    cors = {'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*', 'content-type': 'application/json'}
    if route.request.method == 'OPTIONS':
        return route.fulfill(status=204, headers=cors, body='')
    route.fulfill(status=200, headers=cors, body='[]')


NODES12 = ['kod_1', 'kod_2', 'kod_3', 'ekip_1', 'ekip_2', 'ekip_3', 'musteri_1', 'musteri_2', 'musteri_3', 'yatirim_1', 'yatirim_2', 'yatirim_3']
GENS = ['stajyer', 'junior', 'senior', 'tasarimci', 'pm', 'ai', 'sunucu', 'ofis', 'veri', 'arge', 'cip', 'yzlab', 'mars']


def save(**kw):
    d = {'version': 6, 'saveVersion': 6, 'money': 5e21, 'runEarned': 2e21, 'totalEarned': 3e21, 'cycleEarned': 2e21,
         'clicks': 10, 'clickEarned': 10, 'playTime': 9000, 'startedAt': 0, 'lastSaved': 0,
         'gens': {'stajyer': 160, 'junior': 120, 'senior': 40}, 'upgrades': [], 'shares': 1200, 'prestigeCount': 9, 'cycleRounds': 10,
         'stage': 7, 'stageBest': 7, 'cycleStage': 7, 'stageId': 'asama_1e21', 'stageBestId': 'asama_1e21', 'cycleStageId': 'asama_1e21',
         'achievements': [], 'reputation': 150, 'tree': NODES12[:11], 'ipoShares': 9, 'ipoSharesEarned': 60, 'ipoCount': 5, 'ipoAt': 0,
         'newsSeen': ['yeni_asama', 'siralama', 'acik_ofis'], 'newsPending': []}
    d.update(kw)
    return d


R18 = '/workspace/plans/kodhane-hesap-bilgilendirme-yazi-r18.json'
VP = {'360x640': dict(viewport={'width': 360, 'height': 640}, is_mobile=True, has_touch=True),
      '390x844': dict(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True, device_scale_factor=2),
      '568x320': dict(viewport={'width': 568, 'height': 320}, is_mobile=True, has_touch=True)}
R = json.load(open(R18, encoding='utf-8'))
DET, IDS, KOS = R['ACC_TEXT']['account.privacyDetails'], R['_paragraflar'], R['KOSULLU']
FLAGS = ['loginLog12m', 'resetBackup30d', 'earningsLog', 'progressLog12m', 'progressLogDelete', 'deletionList', 'deletionList45d', 'sharedWithAcikOfis']
DEFAULT = {'enabled': False, 'loginLog12m': False, 'resetBackup30d': False, 'earningsLog': False, 'progressLog12m': False,
           'progressLogDelete': False, 'deletionList': False, 'deletionList45d': False, 'sharedWithAcikOfis': True}
ACIK = 'Bu hesap Açık Ofis oyunuyla ortaktır, orada da aynı hesapla giriş yaparsın.'
GATE = {'kazanç kaydı': 'earningsLog', 'silme listesi': 'deletionList'}
def kflag(k):   # r18 "kod": "PRIVACY.x" ya da "öneri: PRIVACY.x"
    return k['kod'].split('PRIVACY.')[1]

def expected(f):
    """r18'in "yer" tariflerinden beklenen paragraflar [(kimlik, metin)]."""
    items = [[i, t] for i, t in zip(IDS, DET)]
    if not f['sharedWithAcikOfis']:
        for it in items:
            if it[0] == '[0]': it[1] = it[1].replace(' ' + ACIK, '')
    for k in KOS:
        if not f[kflag(k)]: continue
        if k['tur'] == 'paragraf':
            prev = re.match(r'(\[\d+\]) ile', k['yer']).group(1)
            at = [x[0] for x in items].index(prev)
            items.insert(at + 1, [k['kimlik'], k['metin']]); continue
        target = k['kimlik'].split('.')[0]
        q = re.search('“(.*?)”', k['yer'])
        for it in items:
            if it[0] != target: continue
            if q:
                a = q.group(1).lstrip('…')
                pos = it[1].index(a) + len(a)
                it[1] = it[1][:pos] + ' ' + k['metin'] + it[1][pos:]
            else:   # "paragrafının sonu"
                it[1] = it[1] + ' ' + k['metin']
    return [(i, t) for i, t in items if i not in GATE or f[GATE[i]]]

OVERFLOW = """([sel, W]) => {
  const bad = [];
  for (const root of document.querySelectorAll(sel)) for (const el of [root, ...root.querySelectorAll('*')]) {
    if (el.offsetParent === null && getComputedStyle(el).position !== 'fixed') continue;
    if (el.closest('.sr-only')) continue;
    const r = el.getBoundingClientRect(); if (!r.width && !r.height) continue;
    const cs = getComputedStyle(el);
    if ((el.scrollWidth > el.clientWidth + 1 && el.clientWidth > 0 && el.children.length === 0 && cs.textOverflow !== 'ellipsis') || r.right > W + 0.5 || r.left < -0.5) bad.push(el.id || el.className || el.tagName);
  }
  return { n: bad.length, bad: bad.slice(0, 8), doc: document.documentElement.scrollWidth };
}"""
SIGN_IN = """() => { Kodhane.cloud.state.user = { id: '11111111-2222-4333-8444-555555555555', email: 'oyuncu@ornek.com' };
  Kodhane.cloud.state.status = 'saved'; Kodhane.cloud.open(); Kodhane.onCloudRender && Kodhane.onCloudRender(); }"""


with sync_playwright() as p:
    b = p.chromium.launch(args=['--host-resolver-rules=' + SAFETY])

    def new_page(vp):
        ctx = b.new_context(locale='tr-TR', service_workers='block', timezone_id='Europe/Istanbul', **VP[vp])
        ctx.add_init_script('window.KODHANE_QUIET = true;')
        ctx.add_init_script("(() => { if (sessionStorage.getItem('kh_seeded')) return; sessionStorage.setItem('kh_seeded','1');"
                            "localStorage.setItem('kodhane_tel_notice', '1'); localStorage.setItem('kodhane_tel', 'off');"
                            "localStorage.setItem(%s, %s); })();" % (json.dumps(SAVE_KEY), json.dumps(json.dumps(save()))))
        ctx.route(re.compile(r'^https?://(?!kodhane\.teserix\.com/|analiz\.teserix\.com/|kodhane-api\.teserix\.com/|supabase\.teserix\.com/).*'), lambda r: r.abort('blockedbyclient'))
        ctx.route('https://kodhane.teserix.com/**', file_route(ROOT))
        ctx.route('https://analiz.teserix.com/**', lambda r: r.fulfill(status=404, body=''))
        ctx.route('https://kodhane-api.teserix.com/**', supabase)
        ctx.route('https://supabase.teserix.com/**', supabase)
        pg = ctx.new_page()
        errs = []
        pg.on('pageerror', lambda e: errs.append(str(e)))
        pg.goto(BASE)
        pg.wait_for_selector('#clickBtn')
        pg.wait_for_timeout(400)
        pg.evaluate("document.querySelectorAll('#modal:not(.hidden) .ghost, #modal:not(.hidden) .primary').forEach(b => b.click()); Kodhane.hideStageUp && Kodhane.hideStageUp()")
        return ctx, pg, errs

    def shot(pg, name, vp):
        pg.wait_for_timeout(200)
        pg.evaluate("document.querySelectorAll('#toast > *').forEach((t) => t.remove())")
        pg.screenshot(path=os.path.join(SHOTS, 'v45-hesap-bilgi-%s-%s.png' % (name, vp)))

    TITLE = 'Hesap ve bulut kaydı hakkında'
    SET = "(f) => { Object.assign(Kodhane.cloud.PRIVACY, f); Kodhane.cloud.renderPrivacy(); return Kodhane.cloud.privacyItems().map((it) => [it.id, it.text]); }"
    # ---- metin ve tablo (r18 birebir)
    ctx, pg, errs = new_page('360x640')
    ev = pg.evaluate
    A = ev('Kodhane.cloud.ACC_TEXT')
    check('account.privacyDetails = r18 verbatim, 12 paragraphs (0 diff)', A['account.privacyDetails'] == DET and len(DET) == 12,
          [i for i in range(max(len(DET), len(A['account.privacyDetails']))) if i >= len(DET) or i >= len(A['account.privacyDetails']) or DET[i] != A['account.privacyDetails'][i]])
    check('privacyLink / privacyTitle / privacySummary = r18 verbatim', all(A[k] == R['ACC_TEXT'][k] for k in ('account.privacyLink', 'account.privacyTitle', 'account.privacySummary')) and A['account.privacyLink'] == TITLE)
    check('ACC_TEXT has exactly the r18 keys', sorted(A.keys()) == sorted(R['ACC_TEXT'].keys()), sorted(A.keys()))
    check('PRIVACY_IDS = r18 _paragraflar (same order)', ev('Kodhane.cloud.PRIVACY_IDS') == IDS)
    CK = {k['id']: k for k in ev('Kodhane.cloud.PRIVACY_KOSULLU')}
    check('PRIVACY_KOSULLU: same 5 ids as r18 KOSULLU, text verbatim', sorted(CK) == sorted(k['kimlik'] for k in KOS) and all(CK[k['kimlik']]['text'] == k['metin'] for k in KOS), sorted(CK))
    check('PRIVACY_KOSULLU flags = r18 "kod" (PRIVACY.loginLog12m, resetBackup30d; öneri: progressLog12m, progressLogDelete, deletionList45d)', all(CK[k['kimlik']]['flag'] == kflag(k) for k in KOS), {k: v['flag'] for k, v in CK.items()})
    check('default PRIVACY: enabled false, all conditionals false, sharedWithAcikOfis true', ev('Kodhane.cloud.PRIVACY') == DEFAULT, ev('Kodhane.cloud.PRIVACY'))
    ph = [(IDS[i], m) for i, t in enumerate(A['account.privacyDetails']) for m in re.findall(r'\[[^\]]*[A-ZÇĞİÖŞÜ]{3}[^\]]*\]', t)]
    check('remaining placeholders only in [4], [5] (x2), [7]; no whole-paragraph placeholder', [x[0] for x in ph] == ['[4]', '[5]', '[5]', '[7]']
          and not any(t.startswith('[account.') for t in A['account.privacyDetails']), ph)
    SRC = open(os.path.join(ROOT, 'cloud.js'), encoding='utf-8').read()
    check('no "METIN BEKLENIYOR" and no "i === 8" index filter left in cloud.js', 'METIN BEKLENIYOR' not in SRC and 'i === 8' not in SRC)
    check('KOSULLU-only phrases ("12 ay", "30 gün", "45 gün") not in the base text', not any(w in t for t in DET for w in ('12 ay', '30 gün', '45 gün')))

    # ---- bayraklar: varsayılan, her biri tek başına açık/kapalı, hepsi açık
    base = expected(DEFAULT)
    got = ev(SET, {})
    check('flags default: 10 paragraphs ([0] with Açık Ofis, no 12 ay; earnings + deletion list hidden), verbatim', [tuple(x) for x in got] == base and len(base) == 10
          and [x[0] for x in base] == ['[0]', '[1]', '[2]', '[3]', '[4]', '[5]', '[6]', '[7]', '[9]', 'veri sorumlusu'], [x[0] for x in got])
    def only_changed(a, b):   # paragraf kimlikleri ve metinleri arasındaki fark
        da, db = dict(a), dict(b)
        return sorted(set(k for k in set(da) | set(db) if da.get(k) != db.get(k)))
    CHANGE = {'loginLog12m': ['[0]'], 'resetBackup30d': ['[8]'], 'earningsLog': ['kazanç kaydı'], 'progressLog12m': ['kazanç kaydı'],
              'progressLogDelete': ['kazanç kaydı'], 'deletionList': ['silme listesi'], 'deletionList45d': ['silme listesi'], 'sharedWithAcikOfis': ['[0]']}
    NEED = {'progressLog12m': 'earningsLog', 'progressLogDelete': 'earningsLog', 'deletionList45d': 'deletionList'}
    for fl in FLAGS:
        for val in (True, False):
            f = dict(DEFAULT); f[fl] = val
            if fl in NEED: f[NEED[fl]] = True
            ref = dict(DEFAULT)
            if fl in NEED: ref[NEED[fl]] = True
            ref[fl] = not val
            got = [tuple(x) for x in ev(SET, {k: f[k] for k in FLAGS})]
            exp = expected(f)
            ch = only_changed(expected(ref), exp)
            check('flag %s=%s%s: paragraphs verbatim, only %s changes vs. opposite' % (fl, val, (' (+%s)' % NEED[fl]) if fl in NEED else '', CHANGE[fl]),
                  got == exp and ch == CHANGE[fl], {'ids': [x[0] for x in got], 'changed': ch})
    for fl in ('progressLog12m', 'progressLogDelete', 'deletionList45d'):
        f = dict(DEFAULT); f[fl] = True
        got = [tuple(x) for x in ev(SET, {k: f[k] for k in FLAGS})]
        check('flag %s alone (parent paragraph off): nothing shown for it' % fl, got == base)
    ALL = {k: True for k in FLAGS}
    got_all = [tuple(x) for x in ev(SET, ALL)]
    exp_all = expected(dict(DEFAULT, **ALL))
    check('all flags on: 13 paragraphs, [8] between [7] and kazanç kaydı, verbatim', got_all == exp_all and [x[0] for x in got_all] == ['[0]', '[1]', '[2]', '[3]', '[4]', '[5]', '[6]', '[7]', '[8]', 'kazanç kaydı', '[9]', 'silme listesi', 'veri sorumlusu'], [x[0] for x in got_all])
    t0 = dict(got_all)['[0]']
    check('all on: [0] = "…kaydedilir. Bu giriş kayıtları 12 ay sonra silinir. Bu hesap Açık Ofis…" (12 ay before Açık Ofis)', 'kaydedilir. Bu giriş kayıtları 12 ay sonra silinir. ' + ACIK in t0)
    tk = dict(got_all)['kazanç kaydı']
    check('all on: earnings paragraph has C4 after "…geri vermek için kullanırız." and C6+C7 at the end', 'geri vermek için kullanırız. Kayıtlar 12 ay saklanır. Kaydını sıfırlaman' in tk and tk.endswith('silmez. ' + [k for k in KOS if k['kimlik'] == 'kazanç kaydı.C6+C7'][0]['metin']))
    check('all on: deletion list ends with the 45-day sentence', dict(got_all)['silme listesi'].endswith('kullanılır. Listedeki bu bilgiler 45 gün sonra silinir; listenin kopyalarında bir süre daha kalabilir.'))
    check('resetBackup30d on, earningsLog off: [8] after [7], [9] next (no index shift hides anything)', [x[0] for x in ev(SET, dict({k: False for k in FLAGS}, resetBackup30d=True, sharedWithAcikOfis=True))] == ['[0]', '[1]', '[2]', '[3]', '[4]', '[5]', '[6]', '[7]', '[8]', '[9]', 'veri sorumlusu'])
    # dizin kayması: ACC_TEXT'e araya paragraf sokulursa (kimlik tablosuyla birlikte) koşullular yine doğru paragrafa bağlanır
    shift = ev("""() => { const c = Kodhane.cloud, d = c.ACC_TEXT['account.privacyDetails'], ids = c.PRIVACY_IDS;
      const sd = d.slice(), si = ids.slice(); d.splice(2, 0, 'ARA PARAGRAF'); ids.splice(2, 0, 'ara');
      Object.assign(c.PRIVACY, { earningsLog: true, deletionList: false, resetBackup30d: true });
      const r = c.privacyItems().map((it) => it.id); d.splice(0, d.length, ...sd); ids.splice(0, ids.length, ...si); return r; }""")
    check('index shift (extra paragraph inserted): earnings still shown, deletion list still hidden, [8] still after [7]', shift == ['[0]', '[1]', 'ara', '[2]', '[3]', '[4]', '[5]', '[6]', '[7]', '[8]', 'kazanç kaydı', '[9]', 'veri sorumlusu'], shift)
    ev(SET, {k: DEFAULT[k] for k in FLAGS})
    check('no page errors (flag matrix)', not errs, errs)
    ctx.close()

    # ---- kapalı (varsayılan): misafir + girişli, DOM'da görünmez
    ctx, pg, errs = new_page('360x640')
    ev = pg.evaluate
    pg.click('#accountBtn'); pg.wait_for_selector('#accountPanel:not(.hidden)'); pg.wait_for_timeout(250)
    off = ev("() => { const l = document.getElementById('accPrivacyLink'), d = document.getElementById('accPrivacyDetails'); return [l.classList.contains('hidden'), l.textContent, l.offsetParent === null, d.classList.contains('hidden'), d.innerHTML, d.offsetParent === null]; }")
    check('OFF, guest: link hidden + empty, panel hidden + empty (not visible in DOM)', off == [True, '', True, True, '', True], off)
    check('OFF, guest: title and paragraph text nowhere in the page', TITLE not in ev('document.body.innerText') and DET[1][:40] not in ev('document.body.innerHTML'))
    ev("document.getElementById('accPrivacyLink').click()"); pg.wait_for_timeout(100)
    check('OFF: clicking the hidden link does nothing (panel stays empty)', ev("document.getElementById('accPrivacyDetails').innerHTML") == '')
    ev('Object.assign(Kodhane.cloud.PRIVACY, {loginLog12m: true, resetBackup30d: true, earningsLog: true, deletionList: true}); Kodhane.cloud.renderPrivacy()')
    check('OFF with all content flags on: still hidden and empty', ev("document.getElementById('accPrivacyLink').offsetParent === null && document.getElementById('accPrivacyDetails').innerHTML === ''"))
    ev(SIGN_IN); pg.wait_for_timeout(250)
    check('OFF, signed in: still hidden, title nowhere', ev("document.getElementById('accPrivacyLink').offsetParent === null && document.getElementById('accPrivacyDetails').innerHTML === ''") and TITLE not in ev('document.body.innerText'))
    check('no page errors (off)', not errs, errs)
    ctx.close()

    # ---- açıkça açık: 3 görünüm; varsayılan bayraklarla ve hepsi açıkken sığma; ekran görüntüleri hepsi açık
    for vp in VP:
        ctx, pg, errs = new_page(vp)
        ev = pg.evaluate
        W = VP[vp]['viewport']['width']
        ev('Kodhane.cloud.PRIVACY.enabled = true; Kodhane.cloud.renderPrivacy()')
        pg.click('#accountBtn'); pg.wait_for_selector('#accountPanel:not(.hidden)'); pg.wait_for_timeout(250)
        check('[%s] ON, guest: link visible "%s", panel closed' % (vp, TITLE), pg.is_visible('#accPrivacyLink') and pg.inner_text('#accPrivacyLink') == TITLE and not pg.is_visible('#accPrivacyDetails'))
        pg.click('#accPrivacyLink'); pg.wait_for_timeout(150)
        dom = ev("[...document.querySelectorAll('#accPrivacyDetails p')].map((p) => [p.dataset.pid, p.textContent])")
        check('[%s] ON, default flags: title + 10 paragraphs in DOM = r18, aria-expanded true' % vp, pg.inner_text('#accPrivacyDetails h4') == TITLE and [tuple(x) for x in dom] == base
              and ev("document.getElementById('accPrivacyLink').getAttribute('aria-expanded')") == 'true', len(dom))
        r = ev(OVERFLOW, ['#accountPanel', W])
        check('[%s] ON, default flags: no horizontal overflow' % vp, r['n'] == 0 and r['doc'] <= W, r)
        ev(SET, ALL); pg.wait_for_timeout(100)
        dom = ev("[...document.querySelectorAll('#accPrivacyDetails p')].map((p) => [p.dataset.pid, p.textContent])")
        check('[%s] ON, all flags: 13 paragraphs in DOM = r18 + KOSULLU' % vp, [tuple(x) for x in dom] == exp_all, len(dom))
        r = ev(OVERFLOW, ['#accountPanel', W])
        check('[%s] ON, all flags: no horizontal overflow' % vp, r['n'] == 0 and r['doc'] <= W, r)
        reach = ev("""() => { const card = document.querySelector('#accountPanel .account-card'); const ps = [...document.querySelectorAll('#accPrivacyDetails p')]; const last = ps[ps.length - 1];
          last.scrollIntoView({ block: 'nearest' }); const r = last.getBoundingClientRect(), C = card.getBoundingClientRect();
          return r.bottom <= Math.min(innerHeight, C.bottom) + 0.5 && r.top >= Math.max(0, C.top) - 0.5; }""")
        check('[%s] ON, all flags: last paragraph reachable by scrolling inside the account card' % vp, reach)
        ev("document.getElementById('accPrivacyDetails').scrollIntoView({block: 'start'})"); shot(pg, 'acik', vp)
        ev("[...document.querySelectorAll('#accPrivacyDetails p')].find((p) => p.dataset.pid === 'kazanç kaydı').scrollIntoView({block: 'start'})"); shot(pg, 'acik-kazanc', vp)
        ev("[...document.querySelectorAll('#accPrivacyDetails p')].pop().scrollIntoView({block: 'end'})"); shot(pg, 'acik-son', vp)
        pg.click('#accPrivacyLink'); pg.wait_for_timeout(100)
        check('[%s] toggle closes the panel' % vp, not pg.is_visible('#accPrivacyDetails') and ev("document.getElementById('accPrivacyLink').getAttribute('aria-expanded')") == 'false')
        ev(SIGN_IN); pg.wait_for_timeout(200)
        pg.click('#accPrivacyLink'); pg.wait_for_timeout(150)
        r = ev(OVERFLOW, ['#accountPanel', W])
        check('[%s] ON, signed in, all flags, open: visible, no overflow' % vp, pg.is_visible('#accPrivacyDetails') and r['n'] == 0, r)
        if vp == '360x640':
            ev('Kodhane.cloud.PRIVACY.enabled = false; Kodhane.cloud.renderPrivacy()')
            check('switching back OFF empties and hides link + panel', not pg.is_visible('#accPrivacyLink') and ev("document.getElementById('accPrivacyDetails').innerHTML") == '')
        check('[%s] no page errors' % vp, not errs, errs)
        ctx.close()
    b.close()

n_ok = sum(1 for _, ok in results if ok)
print('\nSUMMARY: %d/%d passed' % (n_ok, len(results)))
sys.exit(0 if n_ok == len(results) else 1)
