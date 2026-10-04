"""Kodhane v4.5 "Hesap ve bulut kaydı hakkında" (Yazı kodhane-hesap-bilgilendirme-yazi-r20.json / .md): varsayılan KAPALI;
kapalıyken DOM'da görünmez. Yapı { id, flag, segments: [{ flag, text }] }, okuma kuralı r19 (r20'de aynı). Dört birleşim (hepsi kapalı, bugün,
B günü, hepsi açık) md'deki metinle boşluk ve noktalama dahil birebir; her bayrak açık/kapalı; bilinmeyen/eksik bayrak güvenli.
Açıkken 360x640 / 390x844 / 568x320'de yatay taşma ve kesilme yok, kart içinde kaydırma çalışıyor; 360x640'ta satır sayıları.
Ekran görüntüleri: KODHANE_V45_SHOTS (varsayılan /workspace/kodhane-v45-shots)/r20/r20-<birleşim>-<yer>-360x640.png
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


import json, re
R19J = '/workspace/plans/kodhane-hesap-bilgilendirme-yazi-r20.json'
R19M = '/workspace/plans/kodhane-hesap-bilgilendirme-yazi-r20.md'
J = json.load(open(R19J, encoding='utf-8'))
DET = J['ACC_TEXT']['account.privacyDetails']
FLAGS = {k: v['default'] for k, v in J['PRIVACY_FLAGS'].items()}
CONTENT = [k for k in FLAGS if k != 'enabled']
def compose(f):
    on = lambda fl: fl is None or (isinstance(fl, str) and fl in CONTENT and f.get(fl) is True)
    out = []
    for p in DET:
        if not on(p['flag']): continue
        out.append((p['id'], ' '.join(s['text'] for s in p['segments'] if on(s['flag']))))
    return out
def md_combos():
    md = open(R19M, encoding='utf-8').read()
    sec = md[md.index('### Birleşik metinler'):md.index('## Uzunluk (360×640)')]
    parts = re.split(r'^#### (\d)\. (.*)$', sec, flags=re.M)
    res = {}
    for i in range(1, len(parts), 3):
        n, title, body = parts[i], parts[i + 1].strip(), parts[i + 2]
        hdr = re.search(r'Paragraf: (\d+), karakter: (\d+)\.', body)
        paras = re.findall(r'^\*\*(.+?)\*\* (.+)$', body, flags=re.M)
        res[int(n)] = {'title': title, 'paras': paras, 'n': int(hdr.group(1)), 'chars': int(hdr.group(2))}
    return res
COMBOS = {
    1: {k: False for k in CONTENT},
    2: {k: FLAGS[k] for k in CONTENT},
    3: dict({k: FLAGS[k] for k in CONTENT}, earningsLog=True, deletionList=True),
    4: {k: True for k in CONTENT},
}

VP = {'360x640': dict(viewport={'width': 360, 'height': 640}, is_mobile=True, has_touch=True),
      '390x844': dict(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True, device_scale_factor=2),
      '568x320': dict(viewport={'width': 568, 'height': 320}, is_mobile=True, has_touch=True)}
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



NAMES = {1: 'hepsi-kapali', 2: 'bugun', 3: 'b-gunu', 4: 'hepsi-acik'}
MD = md_combos()
C7 = 'Silinen kayıtlar güvenlik yedeklerinde'
LINES = """() => [...document.querySelectorAll('#accPrivacyDetails p')].map((p) => { const cs = getComputedStyle(p), lh = parseFloat(cs.lineHeight);
  return [p.dataset.pid, Math.round(p.getBoundingClientRect().height / lh), p.scrollWidth <= p.clientWidth + 1 && p.scrollHeight <= p.clientHeight + 1, cs.textOverflow, cs.whiteSpace]; })"""

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
    ctx, pg, errs = new_page('360x640')
    ev = pg.evaluate
    A = ev('Kodhane.cloud.ACC_TEXT')
    check('ACC_TEXT = r20 JSON ACC_TEXT (structure + texts verbatim, 13 paragraph objects)', A == J['ACC_TEXT'] and len(A['account.privacyDetails']) == 13)
    check('md "Birleşik metinler" = JSON by the reading rule (4 combinations; paragraph and character counts from md headers)',
          all(compose(COMBOS[n]) == MD[n]['paras'] and len(MD[n]['paras']) == MD[n]['n'] and sum(len(t) for _, t in MD[n]['paras']) == MD[n]['chars'] for n in (1, 2, 3, 4)))
    check('PRIVACY defaults = r20 PRIVACY_FLAGS defaults (enabled false, sharedWithAcikOfis true, others false)', ev('Kodhane.cloud.PRIVACY') == FLAGS, ev('Kodhane.cloud.PRIVACY'))
    used = sorted({p['flag'] for p in DET if p['flag']} | {s['flag'] for p in DET for s in p['segments'] if s['flag']})
    check('flag names: PRIVACY keys = enabled + every flag used in r20 JSON (no earningsLog12m / earningsLogDelete)', sorted(ev('Object.keys(Kodhane.cloud.PRIVACY)')) == sorted(used + ['enabled'])
          and sorted(ev('Kodhane.cloud.PRIVACY_CONTENT_FLAGS')) == used and 'earningsLog12m' not in used and 'earningsLogDelete' not in used, used)
    SRC = open(os.path.join(ROOT, 'cloud.js'), encoding='utf-8').read()
    check('old flat-array machinery removed (PRIVACY_IDS, PRIVACY_KOSULLU, PRIVACY_OPTIONAL, PRIVACY_GATE, index filters)', not any(w in SRC for w in ('PRIVACY_IDS', 'PRIVACY_KOSULLU', 'PRIVACY_OPTIONAL', 'PRIVACY_GATE', 'i === 8', 'i === 0 &&')))
    ph = re.findall(r'\[[^\]]*— [^\]]*\]', ' '.join(s['text'] for p in A['account.privacyDetails'] for s in p['segments']))
    check('placeholders stay open: [4] x1, [5] x2, [7] x1', ph == ['[TEKNİK KAYIT SAKLAMA SÜRESİ — avukat belirleyecek]', '[GÖNDERİM BÖLGESİ — Yazılım teyit edecek]', '[YURT DIŞI AKTARIM DAYANAĞI — Aryen/avukat belirleyecek]', '[SAKLAMA SÜRESİ — Aryen belirleyecek]'], ph)
    for n in (1, 2, 3, 4):
        got = [tuple(x) for x in ev(SET, COMBOS[n])]
        diff = [(i, a, b) for i, (a, b) in enumerate(zip(got, MD[n]['paras'])) if a != b]
        check('combination %d "%s": %d paragraphs = md text byte for byte (spaces, punctuation)' % (n, MD[n]['title'], MD[n]['n']), got == MD[n]['paras'], diff[:1] or (len(got), MD[n]['n']))
    check('progressLogDelete adds only C6; C7 never in the panel (any combination)', all(C7 not in t for n in (1, 2, 3, 4) for _, t in ev(SET, COMBOS[n]))
          and dict(ev(SET, COMBOS[4]))['kazanç kaydı'].endswith('Kaydını sıfırlaman bu kayıtları silmez. Hesabın ya da Kodhane kaydın silinirse bu kayıtlar da silinir.'))
    # her bayrak tek başına açık / kapalı (bugünkü hâlden), yalnız kendi paragrafı değişir; parça bayrakları paragraf kapalıyken etkisiz
    TARGET = {'sharedWithAcikOfis': '[0]', 'loginLog12m': '[0]', 'resetBackup30d': '[8]', 'earningsLog': 'kazanç kaydı', 'progressLog12m': 'kazanç kaydı',
              'progressLogDelete': 'kazanç kaydı', 'deletionList': 'silme listesi', 'deletionList45d': 'silme listesi'}
    PARENT = {'progressLog12m': 'earningsLog', 'progressLogDelete': 'earningsLog', 'deletionList45d': 'deletionList'}
    def changed(a, b):
        da, db = dict(a), dict(b)
        return sorted(k for k in set(da) | set(db) if da.get(k) != db.get(k))
    for fl in CONTENT:
        for val in (True, False):
            f = dict(COMBOS[2]); f[fl] = val
            if fl in PARENT: f[PARENT[fl]] = True
            opp = dict(f); opp[fl] = not val
            got = [tuple(x) for x in ev(SET, f)]
            check('flag %s=%s%s: verbatim by rule, only %s changes' % (fl, val, ' (+%s)' % PARENT[fl] if fl in PARENT else '', TARGET[fl]),
                  got == compose(f) and changed(compose(opp), got) == [TARGET[fl]], [x[0] for x in got])
    for fl, par in PARENT.items():
        f = dict(COMBOS[2]); f[fl] = True
        check('segment flag %s without its paragraph flag %s: no effect' % (fl, par), [tuple(x) for x in ev(SET, f)] == compose(COMBOS[2]))
    ev(SET, COMBOS[2])
    # güvenli davranış: bilinmeyen / eksik / bozuk
    SAFE = """(cases) => { const c = Kodhane.cloud, d = c.ACC_TEXT['account.privacyDetails'], keep = d.slice(), out = {};
      for (const [name, items] of Object.entries(cases)) {
        d.splice(0, d.length, ...keep, ...items);
        try { out[name] = c.privacyItems().map((it) => [it.id, it.text]); c.PRIVACY.enabled = true; c.renderPrivacy(); }
        catch (e) { out[name] = 'THROW ' + e.message; }
        c.PRIVACY.enabled = false; c.renderPrivacy();
      }
      d.splice(0, d.length, ...keep); return out; }"""
    P = lambda **kw: dict({'id': 'x', 'flag': None, 'segments': [{'flag': None, 'text': 'EK METIN.'}]}, **kw)
    cases = {
        'p-unknown-flag': [P(flag='yokBoyleBayrak')], 'p-missing-flag': [{'id': 'x', 'segments': [{'flag': None, 'text': 'EK METIN.'}]}],
        'p-flag-number': [P(flag=1)], 'p-flag-true': [P(flag=True)], 'p-flag-enabled': [P(flag='enabled')],
        'p-proto-names': [P(flag='__proto__'), P(flag='toString'), P(flag='hasOwnProperty'), P(flag='constructor')],
        'p-no-id': [{'flag': None, 'segments': [{'flag': None, 'text': 'EK METIN.'}]}], 'p-empty-id': [P(id='')],
        'p-segments-missing': [{'id': 'x', 'flag': None}], 'p-segments-not-array': [P(segments='EK METIN.')], 'p-null': [None], 'p-string': ['EK METIN.'],
        's-unknown-flag': [P(segments=[{'flag': 'yokBoyleBayrak', 'text': 'EK METIN.'}])], 's-missing-flag': [P(segments=[{'text': 'EK METIN.'}])],
        's-text-not-string': [P(segments=[{'flag': None, 'text': 5}, {'flag': None}, None, 'EK METIN.'])],
        's-mixed': [P(segments=[{'flag': None, 'text': 'A.'}, {'flag': 'yok', 'text': 'GIZLI.'}, {'text': 'GIZLI2.'}, {'flag': None, 'text': 'B.'}])],
    }
    res = ev(SAFE, cases)
    base = [list(x) for x in compose(COMBOS[2])]
    for name in cases:
        exp = base + ([['x', 'A. B.']] if name == 's-mixed' else [])
        check('safe: %s -> not shown (no crash), rest unchanged' % name, res[name] == exp, res[name] if not isinstance(res[name], list) else res[name][len(base):])
    res2 = ev("""() => { const c = Kodhane.cloud, d = c.ACC_TEXT['account.privacyDetails'], keep = d.slice();
      d.splice(0, d.length, ...keep.slice().reverse()); const r = c.privacyItems().map((it) => it.id); d.splice(0, d.length, ...keep); return r; }""")
    check('order = array order; filtering by id/flag, not index (reversed array -> reversed output, same set)', res2 == [x[0] for x in reversed(compose(COMBOS[2]))], res2)
    check('no page errors (flag matrix + safety)', not errs, errs)
    ctx.close()

    # ---- kapalı (varsayılan): misafir + girişli, DOM'da görünmez
    ctx, pg, errs = new_page('360x640')
    ev = pg.evaluate
    pg.click('#accountBtn'); pg.wait_for_selector('#accountPanel:not(.hidden)'); pg.wait_for_timeout(250)
    off = ev("() => { const l = document.getElementById('accPrivacyLink'), d = document.getElementById('accPrivacyDetails'); return [l.classList.contains('hidden'), l.textContent, l.offsetParent === null, d.classList.contains('hidden'), d.innerHTML, d.offsetParent === null]; }")
    check('OFF, guest: link hidden + empty, panel hidden + empty (not visible in DOM)', off == [True, '', True, True, '', True], off)
    check('OFF: title and paragraph text nowhere in the page', TITLE not in ev('document.body.innerText') and DET[1]['segments'][0]['text'][:40] not in ev('document.body.innerHTML'))
    ev("document.getElementById('accPrivacyLink').click()"); pg.wait_for_timeout(100)
    check('OFF: clicking the hidden link does nothing', ev("document.getElementById('accPrivacyDetails').innerHTML") == '')
    ev(SET, COMBOS[4])
    check('OFF with all content flags on: still hidden and empty', ev("document.getElementById('accPrivacyLink').offsetParent === null && document.getElementById('accPrivacyDetails').innerHTML === ''"))
    ev(SIGN_IN); pg.wait_for_timeout(250)
    check('OFF, signed in: still hidden, title nowhere', ev("document.getElementById('accPrivacyDetails').innerHTML === ''") and TITLE not in ev('document.body.innerText'))
    check('no page errors (off)', not errs, errs)
    ctx.close()

    # ---- açık: 3 görünüm x 4 birleşim; taşma, kesilme, kaydırma; 360x640 satır sayısı ve ekran görüntüleri
    R19SHOTS = os.path.join(SHOTS, 'r20'); os.makedirs(R19SHOTS, exist_ok=True)
    MEASURE = {}
    for vp in VP:
        ctx, pg, errs = new_page(vp)
        ev = pg.evaluate
        W = VP[vp]['viewport']['width']
        ev('Kodhane.cloud.PRIVACY.enabled = true; Kodhane.cloud.renderPrivacy()')
        pg.click('#accountBtn'); pg.wait_for_selector('#accountPanel:not(.hidden)'); pg.wait_for_timeout(250)
        check('[%s] ON: link visible "%s", panel closed until clicked' % (vp, TITLE), pg.is_visible('#accPrivacyLink') and pg.inner_text('#accPrivacyLink') == TITLE and not pg.is_visible('#accPrivacyDetails'))
        pg.click('#accPrivacyLink'); pg.wait_for_timeout(150)
        for n in (1, 2, 3, 4):
            ev(SET, COMBOS[n]); pg.wait_for_timeout(80)
            dom = [tuple(x) for x in ev("[...document.querySelectorAll('#accPrivacyDetails p')].map((p) => [p.dataset.pid, p.textContent])")]
            r = ev(OVERFLOW, ['#accountPanel', W])
            ln = ev(LINES)
            clip = [x[0] for x in ln if not x[2] or x[3] == 'ellipsis' or x[4] == 'nowrap']
            scroll = ev("""() => { const card = document.querySelector('#accountPanel .account-card'); card.scrollTop = 0;
              const ps = [...document.querySelectorAll('#accPrivacyDetails p')], last = ps[ps.length - 1]; const t0 = card.scrollTop;
              last.scrollIntoView({ block: 'end' }); const r = last.getBoundingClientRect(), C = card.getBoundingClientRect();
              return { scrollable: card.scrollHeight > card.clientHeight, moved: card.scrollTop > t0, lastVisible: r.bottom <= Math.min(innerHeight, C.bottom) + 1 && r.top >= C.top - 1, panelH: Math.round(document.getElementById('accPrivacyDetails').getBoundingClientRect().height), cardH: Math.round(C.height) }; }""")
            ok = dom == MD[n]['paras'] and r['n'] == 0 and r['doc'] <= W and not clip and scroll['scrollable'] and scroll['moved'] and scroll['lastVisible']
            check('[%s] %s: DOM = md, no horizontal overflow, no clipped paragraph, card scrolls to the last paragraph' % (vp, NAMES[n]), ok, {'dom': dom == MD[n]['paras'], 'ov': r, 'clip': clip, 'scroll': scroll})
            if vp == '360x640':
                MEASURE[NAMES[n]] = {'lines': {x[0]: x[1] for x in ln}, 'total': sum(x[1] for x in ln), 'panelH': scroll['panelH'], 'cardH': scroll['cardH']}
                ev("document.querySelector('#accountPanel .account-card').scrollTop = 0; document.getElementById('accPrivacyDetails').scrollIntoView({block: 'start'})")
                pg.wait_for_timeout(150); pg.evaluate("document.querySelectorAll('#toast > *').forEach((t) => t.remove())")
                pg.screenshot(path=os.path.join(R19SHOTS, 'r20-%s-bas-360x640.png' % NAMES[n]))
                if n >= 3:
                    ev("[...document.querySelectorAll('#accPrivacyDetails p')].find((p) => p.dataset.pid === 'kazanç kaydı').scrollIntoView({block: 'start'})"); pg.wait_for_timeout(120)
                    pg.screenshot(path=os.path.join(R19SHOTS, 'r20-%s-kazanc-360x640.png' % NAMES[n]))
                ev("[...document.querySelectorAll('#accPrivacyDetails p')].pop().scrollIntoView({block: 'end'})"); pg.wait_for_timeout(120)
                pg.screenshot(path=os.path.join(R19SHOTS, 'r20-%s-son-360x640.png' % NAMES[n]))
        ev(SIGN_IN); pg.wait_for_timeout(200)
        if not pg.is_visible('#accPrivacyDetails'): pg.click('#accPrivacyLink'); pg.wait_for_timeout(150)
        r = ev(OVERFLOW, ['#accountPanel', W])
        check('[%s] ON, signed in, all flags: visible, no overflow' % vp, pg.is_visible('#accPrivacyDetails') and r['n'] == 0, r)
        check('[%s] no page errors' % vp, not errs, errs)
        ctx.close()
    b.close()
    json.dump(MEASURE, open(os.path.join(R19SHOTS, 'olcum-360x640.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    tot = {k: v['total'] for k, v in MEASURE.items()}
    print('360x640 satır: %s' % tot)
    check('360x640 line totals = Yazı r20 (hepsi kapalı 75, bugün 77, B günü 100, hepsi açık 109)', tot == {'hepsi-kapali': 75, 'bugun': 77, 'b-gunu': 100, 'hepsi-acik': 109}, tot)

n_ok = sum(1 for _, ok in results if ok)
print('\nSUMMARY: %d/%d passed' % (n_ok, len(results)))
sys.exit(0 if n_ok == len(results) else 1)
