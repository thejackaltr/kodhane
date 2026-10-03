"""Kodhane v4.4.2 arayüz testi: Hesap kartı kendi içinde kayar (alt kısmına ulaşılır), yatay taşma yok.

4.4.1'de (6358db4) 568x320'de misafir Hesap kartı görünümden uzundu ve alt kısmı (kayıt notu) ulaşılamıyordu.
v4.4.2: .modal-card.account-card { max-height: 100%; overflow-y: auto; overscroll-behavior: contain; } (tel-card ile aynı).
360x640 ve 568x320'de, misafir ve girişli (girişli görünüm DOM ile: #accGuest gizli, #accUser açık, uzun e-posta) Hesap kartı:
  - yatay taşma 0 (MEASURE = test_v441_ui.py / test_v443_ui.py ile aynı ölçüm),
  - kart görünümün içinde (üst >= 0, alt <= yükseklik); içerik uzunsa kart kendi içinde kayar (overflow-y auto/scroll),
  - kart sonuna kaydırınca son öğe (kayıt notu) kartın görünen alanında ve görünümün içinde; kartın tüm düğmeleri ulaşılabilir ve en üstte.
Ekran görüntüleri: KODHANE_V442_SHOTS (varsayılan /workspace/kodhane-v44-audit), adlar v442-<etiket>-<görünüm>-<durum>-<üst|son>.png;
etiket KODHANE_V442_TAG (varsayılan "sonra"; düzeltme öncesi kod için KODHANE_ROOT=<eski kopya> KODHANE_V442_TAG=oncesi).
Ağ yok: oyun Playwright route ile depo dosyalarından, Supabase/Umami sahte; gerçek adlar --host-resolver-rules ile kapalı porta yönlenir.
    python3 tests/test_v442_ui.py
"""
import json
import mimetypes
import os
import re
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

from playwright.sync_api import sync_playwright


ROOT = os.environ.get('KODHANE_ROOT') or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.environ.get('KODHANE_V442_SHOTS', '/workspace/kodhane-v44-audit')
TAG = os.environ.get('KODHANE_V442_TAG', 'sonra')
BASE = 'https://kodhane.teserix.com/'
SAVE_KEY = 'kodhane_ajans_save_v2'
SAFETY = ('MAP analiz.teserix.com 127.0.0.1:9, MAP kodhane-api.teserix.com 127.0.0.1:9, MAP supabase.teserix.com 127.0.0.1:9, '
          'MAP kodhane.teserix.com 127.0.0.1:9, MAP thejackaltr.github.io 127.0.0.1:9, MAP cdn.jsdelivr.net 127.0.0.1:9, '
          'MAP acikofis.teserix.com 127.0.0.1:9, MAP *.supabase.co 127.0.0.1:9')
LB_ROWS = []
ELLIPSIS = ()
results = []
measures = {}
LONG_EMAIL = 'cok.uzun.bir.eposta.adresi.2026@ornek-alanadi-uzun.com.tr'


def check(name, cond, info=''):
    results.append((name, bool(cond), info))
    print(('PASS' if cond else 'FAIL'), name, info if not cond or os.environ.get('VERBOSE') else '')


def note(msg):
    print('     ' + msg)


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
    path = urlsplit(route.request.url).path
    if path.endswith('/rpc/kodhane_leaderboard_v7') or path.endswith('/rpc/kodhane_leaderboard'):
        return route.fulfill(status=200, headers=cors, body=json.dumps(LB_ROWS))
    route.fulfill(status=200, headers=cors, body='null' if path.endswith('kodhane_count_event') else '[]')



def save():
    return {'version': 5, 'saveVersion': 5, 'money': 1.5e12, 'runEarned': 2e12, 'totalEarned': 5e13, 'cycleEarned': 2e12,
            'clicks': 10, 'clickEarned': 10, 'playTime': 9000, 'startedAt': 0, 'lastSaved': 0, 'gens': {'stajyer': 50},
            'upgrades': [], 'shares': 1200, 'prestigeCount': 4, 'cycleRounds': 1, 'stage': 5, 'stageBest': 5, 'cycleStage': 5,
            'stageId': 'global_holding', 'stageBestId': 'global_holding', 'cycleStageId': 'global_holding', 'achievements': [], 'reputation': 20,
            'tree': [], 'ipoShares': 0, 'ipoSharesEarned': 0, 'ipoCount': 0, 'ipoAt': 0, 'newsSeen': ['yeni_asama', 'siralama', 'acik_ofis'], 'newsPending': []}


VP = {
    '360x640': dict(viewport={'width': 360, 'height': 640}, is_mobile=True, has_touch=True),
    '568x320': dict(viewport={'width': 568, 'height': 320}, is_mobile=True, has_touch=True),
}

# Her görünür öğe: sağ/sol kenar ekran dışında mı, kesen kapsayıcı (overflow != visible) içinde scrollWidth > clientWidth mı,
# yaprak metin öğesinde scrollWidth > clientWidth mı. Hedef öğelerin scrollWidth / clientWidth değerleri ayrıca döner.
MEASURE = """([sel, targets, VW]) => {
  // W = tasarlanan görünüm genişliği (mobilde taşan içerik innerWidth'i büyütür; o yüzden innerWidth değil)
  const W = VW, out = [], tg = [], wide = [];
  const doc = document.documentElement.scrollWidth;
  for (const root of document.querySelectorAll(sel)) {
    if (root.offsetParent === null && getComputedStyle(root).position !== 'fixed') continue;
    for (const el of [root, ...root.querySelectorAll('*')]) {
      if (el.offsetParent === null && getComputedStyle(el).position !== 'fixed') continue;
      if (el.closest('.tabs')) continue;   // sekme çubuğu tasarım gereği yatay kaydırılır
      if (el.classList.contains('sr-only')) continue;   // görünmez ekran okuyucu etiketi (1 px kırpılmış, tasarım gereği)
      const r = el.getBoundingClientRect();
      if (r.width === 0 && r.height === 0) continue;
      const cs = getComputedStyle(el);
      // tasarım gereği "…" ile kısalan metin (text-overflow: ellipsis, ör. sıralamadaki takma ad) taşma sayılmaz; genişliği ayrıca raporlanır
      const ell = cs.textOverflow === 'ellipsis' && cs.overflowX === 'hidden';
      const clip = !ell && el.scrollWidth > el.clientWidth + 1 && el.clientWidth > 0 && cs.overflowX !== 'visible' ? 'scroll' : null;
      const self = !ell && el.scrollWidth > el.clientWidth + 1 && el.clientWidth > 0 && el.children.length === 0 ? 'text' : null;
      if (r.right > W + 0.5 || r.left < -0.5 || clip || self)
        out.push({ el: el.id || el.className || el.tagName, r: [Math.round(r.left), Math.round(r.right)], sw: el.scrollWidth, cw: el.clientWidth, why: clip || self || 'offscreen', t: (el.innerText || '').slice(0, 40) });
    }
  }
  for (const t of targets) for (const el of document.querySelectorAll(t)) {
    if (el.offsetParent === null && getComputedStyle(el).position !== 'fixed') continue;
    const r = el.getBoundingClientRect();
    tg.push({ sel: t, sw: el.scrollWidth, cw: el.clientWidth, right: Math.round(r.right), text: (el.innerText || el.textContent || '').trim().slice(0, 60) });
  }
  // sayfanın tamamında görünüm genişliğini aşan en derin öğeler (taşmanın kaynağı)
  for (const el of document.body.querySelectorAll('*')) {
    if (el.offsetParent === null && getComputedStyle(el).position !== 'fixed') continue;
    if (el.closest('.tabs')) continue;
    const r = el.getBoundingClientRect();
    if (r.right > W + 0.5 && ![...el.children].some((c) => c.getBoundingClientRect().right > W + 0.5)) wide.push({ el: el.id || el.className || el.tagName, right: Math.round(r.right), t: (el.innerText || '').slice(0, 30) });
  }
  return { doc, W, iw: innerWidth, bad: out.slice(0, 12), n: out.length, targets: tg.slice(0, 12), wide: wide.slice(0, 8), nw: wide.length };
}"""


# Hesap kartı: konum, kayma, son öğe ve düğmelerin ulaşılabilirliği
CARD = """() => {
  const card = document.querySelector('#accountPanel .account-card');
  const C = card.getBoundingClientRect(), cs = getComputedStyle(card);
  const kids = [...card.querySelectorAll('*')].filter((e) => e.offsetParent !== null && e.children.length === 0 && (e.textContent || '').trim());
  const last = kids[kids.length - 1], L = last.getBoundingClientRect();
  return { cardSH: card.scrollHeight, cardCH: card.clientHeight, cardTop: Math.round(C.top), cardBottom: Math.round(C.bottom), vh: innerHeight,
    oy: cs.overflowY, scrolls: card.scrollHeight > card.clientHeight + 1, scrollTop: Math.round(card.scrollTop),
    last: (last.id || last.className || last.tagName) + ': ' + last.textContent.trim().slice(0, 40),
    lastTop: Math.round(L.top), lastBottom: Math.round(L.bottom),
    lastVisible: L.bottom <= C.bottom + 0.5 && L.bottom <= innerHeight + 0.5 && L.top >= C.top - 0.5 && L.top >= -0.5 };
}"""

# Kartın görünür düğmelerinin her biri: kart içinde görünüme kaydırılınca tamamen görünür ve en üstte mi
BUTTONS = """() => {
  const card = document.querySelector('#accountPanel .account-card');
  const out = [];
  for (const el of card.querySelectorAll('button, input, a[href]')) {
    if (el.offsetParent === null) continue;
    el.scrollIntoView({ block: 'nearest' });
    const r = el.getBoundingClientRect(), C = card.getBoundingClientRect();
    const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
    out.push({ el: el.id || el.className || el.tagName, ok: r.top >= Math.max(0, C.top) - 0.5 && r.bottom <= Math.min(innerHeight, C.bottom) + 0.5 && !!hit && (hit === el || el.contains(hit)) });
  }
  card.scrollTop = 0;
  return out;
}"""

with sync_playwright() as p:
    b = p.chromium.launch(args=['--host-resolver-rules=' + SAFETY])

    def new_ctx(vp):
        opts = dict(locale='tr-TR', service_workers='block')
        opts.update(VP[vp])
        ctx = b.new_context(**opts)
        ctx.add_init_script('window.KODHANE_QUIET = true;')
        ctx.add_init_script("(() => { if (sessionStorage.getItem('kh_seeded')) return; sessionStorage.setItem('kh_seeded','1');"
                            "localStorage.setItem('kodhane_tel_notice', '1'); localStorage.setItem('kodhane_tel', 'off');"
                            "localStorage.setItem(%s, %s); })();" % (json.dumps(SAVE_KEY), json.dumps(json.dumps(save()))))
        ctx.route(re.compile(r'^https?://(?!kodhane\.teserix\.com/|analiz\.teserix\.com/|kodhane-api\.teserix\.com/|supabase\.teserix\.com/).*'), lambda r: r.abort('blockedbyclient'))
        ctx.route('https://kodhane.teserix.com/**', file_route(ROOT))
        ctx.route('https://analiz.teserix.com/**', lambda r: r.fulfill(status=404, body=''))
        ctx.route('https://kodhane-api.teserix.com/**', supabase)
        ctx.route('https://supabase.teserix.com/**', supabase)
        return ctx

    def measure(pg, key, shot):
        pg.wait_for_timeout(250)
        r = pg.evaluate(MEASURE, ['#accountPanel', ['#accountPanel .account-card', '#accountPanel .save-note'], VP[key.split('/')[0]]['viewport']['width']])
        measures[key] = {'doc': r['doc'], 'W': r['W'], 'innerWidth': r['iw'], 'bad': r['n'], 'wide': r['nw']}
        ok = r['doc'] <= r['W'] and r['iw'] <= r['W'] and r['n'] == 0 and r['nw'] == 0 and all(t['sw'] <= t['cw'] + 1 for t in r['targets'])
        check('[%s] no horizontal overflow (scrollWidth %d / viewport %d, innerWidth %d, overflowing elements %d, beyond viewport %d)' % (key, r['doc'], r['W'], r['iw'], r['n'], r['nw']), ok, r)
        if shot:
            pg.screenshot(path=os.path.join(SHOTS, shot))
        return r

    for vp in ('360x640', '568x320'):
        ctx = new_ctx(vp)
        pg = ctx.new_page()
        errs = []
        pg.on('pageerror', lambda e: errs.append(str(e)))
        pg.goto(BASE)
        pg.wait_for_selector('#clickBtn')
        pg.wait_for_timeout(400)
        pg.evaluate("document.querySelectorAll('#modal:not(.hidden) .ghost, #modal:not(.hidden) .primary').forEach(b => b.click())")
        note('[%s] version %s (%s)' % (vp, pg.evaluate('Kodhane.VERSION'), TAG))
        pg.click('#accountBtn')
        pg.wait_for_selector('#accountPanel:not(.hidden)')
        pg.wait_for_timeout(350)
        for state in ('misafir', 'girisli'):
            if state == 'girisli':
                pg.evaluate("""(mail) => { document.getElementById('accGuest').classList.add('hidden'); document.getElementById('accUser').classList.remove('hidden');
                    document.getElementById('accEmailShown').textContent = mail; document.querySelector('#accountPanel .account-card').scrollTop = 0; }""", LONG_EMAIL)
                pg.wait_for_timeout(150)
            key = '%s/%s' % (vp, state)
            C = pg.evaluate(CARD)
            measure(pg, key + '/ust', 'v442-%s-%s-%s-ust.png' % (TAG, vp, state))
            check('[%s] card inside the viewport (top %d >= 0, bottom %d <= %d); content %d px in %d px, overflow-y %s' % (key, C['cardTop'], C['cardBottom'], C['vh'], C['cardSH'], C['cardCH'], C['oy']),
                  C['cardTop'] >= 0 and C['cardBottom'] <= C['vh'], C)
            check('[%s] card fits or scrolls inside itself (scrolls=%s, overflow-y %s)' % (key, C['scrolls'], C['oy']), not C['scrolls'] or C['oy'] in ('auto', 'scroll'), C)
            # kartın sonuna kaydır (tekerlek ile, gerçek kullanıcı gibi): son öğe görünür
            box = pg.evaluate("(() => { const r = document.querySelector('#accountPanel .account-card').getBoundingClientRect(); return [r.left + r.width / 2, Math.max(r.top, 0) + 20]; })()")
            pg.mouse.move(box[0], box[1])
            for _ in range(12):
                pg.mouse.wheel(0, 400)
            pg.wait_for_timeout(300)
            C2 = pg.evaluate(CARD)
            check('[%s] bottom reachable: after scrolling the card the last item (%s) is fully visible (top %d, bottom %d, viewport %d, scrollTop %d)'
                  % (key, C2['last'], C2['lastTop'], C2['lastBottom'], C2['vh'], C2['scrollTop']), C2['lastVisible'], C2)
            measure(pg, key + '/son', 'v442-%s-%s-%s-son.png' % (TAG, vp, state))
            measures[key] = {'ust': measures.pop(key + '/ust'), 'son': measures.pop(key + '/son')}
            measures[key]['card'] = {k: C[k] for k in ('cardSH', 'cardCH', 'cardTop', 'cardBottom', 'vh', 'oy', 'scrolls')}
            measures[key]['afterScroll'] = {k: C2[k] for k in ('scrollTop', 'lastTop', 'lastBottom', 'lastVisible')}
            btn = pg.evaluate(BUTTONS)
            check('[%s] all %d visible controls of the card reachable and on top' % (key, len(btn)), btn and all(x['ok'] for x in btn), [x for x in btn if not x['ok']])
        pg.keyboard.press('Escape')
        pg.wait_for_timeout(150)
        check('[%s] account panel closes (Escape), no page errors' % vp, pg.is_hidden('#accountPanel') and not errs, errs)
        ctx.close()
    b.close()

note('measurements: ' + json.dumps(measures, ensure_ascii=False))
passed = sum(r[1] for r in results)
print('\nSUMMARY: %d/%d passed' % (passed, len(results)))
sys.exit(0 if passed == len(results) else 1)
