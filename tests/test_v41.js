// Kodhane v4.1 çekirdek testleri: aşamaya göre Borsa Payı, harcanmamış pay bonusu, yeni başarımlar,
// müşteri sektörleri (açılış, ret soğuması, gecikmeli ödeme, takip kartları), metinler ve v4 -> v4.1 kayıt taşıma.
// Çalıştır: node tests/test_v41.js
'use strict';
const path = require('path');
const K = require(path.join(__dirname, '..', 'game.js'));
let pass = 0, fail = 0;
function check(name, cond, info) {
  if (cond) pass++; else fail++;
  console.log((cond ? 'PASS ' : 'FAIL ') + name + (info !== undefined && !cond ? ' ' + JSON.stringify(info) : ''));
}
const clone = (o) => JSON.parse(JSON.stringify(o));
function fresh() { K.state = K.newState(); return K.state; }
const CFG = K.CFG, H = CFG.halkaArz, SC = CFG.sectors;
const near = (a, b) => Math.abs(a - b) <= 1e-9 * Math.max(1, Math.abs(a), Math.abs(b));

// ---------------------------------------------------------------- ayarlar
check('Halka Arz settings: stage mode, pays by stage, bonus 1%', H.mode === 'stage' && H.stagePays.length === K.STAGES.length && H.unspentBonus === 0.01 && H.firstMin === 1);
check('stage pays: none before Global Holding, non-decreasing, max 12 (SQL ipo_maxpay)', H.stagePays.slice(0, 5).every((x) => x === 0) && H.stagePays.every((x, i) => i === 0 || x >= H.stagePays[i - 1]) && Math.max(...H.stagePays) === 12, H.stagePays);
check('tree total stays 40', K.TREE.reduce((a, b) => a + b.nodes.reduce((x, n) => x + K.nodeCost(n), 0), 0) === 40);

// ---------------------------------------------------------------- aşamaya göre pay
fresh();
const stagePay = (st, ipoCount) => { K.state.cycleStage = st; K.state.ipoCount = ipoCount; return K.ipoGain(); };
check('first IPO: 1 pay minimum before Global Holding', stagePay(3, 0) === 1 && stagePay(0, 0) === 1);
check('first IPO at Global Holding: 2, at Teknoloji Devi: 5', stagePay(5, 0) === 2 && stagePay(6, 0) === 5);
check('later IPOs: nothing below repeatMinStage (no Global Holding pay farm), then 5/8/12', H.repeatMinStage === 6 && stagePay(4, 2) === 0 && stagePay(5, 2) === 0 && [6, 7, 8].map((i) => stagePay(i, 2)).join(',') === '5,8,12');
check('hint stage for repeat IPOs is Teknoloji Devi', (() => { K.state.ipoCount = 1; const r = K.ipoPayStage() === 6; K.state.ipoCount = 0; return r; })());
check('gain does not depend on total earnings', (() => { K.state.cycleEarned = 1e30; K.state.cycleStage = 5; K.state.ipoCount = 0; return K.ipoGain() === 2; })());
check('pay stage for the hint is Global Holding', K.ipoPayStage() === 5);
fresh();
K.earn(3e9);
check('cycleStage follows run earnings', K.state.cycleStage === 5);
K.earn(1e15);
check('cycleStage reaches Teknoloji Devi', K.state.cycleStage === 6);
K.state.cycleRounds = 3; K.doPrestige();
check('Yatırım Turu keeps cycleStage (highest this cycle)', K.state.cycleStage === 6 && K.state.runEarned === 0);
K.state.cycleRounds = 3; const g = K.doIpo();
check('IPO pays by cycleStage and resets it', g === 5 && K.state.cycleStage === 0 && K.state.ipoShares === 5);

// ---------------------------------------------------------------- harcanmamış pay bonusu
fresh(); K.state.gens.stajyer = 10;
const t0 = K.tps();
K.state.ipoShares = 7;
check('unspent pays: +1% production each', near(K.unspentMult(), 1.07) && near(K.tps(), t0 * 1.07), [K.unspentMult(), K.tps() / t0]);
K.state.ipoShares = 10; K.buyNode('kod_1');
check('spending a pay removes its bonus', near(K.unspentMult(), 1.09));
check('bonus rate is a setting', (() => { const s = H.unspentBonus; H.unspentBonus = 0.02; const r = near(K.unspentMult(), 1.18); H.unspentBonus = s; return r; })());
fresh(); check('no pays: no bonus', K.unspentMult() === 1);
fresh(); K.state.ipoShares = 400;
check('unspent bonus capped at unspentCap (50 -> +50%)', H.unspentCap === 50 && near(K.unspentMult(), 1.5));

// ---------------------------------------------------------------- metinler
const up = K.UPGRADES.find((u) => u.name === 'Yönetim Kurulu Odası');
check('upgrade renamed: Yönetim Kurulu Odası / Tüm üretim +%50', up && up.desc === 'Tüm üretim +%50' && !K.UPGRADES.some((u) => u.name === 'Halka Arz Hazırlığı'));
check('Global Holding description', K.STAGES[5].desc === 'Üç kıtada ofis, her saat diliminde bir toplantı.');
const A = (id) => K.ACHIEVEMENTS.find((a) => a.id === id);
check('new achievements (copy)', A('asama_6').name === 'Acil Kuyruğu' && A('asama_6').desc === 'Teknoloji Devi aşamasına ulaş' &&
  A('asama_7').name === 'Model Eğitildi' && A('asama_7').desc === 'Yapay Zekâ Laboratuvarı aşamasına ulaş' &&
  A('asama_8').name === 'Kızıl Tabela' && A('asama_8').desc === 'Mars Ofisi aşamasına ulaş');
check('achievement count 34, ids unique', K.ACHIEVEMENTS.length === 34 && new Set(K.ACHIEVEMENTS.map((a) => a.id)).size === 34);
check('new achievements follow Kıtalar Arası', K.ACHIEVEMENTS.findIndex((a) => a.id === 'asama_6') === K.ACHIEVEMENTS.findIndex((a) => a.id === 'asama_5') + 1);
fresh(); K.state.stageBest = 7; K.state.stage = 2; K.checkAchievements();
check('players who already passed stages get them (stageBest, even after a reset)', ['asama_6', 'asama_7'].every((x) => K.state.achievements.includes(x)) && !K.state.achievements.includes('asama_8'));

// ---------------------------------------------------------------- sektörler
check('4 sectors', K.SECTORS.map((x) => x.id + ':' + x.name).join(',') === 'esnaf:Mahalle Esnafı,eticaret:E-ticaret,oyun:Oyun şirketi,kamu:Kamu ihalesi');
const sectorCards = K.EVENTS.filter((e) => e.sector && !/_revize$|_destek$/.test(e.id));
check('2 cards per sector', K.SECTORS.every((x) => sectorCards.filter((e) => e.sector === x.id).length === 2));
const T = (id) => K.EVENT_BY_ID[id].title;
check('card copy', T('eticaret_sunucu') === '“İndirim gecesi site yavaşladı. Sunucu ekler misin?”' && T('eticaret_buton') === '“Sepete ekle butonu biraz daha kırmızı olabilir mi?”' &&
  T('oyun_yama') === '“Oyun çıktı ama ilk gün yaması lazım.”' && T('oyun_karakter') === '“Karakter bir tık daha havalı olsun. Nasıl yani, biz de bilmiyoruz.”' &&
  T('kamu_ihale') === '“İhale kazanıldı. Evrak listesi 14 sayfa.”' && T('kamu_imza') === '“Islak imza lazım, PDF olmaz.”' &&
  T('esnaf_kafe') === '“Kafe: Menüyü siteye koyalım. Fiyatlar her hafta değişiyor ama.”' && T('esnaf_emlak') === '“Emlakçı: İlanları ben girerim, sen sadece şifremi hatırla.”');
fresh();
check('start: only Mahalle Esnafı open', K.sectorOpen('esnaf') && !K.sectorOpen('eticaret') && !K.sectorOpen('oyun') && !K.sectorOpen('kamu'));
K.state.stageBest = SC.unlock.eticaret; check('E-ticaret opens at its stage', K.sectorOpen('eticaret') && !K.sectorOpen('oyun'));
K.state.stageBest = SC.unlock.kamu; check('all open at Kamu stage', K.SECTORS.every((x) => K.sectorOpen(x.id)));
check('unlock stages are settings, increasing', SC.unlock.esnaf === 0 && SC.unlock.eticaret < SC.unlock.oyun && SC.unlock.oyun < SC.unlock.kamu);
fresh();
const counts = (n) => { const c = {}; for (let i = 0; i < n; i++) { const e = K.EVENT_BY_ID[K.pickEvent()]; const k = e.sector || 'genel'; c[k] = (c[k] || 0) + 1; } return c; };
let c = counts(3000);
check('closed sectors never appear', !c.eticaret && !c.oyun && !c.kamu && c.esnaf > 0);
check('follow-up cards need an accepted job', !c.esnaf || K.EVENTS.filter((e) => /_revize$|_destek$/.test(e.id)).every((e) => !K.cardAvailable(e)));
K.state.stageBest = 8; c = counts(8000);
check('sector share ≈ CFG.sectors.share', Math.abs((8000 - c.genel) / 8000 - SC.share) < 0.04, c);
// reddetme
K.state.money = 1000; K.state.reputation = 12;
const msg = K.resolveEvent('kamu_ihale', 1);
check('reject: cooldown on that sector, reputation unchanged', K.state.sectorCool.kamu === SC.rejectSec && K.state.reputation === 12 && msg === 'Teklifi geri çevirdin. Kamu ihalesi teklifleri bir süre seyrek gelecek.', msg);
check('reject hint mentions duration', K.EVENT_BY_ID.kamu_ihale.choices[1].hint() === 'Kamu ihalesi teklifleri 10:00 seyrek gelir', K.EVENT_BY_ID.kamu_ihale.choices[1].hint());
check('rejected sector weight drops', K.sectorWeight('kamu') === SC.rejectWeight && K.sectorWeight('oyun') === 1);
c = counts(8000);
check('rejected sector appears less often', c.kamu < c.oyun * 0.5, c);
K.tick(SC.rejectSec - 1); check('cooldown still active before it ends', K.sectorWeight('kamu') === SC.rejectWeight);
K.tick(2); check('cooldown expires', K.sectorWeight('kamu') === 1 && !('kamu' in K.state.sectorCool));
K.resolveEvent('oyun_yama', 1); K.state.lastSaved = Date.now() - 3600e3; K.applyOffline(Date.now());
check('cooldown also ends offline', !('oyun' in K.state.sectorCool));
check('Sektörde Tanınıyorsun achievement unchanged', K.ACHIEVEMENTS.some((a) => a.name === 'Sektörde Tanınıyorsun'));

// kabul etkileri
function prodSetup() { fresh(); K.state.stageBest = 8; K.state.gens.stajyer = 50; K.state.gens.junior = 20; K.state.money = 1e9; }
prodSetup();
let m0 = K.state.money, p = K.pay(1);
K.resolveEvent('eticaret_sunucu', 0);
check('E-ticaret server: costs, then bigger reward', near(K.state.money, m0 - p * SC.eticaret_sunucu.cost + p * SC.eticaret_sunucu.pay) && SC.eticaret_sunucu.pay > SC.eticaret_sunucu.cost, [K.state.money - m0]);
prodSetup(); K.state.money = 0; K.resolveEvent('eticaret_sunucu', 0);
check('E-ticaret server: cost never makes money negative', K.state.money >= 0);
prodSetup(); m0 = K.state.money; p = K.pay(1);
K.resolveEvent('eticaret_buton', 0);
check('E-ticaret button: small pay + short revision', near(K.state.money - m0, p * SC.eticaret_buton.pay) && K.buffMult('prod') === SC.eticaret_buton.mult);
prodSetup(); m0 = K.state.money; p = K.pay(1);
K.resolveEvent('oyun_yama', 0);
check('Oyun patch: high reward, productivity drops for a while', near(K.state.money - m0, p * SC.oyun_yama.pay) && K.buffMult('prod') === SC.oyun_yama.mult && SC.oyun_yama.pay >= SC.eticaret_sunucu.pay);
K.tick(SC.oyun_yama.sec + 1); check('patch slowdown ends', K.buffMult('prod') === 1);
prodSetup(); K.resolveEvent('oyun_karakter', 0);
check('Oyun character: vague revision (slowdown)', K.buffMult('prod') === SC.oyun_karakter.mult);
prodSetup(); m0 = K.state.money; p = K.pay(1);
K.resolveEvent('kamu_ihale', 0);
check('Kamu tender: nothing now, big payment pending', K.state.money === m0 && K.state.pendingPay.length === 1 && near(K.state.pendingPay[0].amount, p * SC.kamu_ihale.pay));
check('Kamu tender is the biggest payment', SC.kamu_ihale.pay === Math.max(...['eticaret_sunucu', 'eticaret_buton', 'oyun_yama', 'oyun_karakter', 'kamu_ihale', 'kamu_imza', 'esnaf_kafe', 'esnaf_emlak'].map((k) => SC[k].pay)));
const tot0 = K.state.totalEarned;
K.state.gens = Object.fromEntries(Object.keys(K.state.gens).map((k) => [k, 0])); // üretimi durdur, yalnız ödemeyi ölç
K.tick(SC.kamu_ihale.delay - 1); check('not paid before the delay', K.state.pendingPay.length === 1);
K.tick(2); check('paid after the delay (counts as earnings)', K.state.pendingPay.length === 0 && near(K.state.totalEarned - tot0, p * SC.kamu_ihale.pay), K.state.totalEarned - tot0);
prodSetup(); K.resolveEvent('kamu_imza', 0);
check('Kamu wet signature: short delay', K.state.pendingPay.length === 1 && K.state.pendingPay[0].left === SC.kamu_imza.delay && SC.kamu_imza.delay < SC.kamu_ihale.delay);
K.state.lastSaved = Date.now() - 600e3; const tb = K.state.totalEarned; K.applyOffline(Date.now());
check('delayed payment also arrives offline', K.state.pendingPay.length === 0 && K.state.totalEarned > tb);
const rt = JSON.parse(JSON.stringify(K.state)); prodSetup(); K.resolveEvent('kamu_ihale', 0);
K.deserialize(K.serialize());
check('pending payment survives save/load', K.state.pendingPay.length === 1 && K.state.pendingPay[0].label === 'İhale ödemesi');
K.earn(1e12); K.state.cycleRounds = 3; K.doPrestige();
check('pending payment survives Yatırım Turu', K.state.pendingPay.length === 1);
// esnaf takip kartları
prodSetup(); m0 = K.state.money; p = K.pay(1);
K.resolveEvent('esnaf_kafe', 0);
check('Kafe: small fast payment, then revisions queued', near(K.state.money - m0, p * SC.esnaf_kafe.pay) && K.state.followUps.kafe === SC.esnaf_kafe.revisions && K.cardAvailable(K.EVENT_BY_ID.esnaf_kafe_revize));
for (let i = 0; i < SC.esnaf_kafe.revisions; i++) K.resolveEvent('esnaf_kafe_revize', 0);
check('Kafe revisions count down to 0', K.state.followUps.kafe === 0 && !K.cardAvailable(K.EVENT_BY_ID.esnaf_kafe_revize));
K.resolveEvent('esnaf_kafe', 0); K.resolveEvent('esnaf_kafe_revize', 1);
check('Kafe: "Artık yapamayız" ends revisions', K.state.followUps.kafe === 0);
K.resolveEvent('esnaf_emlak', 0);
check('Emlakçı: support request becomes possible', K.state.followUps.emlak === 1 && K.cardAvailable(K.EVENT_BY_ID.esnaf_emlak_destek));
const sv = K.rng; let n = 0; K.rng = () => 0.1; n += K.sectorPool('esnaf').some((e) => e.id === 'esnaf_emlak_destek') ? 1 : 0;
K.rng = () => 0.9; n += K.sectorPool('esnaf').some((e) => e.id === 'esnaf_emlak_destek') ? 10 : 0; K.rng = sv;
check('Emlakçı support only occasionally (returnChance)', n === 1, n);
K.resolveEvent('esnaf_emlak_destek', 0);
check('support keeps the client (can return again)', K.state.followUps.emlak === 1 && K.buffMult('prod') < 1);
K.resolveEvent('esnaf_emlak_destek', 1);
check('Emlakçı: "Artık yapamayız" ends support', K.state.followUps.emlak === 0);
check('sector state survives IPO', (() => { fresh(); K.state.followUps.kafe = 2; K.state.sectorCool.oyun = 100; K.state.cycleRounds = 3; K.state.cycleStage = 5; K.doIpo(); return K.state.followUps.kafe === 2 && K.state.sectorCool.oyun === 100; })());
// all choices produce a message and do not throw
prodSetup(); K.state.followUps = { kafe: 1, emlak: 1 };
check('every sector choice runs', K.EVENTS.filter((e) => e.sector).every((e) => e.choices.every((ch, i) => { K.state.followUps = { kafe: 1, emlak: 1 }; const r = K.resolveEvent(e.id, i); return typeof r === 'string' && r.length > 0 && (typeof ch.hint === 'string' || typeof ch.hint() === 'string'); })));

// ---------------------------------------------------------------- kayıt taşıma: v4 kaydı (kayıt sürümü 3) -> v4.1 (4)
function v4Save(over) {
  return Object.assign({
    version: 3, money: 5e14, runEarned: 7e14, totalEarned: 3e16, clicks: 12000, clickEarned: 4e10, playTime: 400000,
    startedAt: Date.now() - 9 * 86400000, lastSaved: Date.now(), gens: { stajyer: 300, junior: 250, senior: 200, tasarimci: 180, pm: 150, ai: 120, sunucu: 90, ofis: 60, arge: 10 },
    upgrades: ['stajyer_1', 'junior_1'], shares: 900, prestigeCount: 14, stage: 5, stageBest: 6,
    achievements: ['tik_1', 'asama_5'], reputation: 40, ipoShares: 4, ipoSharesEarned: 11, ipoCount: 2, cycleRounds: 5, cycleEarned: 9e15,
    tree: ['kod_1', 'kod_2', 'ekip_1'], newsSeen: ['siralama', 'yeni_asama'], newsPending: [],
    daily: { day: '2026-09-28', tasks: [], streak: 2, lastDone: '2026-09-27' }
  }, over || {});
}
const o = v4Save();
K.deserialize(JSON.stringify(o));
const s = K.state;
check('v4 save: version 4, loadedVersion 3', s.version === 4 && K.loadedVersion === 3);
check('v4 save: every v4 field kept (lossless)', ['money', 'runEarned', 'totalEarned', 'clicks', 'clickEarned', 'playTime', 'startedAt', 'shares', 'prestigeCount', 'stage', 'stageBest', 'reputation', 'ipoShares', 'ipoSharesEarned', 'ipoCount', 'cycleRounds', 'cycleEarned'].every((k) => s[k] === o[k]) &&
  JSON.stringify(s.gens) === JSON.stringify(Object.assign({}, s.gens, o.gens)) && JSON.stringify(s.tree) === JSON.stringify(o.tree) && JSON.stringify(s.upgrades) === JSON.stringify(o.upgrades) &&
  JSON.stringify(s.newsSeen) === JSON.stringify(o.newsSeen) && s.daily.streak === 2, s);
check('v4 save after an IPO: cycleStage from this run only (no free pays)', s.cycleStage === 5 && K.ipoGain() === 0);
check('v4 save: new fields start empty', JSON.stringify(s.sectorCool) === '{}' && s.followUps.kafe === 0 && s.followUps.emlak === 0 && s.pendingPay.length === 0);
K.deserialize(JSON.stringify(v4Save({ ipoCount: 0, ipoShares: 0, ipoSharesEarned: 0, tree: [], stage: 3, runEarned: 2e6, stageBest: 6 })));
check('v4 save before any IPO: cycle = all time, cycleStage = stageBest', K.state.cycleStage === 6 && K.ipoGain() === 5);
check('achievements granted on load for passed stages', (() => { K.checkAchievements(); return K.state.achievements.includes('asama_6') && !K.state.achievements.includes('asama_7'); })());
K.deserialize(K.serialize());
check('reload is stable', K.loadedVersion === 4 && K.state.cycleStage === 6);
K.deserialize(JSON.stringify(Object.assign(v4Save({ version: 4 }), { cycleStage: 99, sectorCool: { kamu: 1e9, yok: 5, oyun: -1 }, followUps: { kafe: 50, emlak: 'x' }, pendingPay: [{ amount: 5, left: 3, label: 'İhale ödemesi' }, { amount: -1, left: 3 }, { amount: 1e40, left: 1e9, label: 'x' }, 'bad'] })));
check('v4.1 save sanitised', K.state.cycleStage === 8 && JSON.stringify(Object.keys(K.state.sectorCool)) === '["kamu"]' && K.state.sectorCool.kamu === SC.rejectSec &&
  K.state.followUps.kafe === SC.esnaf_kafe.revisions && K.state.followUps.emlak === 1 && K.state.pendingPay.length <= 2 && K.state.pendingPay.every((q) => q.amount > 0 && q.left > 0), [K.state.cycleStage, K.state.sectorCool, K.state.followUps, K.state.pendingPay]);
// real player shapes (read-only reproductions of the two live saves' counters)
K.deserialize(JSON.stringify(v4Save({ ipoCount: 1, ipoShares: 0, ipoSharesEarned: 1, tree: ['kod_1'], stage: 1, stageBest: 4, runEarned: 5000, cycleEarned: 5000, cycleRounds: 0, prestigeCount: 3, shares: 0 })));
check('first account shape: loads, no retro pays', K.state.cycleStage === 1 && K.state.ipoSharesEarned === 1 && K.state.tree.length === 1);


// ---------------------------------------------------------------- v4.1.1: Yazı metin düzeltmeleri + B1 ayarları
check('B1: sector unlock stages, stage pays, repeatMinStage, unspentCap live in CFG', SC.unlock && typeof SC.unlock.kamu === 'number' && Array.isArray(H.stagePays) && typeof H.repeatMinStage === 'number' && typeof H.unspentCap === 'number');
{ const u = SC.unlock, k0 = u.kamu; fresh(); K.state.stageBest = k0 - 1; const closed = !K.sectorOpen('kamu'); u.kamu = k0 - 1; const moved = K.sectorOpen('kamu'); u.kamu = k0;
  check('B1: sectorOpen reads CFG.sectors.unlock', closed && moved); }
check('sector card subtitle: icon + sector name only', K.EVENT_BY_ID.kamu_ihale.text === '🏛️ Kamu ihalesi' && K.EVENT_BY_ID.eticaret_sunucu.text === '🛒 E-ticaret', K.EVENT_BY_ID.kamu_ihale.text);
fresh(); K.state.stageBest = 8;
check('reject result text', K.resolveEvent('oyun_yama', 1) === 'Teklifi geri çevirdin. Oyun şirketi teklifleri bir süre seyrek gelecek.');
check('reject hint text (m:ss)', K.EVENT_BY_ID.eticaret_buton.choices[1].hint() === 'E-ticaret teklifleri 10:00 seyrek gelir', K.EVENT_BY_ID.eticaret_buton.choices[1].hint());
prodSetup(); { const k = K.tl(K.pay(SC.eticaret_sunucu.cost)), x = K.tl(K.pay(SC.eticaret_sunucu.pay)); const m = K.resolveEvent('eticaret_sunucu', 0);
  check('Sunucu result text', m === 'Sunucular eklendi, site uçtu. Gider -' + k + ', gelir +' + x, m); }
prodSetup(); { const x = K.tl(K.pay(SC.kamu_ihale.pay)); const m = K.resolveEvent('kamu_ihale', 0);
  check('İhale result text', m === 'Evraklar teslim edildi. Ödeme ' + K.fmtSec(SC.kamu_ihale.delay) + ' sonra geliyor: +' + x && /Ödeme 5:00 sonra/.test(m), m); }
prodSetup(); { const x = K.tl(K.pay(SC.kamu_imza.pay)); const m = K.resolveEvent('kamu_imza', 0);
  check('Islak imza result text', m === 'İmza atıldı, kargoya verildi. Ödeme ' + K.fmtSec(SC.kamu_imza.delay) + ' sonra geliyor: +' + x, m); }
check('durations over 60 s as m:ss', K.fmtSec(540) === '9:00' && K.fmtSec(600) === '10:00' && K.fmtSec(61) === '1:01' && K.fmtSec(60) === '60 sn' && K.fmtSec(45) === '45 sn' && K.fmtSec(3725) === '1:02:05', [K.fmtSec(540), K.fmtSec(61), K.fmtSec(3725)]);
{ const a = K.ACHIEVEMENTS.find((x) => x.id === 'ekip_50'); check('50-employee achievement renamed to "Kat Doldu", id kept', a && a.name === 'Kat Doldu' && !K.ACHIEVEMENTS.some((x) => x.name === 'Açık Ofis')); }
{ fresh(); K.state.achievements = ['ekip_50']; const str = K.serialize(); K.state = K.newState(); const st = K.deserialize(str); const got = (st && st.achievements) || K.state.achievements;
  check('earners keep ekip_50 across save/load (id unchanged)', got.includes('ekip_50'), got); }
console.log(`\n${pass}/${pass + fail} passed`);
process.exit(fail ? 1 : 0);
