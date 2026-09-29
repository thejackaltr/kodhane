// v4.4 denge eşdeğerlik testi: yeni game.js'i (yamasız) simülasyonun oyuncu modeliyle çalıştırır ve sonuçları
// denge simülasyonunun referansıyla (kodhane-sim44: canlı v4.3 + E100cd12 yamaları) birebir karşılaştırır.
// Kullanım: KODHANE_SIM=/workspace/kodhane-sim44 DAYS=3 node tests/balance_parity_v44.js
// Simülasyon klasörü yoksa atlanır (çıkış 0).
'use strict';
const fs = require('fs'), path = require('path');
const SIM = process.env.KODHANE_SIM || '/workspace/kodhane-sim44';
const simFile = path.join(SIM, 'tests', 'balance_v44.js');
if (!fs.existsSync(simFile)) { console.log('ATLANDI: simülasyon yok (' + simFile + ')'); process.exit(0); }
const B = require(simFile);
const DAYS = +(process.env.DAYS || 3);
const PROFS = (process.env.PROFS || 'sinir,tutkulu,gunluk').split(',');
const MODES = (process.env.MODES || 'smart,asap').split(',');
const src = fs.readFileSync(path.join(__dirname, '..', 'game.js'), 'utf8');
function freshGame() { const m = { exports: {} }; new Function('module', 'exports', 'require', src).call({}, m, m.exports, require); return m.exports; }
let fails = 0, checks = 0;
function eq(a, b, what) { checks++; const A = JSON.stringify(a), Bs = JSON.stringify(b); if (A !== Bs) { fails++; console.log('FARK ' + what + '\n  yeni: ' + A.slice(0, 400) + '\n  ref : ' + Bs.slice(0, 400)); } }
const pick = (M) => ({
  stages: M.stages,
  first: Object.fromEntries(Object.entries(M.first).map(([k, v]) => [k, v.t])),
  ipo: M.ipo.map((r) => [r.n, r.t, r.gain, r.stage, r.stageName, r.sharesBefore, r.sharesAfter, r.earned, r.tree]),
  prest: M.prest.length, prestLast: M.prest.slice(-3).map((r) => [r.t, r.gain]),
  end: { t: M.end.t, shares: M.end.shares, ipoSharesEarned: M.end.ipoSharesEarned, ipoShares: M.end.ipoShares, tree: M.end.tree, prestigeCount: M.end.prestigeCount, stageBest: M.end.stageBest, totalEarned: M.end.totalEarned },
  treeFull: M.treeFull
});
for (const prof of PROFS) for (const mode of MODES) {
  const P = Object.assign({}, B.PROFILES[prof], { totalSec: DAYS * 86400 });
  const opt = Object.assign({ epoch: Date.parse('2026-10-01T06:00:00Z'), ipo: mode, prestige: 'smart', seed: 44 }, P);
  const ref = B.run(B.loadGame(B.SCEN.E100cd12), Object.assign({}, opt));
  const K = freshGame();
  const neu = B.run(K, Object.assign({}, opt));
  const a = pick(neu), r = pick(ref);
  for (const k of Object.keys(r)) eq(a[k], r[k], prof + '/' + mode + ' ' + k);
  console.log(prof + '/' + mode + ': Halka Arz ' + neu.ipo.length + ' (ref ' + ref.ipo.length + '), tur ' + neu.prest.length + ', en iyi aşama ' + neu.stages[neu.end.stageBest] + ', ağaç ' + neu.end.tree);
}
console.log((fails ? 'BAŞARISIZ ' : 'TAMAM ') + (checks - fails) + '/' + checks + ' karşılaştırma aynı (' + DAYS + ' gün)');
process.exit(fails ? 1 : 0);
