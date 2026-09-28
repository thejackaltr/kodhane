"""Kodhane v4 arayüz testleri (Playwright): aşama tebrik penceresi, paylaşım bağlantıları, Halka Arz bölümü,
Borsa Payı Ağacı, kilitli yeni çalışanlar, tek seferlik haberler ve anonim sayaç çağrıları.
Kendi yerel sunucusunu açar; Supabase yerine sahte bir uç nokta kullanılır (gerçek sunucuya istek gitmez).
    python3 tests/test_v4_ui.py
Ekran görüntüleri (sahte veriyle): screenshots/v4-hisse-agaci-mobile.png, screenshots/v4-asama-tebrik-mobile.png
"""
import functools
import json
import os
import sys
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = int(os.environ.get('KODHANE_V4_PORT', '8767'))
BASE = 'http://127.0.0.1:%d/' % PORT
URL = BASE + 'index.html'
SS = os.path.join(ROOT, 'screenshots') + os.sep
os.makedirs(SS, exist_ok=True)
FAKE = 'https://kodhane-v4test.supabase.co'
SAVE_KEY = 'kodhane_ajans_save_v2'


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(('127.0.0.1', PORT), functools.partial(QuietHandler, directory=ROOT))
threading.Thread(target=server.serve_forever, daemon=True).start()
results = []


def check(name, cond, info=''):
    results.append((name, bool(cond)))
    print(('PASS' if cond else 'FAIL'), name, '' if cond else info)


CORS = {'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': 'GET,POST,OPTIONS'}
events = []      # sayaç RPC çağrıları: (p_event, authorization başlığı)
real_hits = []   # gerçek sunucuya giden istek olmamalı


def fake(route):
    req = route.request
    if req.method == 'OPTIONS':
        return route.fulfill(status=204, headers=CORS, body='')
    path = req.url.split('?')[0][len(FAKE):]
    h = dict(CORS, **{'content-type': 'application/json'})
    if path == '/rest/v1/rpc/kodhane_count_event':
        body = json.loads(req.post_data or '{}')
        events.append((body.get('p_event'), req.headers.get('authorization', '')))
        return route.fulfill(status=200, headers=h, body=json.dumps(body.get('p_event') in ('news_leaderboard_shown', 'news_leaderboard_click')))
    if path == '/rest/v1/rpc/kodhane_leaderboard':
        return route.fulfill(status=200, headers=h, body='[]')
    return route.fulfill(status=401, headers=h, body=json.dumps({'message': 'JWT required'}))


def v3_save(**over):
    now = int(time.time() * 1000)
    d = {'version': 2, 'money': 5e8, 'runEarned': 3.2e9, 'totalEarned': 6e11, 'clicks': 900, 'clickEarned': 1e6, 'playTime': 40000,
         'startedAt': now - 4 * 86400000, 'lastSaved': now, 'gens': {'stajyer': 100, 'junior': 80, 'senior': 60, 'tasarimci': 40, 'pm': 30, 'ai': 20, 'sunucu': 10, 'ofis': 5},
         'upgrades': ['stajyer_1', 'junior_1'], 'shares': 40, 'prestigeCount': 3, 'boostLeft': 0, 'eventsClicked': 10, 'offlineEarned': 0, 'stage': 5,
         'buffs': [], 'achievements': ['tik_1', 'asama_5'], 'reputation': 5}
    d.update(over)
    return d


def seed(save):
    return "(() => { if (sessionStorage.getItem('v4_seeded')) return; sessionStorage.setItem('v4_seeded','1'); localStorage.setItem(%s, %s); })();" % (
        json.dumps(SAVE_KEY), json.dumps(json.dumps(save)))


with sync_playwright() as p:
    b = p.chromium.launch()

    def ctx_for(mobile=False, quiet=False, cloud=True, init=None):
        opts = dict(locale='tr-TR', service_workers='block')
        if mobile:
            opts.update(viewport={'width': 390, 'height': 844}, device_scale_factor=3, is_mobile=True, has_touch=True)
        else:
            opts.update(viewport={'width': 1280, 'height': 800})
        c = b.new_context(**opts)
        cfg = {'url': FAKE, 'key': 'sb_publishable_test'} if cloud else {'url': '', 'key': '__NOT_CONFIGURED__'}
        c.add_init_script('window.KODHANE_CLOUD_CONFIG = %s;%s' % (json.dumps(cfg), ' window.KODHANE_QUIET = true;' if quiet else ''))
        # Web Share yok: paylaşım panoya/bildirime düşer, metni Kodhane.lastShare üzerinden okuruz
        c.add_init_script("try { Object.defineProperty(navigator, 'share', { value: undefined, configurable: true }); } catch (e) {}")
        if init:
            c.add_init_script(init)
        c.route(FAKE + '/**', fake)
        c.route('https://supabase.teserix.com/**', lambda r: (real_hits.append(r.request.url), r.abort()))
        c.route('https://cdn.jsdelivr.net/**', lambda r: r.abort())
        return c

    def open_page(c):
        pg = c.new_page()
        errs = []
        pg.on('pageerror', lambda e: errs.append(str(e)))
        pg.goto(URL)
        pg.wait_for_selector('#clickBtn')
        pg.errs = errs
        return pg

    def modal_title(pg):
        return pg.evaluate("document.getElementById('modal').classList.contains('hidden') ? null : document.getElementById('modalTitle').textContent")

    # ------------------------------------------------------------ 1) aşama tebrik penceresi
    c = ctx_for()
    pg = open_page(c)
    ev = pg.evaluate
    ev("Kodhane.state.newsSeen = ['siralama']")  # bu bölümde haber araya girmesin
    check('fresh game: no stage-up overlay', ev("document.getElementById('stageUp').classList.contains('hidden')"))
    ev("Kodhane.earn(1000)")
    pg.wait_for_selector('#stageUp:not(.hidden)', timeout=3000)
    check('first Ev Ofisi: full-screen overlay with copy',
          pg.inner_text('#suTitle') == 'Ev Ofisi' and pg.text_content('#suKicker') == 'Yeni aşama' and
          pg.inner_text('#suMsg') == ev("Kodhane.STAGES[1].msg") and pg.inner_text('#suBonus') == '+%10 üretim', pg.inner_text('#stageUp'))
    box = pg.locator('#stageUp').bounding_box()
    check('overlay covers the viewport', box and box['width'] >= 1280 and box['height'] >= 800, str(box))
    check('stage tint applied', ev("getComputedStyle(document.documentElement).getPropertyValue('--stage-tint').trim()") == ev("Kodhane.STAGE_TINTS[1]"))
    pg.click('#suShare')
    check('share text with separate UTM campaign',
          ev('Kodhane.lastShare') == "Kodhane'de artık Ev Ofisi aşamasındayım! Sen de ajansını kur: " + BASE + '?utm_source=paylasim&utm_medium=sosyal&utm_campaign=asama_paylasim',
          ev('Kodhane.lastShare'))
    pg.click('#suClose')
    check('Devam closes the overlay', ev("document.getElementById('stageUp').classList.contains('hidden')"))
    ev("Kodhane.CFG.stageModalSec = 0.4; Kodhane.earn(60000)")
    pg.wait_for_selector('#stageUp:not(.hidden)', timeout=3000)
    t1 = pg.inner_text('#suTitle')
    pg.wait_for_selector('#stageUp.hidden', state='attached', timeout=3000)
    check('overlay closes itself after CFG.stageModalSec', t1 == 'Butik Stüdyo')
    # yeni tur gibi: tur kazancı ve aşama sıfır, en iyi aşama korunur
    ev("Kodhane.CFG.stageModalSec = 7; const d = JSON.parse(JSON.stringify(Kodhane.state)); d.runEarned = 0; d.stage = 0; d.money = 0; Kodhane.applySave(d)")
    ev("Kodhane.earn(1000)")
    pg.wait_for_timeout(400)
    check('stage reached again in a later round: toast only, no overlay',
          ev("document.getElementById('stageUp').classList.contains('hidden')"), pg.inner_text('#toast'))
    check('stageBest tracked', ev('Kodhane.state.stageBest') == 2)
    check('no page errors (stage-up)', not pg.errs, '; '.join(pg.errs))
    c.close()

    # ------------------------------------------------------------ 2) Halka Arz + ağaç (masaüstü)
    c = ctx_for(quiet=True)
    pg = open_page(c)
    ev = pg.evaluate
    ev("Kodhane.selectTab('prestige')")
    check('IPO section locked with blur', ev("document.getElementById('ipoSection').classList.contains('locked')") and
          'blur' in ev("getComputedStyle(document.getElementById('ipoBody')).filter"), ev("getComputedStyle(document.getElementById('ipoBody')).filter"))
    check('lock text', pg.inner_text('#ipoLock') == '🔒 3 yatırım turundan sonra açılır. (0/3)', pg.inner_text('#ipoLock'))
    check('IPO button disabled while locked', pg.is_disabled('#ipoBtn') and pg.inner_text('#ipoBtn') == 'Halka arz et')
    check('tree visible (blurred) with 12 nodes and titles', ev("document.querySelectorAll('#treeGrid .tree-node').length") == 12 and 'Borsa Payı Ağacı' in pg.inner_text('#ipoSection'))
    ev("Kodhane.state.cycleRounds = 2; Kodhane.renderAll()")
    check('lock progress (2/3)', pg.inner_text('#ipoLock').endswith('(2/3)'))
    ev("Kodhane.state.cycleRounds = 3; Kodhane.state.cycleEarned = 8e14; Kodhane.state.totalEarned = 9e14; Kodhane.state.runEarned = 1e9; Kodhane.renderAll()")
    check('unlocked after 3 rounds', not ev("document.getElementById('ipoSection').classList.contains('locked')") and not pg.is_disabled('#ipoBtn') and pg.inner_text('#ipoGain') == '2 Borsa Payı')
    total0 = ev('Kodhane.state.totalEarned')
    pg.click('#ipoBtn')
    check('confirm modal copy', modal_title(pg) == 'Halka arz et?' and
          'Kasa, çalışanlar ve ofis sıfırlanacak. Karşılığında kalıcı Borsa Payı kazanacaksın. Sıralamadaki puanın olduğu gibi kalır.' in pg.inner_text('#modalText'), pg.inner_text('#modalText'))
    pg.click('#modalActions button:has-text("Vazgeç")')
    check('cancel keeps everything', ev('Kodhane.state.ipoCount') == 0 and ev('Kodhane.state.cycleRounds') == 3)
    pg.click('#ipoBtn'); pg.click('#modalActions button:has-text("Halka arz et")')
    check('done modal copy', modal_title(pg) == 'Borsa zili çaldı!' and pg.inner_text('#modalText') == 'Artık halka açık bir şirketsin. Borsa Payların: 2', pg.inner_text('#modalText'))
    check('IPO keeps the leaderboard score (totalEarned)', ev('Kodhane.state.totalEarned') >= total0 and ev('Kodhane.state.ipoCount') == 1)
    check('Borsa Zili unlocked', 'borsa_zili' in ev('Kodhane.state.achievements'))
    pg.click('#modalActions button:has-text("Paylaş")')
    check('IPO share text with its own UTM campaign', ev('Kodhane.lastShare') == "Kodhane'de şirketimi halka arz ettim, borsa zili çaldı! " + BASE + '?utm_source=paylasim&utm_medium=sosyal&utm_campaign=halka_arz', ev('Kodhane.lastShare'))
    check('locked again after IPO', ev("document.getElementById('ipoSection').classList.contains('locked')"))
    node = lambda i: pg.locator('#treeGrid [data-node="%s"]' % i)
    check('node texts: ready / locked', node('kod_1').locator('.tn-state').inner_text() == '1 Borsa Payı ile al' and
          node('kod_2').locator('.tn-state').inner_text() == 'Önce Parmak Hızı gerekli.', node('kod_1').inner_text())
    ev("Kodhane.state.cycleRounds = 3; Kodhane.renderAll()")  # ağaç kilitli bölümde bulanık; alım için bölümü aç
    node('kod_1').click()
    check('buy node via UI', ev("Kodhane.state.tree") == ['kod_1'] and ev('Kodhane.state.ipoShares') == 1 and
          node('kod_1').locator('.tn-state').inner_text() == 'Alındı! Bu bonus artık kalıcı.', node('kod_1').inner_text())
    check('poor node text', node('kod_2').locator('.tn-state').inner_text() == '3 Borsa Payı gerekiyor. Bir halka arz daha?' and node('kod_2').is_disabled())
    check('node desc shown from settings', "×2." in node('kod_1').inner_text())
    pg.reload(); pg.wait_for_selector('#clickBtn')
    check('tree and Borsa Payı persist after reload', ev('Kodhane.state.tree') == ['kod_1'] and ev('Kodhane.state.ipoShares') == 1 and ev('Kodhane.state.ipoCount') == 1)
    ev("Kodhane.selectTab('prestige'); Kodhane.state.tree = ['yatirim_1', 'yatirim_2']; Kodhane.renderAll()")
    check('Yatırım Turu intro shows the boosted share bonus', pg.inner_text('#prPer') == '+%12,5', pg.inner_text('#prPer'))
    # kilitli yeni çalışan satırı
    ev("Kodhane.GENERATORS.forEach(g => { if (!g.stage) Kodhane.state.gens[g.id] = 1; }); Kodhane.renderAll()")
    txt = ev("document.querySelector('#genList [data-gen=arge]').textContent")
    check('only the next new employee is teased', ev("document.querySelector('#genList [data-gen=yzlab]').classList.contains('hidden')"))
    check('new employee row locked until Teknoloji Devi', 'Teknoloji Devi aşamasında açılır' in txt, txt[:200])
    check('no page errors (IPO)', not pg.errs, '; '.join(pg.errs))
    c.close()

    # ------------------------------------------------------------ 3) haberler: yeni oyuncu, tek sefer, sayaç
    events.clear()
    c = ctx_for()
    pg = open_page(c)
    ev = pg.evaluate
    check('news waits a few seconds', modal_title(pg) is None)
    pg.wait_for_function("!document.getElementById('modal').classList.contains('hidden')", timeout=9000)
    check('new player: Sıralama news', modal_title(pg) == 'Yeni: Sıralama!' and
          pg.inner_text('#modalText') == 'Toplam kazancınla listeye gir. Yatırım turu yapsan da yerin korunur.' and
          [x.strip() for x in pg.locator('#modalActions button').all_inner_texts()] == ['Kapat', 'Sıralamaya bak'], pg.inner_text('#modal'))
    check('flag saved right away (survives a closed tab)', 'siralama' in json.loads(ev("localStorage.getItem(%s)" % json.dumps(SAVE_KEY)))['newsSeen'])
    pg.wait_for_timeout(300)
    check('shown event counted anonymously (anon key, no user token)', events and events[0][0] == 'news_leaderboard_shown' and events[0][1] == 'Bearer sb_publishable_test', events)
    pg.click('#modalActions button:has-text("Sıralamaya bak")')
    pg.wait_for_timeout(300)
    check('"Sıralamaya bak" opens the Sıralama tab', ev('Kodhane.activeTab()') == 'siralama' and pg.is_visible('#tab-siralama'))
    check('click event counted', [e[0] for e in events] == ['news_leaderboard_shown', 'news_leaderboard_click'], events)
    pg.reload(); pg.wait_for_selector('#clickBtn'); pg.wait_for_timeout(5500)
    check('once only: not shown again after reload', modal_title(pg) is None and ev('Kodhane.lastNews') is None and len(events) == 2)
    check('no page errors (news)', not pg.errs, '; '.join(pg.errs))
    c.close()

    # Global Holding oyuncusu (oyun v3 kaydı): önce yeni aşama haberi, aynı oturumda ikinci haber yok, sonra Sıralama
    events.clear()
    c = ctx_for(init=seed(v3_save()))
    pg = open_page(c)
    ev = pg.evaluate
    pg.wait_for_function("!document.getElementById('modal').classList.contains('hidden')", timeout=9000)
    # ilk modal, göç bildirimi veya tekrar hoş geldin olabilir; haberi bekle
    for _ in range(3):
        if modal_title(pg) == 'Global Holding son durak değilmiş.':
            break
        pg.click('#modalActions button >> nth=-1')
        pg.wait_for_timeout(5000)
    check('GH player: new-stage news first', modal_title(pg) == 'Global Holding son durak değilmiş.' and pg.inner_text('#modalText') == 'Yeni aşama açıldı: Teknoloji Devi.', str(modal_title(pg)))
    pg.click('#modalActions button >> nth=-1')
    pg.wait_for_timeout(5500)
    check('max one news per session', modal_title(pg) is None and ev('Kodhane.newsSession.shown') == 1 and not events, events)
    check('migrated save keeps its progress', ev('Kodhane.state.gens.ofis') == 5 and ev('Kodhane.state.shares') == 40 and ev('Kodhane.state.cycleRounds') == 3)
    pg.reload(); pg.wait_for_selector('#clickBtn')
    pg.wait_for_function("!document.getElementById('modal').classList.contains('hidden')", timeout=9000)
    check('next session: Sıralama news', modal_title(pg) == 'Yeni: Sıralama!', str(modal_title(pg)))
    pg.click('#modalActions button:has-text("Kapat")')
    check('"Kapat" counts only the shown event', [e[0] for e in events] == ['news_leaderboard_shown'], events)
    pg.reload(); pg.wait_for_selector('#clickBtn'); pg.wait_for_timeout(5500)
    check('third session: no news left', modal_title(pg) is None and sorted(ev('Kodhane.state.newsSeen')) == ['siralama', 'yeni_asama'])
    c.close()

    # Mobil: haber düğmesi Sıralama görünümünü açar
    c = ctx_for(mobile=True)
    pg = open_page(c)
    pg.wait_for_function("!document.getElementById('modal').classList.contains('hidden')", timeout=9000)
    pg.tap('#modalActions button:has-text("Sıralamaya bak")')
    pg.wait_for_timeout(300)
    check('mobile: "Sıralamaya bak" opens the Sıralama view', pg.evaluate('document.body.dataset.view') == 'siralama' and pg.is_visible('#tab-siralama'))
    c.close()

    # Sıralama kullanılamıyorsa (bulut yapılandırılmamış) haber gösterilmez, sayaç çağrılmaz
    events.clear()
    c = ctx_for(cloud=False)
    pg = open_page(c)
    pg.wait_for_timeout(5500)
    check('no leaderboard configured: no Sıralama news, no counter call', modal_title(pg) is None and not events)
    c.close()

    # ------------------------------------------------------------ 4) ekran görüntüleri (mobil, sahte veri)
    c = ctx_for(mobile=True, quiet=True)
    pg = open_page(c)
    ev = pg.evaluate
    ev("""(() => { const S = Kodhane.state; S.prestigeCount = 7; S.cycleRounds = 3; S.shares = 120; S.ipoCount = 2; S.ipoSharesEarned = 9;
      S.tree = ['kod_1', 'kod_2', 'ekip_1', 'yatirim_1']; S.ipoShares = 4; S.cycleEarned = 2.7e15; S.totalEarned = 4.1e16; S.runEarned = 3e12;
      S.stage = 5; S.stageBest = 6; S.newsSeen = ['siralama', 'yeni_asama']; Kodhane.renderAll(); })()""")
    pg.tap('#bottomNav [data-view="prestige"]')
    ev("Kodhane.selectTab('prestige')")
    pg.wait_for_timeout(300)
    pg.wait_for_timeout(600)
    ev("document.getElementById('ipoSection').scrollIntoView({block: 'start'}); window.scrollBy(0, -80); document.getElementById('toast').innerHTML = ''")
    pg.wait_for_timeout(300)
    pg.screenshot(path=SS + 'v4-hisse-agaci-mobile.png')
    check('screenshot: tree (mobile)', os.path.getsize(SS + 'v4-hisse-agaci-mobile.png') > 20000)
    c.close()
    c = ctx_for(mobile=True)
    pg = open_page(c)
    ev = pg.evaluate
    ev("Kodhane.state.newsSeen = ['siralama']; Kodhane.state.stageBest = 7; Kodhane.state.stage = 7; Kodhane.state.runEarned = Kodhane.STAGES[7].at; Kodhane.renderAll()")
    ev("Kodhane.earn(Kodhane.STAGES[8].at)")
    pg.wait_for_selector('#stageUp:not(.hidden)', timeout=3000)
    ev("Kodhane.CFG.stageModalSec = 60")
    pg.wait_for_timeout(700)
    ev("document.getElementById('toast').innerHTML = ''")
    pg.wait_for_timeout(200)
    check('Mars overlay', pg.inner_text('#suTitle') == 'Mars Ofisi' and ev("getComputedStyle(document.documentElement).getPropertyValue('--stage-tint').trim()") == ev('Kodhane.STAGE_TINTS[8]'))
    pg.screenshot(path=SS + 'v4-asama-tebrik-mobile.png')
    check('screenshot: stage-up (mobile)', os.path.getsize(SS + 'v4-asama-tebrik-mobile.png') > 20000)
    c.close()

    check('never touched the real Supabase', not real_hits, real_hits)
    b.close()

server.shutdown()
ok = sum(1 for _, r in results if r)
print('\n%d/%d passed' % (ok, len(results)))
sys.exit(0 if ok == len(results) else 1)
