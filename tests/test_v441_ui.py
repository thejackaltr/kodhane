"""Kodhane v4.4.1 arayüz testi: sayı adlarının (Yazı r2, Bin ... Vigintilyon) dar ekranlarda taşmaması.

En uzun değer "999,99 Septendesilyon TL" (24 karakter, tl(999.99e54)). 360x640 ve 568x320'de şu yerler ölçülür
(her öğe için scrollWidth / clientWidth ve sayfa genişliği; OVERFLOW = test_v44_ui.py ile aynı ölçüm):
  kasa (üst sayaç), fiyat düğmeleri (Ekip + Geliştirme), sıralama satırı (leaderboard.js lb-score), Yatırım Turu paneli,
  bulut bildirimi (cloud.js "Çevrimdışı kazanç: +..." toast'ı), başarım metinleri, telemetri ayrıntı paneli (Gizlilik).
Sıralama satır bazlı (v4.4.1 r2): v4.4.0'daki en uzun puan metninden (14 karakter) uzun puanlı satırda dar ekranda puan alt satıra
geçer; normal puanlı satır v4.4.0 (879f67b, git archive ile geçici klasöre açılır; KODHANE_V440_ROOT ile verilebilir) ile aynı
konum ve genişlikte ölçülür. Aynı listede uzun ve normal puanlı satırlar birlikte.
Ekran görüntüleri: KODHANE_V441_SHOTS (varsayılan /workspace/kodhane-v44-audit), adlar v441b-<alan>-<görünüm>.png. Ağ yok: oyun Playwright route ile depo
dosyalarından, Supabase/Umami sahte; gerçek adlar --host-resolver-rules ile kapalı porta yönlenir.
    python3 tests/test_v441_ui.py
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
SHOTS = os.environ.get('KODHANE_V441_SHOTS', '/workspace/kodhane-v44-audit')
BASE = 'https://kodhane.teserix.com/'
SAVE_KEY = 'kodhane_ajans_save_v2'
SAFETY = ('MAP analiz.teserix.com 127.0.0.1:9, MAP kodhane-api.teserix.com 127.0.0.1:9, MAP supabase.teserix.com 127.0.0.1:9, '
          'MAP kodhane.teserix.com 127.0.0.1:9, MAP thejackaltr.github.io 127.0.0.1:9, MAP cdn.jsdelivr.net 127.0.0.1:9, '
          'MAP acikofis.teserix.com 127.0.0.1:9, MAP *.supabase.co 127.0.0.1:9')
LONG = 999.99e54
ELLIPSIS = ('.lb-name',)   # tasarım gereği "…" ile kısalır (v4.4.0'da da); yalnız görünen genişliği ölçülür
results = []
measures = {}


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


# Aynı listede uzun puanlı (1-3: Vigintilyon / Novemdesilyon / Septendesilyon) ve normal puanlı (4-6) satırlar.
# 4: uzun takma ad + "1,23 Milyar TL" (v4.4.0: "1,23 Mr TL"), 5: kısa takma ad + "1,23 Milyar TL",
# 6: uzun takma ad + "950 TL" (iki sürümde metin aynı: yerleşim birebir karşılaştırılır).
LB_ROWS = [
    {'rank': 1, 'nickname': 'ben', 'score': 999.99e63, 'stage': 8, 'stage_id': 'mars_ofisi', 'is_me': True, 'status': 'ok'},
    {'rank': 2, 'nickname': 'Novemdesilyon Ajansı', 'score': 999.99e60, 'stage': 8, 'stage_id': 'mars_ofisi', 'is_me': False, 'status': 'ok'},
    {'rank': 3, 'nickname': 'Septendesilyoner2026', 'score': LONG, 'stage': 8, 'stage_id': 'mars_ofisi', 'is_me': False, 'status': 'ok'},
    {'rank': 4, 'nickname': 'ÇokUzunTakmaAdımVar', 'score': 1.23e9, 'stage': 7, 'stage_id': 'yapay_zeka_lab', 'is_me': False, 'status': 'ok'},
    {'rank': 5, 'nickname': 'Aryen', 'score': 1.23e9, 'stage': 5, 'stage_id': 'global_holding', 'is_me': False, 'status': 'ok'},
    {'rank': 6, 'nickname': 'UzunTakmaAdıOlanOyuncu', 'score': 950, 'stage': 0, 'stage_id': 'freelancer', 'is_me': False, 'status': 'ok'},
]
LONG_RANKS, NORMAL_RANKS = (1, 2, 3), (4, 5, 6)

# satır başına: takma ad (sol, üst: satıra göre; kutu genişliği; görünen metin genişliği = min(metin, kutu); kısaldı mı),
# puan (sol, üst: satıra göre; genişlik; takma adın altında mı), satır yüksekliği, lb-long sınıfı
LB_MEASURE = """() => [...document.querySelectorAll('#lbList .lb-row')].map((row, i) => {
  const R = row.getBoundingClientRect(), nm = row.querySelector('.lb-name'), sc = row.querySelector('.lb-score');
  const N = nm.getBoundingClientRect(), C = sc.getBoundingClientRect();
  const rg = document.createRange(); rg.selectNodeContents(nm.firstChild); const tw = rg.getBoundingClientRect().width;
  return { rank: i + 1, nick: nm.firstChild.textContent, score: sc.textContent,
    long: row.classList.contains('lb-long'), rowH: Math.round(R.height * 10) / 10,
    nameL: Math.round((N.left - R.left) * 10) / 10, nameT: Math.round((N.top - R.top) * 10) / 10, nameW: nm.clientWidth,
    nameVis: Math.round(Math.min(tw, nm.clientWidth) * 10) / 10, textW: Math.round(tw * 10) / 10, cut: tw > nm.clientWidth + 0.5,
    scoreL: Math.round((C.left - R.left) * 10) / 10, scoreT: Math.round((C.top - R.top) * 10) / 10, scoreW: Math.round(C.width * 10) / 10,
    scoreBelow: C.top >= N.bottom - 1, scoreRight: Math.round((R.right - C.right) * 10) / 10 };
})"""


def v440_root():
    r = os.environ.get('KODHANE_V440_ROOT')
    if r:
        return r
    d = tempfile.mkdtemp(prefix='k440-')
    tar = subprocess.run(['git', '-C', ROOT, 'archive', '879f67b'], check=True, capture_output=True).stdout
    subprocess.run(['tar', '-x', '-C', d], input=tar, check=True)
    return d


def supabase(route):
    cors = {'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*', 'content-type': 'application/json'}
    if route.request.method == 'OPTIONS':
        return route.fulfill(status=204, headers=cors, body='')
    path = urlsplit(route.request.url).path
    if path.endswith('/rpc/kodhane_leaderboard_v7') or path.endswith('/rpc/kodhane_leaderboard'):
        return route.fulfill(status=200, headers=cors, body=json.dumps(LB_ROWS))
    route.fulfill(status=200, headers=cors, body='null' if path.endswith('kodhane_count_event') else '[]')


def save():
    return {'version': 5, 'saveVersion': 5, 'money': LONG, 'runEarned': 999.98e54, 'totalEarned': 999.99e63, 'cycleEarned': 999.98e54,
            'clicks': 10, 'clickEarned': 10, 'playTime': 9000, 'startedAt': 0, 'lastSaved': 0, 'gens': {'stajyer': 100},
            'upgrades': [], 'shares': 999990000000, 'prestigeCount': 30, 'cycleRounds': 3, 'stage': 8, 'stageBest': 8, 'cycleStage': 8,
            'stageId': 'mars_ofisi', 'stageBestId': 'mars_ofisi', 'cycleStageId': 'mars_ofisi', 'achievements': [], 'reputation': 50,
            'tree': [], 'ipoShares': 0, 'ipoSharesEarned': 40, 'ipoCount': 3, 'ipoAt': 1, 'newsSeen': ['yeni_asama', 'siralama', 'acik_ofis'], 'newsPending': []}


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

V440 = v440_root()
lb = {}
with sync_playwright() as p:
    b = p.chromium.launch(args=['--host-resolver-rules=' + SAFETY])

    def new_ctx(vp, root=None):
        opts = dict(locale='tr-TR', service_workers='block')
        opts.update(VP[vp])
        ctx = b.new_context(**opts)
        ctx.add_init_script('window.KODHANE_QUIET = true;')
        ctx.add_init_script("(() => { if (sessionStorage.getItem('kh_seeded')) return; sessionStorage.setItem('kh_seeded','1');"
                            "localStorage.setItem('kodhane_tel_notice', '1'); localStorage.setItem('kodhane_tel', 'off');"
                            "localStorage.setItem(%s, %s); })();" % (json.dumps(SAVE_KEY), json.dumps(json.dumps(save()))))
        ctx.route(re.compile(r'^https?://(?!kodhane\.teserix\.com/|analiz\.teserix\.com/|kodhane-api\.teserix\.com/|supabase\.teserix\.com/).*'), lambda r: r.abort('blockedbyclient'))
        ctx.route('https://kodhane.teserix.com/**', file_route(root or ROOT))
        ctx.route('https://analiz.teserix.com/**', lambda r: r.fulfill(status=404, body=''))
        ctx.route('https://kodhane-api.teserix.com/**', supabase)
        ctx.route('https://supabase.teserix.com/**', supabase)
        return ctx

    def oneline(pg, vp, sel):
        # sayaç tek satırda kalmalı (yükseklik <= 1,5 satır) ve görünüm içinde bitmeli; ekran görüntüsünü bildirimler örtmesin
        pg.evaluate("document.getElementById('toast').innerHTML = ''")
        r = pg.evaluate("""(s) => { const e = document.querySelector(s), cs = getComputedStyle(e), b = e.getBoundingClientRect();
            const lh = parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) * 1.2; return {h: b.height, lh: lh, right: b.right, fs: cs.fontSize}; }""", sel)
        W = int(vp.split('x')[0])
        check('[%s][kasa] %s stays on one line inside the viewport (h %.0f / line %.0f, right %.0f / %d, font %s)' % (vp, sel, r['h'], r['lh'], r['right'], W, r['fs']),
              r['h'] <= r['lh'] * 1.5 and r['right'] <= W + 0.5, r)

    def measure(pg, key, sel, targets, shot):
        pg.wait_for_timeout(250)
        r = pg.evaluate(MEASURE, [sel, targets, VP[key.split('/')[0]]['viewport']['width']])
        measures[key] = {'doc': r['doc'], 'W': r['W'], 'innerWidth': r['iw'], 'bad': r['n'], 'wide': r['nw'], 'targets': [(t['sel'], t['sw'], t['cw'], t['text']) for t in r['targets']]}
        ok = r['doc'] <= r['W'] and r['iw'] <= r['W'] and r['n'] == 0 and r['nw'] == 0 and all(t['sw'] <= t['cw'] + 1 for t in r['targets'] if t['sel'] not in ELLIPSIS)
        check('[%s] no horizontal overflow (scrollWidth %d / viewport %d, innerWidth %d, overflowing elements %d, beyond viewport %d)' % (key, r['doc'], r['W'], r['iw'], r['n'], r['nw']), ok, r)
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
        check('[%s] longest value: tl(999.99e54) = "999,99 Septendesilyon TL" (24 chars)' % vp, pg.evaluate('Kodhane.tl(%r)' % LONG) == '999,99 Septendesilyon TL')

        # 1) kasa (üst sayaç)
        # (a) kasa = en uzun değer; üretim 0 (kasa sabit kalsın)
        pg.evaluate("Kodhane.GENERATORS.forEach(g => { g._tps = g.tps; g.tps = 0; }); Kodhane.setView('kod'); Kodhane.state.money = %r; Kodhane.renderAll(); window.scrollTo(0, 0)" % LONG)
        pg.wait_for_timeout(600)
        check('[%s][kasa] counter shows the longest value' % vp, pg.inner_text('#money') == '999,99 Septendesilyon TL', pg.inner_text('#money'))
        oneline(pg, vp, '#money')
        measure(pg, '%s/kasa' % vp, 'header.topbar', ['#money', '#rate', '.money-box'], 'v441b-kasa-%s.png' % vp)
        # (b) üretim satırı = en uzun değer + "/sn" ("999,99 Septendesilyon TL/sn", 27 karakter)
        pg.evaluate("(L) => { const K = Kodhane, g = K.GENERATORS[0]; g.tps = 1; const per = K.baseTps(); g.tps = L / per; K.renderAll(); }", LONG)
        pg.wait_for_timeout(600)
        rate = pg.inner_text('#rate')
        check('[%s][kasa] rate line shows the longest value + /sn' % vp, rate == '999,99 Septendesilyon TL/sn', rate)
        oneline(pg, vp, '#money'); oneline(pg, vp, '#rate')
        measure(pg, '%s/kasa-uretim' % vp, 'header.topbar', ['#money', '#rate', '.money-box'], 'v441b-kasa-uretim-%s.png' % vp)
        pg.evaluate("Kodhane.GENERATORS.forEach(g => { g.tps = g._tps; })")

        # 2) fiyat düğmeleri: her çalışanın ve görünen geliştirmelerin fiyatı en uzun değer (yalnız bu sayfada, test için)
        pg.evaluate("""(L) => { const K = Kodhane; K.GENERATORS.forEach(g => { g.base = L; });
            K.UPGRADES.forEach(u => { u.cost = L; }); K.state.money = L * 1.0000001; K.setView('ekip'); K.renderAll(); window.scrollTo(0, 0); }""", LONG)
        pg.wait_for_timeout(300)
        gl = pg.inner_text('#genList')
        check('[%s][fiyat] employee buttons show "999,99 Septendesilyon"' % vp, '999,99 Septendesilyon' in gl, gl[:200])
        measure(pg, '%s/fiyat-ekip' % vp, '#panelEkip', ['#genList button', '#genList .price', '#genList [class*=cost]'], 'v441b-fiyat-ekip-%s.png' % vp)
        pg.evaluate("Kodhane.setView('upgrades'); Kodhane.renderAll(); window.scrollTo(0, 0)")
        pg.wait_for_timeout(300)
        up = pg.inner_text('#panelSide')
        check('[%s][fiyat] upgrade buttons show "999,99 Septendesilyon"' % vp, '999,99 Septendesilyon' in up, up[:200])
        measure(pg, '%s/fiyat-gelistirme' % vp, '#panelSide', ['#panelSide button'], 'v441b-fiyat-gelistirme-%s.png' % vp)

        # 3) sıralama satırı (leaderboard.js rowNode -> .lb-score): uzun ve normal puanlı satırlar aynı listede
        pg.evaluate("Kodhane.setView('siralama'); Kodhane.leaderboard.refresh()")
        try:
            pg.wait_for_function("document.querySelectorAll('#lbList .lb-row').length >= 6", timeout=8000)
            got = pg.evaluate("[...document.querySelectorAll('.lb-score')].map(e => e.textContent)")
        except Exception as e:  # noqa: BLE001
            got = ['(sıralama yüklenmedi: %s)' % e]
        check('[%s][siralama] rows show full names: long (Vigintilyon / Novemdesilyon / Septendesilyon) and normal (1,23 Milyar / 950) in one list' % vp,
              got == ['999,99 Vigintilyon TL', '999,99 Novemdesilyon TL', '999,99 Septendesilyon TL', '1,23 Milyar TL', '1,23 Milyar TL', '950 TL'], got)
        pg.evaluate("document.getElementById('lbList').scrollIntoView({ block: 'start' })")
        r = measure(pg, '%s/siralama' % vp, '#panelSide', ['.lb-row', '.lb-score'], 'v441b-siralama-%s.png' % vp)
        rows = {x['rank']: x for x in pg.evaluate(LB_MEASURE)}
        lb[vp] = {'v441': rows}
        for k in sorted(rows):
            x = rows[k]
            note('[%s][siralama] #%d %-24s %-26s long=%s nick: left %.1f top %.1f box %d visible %.1f%s | score: left %.1f top %.1f w %.1f %s | row h %.1f' % (
                vp, k, x['nick'], x['score'], x['long'], x['nameL'], x['nameT'], x['nameW'], x['nameVis'], ' (…)' if x['cut'] else '',
                x['scoreL'], x['scoreT'], x['scoreW'], 'BELOW' if x['scoreBelow'] else 'inline', x['rowH']))
        narrow = vp == '360x640'
        check('[%s][siralama] row-based: only long-score rows (> 14 chars) get lb-long' % vp,
              all(rows[k]['long'] for k in LONG_RANKS) and not any(rows[k]['long'] for k in NORMAL_RANKS), {k: rows[k]['long'] for k in rows})
        if narrow:
            check('[360x640][siralama] long-score rows: score moves below the nickname, right-aligned inside the row',
                  all(rows[k]['scoreBelow'] and rows[k]['scoreRight'] >= 0 for k in LONG_RANKS), {k: (rows[k]['scoreBelow'], rows[k]['scoreRight']) for k in LONG_RANKS})
            check('[360x640][siralama] long-score rows: nickname not cut (full width of the row)', not any(rows[k]['cut'] for k in LONG_RANKS),
                  {k: (rows[k]['nameVis'], rows[k]['textW']) for k in LONG_RANKS})
        else:
            check('[568x320][siralama] all rows single line (score inline, right of the nickname)', not any(rows[k]['scoreBelow'] for k in rows), {k: rows[k]['scoreBelow'] for k in rows})
        check('[%s][siralama] normal-score rows: score inline (same line as the nickname)' % vp, not any(rows[k]['scoreBelow'] for k in NORMAL_RANKS))
        check('[%s][siralama] a cut ("…") nickname still shows >= 80 px' % vp, all(x['nameVis'] >= 80 for x in rows.values() if x['cut']),
              {k: (rows[k]['nameVis'], rows[k]['cut']) for k in rows})

        # 3b) aynı liste v4.4.0 (879f67b) ile: normal puanlı satırlarda takma ad konumu / genişliği karşılaştırması
        c0 = new_ctx(vp, V440)
        p0 = c0.new_page()
        p0.goto(BASE)
        p0.wait_for_selector('#clickBtn')
        p0.wait_for_timeout(400)
        p0.evaluate("document.querySelectorAll('#modal:not(.hidden) .ghost, #modal:not(.hidden) .primary').forEach(b => b.click())")
        p0.evaluate("Kodhane.setView('siralama'); Kodhane.leaderboard.refresh()")
        p0.wait_for_function("document.querySelectorAll('#lbList .lb-row').length >= 6", timeout=8000)
        p0.evaluate("document.getElementById('lbList').scrollIntoView({ block: 'start' })")
        p0.wait_for_timeout(250)
        check('[%s][siralama] reference is v4.4.0' % vp, p0.evaluate('Kodhane.VERSION') == '4.4.0')
        p0.screenshot(path=os.path.join(SHOTS, 'v441b-siralama-v440-%s.png' % vp))
        rows0 = {x['rank']: x for x in p0.evaluate(LB_MEASURE)}
        lb[vp]['v440'] = rows0
        c0.close()
        for k in sorted(rows0):
            x = rows0[k]
            note('[%s][siralama v4.4.0] #%d %-24s %-14s nick: left %.1f top %.1f box %d visible %.1f%s | score: left %.1f top %.1f w %.1f | row h %.1f' % (
                vp, k, x['nick'], x['score'], x['nameL'], x['nameT'], x['nameW'], x['nameVis'], ' (…)' if x['cut'] else '', x['scoreL'], x['scoreT'], x['scoreW'], x['rowH']))
        same_pos = all(rows[k]['nameL'] == rows0[k]['nameL'] and rows[k]['nameT'] == rows0[k]['nameT'] for k in NORMAL_RANKS)
        check('[%s][siralama] normal-score rows: nickname position (left/top in row) identical to v4.4.0' % vp, same_pos,
              {k: [(rows[k]['nameL'], rows0[k]['nameL']), (rows[k]['nameT'], rows0[k]['nameT'])] for k in NORMAL_RANKS})
        check('[%s][siralama] same score text (950 TL): nickname box / visible width, row height and score position identical to v4.4.0 (%d / %d px)' % (vp, rows[6]['nameW'], rows0[6]['nameW']),
              all(rows[6][f] == rows0[6][f] for f in ('nameW', 'nameVis', 'rowH', 'scoreL', 'scoreT', 'score')), (rows[6], rows0[6]))
        if rows[4]['rowH'] != rows0[4]['rowH']:
            note('[%s][siralama] #4 row height %.1f vs v4.4.0 %.1f: the stage label ("Yapay Zekâ Laboratuvarı") wraps in the %d px column (v4.4.0: %d px)' % (
                vp, rows[4]['rowH'], rows0[4]['rowH'], rows[4]['nameW'], rows0[4]['nameW']))
        check('[%s][siralama] short nickname with "1,23 Milyar TL": visible nickname width identical to v4.4.0 (%.1f / %.1f px)' % (vp, rows[5]['nameVis'], rows0[5]['nameVis']),
              rows[5]['nameVis'] == rows0[5]['nameVis'] and not rows[5]['cut'])
        d4 = (rows[4]['scoreW'] - rows0[4]['scoreW'])
        check('[%s][siralama] long nickname with "1,23 Milyar TL": nickname box = v4.4.0 box minus only the longer score text ("%s" vs "%s", %+.1f px): %d / %d px' % (
              vp, rows[4]['score'], rows0[4]['score'], d4, rows[4]['nameW'], rows0[4]['nameW']), abs((rows0[4]['nameW'] - rows[4]['nameW']) - d4) <= 1.5)
        if narrow:
            check('[360x640][siralama] long-score rows: nickname box at least as wide as v4.4.0 for the same rows (%s vs %s)' % (
                  [rows[k]['nameW'] for k in LONG_RANKS], [rows0[k]['nameW'] for k in LONG_RANKS]), all(rows[k]['nameW'] >= rows0[k]['nameW'] for k in LONG_RANKS))

        # 4) Yatırım Turu paneli (prShares, prBonus, prGain, prNext)
        pg.evaluate("Kodhane.setView('prestige'); Kodhane.renderAll(); window.scrollTo(0, 0)")
        pg.wait_for_timeout(300)
        pr = pg.evaluate("['prShares', 'prBonus', 'prGain', 'prNext'].map(id => document.getElementById(id).textContent)")
        note('[%s][yatirim] %s' % (vp, json.dumps(pr, ensure_ascii=False)))
        check('[%s][yatirim] panel values use full names' % vp, all(not re.search(r'\d\s*(Mn|Mr|Tn|Kat|Kent)\b', x) for x in pr) and any(re.search(r'[a-zçğıöşü]ilyon', x) for x in pr), pr)
        measure(pg, '%s/yatirim' % vp, '#panelSide', ['#prShares', '#prBonus', '#prGain', '#prNext', '.stats dd'], 'v441b-yatirim-turu-%s.png' % vp)

        # 5) bulut bildirimi (cloud.js: '☁️ Buluttaki kaydın yüklendi ... Çevrimdışı kazanç: +' + K.tl(gain))
        pg.evaluate("Kodhane.setView('kod'); window.scrollTo(0, 0); document.getElementById('toast').innerHTML = '';"
                    "Kodhane.toast('☁️ Buluttaki kaydın yüklendi (bu cihazdaki kayıt yedeklendi). Çevrimdışı kazanç: +' + Kodhane.tl(%r), 60000)" % LONG)
        pg.wait_for_timeout(400)
        tt = pg.inner_text('#toast')
        check('[%s][bulut] toast shows "+999,99 Septendesilyon TL"' % vp, '+999,99 Septendesilyon TL' in tt, tt)
        measure(pg, '%s/bulut-bildirim' % vp, '#toast', ['#toast > *'], 'v441b-bulut-bildirim-%s.png' % vp)
        pg.evaluate("document.getElementById('toast').innerHTML = ''")

        # 6) başarım metinleri (tümü açık): açıklamalarda kısaltma yok, taşma yok
        pg.evaluate("Kodhane.state.achievements = Kodhane.ACHIEVEMENTS.map(a => a.id); Kodhane.setView('achievements'); Kodhane.renderAll(); window.scrollTo(0, 0)")
        pg.wait_for_timeout(300)
        ach = pg.inner_text('#panelSide')
        check('[%s][basarim] texts: "Toplam 1 Milyon/Milyar/Trilyon TL kazan", no Mn/Mr/Tn' % vp,
              all(x in ach for x in ('Toplam 1 Milyon TL kazan', 'Toplam 1 Milyar TL kazan', 'Toplam 1 Trilyon TL kazan')) and not re.search(r'\d\s*(Mn|Mr|Tn)\b', ach), ach[:300])
        el = pg.query_selector('#achGrid [title*="Trilyon"], #achGrid :text("Trilyon Kulübü")')
        if el:
            el.scroll_into_view_if_needed()
        measure(pg, '%s/basarim' % vp, '#panelSide', ['#achGrid > *'], 'v441b-basarim-%s.png' % vp)

        # 7) telemetri ayrıntı paneli (Gizlilik -> ayrıntılar): v4.4.1 metni (Yazı telemetry-details r1, "Üç olayda"), taşma yok
        pg.evaluate("Kodhane.setView('stats'); Kodhane.renderAll(); document.getElementById('telDetailsBtn').click()")
        pg.wait_for_selector('.tel-details')
        pg.wait_for_timeout(300)
        det = pg.inner_text('.tel-details')
        check('[%s][telemetri] details panel shows the new first paragraph ("Üç olayda ... Yatırım turunda ulaştığın aşama; Halka Arz\'da ...")' % vp,
              "Üç olayda oyundaki ilerlemenden birkaç bilgi de gider: Yatırım turunda ulaştığın aşama; Halka Arz'da ulaştığın aşama" in det and 'İki olayda' not in det, det[:300])
        measure(pg, '%s/telemetri-ayrinti' % vp, '#modal', ['.tel-details p', '#modalCard'], 'v441b-telemetri-ayrinti-%s.png' % vp)
        pg.evaluate("document.querySelector('[data-test=tel-details-close]').scrollIntoView({ block: 'end' })")
        measure(pg, '%s/telemetri-ayrinti-son' % vp, '#modal', ['.tel-details p', '#modalCard'], 'v441b-telemetri-ayrinti-son-%s.png' % vp)
        pg.click('[data-test=tel-details-close]')
        pg.wait_for_timeout(200)
        check('[%s] no page errors' % vp, not errs, errs)
        ctx.close()
    b.close()

note('measurements: ' + json.dumps(measures, ensure_ascii=False))
note('leaderboard rows: ' + json.dumps(lb, ensure_ascii=False))
passed = sum(r[1] for r in results)
print('\nSUMMARY: %d/%d passed' % (passed, len(results)))
sys.exit(0 if passed == len(results) else 1)
