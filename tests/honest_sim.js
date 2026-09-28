/* Dürüst oyuncu simülasyonları (sıralama makullük kontrolü testleri için).
 * Oyunun gerçek çekirdeğini (game.js) kullanır; olabildiğince hızlı ilerleyen ama hile yapmayan oyuncular:
 * sürekli tıklama (10-20/sn), açgözlü alım, her müşteri teklifini ve olay kartını en yüksek ödemeyle yakalama,
 * itibar 100, günlük görevler, çevrimdışı kazanç (8-24 saat sınırı), Yatırım Turları, v4: Halka Arz + Borsa Payı Ağacı,
 * v4.1: müşteri sektörü kartları (oyunun gerçek kart seçimi; sektör kartları hep kabul, diğer kartlar en yüksek ödeme).
 * Ayrıca denge ölçümleri (aşamalara ve halka arzlara ulaşma süreleri) için kullanılır: tests/balance_v4.js
 * Kullanım: node tests/honest_sim.js [senaryo...]  -> JSON: [{name, now, save}]
 */
const K = require('../game.js');

function greedy(cps) {
  for (let k = 0; k < 60; k++) {
    let best = null;
    for (const g of K.GENERATORS) {
      if (!K.genUnlocked(g)) continue;
      const c = K.genCost(g, 1), d = K.genTps(g);
      const sc = c / d; if (!best || sc < best.sc) best = { sc, t: 'g', id: g.id, c };
    }
    for (const u of K.availableUpgrades()) {
      const b0 = K.baseTps() + K.clickValue() * cps; K.state.upgrades.push(u.id);
      const b1 = K.baseTps() + K.clickValue() * cps; K.state.upgrades.pop();
      const d = b1 - b0; if (d <= 0) { if (K.state.money >= u.cost && u.type === 'perk') K.buyUpgrade(u.id); continue; }
      const sc = u.cost / d; if (sc < best.sc) best = { sc, t: 'u', id: u.id, c: u.cost };
    }
    if (best && K.state.money >= best.c) { best.t === 'g' ? K.buyGen(best.id, 1) : K.buyUpgrade(best.id); } else break;
  }
}

function day(ms) { return new Date(ms).toISOString().slice(0, 10); }

// Borsa Payı Ağacı alım önceliği (dürüst ve mantıklı bir oyuncu)
const NODE_PRIORITY = ['ekip_1', 'kod_1', 'musteri_1', 'yatirim_1', 'ekip_2', 'musteri_2', 'kod_2', 'yatirim_2', 'ekip_3', 'musteri_3', 'kod_3', 'yatirim_3'];
function buyNodes() { for (const id of NODE_PRIORITY) if (K.nodeState(id) === 'ready') K.buyNode(id); }

// plan: [[aktifSaniye, çevrimdışıSaniye], ...] tekrar eder; prestige: 'none' | 'asap' | 'smart'; ipo: 'none' | 'asap' | 'smart'
function run(name, { totalSec, plan, cps, prestige, ipo = 'none', epoch, log = false }) {
  K.rng = Math.random;
  K.state = K.newState();
  const S0 = K.state; S0.startedAt = epoch; S0.lastSaved = epoch; S0.reputation = 100;
  let t = 0, pi = 0, lastDay = null, offerAcc = 0, lastIpoT = 0;
  const clock = () => epoch + t * 1000;
  const miles = { stage: {}, ipo: [], rounds: 0, p10: {} };
  const mark = () => {
    const e10 = Math.floor(Math.log10(Math.max(1, K.state.runEarned)));
    for (let k = e10; k >= 0 && miles.p10[k] === undefined; k--) miles.p10[k] = t;
    const si = K.stageIndex(K.state.runEarned);
    if (si > K.state.stageBest) K.state.stageBest = si;
    if (si > K.state.stage) K.state.stage = si;
    if (miles.stage[si] === undefined) miles.stage[si] = t;
  };
  while (t < totalSec) {
    const [act, off] = plan[pi % plan.length]; pi++;
    for (let a = 0; a < act && t < totalSec; a++, t++) {
      const d = day(clock()); if (d !== lastDay) { lastDay = d; K.setToday(d); K.checkDaily(); }
      K.state.reputation = 100;
      for (let i = 0; i < cps; i++) K.doClick();
      K.tick(1);
      offerAcc += 1 / K.offerFreq();
      if (offerAcc >= 60) { // müşteri projesi (her 60 sn, Sadık Müşteri ile daha sık): en yüksek nakit ödeme ya da 30 sn x2
        offerAcc -= 60;
        if (t % 180 < 60) K.state.boostLeft = 30;
        else K.earn(Math.max(K.clickValue() * 40, K.baseTps() * 120, 50) * K.repMult() * K.offerPayMult());
        K.state.eventsClicked++; K.taskProgress('offer', 1);
      }
      if (t % 150 === 0) { // olay kartı: sektör kartıysa kabul (gerçek etkiler), değilse en yüksek ödeme
        const id = K.pickEvent();
        const e = K.EVENT_BY_ID[id];
        if (e && e.sector) K.resolveEvent(id, 0);
        else { K.earn(K.pay(120)); K.state.eventsResolved++; }
      }
      if (t % 10 === 0) K.checkAchievements();
      greedy(cps);
      mark();
      const g = K.sharesGain();
      if ((prestige === 'asap' && g >= 1) || (prestige === 'smart' && g >= Math.max(1, K.state.shares))) { K.doPrestige(); miles.rounds++; }
      if (ipo !== 'none' && K.ipoUnlocked()) {
        const ig = K.ipoGain();
        // asap: ilk fırsatta; smart: bir öncekinin en az iki katı pay verecekse ya da ağaç bitmemişken son halka arzdan
        // 12 saat geçti ve en az bir önceki kadar pay verecekse (ilk halka arz: açılır açılmaz)
        const last = miles.ipo.length ? miles.ipo[miles.ipo.length - 1].gain : 0;
        const smartOk = ig >= Math.max(1, 2 * last) || (ig >= Math.max(1, last) && t - lastIpoT >= 12 * 3600 && K.state.ipoSharesEarned < 40);
        if (ipo === 'asap' ? ig >= 1 : smartOk) {
          K.doIpo(); lastIpoT = t; miles.ipo.push({ t, gain: ig, earned: K.state.ipoSharesEarned });
          buyNodes();
        }
      }
    }
    if (off > 0 && t < totalSec) {
      K.state.lastSaved = clock();
      const o = Math.min(off, totalSec - t);
      t += o;
      K.applyOffline(clock());
    }
  }
  K.state.lastSaved = clock();
  K.setToday(null);
  return { name, now: clock(), save: JSON.parse(JSON.stringify(K.state)), miles };
}

const EPOCH = Date.parse('2026-10-01T06:00:00Z');
const H = 3600, D = 86400;
const SCEN = {
  'yeni-30sn':        () => run('yeni-30sn', { totalSec: 30, plan: [[30, 0]], cps: 20, prestige: 'none', epoch: EPOCH }),
  'kisa-10dk':        () => run('kisa-10dk', { totalSec: 600, plan: [[600, 0]], cps: 20, prestige: 'none', epoch: EPOCH }),
  'aktif-1gun-asap':  () => run('aktif-1gun-asap', { totalSec: D, plan: [[D, 0]], cps: 20, prestige: 'asap', epoch: EPOCH }),
  'aktif-2gun-smart': () => run('aktif-2gun-smart', { totalSec: 2 * D, plan: [[16 * H, 8 * H]], cps: 20, prestige: 'smart', epoch: EPOCH }),
  'offline-3gun':     () => run('offline-3gun', { totalSec: 3 * D, plan: [[600, 8 * H]], cps: 10, prestige: 'smart', epoch: EPOCH }),
  'idle-7gun':        () => run('idle-7gun', { totalSec: 7 * D, plan: [[30 * 60, 8 * H], [0, 16 * H]], cps: 10, prestige: 'smart', epoch: EPOCH }),
  'donus-3gun-sonra': () => run('donus-3gun-sonra', { totalSec: 4 * D, plan: [[4 * H, 3 * D + 20 * H]], cps: 20, prestige: 'none', epoch: EPOCH }),
  // v4: Halka Arz yolları
  'ipo-aktif-3gun':   () => run('ipo-aktif-3gun', { totalSec: 3 * D, plan: [[16 * H, 8 * H]], cps: 20, prestige: 'smart', ipo: 'asap', epoch: EPOCH }),
  'ipo-smart-7gun':   () => run('ipo-smart-7gun', { totalSec: 7 * D, plan: [[6 * H, 18 * H]], cps: 15, prestige: 'smart', ipo: 'smart', epoch: EPOCH }),
  'ipo-idle-14gun':   () => run('ipo-idle-14gun', { totalSec: 14 * D, plan: [[45 * 60, 12 * H], [30 * 60, 10 * H]], cps: 10, prestige: 'smart', ipo: 'asap', epoch: EPOCH }),
  // canlı e2e için: şimdi bitecek şekilde 20 saatlik yoğun oyun
  'canli-20sa':       () => run('canli-20sa', { totalSec: 20 * H, plan: [[20 * H, 0]], cps: 20, prestige: 'smart', epoch: Date.now() - 20 * H * 1000 })
};

if (require.main === module) {
  const names = process.argv.slice(2).length ? process.argv.slice(2) : Object.keys(SCEN).filter(n => n !== 'canli-20sa');
  const out = names.map(n => SCEN[n]());
  process.stdout.write(JSON.stringify(out));
}
module.exports = { run, SCEN };
