import time, json
from playwright.sync_api import sync_playwright

URL = 'http://127.0.0.1:8765/index.html'
SS = '/workspace/idle-ajans/screenshots/'
results = []
def check(name, cond, info=''):
    results.append((name, bool(cond), info))
    print(('PASS' if cond else 'FAIL'), name, info)

INIT = """
(() => { try {
  const off = sessionStorage.getItem('kh_offline');
  if (off) { sessionStorage.removeItem('kh_offline');
    const k='kodhane_ajans_save_v1'; const d=JSON.parse(localStorage.getItem(k));
    d.lastSaved = Date.now() - Number(off)*1000; localStorage.setItem(k, JSON.stringify(d)); }
} catch(e){} })();
"""

with sync_playwright() as p:
    b = p.chromium.launch()
    ctx = b.new_context(viewport={'width':1280,'height':800}, locale='tr-TR')
    ctx.add_init_script(INIT)
    page = ctx.new_page()
    errors = []
    page.on('console', lambda m: errors.append(m.text) if m.type == 'error' else None)
    page.on('pageerror', lambda e: errors.append(str(e)))
    page.goto(URL); page.wait_for_selector('#clickBtn')
    ev = page.evaluate
    check('title', page.title() == 'Kodhane: Ajans Tycoon', page.title())
    for _ in range(20): page.click('#clickBtn')
    st = ev('Kodhane.state')
    check('20 clicks -> 20 TL', st['clicks'] == 20 and abs(st['money'] - 20) < 0.5, f"money={st['money']:.2f}")
    page.click('[data-gen="stajyer"]')
    st = ev('Kodhane.state')
    check('buy Stajyer via UI', st['gens']['stajyer'] == 1 and st['money'] < 6, f"money={st['money']:.2f}")
    m0 = ev('Kodhane.state.money'); time.sleep(2.0); m1 = ev('Kodhane.state.money')
    check('real-time production (~0.2 TL/sn)', 0.3 < m1 - m0 < 0.6, f"+{m1-m0:.3f} in 2s")
    for _ in range(10): page.click('#clickBtn')
    page.wait_for_timeout(1200)
    page.screenshot(path=SS + 'early-1280x800.png')
    # stage + upgrade
    ev('Kodhane.earn(1500)'); page.wait_for_timeout(300)
    check('stage -> Ev Ofisi', page.inner_text('#stageName') == 'Ev Ofisi', page.inner_text('#stageName'))
    check('stage progress text', 'Butik Stüdyo' in page.inner_text('#stageNext'), page.inner_text('#stageNext'))
    tps_before = ev('Kodhane.tps()')
    page.click('[data-upg="stajyer_1"]'); page.wait_for_timeout(200)
    tps_after = ev('Kodhane.tps()')
    check('upgrade Staj Sertifikası doubles stajyer', ev("Kodhane.has('stajyer_1')") and abs(tps_after - 2*tps_before) < 1e-9, f"{tps_before}->{tps_after}")
    page.click('[data-upg="click_1"]'); page.wait_for_timeout(200)
    check('click upgrade x2', abs(ev('Kodhane.clickValue()') - 2.2) < 1e-9, f"click={ev('Kodhane.clickValue()')}")
    ev('Kodhane.tick(100)')
    check('tick(100) production', ev('Kodhane.state.playTime') > 100)
    # number format
    check('TR format', ev("[Kodhane.tl(1234.5), Kodhane.tl(2.5e6), Kodhane.tl(3.75e9), Kodhane.tl(1.2e12)].join('|')") == '1,23 Bin TL|2,5 Mn TL|3,75 Mr TL|1,2 Tn TL', ev("[Kodhane.tl(1234.5), Kodhane.tl(2.5e6), Kodhane.tl(3.75e9), Kodhane.tl(1.2e12)].join('|')"))
    # client offer
    mb = ev('Kodhane.state.money'); ev("Kodhane.spawnOffer('cash')"); page.click('#clientOffer', force=True); page.wait_for_timeout(200)
    check('client offer cash claimed', ev('Kodhane.state.eventsClicked') == 1 and ev('Kodhane.state.money') > mb + 40)
    ev("Kodhane.spawnOffer('boost')"); page.click('#clientOffer', force=True); page.wait_for_timeout(200)
    check('client offer boost x2', ev('Kodhane.state.boostLeft') > 29 and not page.is_hidden('#boostBar'))
    # persistence
    snap = ev('({c: Kodhane.state.clicks, s: Kodhane.state.gens.stajyer, u: Kodhane.state.upgrades.slice()})')
    page.reload(); page.wait_for_selector('#clickBtn'); page.wait_for_timeout(300)
    snap2 = ev('({c: Kodhane.state.clicks, s: Kodhane.state.gens.stajyer, u: Kodhane.state.upgrades.slice()})')
    check('save persists across reload', snap == snap2, json.dumps(snap2))
    check('no welcome popup on quick reload', page.is_hidden('#modal'))
    # autosave interval
    t_before = ev("JSON.parse(localStorage.getItem(Kodhane.SAVE_KEY)).lastSaved")
    page.wait_for_timeout(10800)
    t_after = ev("JSON.parse(localStorage.getItem(Kodhane.SAVE_KEY)).lastSaved")
    check('autosave every ~10s', t_after > t_before, f"delta={(t_after-t_before)/1000:.1f}s")
    # offline 2h
    tps = ev('Kodhane.baseTps()'); mo = ev('Kodhane.state.money')
    ev("sessionStorage.setItem('kh_offline', '7200')")
    page.reload(); page.wait_for_selector('#clickBtn'); page.wait_for_timeout(400)
    txt = page.inner_text('#modal') if not page.is_hidden('#modal') else ''
    gain = ev('Kodhane.state.offlineEarned')
    check('offline popup shown (2h)', 'Tekrar hoş geldin' in txt and '2 sa' in txt, txt.replace('\n', ' / '))
    check('offline earnings ~ tps*7200', abs(gain - tps*7200) / (tps*7200) < 0.01, f"gain={gain:.1f} expected={tps*7200:.1f}")
    page.screenshot(path=SS + 'offline-popup-1280x800.png')
    page.click('#modalActions button'); page.wait_for_timeout(200)
    # offline cap 8h
    ev("sessionStorage.setItem('kh_offline', String(20*3600))")
    g0 = ev('Kodhane.state.offlineEarned'); tps = ev('Kodhane.baseTps()')
    page.reload(); page.wait_for_selector('#clickBtn'); page.wait_for_timeout(400)
    txt = page.inner_text('#modal')
    g1 = ev('Kodhane.state.offlineEarned')
    check('offline capped at 8h', '8 sa' in txt and 'en fazla 8 saat' in txt and abs((g1-g0) - tps*28800)/(tps*28800) < 0.01, txt.replace('\n', ' / '))
    page.click('#modalActions button')
    # mid-game state
    ev("""(() => { const K=Kodhane; K.earn(3.5e6);
      const plan={stajyer:30,junior:25,senior:20,tasarimci:12,pm:4};
      for (const id in plan) { K.state.money += K.genCost(K.GENERATORS.find(g=>g.id===id), plan[id]); K.buyGen(id, plan[id]); }
      ['junior_1','junior_2','senior_1','senior_2','tasarimci_1','tasarimci_2','stajyer_2','stajyer_3','click_2','click_3','all_1','pm_1'].forEach(id=>{K.state.money+=1e6; K.buyUpgrade(id);});
      K.state.money = 842500; K.state.boostLeft = 0; K.state.playTime = 1830; K.state.clicks = 1450; K.renderAll(); })()""")
    page.wait_for_timeout(400)
    check('mid-game stage Ajans', page.inner_text('#stageName') == 'Ajans', page.inner_text('#stageName'))
    ev("Kodhane.spawnOffer('cash')"); ev("document.getElementById('clientOffer').style.left='40px';document.getElementById('clientOffer').style.top='560px'")
    ev("document.getElementById('toast').classList.add('hidden')"); page.wait_for_timeout(500)
    page.screenshot(path=SS + 'midgame-1280x800.png')
    ev("document.getElementById('clientOffer').classList.add('hidden')")
    page.click('[data-tab="stats"]'); page.wait_for_timeout(200)
    check('stats panel', 'Toplam tıklama' in page.inner_text('#statsList') and 'Oynama süresi' in page.inner_text('#statsList'))
    # prestige (core)
    pr = ev("(() => { const K=Kodhane; K.earn(4e8); const g=K.sharesGain(); const got=K.doPrestige(); return {g, got, shares:K.state.shares, money:K.state.money, gens:K.totalOwned()}; })()")
    check('prestige Yatırım Turu', pr['g'] == 2 and pr['shares'] == 2 and pr['gens'] == 0 and pr['money'] == 0, json.dumps(pr))
    page.click('[data-tab="upgrades"]')
    # reset
    page.click('[data-tab="stats"]'); page.click('#resetBtn'); page.wait_for_timeout(200)
    check('reset confirm dialog', 'Kaydı sıfırla?' in page.inner_text('#modal'))
    page.click('#modalActions .btn.danger'); page.wait_for_load_state('load'); page.wait_for_selector('#clickBtn'); page.wait_for_timeout(300)
    st = ev('Kodhane.state')
    check('reset clears save', st['clicks'] == 0 and st['money'] == 0 and st['shares'] == 0)
    check('no console errors (desktop)', not errors, '; '.join(errors))

    # mobile
    mctx = b.new_context(viewport={'width':390,'height':844}, device_scale_factor=2, is_mobile=True, has_touch=True, locale='tr-TR')
    mp = mctx.new_page(); merr = []
    mp.on('console', lambda m: merr.append(m.text) if m.type == 'error' else None)
    mp.on('pageerror', lambda e: merr.append(str(e)))
    mp.goto(URL); mp.wait_for_selector('#clickBtn')
    for _ in range(12): mp.tap('#clickBtn')
    mp.evaluate("(() => { const K=Kodhane; K.earn(60000); K.state.money += 5000; ['stajyer','stajyer','junior','junior','junior','senior'].forEach(id=>K.buyGen(id,1)); K.buyUpgrade('click_1'); K.state.money = 7340; K.renderAll(); })()")
    mp.wait_for_timeout(4200)  # toast fades
    sw = mp.evaluate('document.documentElement.scrollWidth')
    check('mobile no horizontal overflow', sw <= 390, f"scrollWidth={sw}")
    mp.screenshot(path=SS + 'mobile-390x844.png')
    check('no console errors (mobile)', not merr, '; '.join(merr))

    # file:// works
    fctx = b.new_context(); fp = fctx.new_page(); ferr = []
    fp.on('pageerror', lambda e: ferr.append(str(e)))
    fp.goto('file:///workspace/idle-ajans/index.html'); fp.wait_for_selector('#clickBtn'); fp.click('#clickBtn')
    check('works via file://', not ferr and fp.evaluate('Kodhane.state.clicks') == 1, '; '.join(ferr))
    b.close()

print('\nSUMMARY: %d/%d passed' % (sum(r[1] for r in results), len(results)))
