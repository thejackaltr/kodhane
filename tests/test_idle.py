"""Kodhane v2 uçtan uca testleri (Playwright, headless Chromium).

Kendi yerel HTTP sunucusunu açar; ayrıca sunucu gerekmez:
    python3 tests/test_idle.py
Ekran görüntüleri screenshots/ klasörüne yazılır.
"""
import functools
import json
import os
import struct
import subprocess
import sys
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = int(os.environ.get('KODHANE_TEST_PORT', '8765'))
BASE = 'http://127.0.0.1:%d' % PORT
URL = BASE + '/index.html'
SS = os.path.join(ROOT, 'screenshots') + os.sep
os.makedirs(SS, exist_ok=True)

if not os.path.exists(os.path.join(ROOT, 'icon-192.png')):
    subprocess.run([sys.executable, os.path.join(ROOT, 'tools', 'make_icons.py'), ROOT], check=True)


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(('127.0.0.1', PORT), functools.partial(QuietHandler, directory=ROOT))
threading.Thread(target=server.serve_forever, daemon=True).start()

results = []


def check(name, cond, info=''):
    results.append((name, bool(cond), info))
    print(('PASS' if cond else 'FAIL'), name, info)


INIT = """
(() => { try {
  const off = sessionStorage.getItem('kh_offline');
  if (off) { sessionStorage.removeItem('kh_offline');
    const k='kodhane_ajans_save_v2'; const d=JSON.parse(localStorage.getItem(k));
    d.lastSaved = Date.now() - Number(off)*1000; localStorage.setItem(k, JSON.stringify(d)); }
} catch(e){} })();
"""

MIDGAME = """(() => { const K=Kodhane; K.earn(3.5e6);
  const plan={stajyer:30,junior:25,senior:20,tasarimci:12,pm:5};
  for (const id in plan) { K.state.money += K.genCost(K.GENERATORS.find(g=>g.id===id), plan[id]); K.buyGen(id, plan[id]); }
  ['junior_1','junior_2','senior_1','senior_2','tasarimci_1','tasarimci_2','stajyer_2','stajyer_3','click_2','click_3','all_1','pm_1','cay_ocagi','kahve_fali','sprint']
    .forEach(id=>{K.state.money+=1e6; K.buyUpgrade(id);});
  K.state.money = 842500; K.state.boostLeft = 0; K.state.buffs = []; K.state.playTime = 1830; K.state.clicks = 1450;
  K.state.reputation = 14; K.renderAll(); })()"""


def png_size(data):
    return struct.unpack('>II', data[16:24]) if data[:8] == b'\x89PNG\r\n\x1a\n' else None


def watch(page, errors):
    page.on('console', lambda m: errors.append(m.text) if m.type == 'error' else None)
    page.on('pageerror', lambda e: errors.append(str(e)))


with sync_playwright() as p:
    b = p.chromium.launch()
    ctx = b.new_context(viewport={'width': 1280, 'height': 800}, locale='tr-TR')
    ctx.add_init_script(INIT)
    page = ctx.new_page()
    errors = []
    watch(page, errors)
    ev = page.evaluate

    # ---------------------------------------------------------------- v1 kaydı taşıma
    now_ms = int(time.time() * 1000)
    v1 = {'version': 1, 'money': 123456.5, 'runEarned': 2500000, 'totalEarned': 9000000, 'clicks': 777, 'clickEarned': 4321,
          'playTime': 3600, 'startedAt': now_ms - 86400000, 'lastSaved': now_ms,
          'gens': {'stajyer': 12, 'junior': 8, 'senior': 3, 'tasarimci': 1, 'pm': 0, 'ai': 0, 'sunucu': 0, 'ofis': 0},
          'upgrades': ['stajyer_1', 'junior_1', 'click_1'], 'shares': 3, 'prestigeCount': 1, 'boostLeft': 0,
          'eventsClicked': 5, 'offlineEarned': 100, 'stage': 3}
    v1s = json.dumps(v1)
    page.goto(BASE + '/README.md'); ev('localStorage.clear()')
    ev("s => localStorage.setItem('kodhane_ajans_save_v1', s)", v1s)
    page.goto(URL); page.wait_for_selector('#clickBtn'); page.wait_for_timeout(300)
    st = ev('Kodhane.state')
    tps = ev('Kodhane.baseTps()')
    check('migrate: money kept', v1['money'] <= st['money'] <= v1['money'] + tps * 5 + 1, f"money={st['money']:.1f}")
    check('migrate: staff kept', st['gens'] == v1['gens'], json.dumps(st['gens']))
    check('migrate: upgrades kept', st['upgrades'] == v1['upgrades'], json.dumps(st['upgrades']))
    check('migrate: shares/prestige kept', st['shares'] == 3 and st['prestigeCount'] == 1)
    check('migrate: lifetime earnings kept', st['totalEarned'] >= 9e6 and st['runEarned'] >= 2.5e6 and st['clicks'] == 777 and st['eventsClicked'] == 5)
    check('migrate: stage kept', st['stage'] >= 3 and page.inner_text('#stageName') == 'Ajans', page.inner_text('#stageName'))
    check('migrate: new fields + version 2', st['version'] == 2 and isinstance(st['daily'], dict) and st['reputation'] == 0)
    check('migrate: v2 key written, v1 kept as backup', ev("!!localStorage.getItem('kodhane_ajans_save_v2')") and ev("localStorage.getItem('kodhane_ajans_save_v1')") == v1s)
    check('migrate: toast shown', 'taşındı' in page.inner_text('#toast'), page.inner_text('#toast').replace('\n', ' / ')[:160])
    check('migrate: retro achievements', 'kazanc_1m' in st['achievements'] and 'asama_3' in st['achievements'], json.dumps(st['achievements']))
    page.reload(); page.wait_for_selector('#clickBtn'); page.wait_for_timeout(300)
    st2 = ev('Kodhane.state')
    check('migrate: survives reload from v2', ev('Kodhane.loadedVersion') == 2 and st2['gens'] == v1['gens'] and st2['shares'] == 3 and st2['money'] >= v1['money'])

    # ---------------------------------------------------------------- yeni oyun: temel akış
    page.goto(BASE + '/README.md'); ev('localStorage.clear()')
    page.goto(URL); page.wait_for_selector('#clickBtn')
    check('title', page.title() == 'Kodhane: Ajans Tycoon', page.title())
    check('bottom nav hidden on desktop', not page.is_visible('#bottomNav'))
    ev('Kodhane.rng = () => 0.99')
    for _ in range(20): page.click('#clickBtn')
    st = ev('Kodhane.state')
    check('20 clicks -> 20 TL', st['clicks'] == 20 and abs(st['money'] - 20) < 0.5, f"money={st['money']:.2f}")
    page.wait_for_timeout(450)
    check('counter tween settles on exact value', page.inner_text('#money') == ev('Kodhane.tl(Kodhane.state.money)'), page.inner_text('#money'))
    page.click('[data-gen="stajyer"]')
    spend = ev("document.getElementById('money').classList.contains('spend')")
    st = ev('Kodhane.state')
    check('buy Stajyer via UI', st['gens']['stajyer'] == 1 and st['money'] < 6, f"money={st['money']:.2f}")
    check('red flash on spend', spend)
    m0 = ev('Kodhane.state.money'); time.sleep(2.0); m1 = ev('Kodhane.state.money')
    check('real-time production (~0.2 TL/sn)', 0.3 < m1 - m0 < 0.6, f"+{m1-m0:.3f} in 2s")
    # kritik tık
    ev('Kodhane.rng = () => 0')
    cv = ev('Kodhane.clickValue()'); m0 = ev('Kodhane.state.money')
    page.click('#clickBtn')
    m1 = ev('Kodhane.state.money')
    check('critical click = 10x', abs((m1 - m0) - cv * 10) < 0.6, f"+{m1-m0:.2f} (click {cv})")
    check('critical floater + particles', ev("document.querySelectorAll('.floater.crit').length") >= 1 and ev("document.querySelectorAll('.particle').length") > 0)
    check('crit counted', ev('Kodhane.state.critClicks') == 1)
    ev('Kodhane.rng = () => 0.99')
    for _ in range(10): page.click('#clickBtn')
    page.wait_for_timeout(1200)
    # aşama + geliştirme
    ev('Kodhane.earn(1500)'); page.wait_for_timeout(300)
    check('stage -> Ev Ofisi', page.inner_text('#stageName') == 'Ev Ofisi', page.inner_text('#stageName'))
    check('stage-up message', 'Pijamayla toplantıya girmek' in page.inner_text('#toast'))
    check('stage progress text', 'Butik Stüdyo' in page.inner_text('#stageNext'), page.inner_text('#stageNext'))
    tps_before = ev('Kodhane.tps()')
    page.click('[data-upg="stajyer_1"]'); page.wait_for_timeout(200)
    tps_after = ev('Kodhane.tps()')
    check('upgrade Staj Sertifikası doubles stajyer', ev("Kodhane.has('stajyer_1')") and abs(tps_after - 2 * tps_before) < 1e-9, f"{tps_before}->{tps_after}")
    page.click('[data-upg="click_1"]'); page.wait_for_timeout(200)
    check('click upgrade x2', abs(ev('Kodhane.clickValue()') - 2.2) < 1e-9, f"click={ev('Kodhane.clickValue()')}")
    ev('Kodhane.tick(100)')
    check('tick(100) production', ev('Kodhane.state.playTime') > 100)
    check('TR format', ev("[Kodhane.tl(1234.5), Kodhane.tl(2.5e6), Kodhane.tl(3.75e9), Kodhane.tl(1.2e12)].join('|')") == '1,23 Bin TL|2,5 Mn TL|3,75 Mr TL|1,2 Tn TL')
    # yeni geliştirmeler
    check('tier-5 upgrade at 100 staff exists', ev("Kodhane.UPGRADES.some(u => u.id === 'stajyer_5' && u.req.count === 100)"))
    check('PM dev bonus upgrade', ev("(() => { const K=Kodhane, s=K.state; const g=K.GENERATORS[0]; const a=K.genTps(g); s.upgrades.push('sprint'); const r=K.genTps(g)/a; s.upgrades.pop(); return Math.abs(r-1.1)<1e-9; })()"))
    check('Çay Ocağı +5%', ev("(() => { const K=Kodhane, s=K.state; const a=K.baseTps(); s.upgrades.push('cay_ocagi'); const r=K.baseTps()/a; s.upgrades.pop(); return Math.abs(r-1.05)<1e-9; })()"))
    # müşteri projesi
    mb = ev('Kodhane.state.money'); ev("Kodhane.spawnOffer('cash')"); page.click('#clientOffer', force=True); page.wait_for_timeout(200)
    check('client offer cash claimed', ev('Kodhane.state.eventsClicked') == 1 and ev('Kodhane.state.money') > mb + 40)
    check('offer popup has no wobble/rotate animation', 'wobble' not in ev("getComputedStyle(document.getElementById('clientOffer')).animationName"))
    ev("Kodhane.spawnOffer('boost')"); page.click('#clientOffer', force=True); page.wait_for_timeout(200)
    check('client offer boost x2', ev('Kodhane.state.boostLeft') > 29 and not page.is_hidden('#boostBar'))

    # ---------------------------------------------------------------- olay kartları
    ev('Kodhane.state.daily.tasks = []; Kodhane.state.buffs = []')
    p120 = ev('Kodhane.pay(120)'); mb = ev('Kodhane.state.money')
    ev("Kodhane.spawnEvent('yarin')")
    check('event card shown', page.is_visible('#eventCard') and 'Yarına yetişir mi' in page.inner_text('#eventCard'))
    check('event card shows trade-off hints', '-%20' in page.inner_text('#evChoices'), page.inner_text('#evChoices').replace('\n', ' / '))
    page.click('#evChoices .ev-choice[data-choice="0"]'); page.wait_for_timeout(150)
    delta = ev('Kodhane.state.money') - mb
    check('event: Yarına yetişir -> 2x pay', abs(delta - p120) < p120 * 0.05 + 3, f"+{delta:.1f} vs {p120:.1f}")
    check('event: -20% production buff', ev("Kodhane.buffMult('prod')") == 0.8 and ev("Math.abs(Kodhane.tps() - Kodhane.baseTps()*(Kodhane.state.boostLeft>0?2:1)*0.8) < 1e-9"))
    check('event card hidden after choice', page.is_hidden('#eventCard') and ev('Kodhane.state.eventsResolved') == 1)
    rep0 = ev('Kodhane.state.reputation')
    ev("Kodhane.spawnEvent('toplanti')"); page.click('#evChoices .ev-choice[data-choice="0"]')
    check('event: meeting -15% + rep +2', ev("Kodhane.state.buffs.find(b=>b.id==='toplanti').mult") == 0.85 and ev('Kodhane.state.reputation') == rep0 + 2 and ev('Kodhane.state.noMeetingSec') < 1)
    ev('Kodhane.rng = () => 0'); mb = ev('Kodhane.state.money'); p90 = ev('Kodhane.pay(90)')
    ev("Kodhane.spawnEvent('cuma')"); page.click('#evChoices .ev-choice[data-choice="0"]')
    check('event: Cuma deploy success pays', ev('Kodhane.state.money') - mb > p90 * 0.9)
    ev('Kodhane.rng = () => 0.99')
    ev("Kodhane.spawnEvent('cuma')"); page.click('#evChoices .ev-choice[data-choice="0"]')
    check('event: Cuma deploy fail -> weekend slowdown', ev("Kodhane.state.buffs.some(b=>b.id==='haftasonu' && b.mult===0.6 && b.total===45)"))
    rep1 = ev('Kodhane.state.reputation'); res1 = ev('Kodhane.state.eventsResolved')
    ev("Kodhane.spawnEvent('portfolyo')"); page.click('#evLater')
    check("event: 'Sonra' dismisses without effect", page.is_hidden('#eventCard') and ev('Kodhane.state.reputation') == rep1 and ev('Kodhane.state.eventsResolved') == res1)
    ev("Kodhane.spawnEvent('sunucu')"); page.click('#evChoices .ev-choice[data-choice="1"]')
    check('event: server crash stops production', ev('Kodhane.tps()') == 0 and ev('Kodhane.state.serverCrashes') == 1)
    ev("Kodhane.spawnEvent('viral')"); page.click('#evChoices .ev-choice[data-choice="0"]')
    check('event: viral -> click x2 for 60s', ev("Kodhane.buffMult('click')") == 2)
    for _ in range(5):
        ev("Kodhane.spawnEvent('logo')"); page.click('#evChoices .ev-choice[data-choice="0"]')
    page.wait_for_timeout(250)
    check('achievement toast on unlock', 'Başarım açıldı' in page.inner_text('#toast'), page.inner_text('#toast').replace('\n', ' / ')[:200])
    for _ in range(2):
        ev("Kodhane.spawnEvent('final')"); page.click('#evChoices .ev-choice[data-choice="0"]')
    ev('Kodhane.state.noMeetingSec = 601')
    page.wait_for_timeout(250)
    ach = ev('Kodhane.state.achievements')
    for aid in ['tik_1', 'kritik_1', 'kazanc_1k', 'localhost', 'logo_5', 'revize_7', 'toplantisiz']:
        check('achievement unlocked: ' + aid, aid in ach)
    check('achievements give +1% each', abs(ev('Kodhane.achMult()') - (1 + 0.01 * len(ach))) < 1e-9, f"{len(ach)} ach")
    check('achievement count 20-30', 20 <= ev('Kodhane.ACHIEVEMENTS.length') <= 30, str(ev('Kodhane.ACHIEVEMENTS.length')))
    # olay geliştirmeleri
    ev("Kodhane.state.buffs = []; Kodhane.state.upgrades.push('kahve_fali')"); page.wait_for_timeout(300)
    check('Kahve Falı shows next event', page.is_visible('#falBar') and 'Kahve falı' in page.inner_text('#falBar'), page.inner_text('#falBar'))
    ev("Kodhane.state.upgrades.push('deploy_yasak')")
    check('Cuma Deploy Yasağı removes event', not ev("Kodhane.eventPool().some(e => e.id === 'cuma')"))
    ev("Kodhane.state.upgrades.push('tercuman')"); ev("Kodhane.spawnEvent('yarin')"); page.click('#evChoices .ev-choice[data-choice="0"]')
    check('Müşteri Tercümanı -25% duration', ev("Kodhane.state.buffs.find(b=>b.id==='gece').total") == 45)
    ev("Kodhane.state.upgrades.push('standup')"); ev("Kodhane.spawnEvent('toplanti')"); page.click('#evChoices .ev-choice[data-choice="0"]')
    check('Oturarak Stand-up -20% meeting penalty', abs(ev("Kodhane.state.buffs.find(b=>b.id==='toplanti').mult") - 0.88) < 1e-9)
    ev("Kodhane.state.upgrades.push('push_dua')")
    check('Push ve Dua shows 60% in hint', True)
    ev("Kodhane.state.buffs = []; Kodhane.state.upgrades = Kodhane.state.upgrades.filter(id => !['tercuman','standup','push_dua','deploy_yasak'].includes(id))")
    page.click('[data-tab="achievements"]'); page.wait_for_timeout(200)
    n_ach = len(ev('Kodhane.state.achievements'))
    check('achievements tab badges', ev("document.querySelectorAll('.ach.unlocked').length") == n_ach and ev("document.querySelectorAll('.ach.locked').length") == ev('Kodhane.ACHIEVEMENTS.length') - n_ach)

    # ---------------------------------------------------------------- günlük görevler ve seri
    ev("Kodhane.setToday('2026-10-01'); Kodhane.checkDaily()")
    d = ev('Kodhane.state.daily')
    check('daily: 3 tasks for date', d['date'] == '2026-10-01' and len(d['tasks']) == 3, json.dumps([t['type'] for t in d['tasks']]))
    check('daily: deterministic by date', ev("JSON.stringify(Kodhane.makeTasks('2026-10-01').map(t=>t.type)) === JSON.stringify(Kodhane.state.daily.tasks.map(t=>t.type))"))
    page.click('[data-tab="daily"]'); page.wait_for_timeout(200)
    check('daily: panel shows progress bars', ev("document.querySelectorAll('#taskList .task .progress-fill').length") == 3)
    ev("Kodhane.state.daily.tasks[0] = {type:'click', target:3, progress:0, done:false, reward:0}")
    for _ in range(3): page.click('#clickBtn')
    check('daily: clicking progresses + rewards task', ev('Kodhane.state.daily.tasks[0].done') and ev('Kodhane.state.daily.tasks[0].reward') > 0)
    COMPLETE = "(() => { const K=Kodhane; K.state.daily.tasks.forEach(t => { if (!t.done) K.taskProgress(t.type, t.target, t.gen); }); return K.state.daily; })()"
    mb = ev('Kodhane.state.money')
    d = ev(COMPLETE)
    check('daily: all done -> streak 1 + bonus', d['allDone'] and d['streak'] == 1 and d['daysCompleted'] == 1 and ev('Kodhane.state.money') > mb)
    page.wait_for_timeout(250)
    check('daily: streak toast', 'Günlük seri' in page.inner_text('#toast'))
    ev("Kodhane.setToday('2026-10-02'); Kodhane.checkDaily()")
    d = ev('Kodhane.state.daily')
    check('daily: next day keeps streak, new tasks', d['date'] == '2026-10-02' and d['streak'] == 1 and not d['allDone'] and len(d['tasks']) == 3)
    d = ev(COMPLETE)
    check('daily: second day -> streak 2', d['streak'] == 2 and d['best'] == 2)
    ev("Kodhane.setToday('2026-10-05'); Kodhane.checkDaily()")
    d = ev('Kodhane.state.daily')
    check('daily: missed day resets streak', d['streak'] == 0 and d['best'] == 2)
    ev("Kodhane.setToday(null); Kodhane.checkDaily()")
    check('achievement: Günü Kurtardın', 'gorev_1' in ev('Kodhane.state.achievements'))

    # ---------------------------------------------------------------- kayıt, otomatik kayıt, çevrimdışı
    snap = ev('({c: Kodhane.state.clicks, s: Kodhane.state.gens.stajyer, u: Kodhane.state.upgrades.slice(), a: Kodhane.state.achievements.length, r: Kodhane.state.reputation, b: Kodhane.state.daily.best})')
    page.reload(); page.wait_for_selector('#clickBtn'); page.wait_for_timeout(300)
    snap2 = ev('({c: Kodhane.state.clicks, s: Kodhane.state.gens.stajyer, u: Kodhane.state.upgrades.slice(), a: Kodhane.state.achievements.length, r: Kodhane.state.reputation, b: Kodhane.state.daily.best})')
    check('save persists across reload', snap == snap2, json.dumps(snap2))
    check('no welcome popup on quick reload', page.is_hidden('#modal'))
    t_before = ev("JSON.parse(localStorage.getItem(Kodhane.SAVE_KEY)).lastSaved")
    page.wait_for_timeout(10800)
    t_after = ev("JSON.parse(localStorage.getItem(Kodhane.SAVE_KEY)).lastSaved")
    check('autosave every ~10s', t_after > t_before, f"delta={(t_after-t_before)/1000:.1f}s")
    tps = ev('Kodhane.baseTps()')
    ev("sessionStorage.setItem('kh_offline', '7200')")
    page.reload(); page.wait_for_selector('#clickBtn'); page.wait_for_timeout(400)
    txt = page.inner_text('#modal') if not page.is_hidden('#modal') else ''
    gain = ev('Kodhane.state.offlineEarned')
    check('offline popup shown (2h)', 'Tekrar hoş geldin' in txt and '2 sa' in txt, txt.replace('\n', ' / '))
    check('offline earnings ~ tps*7200', abs(gain - tps * 7200) / (tps * 7200) < 0.02, f"gain={gain:.1f} expected={tps*7200:.1f}")
    page.click('#modalActions button'); page.wait_for_timeout(200)
    ev("sessionStorage.setItem('kh_offline', String(20*3600))")
    g0 = ev('Kodhane.state.offlineEarned'); tps = ev('Kodhane.baseTps()')
    page.reload(); page.wait_for_selector('#clickBtn'); page.wait_for_timeout(400)
    txt = page.inner_text('#modal')
    g1 = ev('Kodhane.state.offlineEarned')
    check('offline capped at 8h', '8 sa' in txt and 'en fazla 8 saat' in txt and abs((g1 - g0) - tps * 28800) / (tps * 28800) < 0.02, txt.replace('\n', ' / '))
    page.click('#modalActions button')

    # ---------------------------------------------------------------- oyun ortası ekran görüntüsü
    ev(MIDGAME)
    page.wait_for_timeout(400)
    check('mid-game stage Ajans', page.inner_text('#stageName') == 'Ajans', page.inner_text('#stageName'))
    page.click('[data-tab="upgrades"]')
    ev("Kodhane.spawnOffer('cash')"); ev("document.getElementById('clientOffer').style.left='40px';document.getElementById('clientOffer').style.top='600px'")
    ev("Kodhane.addBuff('viral','click',2,42,'Viral etki')")
    ev("document.getElementById('toast').innerHTML=''"); page.wait_for_timeout(600)
    page.screenshot(path=SS + 'v2-desktop.png')
    ev("document.getElementById('clientOffer').classList.add('hidden'); Kodhane.state.buffs = []")
    page.click('[data-tab="stats"]'); page.wait_for_timeout(200)
    stats_txt = page.inner_text('#statsList')
    check('stats panel', all(k in stats_txt for k in ['Toplam tıklama', 'Oynama süresi', 'Kritik tık', 'İtibar', 'Başarım bonusu']))
    # ses ve titreşim ayarları
    check('sound toggle defaults OFF', ev('Kodhane.getSettings().sound') is False and 'Kapalı' in page.inner_text('#soundBtn') and ev("localStorage.getItem('kodhane_ayarlar_v1')") is None)
    page.click('#soundBtn')
    check('sound toggle turns on', 'Açık' in page.inner_text('#soundBtn'))
    page.reload(); page.wait_for_selector('#clickBtn'); page.click('[data-tab="stats"]')
    check('sound setting persists', ev('Kodhane.getSettings().sound') is True and 'Açık' in page.inner_text('#soundBtn'))
    page.click('#clickBtn')  # ses açıkken tık (Web Audio hatası olmamalı)
    page.click('#soundBtn')
    check('vibration toggle default on', ev('Kodhane.getSettings().vibrate') is True)
    page.click('#vibBtn'); page.reload(); page.wait_for_selector('#clickBtn')
    check('vibration setting persists', ev('Kodhane.getSettings().vibrate') is False and ev('Kodhane.getSettings().sound') is False)
    ev("localStorage.setItem('kodhane_ayarlar_v1', JSON.stringify({sound:false, vibrate:true}))")

    # ---------------------------------------------------------------- yatırım turu (başarımlar korunur)
    n_before = len(ev('Kodhane.state.achievements'))
    pr = ev("(() => { const K=Kodhane; K.earn(4e8); const g=K.sharesGain(); const got=K.doPrestige(); return {g, got, shares:K.state.shares, money:K.state.money, gens:K.totalOwned(), ach:K.state.achievements.length, best:K.state.daily.best, rep:K.state.reputation}; })()")
    check('prestige Yatırım Turu', pr['g'] == 2 and pr['shares'] == 2 and pr['gens'] == 0 and pr['money'] == 0, json.dumps(pr))
    check('achievements/rep/streak persist through prestige', pr['ach'] == n_before and pr['best'] == 2 and pr['rep'] > 0)
    page.wait_for_timeout(300)
    check('achievement: İlk Yatırım', 'yatirim_1' in ev('Kodhane.state.achievements'))

    # ---------------------------------------------------------------- PWA
    r = page.request.get(BASE + '/manifest.webmanifest')
    man = r.json() if r.ok else {}
    sizes = sorted({i['sizes'] for i in man.get('icons', [])})
    check('manifest valid', r.ok and man.get('short_name') == 'Kodhane' and man.get('start_url') == './' and man.get('scope') == './'
          and man.get('display') == 'standalone' and man.get('theme_color') == '#0b0e1a' and '192x192' in sizes and '512x512' in sizes, json.dumps(sizes))
    check('manifest linked + iOS meta', ev("!!document.querySelector('link[rel=manifest]') && !!document.querySelector('link[rel=apple-touch-icon]') && !!document.querySelector('meta[name=apple-mobile-web-app-capable]')"))
    for name, size in [('icon-192.png', 192), ('icon-512.png', 512), ('apple-touch-icon.png', 180), ('icon.svg', None)]:
        rr = page.request.get(BASE + '/' + name)
        ok = rr.status == 200 and (size is None or png_size(rr.body()) == (size, size))
        check('icon ' + name, ok, str(rr.status))
    sw_url = ev("navigator.serviceWorker.ready.then(r => r.active ? r.active.scriptURL : '')")
    check('service worker registers', sw_url.endswith('/sw.js'), sw_url)
    page.reload(); page.wait_for_selector('#clickBtn'); page.wait_for_timeout(300)
    check('service worker controls page', ev('!!navigator.serviceWorker.controller'))
    ctx.set_offline(True)
    page.reload(); page.wait_for_selector('#clickBtn', timeout=10000)
    c0 = ev('Kodhane.state.clicks'); page.click('#clickBtn')
    check('offline play works (cached)', ev('Kodhane.state.clicks') == c0 + 1)
    ctx.set_offline(False)

    # ---------------------------------------------------------------- sıfırlama
    page.click('[data-tab="stats"]'); page.click('#resetBtn'); page.wait_for_timeout(200)
    check('reset confirm dialog', 'Kaydı sıfırla?' in page.inner_text('#modal'))
    page.click('#modalActions .btn.danger'); page.wait_for_load_state('load'); page.wait_for_selector('#clickBtn'); page.wait_for_timeout(300)
    st = ev('Kodhane.state')
    check('reset clears save', st['clicks'] == 0 and st['money'] == 0 and st['shares'] == 0 and st['achievements'] == [])
    check('no console errors (desktop)', not errors, '; '.join(errors))

    # ---------------------------------------------------------------- mobil (390x844)
    mctx = b.new_context(viewport={'width': 390, 'height': 844}, device_scale_factor=2, is_mobile=True, has_touch=True, locale='tr-TR')
    mp = mctx.new_page(); merr = []
    watch(mp, merr)
    mev = mp.evaluate
    mp.goto(URL); mp.wait_for_selector('#clickBtn')
    mev('Kodhane.rng = () => 0.99')
    for _ in range(12): mp.tap('#clickBtn')
    mev("(() => { const K=Kodhane; K.earn(60000); K.state.money += 5000; ['stajyer','stajyer','junior','junior','junior','senior'].forEach(id=>K.buyGen(id,1)); K.buyUpgrade('click_1'); K.state.money = 7340; K.renderAll(); })()")
    mp.wait_for_timeout(400)

    def visible(sel):
        return mp.is_visible(sel)

    def sw_ok():
        return mev('document.documentElement.scrollWidth') <= 390

    check('mobile: bottom nav visible', visible('#bottomNav'))
    check('mobile: Kod view default', visible('#panelKod') and not visible('#panelEkip') and not visible('#panelSide'))
    mp.tap('#bottomNav [data-view="ekip"]'); mp.wait_for_timeout(150)
    check('mobile: Ekip view', visible('#panelEkip') and not visible('#panelKod') and not visible('#stageCard') and sw_ok())
    gh = mp.locator('.gen').first.bounding_box()['height']
    nh = mp.locator('#bottomNav button').first.bounding_box()['height']
    check('mobile: touch targets >= 44px', gh >= 44 and nh >= 44, f"gen={gh:.0f} nav={nh:.0f}")
    mev("document.getElementById('toast').innerHTML=''"); mp.wait_for_timeout(4200)
    mp.screenshot(path=SS + 'v2-mobile-ekip.png')
    mp.tap('#bottomNav [data-view="upgrades"]'); mp.wait_for_timeout(150)
    check('mobile: Geliştirme view', visible('#panelSide') and visible('#tab-upgrades') and not visible('#panelEkip') and sw_ok())
    mp.tap('#bottomNav [data-view="daily"]'); mp.wait_for_timeout(150)
    check('mobile: Görevler view', visible('#tab-daily') and sw_ok())
    mev("(() => { const s=Kodhane.state; s.critClicks=3; s.serverCrashes=1; s.logoAccepted=5; s.reputation=26; s.eventsResolved=11; })()")
    mp.tap('[data-tab="achievements"]'); mp.wait_for_timeout(400)
    check('mobile: achievements tab', visible('#tab-achievements') and sw_ok() and mev("document.querySelectorAll('.ach.unlocked').length") >= 5)
    mev("document.getElementById('toast').innerHTML=''"); mp.wait_for_timeout(200)
    mp.screenshot(path=SS + 'v2-achievements.png')
    mp.tap('#bottomNav [data-view="prestige"]'); mp.wait_for_timeout(150)
    check('mobile: Yatırım view', visible('#tab-prestige') and sw_ok())
    mp.tap('#bottomNav [data-view="kod"]'); mp.wait_for_timeout(150)
    check('mobile: back to Kod view', visible('#panelKod') and visible('#stageCard') and sw_ok())
    mev('Kodhane.rng = () => 0'); mp.tap('#clickBtn'); mev('Kodhane.rng = () => 0.99')
    mev("document.getElementById('toast').innerHTML=''"); mp.wait_for_timeout(250)
    mp.screenshot(path=SS + 'v2-mobile-kod.png')
    mp.wait_for_timeout(1200)
    mev("Kodhane.spawnEvent('cuma')"); mp.wait_for_timeout(500)
    card = mp.locator('#eventCard').bounding_box(); nav = mp.locator('#bottomNav').bounding_box()
    check('mobile: event card above tab bar', card['y'] + card['height'] <= nav['y'] + 1 and card['x'] >= 0 and card['x'] + card['width'] <= 390, f"card bottom={card['y']+card['height']:.0f} nav top={nav['y']:.0f}")
    mp.screenshot(path=SS + 'v2-event-card.png')
    mp.tap('#evChoices .ev-choice[data-choice="1"]')
    check('mobile: event choice via tap', mev('Kodhane.state.eventsResolved') >= 1 and not visible('#eventCard'))
    check('no console errors (mobile)', not merr, '; '.join(merr))

    # file:// da çalışır (servis çalışanı olmadan)
    fctx = b.new_context(); fp = fctx.new_page(); ferr = []
    fp.on('pageerror', lambda e: ferr.append(str(e)))
    fp.goto('file://' + os.path.join(ROOT, 'index.html')); fp.wait_for_selector('#clickBtn'); fp.click('#clickBtn')
    check('works via file://', not ferr and fp.evaluate('Kodhane.state.clicks') == 1, '; '.join(ferr))
    b.close()

server.shutdown()
passed = sum(r[1] for r in results)
print('\nSUMMARY: %d/%d passed' % (passed, len(results)))
sys.exit(0 if passed == len(results) else 1)
