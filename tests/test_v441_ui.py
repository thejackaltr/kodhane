"""Kodhane v4.4.1 arayüz testi: sayı adlarının (Yazı r2, Bin ... Vigintilyon) dar ekranlarda taşmaması.

En uzun değer "999,99 Septendesilyon TL" (24 karakter, tl(999.99e54)). 360x640 ve 568x320'de şu yerler ölçülür
(her öğe için scrollWidth / clientWidth ve sayfa genişliği; OVERFLOW = test_v44_ui.py ile aynı ölçüm):
  kasa (üst sayaç), fiyat düğmeleri (Ekip + Geliştirme), sıralama satırı (leaderboard.js lb-score), Yatırım Turu paneli,
  bulut bildirimi (cloud.js "Çevrimdışı kazanç: +..." toast'ı), başarım metinleri.
Ekran görüntüleri: KODHANE_V441_SHOTS (varsayılan /workspace/kodhane-v44-audit). Ağ yok: oyun Playwright route ile depo
dosyalarından, Supabase/Umami sahte; gerçek adlar --host-resolver-rules ile kapalı porta yönlenir.
    python3 tests/test_v441_ui.py
"""
import json
import mimetypes
import os
import re
import sys
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


LB_ROWS = [
    {'rank': 1, 'nickname': 'Septendesilyoner2026', 'score': LONG, 'stage': 8, 'stage_id': 'mars_ofisi', 'is_me': False, 'status': 'ok'},
    {'rank': 2, 'nickname': 'ÇokUzunTakmaAdımVar', 'score': 999.99e51, 'stage': 7, 'stage_id': 'yapay_zeka_lab', 'is_me': False, 'status': 'ok'},
    {'rank': 3, 'nickname': 'Novemdesilyon Ajansı', 'score': 999.99e60, 'stage': 8, 'stage_id': 'mars_ofisi', 'is_me': False, 'status': 'ok'},
    {'rank': 4, 'nickname': 'ben', 'score': 999.99e63, 'stage': 8, 'stage_id': 'mars_ofisi', 'is_me': True, 'status': 'ok'},
]


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
        measure(pg, '%s/kasa' % vp, 'header.topbar', ['#money', '#rate', '.money-box'], 'v441-kasa-%s.png' % vp)
        # (b) üretim satırı = en uzun değer + "/sn" ("999,99 Septendesilyon TL/sn", 27 karakter)
        pg.evaluate("(L) => { const K = Kodhane, g = K.GENERATORS[0]; g.tps = 1; const per = K.baseTps(); g.tps = L / per; K.renderAll(); }", LONG)
        pg.wait_for_timeout(600)
        rate = pg.inner_text('#rate')
        check('[%s][kasa] rate line shows the longest value + /sn' % vp, rate == '999,99 Septendesilyon TL/sn', rate)
        oneline(pg, vp, '#money'); oneline(pg, vp, '#rate')
        measure(pg, '%s/kasa-uretim' % vp, 'header.topbar', ['#money', '#rate', '.money-box'], 'v441-kasa-uretim-%s.png' % vp)
        pg.evaluate("Kodhane.GENERATORS.forEach(g => { g.tps = g._tps; })")

        # 2) fiyat düğmeleri: her çalışanın ve görünen geliştirmelerin fiyatı en uzun değer (yalnız bu sayfada, test için)
        pg.evaluate("""(L) => { const K = Kodhane; K.GENERATORS.forEach(g => { g.base = L; });
            K.UPGRADES.forEach(u => { u.cost = L; }); K.state.money = L * 1.0000001; K.setView('ekip'); K.renderAll(); window.scrollTo(0, 0); }""", LONG)
        pg.wait_for_timeout(300)
        gl = pg.inner_text('#genList')
        check('[%s][fiyat] employee buttons show "999,99 Septendesilyon"' % vp, '999,99 Septendesilyon' in gl, gl[:200])
        measure(pg, '%s/fiyat-ekip' % vp, '#panelEkip', ['#genList button', '#genList .price', '#genList [class*=cost]'], 'v441-fiyat-ekip-%s.png' % vp)
        pg.evaluate("Kodhane.setView('upgrades'); Kodhane.renderAll(); window.scrollTo(0, 0)")
        pg.wait_for_timeout(300)
        up = pg.inner_text('#panelSide')
        check('[%s][fiyat] upgrade buttons show "999,99 Septendesilyon"' % vp, '999,99 Septendesilyon' in up, up[:200])
        measure(pg, '%s/fiyat-gelistirme' % vp, '#panelSide', ['#panelSide button'], 'v441-fiyat-gelistirme-%s.png' % vp)

        # 3) sıralama satırı (leaderboard.js rowNode -> .lb-score)
        pg.evaluate("Kodhane.setView('siralama'); Kodhane.leaderboard.refresh()")
        try:
            pg.wait_for_function("document.querySelectorAll('#lbList .lb-row').length >= 3", timeout=8000)
            got = pg.evaluate("[...document.querySelectorAll('.lb-score')].map(e => e.textContent)")
        except Exception as e:  # noqa: BLE001
            got = ['(sıralama yüklenmedi: %s)' % e]
        check('[%s][siralama] rows show full names incl. the longest value' % vp, '999,99 Septendesilyon TL' in got and '999,99 Vigintilyon TL' in ' '.join(got), got)
        pg.evaluate("document.getElementById('lbList').scrollIntoView({ block: 'start' })")
        r = measure(pg, '%s/siralama' % vp, '#panelSide', ['.lb-row', '.lb-score', '.lb-name'], 'v441-siralama-%s.png' % vp)
        names_w = [t['cw'] for t in r['targets'] if t['sel'] == '.lb-name']
        note('[%s][siralama] nickname visible widths (px, ellipsis): %s; score widths: %s' % (vp, names_w, [t['cw'] for t in r['targets'] if t['sel'] == '.lb-score']))
        check('[%s][siralama] nickname keeps >= 80 px next to the longest score' % vp, names_w and min(names_w) >= 80, names_w)

        # 4) Yatırım Turu paneli (prShares, prBonus, prGain, prNext)
        pg.evaluate("Kodhane.setView('prestige'); Kodhane.renderAll(); window.scrollTo(0, 0)")
        pg.wait_for_timeout(300)
        pr = pg.evaluate("['prShares', 'prBonus', 'prGain', 'prNext'].map(id => document.getElementById(id).textContent)")
        note('[%s][yatirim] %s' % (vp, json.dumps(pr, ensure_ascii=False)))
        check('[%s][yatirim] panel values use full names' % vp, all(not re.search(r'\d\s*(Mn|Mr|Tn|Kat|Kent)\b', x) for x in pr) and any(re.search(r'[a-zçğıöşü]ilyon', x) for x in pr), pr)
        measure(pg, '%s/yatirim' % vp, '#panelSide', ['#prShares', '#prBonus', '#prGain', '#prNext', '.stats dd'], 'v441-yatirim-turu-%s.png' % vp)

        # 5) bulut bildirimi (cloud.js: '☁️ Buluttaki kaydın yüklendi ... Çevrimdışı kazanç: +' + K.tl(gain))
        pg.evaluate("Kodhane.setView('kod'); window.scrollTo(0, 0); document.getElementById('toast').innerHTML = '';"
                    "Kodhane.toast('☁️ Buluttaki kaydın yüklendi (bu cihazdaki kayıt yedeklendi). Çevrimdışı kazanç: +' + Kodhane.tl(%r), 60000)" % LONG)
        pg.wait_for_timeout(400)
        tt = pg.inner_text('#toast')
        check('[%s][bulut] toast shows "+999,99 Septendesilyon TL"' % vp, '+999,99 Septendesilyon TL' in tt, tt)
        measure(pg, '%s/bulut-bildirim' % vp, '#toast', ['#toast > *'], 'v441-bulut-bildirim-%s.png' % vp)
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
        measure(pg, '%s/basarim' % vp, '#panelSide', ['#achGrid > *'], 'v441-basarim-%s.png' % vp)
        check('[%s] no page errors' % vp, not errs, errs)
        ctx.close()
    b.close()

note('measurements: ' + json.dumps(measures, ensure_ascii=False))
passed = sum(r[1] for r in results)
print('\nSUMMARY: %d/%d passed' % (passed, len(results)))
sys.exit(0 if passed == len(results) else 1)
