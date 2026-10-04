// Kodhane v4.4 plausibility input: runs a REAL client game.js (unpatched) with the balance simulation's player model
// (kodhane-sim44/tests/balance_v44.js run(): greedy buys, offers/events, daily tasks, offline, smart/asap/farm/none
// Halka Arz) and writes save snapshots (exactly what the client would upload: K.saveData()) as JSON lines
// {game, prof, mode, seed, now_ms, kind, data}. Local only: no network, no real player data.
//   node sim_saves.cjs <game.js> <label> <profile> <mode> [seed] > out.jsonl      (DAYS=n shortens the run)
'use strict';
const fs = require('fs'), path = require('path');
const SIM = process.env.KODHANE_SIM || '/workspace/kodhane-sim44';
const B = require(path.join(SIM, 'tests', 'balance_v44.js'));
const [gameFile, label, prof, mode = 'smart', seedArg] = process.argv.slice(2);
const seed = seedArg ? +seedArg : 44;
const src = fs.readFileSync(gameFile, 'utf8');
const m = { exports: {} }; new Function('module', 'exports', 'require', src).call({}, m, m.exports, require);
const K = m.exports;
const P = Object.assign({}, B.PROFILES[prof]); if (process.env.DAYS) P.totalSec = +process.env.DAYS * 86400;
const epoch = Date.parse('2026-10-01T06:00:00Z');
let n = 0, lastSnap = -1, prestN = 0;
const out = [];
function snap(kind) {
  const now = K.nowMs ? K.nowMs() : epoch;
  const d = K.saveData ? JSON.parse(JSON.stringify(K.saveData())) : JSON.parse(K.serialize());   // v4.1.x: serialize()
  d.lastSaved = now;                       // serialize() sets it when the client uploads
  out.push(JSON.stringify({ game: label, prof, mode, seed, now_ms: now, kind, data: d })); n++;
}
const tick = K.tick, doIpo = K.doIpo, doPrestige = K.doPrestige;
let simT = 0;
K.tick = function (dt) { const r = tick.apply(this, arguments); simT += dt; const h = Math.floor(simT / 3600); if (h !== lastSnap) { lastSnap = h; snap('hour'); } return r; };
K.doIpo = function () { snap('pre_ipo'); const r = doIpo.apply(this, arguments); snap('post_ipo'); return r; };
K.doPrestige = function () { prestN++; const every = prestN < 50 ? 1 : 25; if (prestN % every === 0) snap('pre_round'); const r = doPrestige.apply(this, arguments); if (prestN % every === 0) snap('post_round'); return r; };
const applyOffline = K.applyOffline;
K.applyOffline = function () { const r = applyOffline.apply(this, arguments); snap('offline'); return r; };
const ipoRule = mode === 'farm' ? 'asap' : mode, prestige = mode === 'farm' ? 'farm' : 'smart';
const M = B.run(K, Object.assign({ epoch, ipo: ipoRule, prestige, seed }, P));
snap('end');
process.stdout.write(out.join('\n') + '\n');
process.stderr.write(`${label} ${prof}/${mode}: ${n} snapshots, IPO ${M.ipo.length}, rounds ${M.prest.length}, best ${M.stages[M.end.stageBest]}, total ${M.end.totalEarned.toExponential(3)}\n`);
