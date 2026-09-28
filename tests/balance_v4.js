/* v4 denge ölçümü: yeni aşamalara ve 1./3. Halka Arz'a ulaşma süreleri (oyun içi saat, çevrimdışı dahil).
 * Kullanım: node tests/balance_v4.js [profil]   Profiller: sinir (20 tık/sn, kesintisiz), tutkulu, gunluk */
const { run } = require('./honest_sim.js');
const K = require('../game.js');
const H = 3600, D = 86400;
const PROFILES = {
  // üst sınır: kesintisiz 20 tık/sn, her teklif ve olay kartı yakalanır
  sinir:   { totalSec: 4 * D, plan: [[4 * D, 0]], cps: 20, prestige: 'smart', ipo: 'asap' },
  // günde 8 saat aktif (8 tık/sn), gece 8 saat çevrimdışı + gündüz 8 saat çevrimdışı
  tutkulu: { totalSec: 14 * D, plan: [[4 * H, 8 * H], [4 * H, 8 * H]], cps: 8, prestige: 'smart', ipo: 'asap' },
  // günde 2 x 45 dk aktif (5 tık/sn), arada uzun çevrimdışı
  gunluk:  { totalSec: 30 * D, plan: [[45 * 60, 11 * H], [45 * 60, 10.5 * H]], cps: 5, prestige: 'smart', ipo: 'asap' }
};
const fmtH = (s) => s === undefined ? '—' : (s < 3600 ? (s / 60).toFixed(0) + ' dk' : s < 2 * D ? (s / H).toFixed(1) + ' sa' : (s / D).toFixed(1) + ' gün');
const name = process.argv[2] || 'sinir';
const ipoMode = process.argv[3] || 'smart';
if (process.argv[4]) K.CFG.halkaArz.threshold = +process.argv[4];
// Deneme için: BAL='{"at":[6.aşama,7.,8.],"g":{"arge":[taban,tps],...}}' (oyun dosyası değişmeden)
if (process.env.BAL) {
  const o = JSON.parse(process.env.BAL);
  (o.at || []).forEach((v, i) => { K.STAGES[6 + i].at = v; });
  if (o.ha) Object.assign(K.CFG.halkaArz, o.ha);          // ör. {"mode":"root","root":6}
  if (o.nosector) K.CFG.sectors.share = 0;                 // sektör kartları kapalı (karşılaştırma)
  Object.keys(o.g || {}).forEach((id) => {
    const g = K.GENERATORS.find((x) => x.id === id), f = o.g[id][0] / g.base;
    K.UPGRADES.forEach((u) => { if (u.target === id) u.cost *= f; });
    g.base = o.g[id][0]; g.tps = o.g[id][1];
  });
}
const r = run(name, Object.assign({ epoch: Date.parse('2026-10-01T06:00:00Z') }, PROFILES[name], { ipo: ipoMode }));
const m = r.miles, st = r.save;
const out = { profil: name, halkaArz: ipoMode, esik: K.CFG.halkaArz.threshold };
[5, 6, 7, 8].forEach(i => { out[K.STAGES[i].name] = fmtH(m.stage[i]); });
out['1. Halka Arz'] = m.ipo[0] ? fmtH(m.ipo[0].t) + ' (' + m.ipo[0].gain + ' pay)' : '—';
out['3. Halka Arz'] = m.ipo[2] ? fmtH(m.ipo[2].t) + ' (' + m.ipo[2].gain + ' pay)' : '—';
out['halka arzlar'] = m.ipo.map(x => fmtH(x.t) + ':' + x.gain).join(', ');
out['ağaç'] = st.tree.length + '/12 düğüm, toplam kazanılan pay ' + st.ipoSharesEarned + ', harcanmamış ' + st.ipoShares + ' (+%' + Math.round(Math.min(st.ipoShares, K.CFG.halkaArz.unspentCap) * K.CFG.halkaArz.unspentBonus * 100) + ' üretim)';
const cost40 = m.ipo.findIndex(x => x.earned >= 40);
out['40 pay (tüm ağaç)'] = cost40 >= 0 ? fmtH(m.ipo[cost40].t) + ' (' + (cost40 + 1) + '. halka arz)' : '—';
out['toplam kazanç'] = K.fmt(st.totalEarned);
out['yatırım turu'] = st.prestigeCount;
out['tur kazancı 10^k ilk ulaşma'] = Object.keys(m.p10).filter(k => k >= 9).map(k => k + ':' + fmtH(m.p10[k])).join(' ');
console.log(JSON.stringify(out, null, 1));
// BAL_SAVE=dosya: son kaydı (makullük kontrolü için) yaz
if (process.env.BAL_SAVE) require('fs').writeFileSync(process.env.BAL_SAVE, JSON.stringify([{ name: 'denge-' + name + '-' + ipoMode, save: r.save, now: r.now }]));
