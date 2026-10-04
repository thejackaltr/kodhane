"""Kodhane v4.5 metinleri, 360x640 ölçümü (Yazı kodhane-v4.5-metinler-yazi-r1): avantaj satırı E1, büyük müşteri teklif kutusu,
borsa_2 / borsa_3 açıklamaları, 247 çalışan kademe adının kartta satır sayısı ve taşma/kesilme kontrolü, geliştirme listesi.
Satır sayısı: metnin Range dikdörtgenlerindeki farklı satır üstleri. Taşma: scrollWidth > clientWidth, karttan/ekrandan dışarı taşan kutu.
Ekran görüntüleri: KODHANE_V45_TEXT_SHOTS (varsayılan /workspace/kodhane-v45-shots/metinler). Ölçümler JSON: <shots>/olcumler-360x640.json
    python3 tests/test_v45_texts_ui.py
"""
import json
import mimetypes
import os
import re
import sys
from urllib.parse import urlsplit

from playwright.sync_api import sync_playwright

ROOT = os.environ.get('KODHANE_ROOT') or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.environ.get('KODHANE_V45_TEXT_SHOTS', '/workspace/kodhane-v45-shots/metinler')
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


# Satır sayısı ve taşma ölçer (sayfada): el -> { lines, overflowX, clipped, outOfCard, text }
MEASURE = """(el, cardSel) => {
  const r = document.createRange(); r.selectNodeContents(el);
  const tops = []; for (const q of r.getClientRects()) { if (q.width < 1) continue; const t = Math.round(q.top); if (!tops.some((x) => Math.abs(x - t) <= 3)) tops.push(t); }
  const cs = getComputedStyle(el); const b = el.getBoundingClientRect();
  const card = cardSel ? el.closest(cardSel) : null; const c = card ? card.getBoundingClientRect() : null;
  const tr = r.getBoundingClientRect();
  return { lines: tops.length, text: el.textContent, w: Math.round(b.width),
    overflowX: el.scrollWidth > el.clientWidth + 1,
    clipped: (cs.textOverflow === 'ellipsis' || cs.overflow === 'hidden' || cs.overflowX === 'hidden') && (el.scrollWidth > el.clientWidth + 1 || el.scrollHeight > el.clientHeight + 1),
    outOfCard: !!c && (tr.left < c.left - 0.5 || tr.right > c.right + 0.5 || tr.top < c.top - 0.5 || tr.bottom > c.bottom + 0.5),
    outOfScreen: tr.left < -0.5 || tr.right > innerWidth + 0.5 };
}"""


def measure(pg, sel, card=None):
    return pg.eval_on_selector(sel, MEASURE, card)


def bad(m):
    return m['overflowX'] or m['clipped'] or m['outOfCard'] or m['outOfScreen']


with sync_playwright() as p:
    b = p.chromium.launch(args=['--host-resolver-rules=' + SAFETY])

    def new_page(sv):
        ctx = b.new_context(locale='tr-TR', service_workers='block', timezone_id='Europe/Istanbul', viewport={'width': 360, 'height': 640}, is_mobile=True, has_touch=True)
        ctx.add_init_script('window.KODHANE_QUIET = true;')
        ctx.add_init_script("(() => { if (sessionStorage.getItem('kh_seeded')) return; sessionStorage.setItem('kh_seeded','1');"
                            "localStorage.setItem('kodhane_tel_notice', '1'); localStorage.setItem('kodhane_tel', 'off');"
                            "localStorage.setItem(%s, %s); })();" % (json.dumps(SAVE_KEY), json.dumps(json.dumps(sv))))
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

    def shot(pg, name):
        pg.wait_for_timeout(200)
        pg.evaluate("document.querySelectorAll('#toast > *').forEach((t) => t.remove())")
        pg.screenshot(path=os.path.join(SHOTS, name + '-360x640.png'))

    ctx, pg, errs = new_page(save())
    ev = pg.evaluate
    VT = ev('Kodhane.V45_TEXT')

    # 1) E1 avantaj satırı (İstatistik)
    ev("Kodhane.setView('stats')"); pg.wait_for_timeout(200)
    ev("(t) => { const d = [...document.querySelectorAll('#statsList dt')].find((x) => x.textContent === t); d.id = 'perkE1'; d.scrollIntoView({block: 'center'}); }", VT['rep.perk.E1'])
    m = measure(pg, '#perkE1', '#statsList > div'); MEAS['rep.perk.E1'] = m
    check('E1 row: %d line(s) at 360x640, no overflow/clip' % m['lines'], m['lines'] <= 2 and not bad(m), m)
    for e in ('E2', 'E4'):
        ev("([t, id]) => { const d = [...document.querySelectorAll('#statsList dt')].find((x) => x.textContent === t); d.id = id; }", [VT['rep.perk.' + e], 'perk' + e])
        m2 = measure(pg, '#perk' + e, '#statsList > div'); MEAS['rep.perk.' + e] = m2
        check('%s row: %d line(s), no overflow' % (e, m2['lines']), not bad(m2), m2)
    shot(pg, 'e1-avantaj')

    # 2) Büyük müşteri teklif kutusu: tüm teklif metinleri x gerçekçi tutarlar (1e21–1e27 aşamaları), 💎 ön ekiyle
    ev("() => { const r = Math.random; Math.random = () => 0.01; Kodhane.state.reputation = 100; Kodhane.spawnOffer('cash'); Math.random = r; }"); pg.wait_for_timeout(450)
    src = open(os.path.join(ROOT, 'game.js'), encoding='utf-8').read()
    arr = src[src.index('var OFFER_TEXTS = ['):]; arr = arr[:arr.index('];')]
    offers = re.findall(r"'([^']+)'", arr)
    check('offer texts parsed from game.js OFFER_TEXTS (%d)' % len(offers), len(offers) >= 5)
    worst = None; counts = {}
    for t in offers:
        for amt in (1.23e21, 888.88e21, 1.23e24, 888.88e24, 888.88e27):
            # game.js spawnOffer ile aynı biçim: offer.big ön eki + metin + ' — ' + tl(tutar) + ' ödeme!'
            txt = ev("([p, t, a]) => { const el = document.getElementById('coText'); el.textContent = p + ' ' + t + ' — ' + Kodhane.tl(a) + ' ödeme!'; return el.textContent; }", [VT['offer.big'], t, amt])
            mm = measure(pg, '#coText', '#clientOffer')
            counts[mm['lines']] = counts.get(mm['lines'], 0) + 1
            if bad(mm):
                check('offer box: no overflow for "%s"' % txt, False, mm)
            if not worst or mm['lines'] > worst['lines'] or (mm['lines'] == worst['lines'] and len(txt) > len(worst['text'])):
                worst = dict(mm)
    MEAS['offer.big'] = {'lineCounts': counts, 'worst': worst, 'boxMaxWidth': 290}
    check('big offer box: max %d line(s) over %d texts x 5 amounts, none overflows (line counts %s)' % (worst['lines'], len(offers), counts), worst['lines'] <= 3, worst)
    ev("(t) => { document.getElementById('coText').textContent = t; }", worst['text']); pg.wait_for_timeout(100)
    shot(pg, 'teklif-buyuk-musteri-en-uzun')
    ev("document.getElementById('clientOffer').classList.add('hidden')")

    # 3) Borsa dalı açıklamaları (düğüm kartı)
    ev("Kodhane.state.tree = %s; Kodhane.state.ipoShares = 20; Kodhane.renderAll()" % json.dumps(NODES12))
    ev("Kodhane.setView('prestige')"); pg.wait_for_timeout(300)
    for nid in ('borsa_1', 'borsa_2', 'borsa_3'):
        mn = measure(pg, '[data-node=%s] small:not(.tn-state)' % nid, '.tree-node'); MEAS['tree.%s.desc' % nid] = mn
        mt = measure(pg, '[data-node=%s] b' % nid, '.tree-node'); MEAS['tree.%s.name' % nid] = mt
        check('%s desc: %d line(s), name %d line(s), no overflow' % (nid, mn['lines'], mt['lines']), not bad(mn) and not bad(mt), [mn, mt])
    ev("document.querySelector('[data-node=borsa_2]').scrollIntoView({block: 'center'})"); shot(pg, 'borsa-dali-aciklamalar')
    ml = None
    ev("Kodhane.state.tree = %s; Kodhane.renderAll()" % json.dumps(NODES12[:11])); pg.wait_for_timeout(200)
    ml = measure(pg, '[data-node=borsa_1] .tn-state', '.tree-node'); MEAS['tree.borsa.lockedFull'] = ml
    check('lockedFull state line: %d line(s), no overflow' % ml['lines'], not bad(ml), ml)
    ev("document.querySelector('[data-node=borsa_1]').scrollIntoView({block: 'center'})"); shot(pg, 'borsa-kilitli')

    # 4) 247 çalışan kademe adı: gerçek .upg kart yapısında (ad + açıklama + gerçek maliyet), satır sayısı ve taşma
    ev("Kodhane.setView('upgrades')"); pg.wait_for_timeout(200)
    names = ev("""() => { const list = document.getElementById('upgList'); const host = document.createElement('div'); host.id = 'nameProbe'; host.className = 'upg-list'; host.style.maxHeight = 'none';
      list.parentNode.insertBefore(host, list);
      const out = [];
      for (const u of Kodhane.UPGRADES.filter((x) => x.type === 'gen')) {
        const b = document.createElement('button'); b.className = 'upg'; b.dataset.upg = u.id;
        b.innerHTML = '<div class="upg-icon"></div><div><div class="upg-name"></div><div class="upg-desc"></div></div><div class="upg-cost"></div>';
        b.querySelector('.upg-icon').textContent = u.icon; b.querySelector('.upg-name').textContent = u.name; b.querySelector('.upg-desc').textContent = u.desc;
        b.querySelector('.upg-cost').textContent = Kodhane.tl(u.cost); host.appendChild(b);
      }
      return Kodhane.UPGRADES.filter((x) => x.type === 'gen').map((u) => u.id); }""")
    per = []
    for uid in names:
        mu = measure(pg, '#nameProbe [data-upg="%s"] .upg-name' % uid, '.upg')
        mu['id'] = uid; mu['len'] = len(mu['text']); per.append(mu)
    costs = dict(ev("[...document.querySelectorAll('#nameProbe .upg')].map((b) => [b.dataset.upg, b.querySelector('.upg-cost').textContent])"))
    for x in per:
        x['cost'] = costs.get(x['id'])
    two = [x for x in per if x['lines'] == 2]; more = [x for x in per if x['lines'] > 2]; badn = [x for x in per if bad(x)]
    newtwo = [x for x in two if int(x['id'].rsplit('_', 1)[1]) > 5]
    MEAS['upg.names'] = {'total': len(per), 'oneLine': len([x for x in per if x['lines'] == 1]), 'twoLines': len(two), 'twoLinesNewTiers': len(newtwo), 'moreThanTwoCount': len(more),
                         'overflowOrClip': [x['id'] for x in badn], 'longest': sorted(((x['len'], x['text'], x['id'], x['lines']) for x in per), reverse=True)[:8]}
    check('247 worker tier names measured in real cards', len(per) == 247, len(per))
    check('names: none overflows or is clipped (all 247)', not badn, [(x['id'], x['text']) for x in badn])
    # Bulgu (rapor): uzun maliyet metni (nowrap, ör. "36,39 Novemdesilyon TL") ad sütununu ~90 px'e daraltınca bazı adlar 3 satır olur; taşma/kesilme yok.
    check('names: at most 3 lines (3-line names listed in olcumler JSON), no 4+', not [x for x in per if x['lines'] > 3], [(x['id'], x['lines']) for x in per if x['lines'] > 3])
    print('INFO 3-line names (%d): %s' % (len(more), [(x['id'], x['text'], x['cost']) for x in more]))
    MEAS['upg.names']['threeLines'] = [(x['id'], x['text'], x['cost']) for x in more]
    print('INFO names: %d one line, %d two lines (%d of them new tiers 6–19), longest %s' % (MEAS['upg.names']['oneLine'], len(two), len(newtwo), MEAS['upg.names']['longest'][:3]))
    # en uzun adların ekran görüntüsü: yalnız en uzun 6 kart
    longest_ids = [x[2] for x in MEAS['upg.names']['longest'][:6]]
    ev("(ids) => { for (const b of document.querySelectorAll('#nameProbe .upg')) b.style.display = ids.includes(b.dataset.upg) ? '' : 'none'; const h = document.getElementById('nameProbe'); h.style.flexDirection = 'column';"
       " ids.forEach((id) => h.appendChild(h.querySelector('[data-upg=\"' + id + '\"]'))); h.scrollIntoView({block: 'start'}); }", longest_ids)
    shot(pg, 'kademe-adlari-en-uzun')
    ev("document.getElementById('nameProbe').remove()")

    # 5) Geliştirme listesi (gerçek liste; farklı kademeler açık)
    ctx.close()
    gens = {g: c for g, c in zip(GENS, [10000, 7500, 5000, 3000, 2000, 1500, 1000, 750, 500, 400, 300, 250, 200])}
    owned = []
    tiers = [1, 10, 25, 50, 100, 150, 200, 250, 300, 400, 500, 750, 1000, 1500, 2000, 3000, 5000, 7500, 10000]
    for g, c in gens.items():
        k = len([t for t in tiers if t <= c])
        owned += ['%s_%d' % (g, i) for i in range(1, k)]   # sonuncusu alınmamış: listede görünür
    ctx, pg, errs2 = new_page(save(gens=gens, upgrades=owned, tree=NODES12 + ['borsa_1', 'borsa_2', 'borsa_3'], money=1e300))
    ev = pg.evaluate
    ev("Kodhane.setView('upgrades')"); pg.wait_for_timeout(300)
    shown = ev("[...document.querySelectorAll('#upgList .upg')].map((b) => b.dataset.upg)")
    lst = []
    for uid in shown:
        mu = measure(pg, '#upgList [data-upg="%s"] .upg-name' % uid, '.upg'); mu['id'] = uid; lst.append(mu)
    MEAS['upgList'] = [(x['id'], x['text'], x['lines']) for x in lst]
    check('upgrade list (%d cards, mixed tiers incl. 10000): no overflow/clip, max 3 lines' % len(lst), len(lst) >= 10 and not [x for x in lst if bad(x) or x['lines'] > 3], [x for x in lst if bad(x) or x['lines'] > 3])
    print('INFO upgrade list line counts: %s' % {n: len([x for x in lst if x['lines'] == n]) for n in (1, 2, 3)})
    ev("document.getElementById('upgList').scrollIntoView({block: 'start'})"); shot(pg, 'gelistirme-listesi')
    three = [x['id'] for x in lst if x['lines'] == 3]
    ev("(id) => { const c = id ? [...document.querySelectorAll('#upgList .upg')].find((b) => b.dataset.upg === id) : null; if (c) c.scrollIntoView({block: 'center'}); else document.getElementById('upgList').scrollTop = 99999; }", three[0] if three else None)
    shot(pg, 'gelistirme-listesi-kademeler')
    check('no page errors', not errs and not errs2, errs + errs2)
    ctx.close()
    b.close()

json.dump(MEAS, open(os.path.join(SHOTS, 'olcumler-360x640.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
n_ok = sum(1 for _, ok in results if ok)
print('\nSUMMARY: %d/%d passed' % (n_ok, len(results)))
sys.exit(0 if n_ok == len(results) else 1)
