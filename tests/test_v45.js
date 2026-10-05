// Kodhane v4.5 denge testleri (Node, tarayıcısız): tek config (CFG.v45, F2/F3), fiyat eğrisi ve 150+ kademeler, itibar (tavansız,
// bonus en fazla +%100, E1–E4), E1 aralıkları, Borsa dalı 4/5/5, asama_1e21, kayıt sürümü 6. Sayılar sim r3 config'iyle karşılaştırılır
// (/workspace/kodhane-v45-sim/kodhane-v4.5-config.json varsa).
// Çalıştır: node tests/test_v45.js
'use strict';
const path = require('path'), fs = require('fs');
const GP = path.join(__dirname, '..', 'game.js');
let pass = 0, fail = 0;
function check(name, cond, info) {
  if (cond) pass++; else fail++;
  console.log((cond ? 'PASS ' : 'FAIL ') + name + (info !== undefined && !cond ? ' ' + JSON.stringify(info) : ''));
}
// ayrı çekirdek kopyası; preset verilirse tarayıcıdaki window.KODHANE_CFG_OVERRIDE = { v45Preset } gibi (root = this)
function load(preset) {
  const m = { exports: {} };
  new Function('module', 'exports', 'require', fs.readFileSync(GP, 'utf8')).call(preset ? { KODHANE_CFG_OVERRIDE: { v45Preset: preset } } : {}, m, m.exports, require);
  return m.exports;
}
const near = (a, b, tol) => Math.abs(a / b - 1) <= (tol || 1e-3);
const K = load();
const fresh = () => { K.state = K.newState(); return K.state; };
const V = K.V45, C = K.CFG.v45;

// ---------------------------------------------------------------- tek config
check('single config object CFG.v45: active F2, presets F2 + F3, common', C.active === 'F2' && !!C.presets.F2 && !!C.presets.F3 && !!C.common && V.name === 'F2');
check('game reads only V45 = common + presets[active] (growth/tierMult from preset, rest common)', V.growth === C.presets.F2.growth && V.tierMult === C.presets.F2.tierMult && V.rep === C.common.rep && V.borsa === C.common.borsa);
check('F2 growth = GD [[0,1.15],[300,1.10],[500,1.05],[1000,1.025],[3000,1.0125]], tiers x1.25', JSON.stringify(V.growth) === '[[0,1.15],[300,1.1],[500,1.05],[1000,1.025],[3000,1.0125]]' && V.tierMult === 1.25);
check('rep: max 1e9, +1%/point, cap +100%, thresholds 25/100/250/500', V.rep.max === 1e9 && V.rep.perPoint === 0.01 && V.rep.cap === 1 && JSON.stringify(V.rep.thr) === '{"E1":25,"E2":100,"E3":250,"E4":500}');
check('E1 offer + event 0.25, E2 0.10 x3, E4 0.25, E3 off (enabled: false, 0.3 kept in config)', V.rep.E1.offerMore === 0.25 && V.rep.E1.eventMore === 0.25 && V.rep.E2.bigChance === 0.1 && V.rep.E2.bigMult === 3 && V.rep.E4.bigChance === 0.25 && V.rep.E3.penaltyCut === 0.3 && V.rep.E3.enabled === false);
check('Borsa 4/5/5, growthCut 0.8, IPO start 1e9 + senior 10 / tasarimci 10 / pm 5, full tree required', V.borsa.costs.join() === '4,5,5' && V.borsa.growthCut === 0.8 && V.borsa.ipoStartCash === 1e9 && JSON.stringify(V.borsa.ipoStartGens) === '[["senior",10],["tasarimci",10],["pm",5]]' && V.borsa.requireFullTree === true);
check('asama_1e21 at 1e21, pay 9', V.stage1e21.id === 'asama_1e21' && V.stage1e21.at === 1e21 && V.stage1e21.pay === 9 && K.CFG.halkaArz.stagePays.asama_1e21 === 9);
const SRC = fs.readFileSync(GP, 'utf8');
check('switching to F3 is one config line (active: \'F2\' in CFG.v45)', (SRC.match(/^\s*active: 'F2',/mg) || []).length === 1);

// ---------------------------------------------------------------- sim config ile birebir
const SIMCFG = '/workspace/kodhane-v45-sim/kodhane-v4.5-config.json';
if (fs.existsSync(SIMCFG)) {
  const J = JSON.parse(fs.readFileSync(SIMCFG, 'utf8'));
  check('sim config: growth segments', JSON.stringify(J.calisanFiyatEgrisi.bolumler.map((b) => [b.baslangicAdedi, b.buyume])) === JSON.stringify(V.growth));
  check('sim config: new tiers count/mult/lock', JSON.stringify(J.calisanGelistirmeleri.yeni.map((t) => [t.adet, t.etki, t.kilit])) === JSON.stringify(K.GEN_TIERS.slice(5).map((t) => [t[0], t[2], t[3]])));
  check('sim config: new tier cost multipliers (computed from the curve) within 0.1%', J.calisanGelistirmeleri.yeni.every((t, i) => near(K.GEN_TIERS[5 + i][1], t.maliyetCarpani)), K.GEN_TIERS.slice(5).map((t) => t[1].toPrecision(4)));
  check('sim config: old tiers x2', JSON.stringify(J.calisanGelistirmeleri.eski.map((t) => [t.adet, t.maliyetCarpani, t.etki])) === JSON.stringify(K.GEN_TIERS.slice(0, 5).map((t) => t.slice(0, 3))));
  check('sim config: rep thresholds / E1 / E2 / E4 / borsa / 1e21', J.itibar.esikler.E1 === V.rep.thr.E1 && J.itibar.esikler.E4 === V.rep.thr.E4 && J.itibar.E1.teklifSikligi === V.rep.E1.offerMore && J.itibar.E1.olayKartiSikligi === V.rep.E1.eventMore
    && J.itibar.E2.buyukMusteriIhtimali === V.rep.E2.bigChance && J.itibar.E4.buyukMusteriIhtimali === V.rep.E4.bigChance && J.borsaDali.maliyet.join() === V.borsa.costs.join() && J.asama1e21.borsaPayi === V.stage1e21.pay && J.itibar.guvenlikTavani === V.rep.max);
} else console.log('NOTE sim config yok: karşılaştırma atlandı');

// ---------------------------------------------------------------- fiyat eğrisi
fresh();
const st = K.GENERATORS[0];
check('unit 1..300 still x1.15 each (unchanged early game)', [0, 1, 50, 299].every((k) => { K.state.gens.stajyer = k; return near(K.genCost(st, 1), st.base * Math.pow(1.15, k), 1e-9); }));
K.state.gens.stajyer = 300; const p300 = K.genCost(st, 1); K.state.gens.stajyer = 301;
check('from unit 300 the growth drops to 1.10', near(K.genCost(st, 1) / p300, 1.10, 1e-9));
K.state.gens.stajyer = 3500; const a = K.genCost(st, 1); K.state.gens.stajyer = 3501;
check('beyond 3000: 1.0125', near(K.genCost(st, 1) / a, 1.0125, 1e-9));
K.state.gens.stajyer = 280; const sum = Array.from({ length: 50 }, (_, i) => { K.state.gens.stajyer = 280 + i; return K.genCost(st, 1); }).reduce((x, y) => x + y, 0); K.state.gens.stajyer = 280;
check('genCost(n) across a segment border = sum of single prices', near(K.genCost(st, 50), sum, 1e-9));
const affordOk = [1e3, 1e20, 1e40, 1e80, 1e120].every((m) => { K.state.money = m; K.state.gens.stajyer = 0; const n = K.maxAffordable(st); return n > 0 && K.genCost(st, n) <= m && K.genCost(st, n + 1) > m; });
check('maxAffordable: largest n with genCost(n) <= money (1e3 … 1e120)', affordOk);
K.state.tree = ['ekip_1', 'ekip_2', 'ekip_3']; K.state.gens.stajyer = 0;
check('İK Anlaşması: growth excess x 0.14/0.15 (1.14 in the first segment)', near(K.genCost(st, 2) / K.genCost(st, 1), 1 + 1.14, 1e-9) && near(K.growthF(), 0.14 / 0.15, 1e-12));
K.state.tree.push('borsa_1');
check('borsa_1: growth excess x 0.8 on top (1 + 0.15 x 0.14/0.15 x 0.8)', near(K.growthF(), 0.14 / 0.15 * 0.8, 1e-12) && near(K.genCost(st, 2) / K.genCost(st, 1), 2 + 0.15 * (0.14 / 0.15) * 0.8, 1e-9));
fresh();
const top = K.GENERATORS[K.GENERATORS.length - 1];
K.state.gens[top.id] = 9999;
const p10k = K.genCost(top, 1);
check('1e308: the 10,000th unit of the most expensive employee is finite and < 1e308 (sim: 1e108.8)', isFinite(p10k) && p10k < 1e308 && Math.abs(Math.log10(p10k) - 108.8) < 0.1, Math.log10(p10k));
K.state.gens[top.id] = 0; K.state.money = 1e300; K.state.stageBest = K.stageRank('mars_ofisi');
check('maxAffordable with huge money stays finite and fast', (() => { const t = Date.now(); const n = K.maxAffordable(top); return n > 10000 && isFinite(K.genCost(top, n)) && Date.now() - t < 200; })());

// ---------------------------------------------------------------- 150+ kademeler
const upg = (g, n) => K.UPGRADES.find((u) => u.target === g && u.req.count === n);
check('19 tiers per employee (5 old + 14 new), ids <gen>_6 … <gen>_19', K.GENERATORS.every((g) => K.UPGRADES.filter((u) => u.target === g.id).length === 19) && upg('stajyer', 10000).id === 'stajyer_19');
check('new tier: cost = base x curve price, effect x1.25, desc from data', upg('junior', 150).cost === K.GENERATORS[1].base * K.GEN_TIERS[5][1] && upg('junior', 150).mult === 1.25 && /x1,25$/.test(upg('junior', 150).desc));
check('tiers above 500 need borsa_3; 150–500 do not', K.UPGRADES.filter((u) => u.type === 'gen' && u.req.count > 500).every((u) => u.req.node === 'borsa_3') && K.UPGRADES.filter((u) => u.type === 'gen' && u.req.count <= 500).every((u) => !u.req.node));
fresh(); K.state.gens.stajyer = 800;
const vis = () => K.availableUpgrades().filter((u) => u.target === 'stajyer').map((u) => u.req.count);
check('800 Stajyer without borsa_3: 750 tier hidden (locked), 500 shown', !vis().includes(750) && vis().includes(500));
K.state.tree.push('borsa_3');
check('with borsa_3: 750 shown; 1000 not yet (UI shows only reached tiers)', vis().includes(750) && !vis().includes(1000));
fresh(); K.state.upgrades = ['stajyer_1', 'stajyer_6', 'stajyer_7'];
check('tier effects multiply: x2 x1.25 x1.25', near(K.genTps(K.GENERATORS[0]) / (K.GENERATORS[0].tps * K.globalMult()), 2 * 1.25 * 1.25, 1e-12));
check('new tier names from Yazı (ai 2000 = Ajan Kuluçkası 🥚)', upg('ai', 2000).name === 'Ajan Kuluçkası' && upg('ai', 2000).icon === '🥚');

// ---------------------------------------------------------------- itibar
fresh();
K.addRep(150);
check('reputation passes 100 (no cap at 100)', K.state.reputation === 150);
check('payment bonus capped at +100% (repMult 2 at 150)', K.repMult() === 2);
K.state.reputation = 40;
check('below the cap: +1%/point (40 -> 1.4)', near(K.repMult(), 1.4, 1e-12));
K.state.reputation = 2e9; K.addRep(1);
check('safety cap 1e9', K.state.reputation === 1e9);
{ const d = JSON.parse(K.serialize()); d.reputation = 12345; K.deserialize(JSON.stringify(d)); check('save/load keeps reputation > 100', K.state.reputation === 12345); }
check('thresholds: repPerk', (() => { const out = []; [24, 25, 99, 100, 250, 500].forEach((r) => { K.state.reputation = r; out.push(['E1', 'E2', 'E3', 'E4'].filter(K.repPerk).join('')); }); return out.join('|') === '|E1|E1|E1E2|E1E2|E1E2E4'; })());

// ---------------------------------------------------------------- E1 aralıkları
fresh();
K.state.reputation = 24;
check('below E1: offer interval x1, event interval x1', K.offerFreq() === 1 && K.eventFreq() === 1);
K.state.reputation = 25;
check('E1: offer interval / 1.25 and event card interval / 1.25', near(K.offerFreq(), 1 / 1.25, 1e-12) && near(K.eventFreq(), 1 / 1.25, 1e-12));
K.state.tree = ['musteri_1'];
check('E1 + Sadık Müşteri: both apply (/ 1.25 / 1.25)', near(K.offerFreq(), 1 / 1.5625, 1e-12));
check('event schedule uses eventFreq (scheduleEvent)', /\(min \+ Math\.random\(\) \* \(max - min\)\) \* eventFreq\(\) \* 1000/.test(SRC) && /\* f \* 1000/.test(SRC));
// E2 / E4
fresh();
const bc = (r) => { K.state.reputation = r; return K.bigOfferChance(); };
check('big customer chance: 0 below E2, 0.10 at E2/E3, 0.25 at E4', bc(99) === 0 && bc(100) === 0.1 && bc(250) === 0.1 && bc(500) === 0.25);
check('E3 penaltyCut is config only (not used by the game code)', (SRC.match(/penaltyCut/g) || []).length === 1);
// E3 kapalı (karar 3): bayrak config'te, oyunda hiçbir etkisi yok, avantaj panelinde yok
{
  const snap = (r) => { K.state.reputation = r; return JSON.stringify([K.repPerk('E3'), K.offerFreq(), K.eventFreq(), K.bigOfferChance(), K.repMult ? K.repMult() : null]); };
  fresh();
  check('E3 disabled: repPerk(E3) false even at 1e6 reputation', [250, 499, 1e6].every((r) => { K.state.reputation = r; return K.repPerk('E3') === false; }));
  check('E3 disabled: crossing 250 changes nothing (offer/event interval, big customer, rep bonus same at 249 and 250/499)', snap(249) === snap(250) && snap(249) === snap(499), [snap(249), snap(250), snap(499)]);
  check('E3 disabled: game code never asks for E3 (no repPerk(\'E3\'), penaltyCut unused)', !/repPerk\(\s*'E3'\s*\)/.test(SRC) && (SRC.match(/penaltyCut/g) || []).length === 1);
  check('E3 disabled: advantage panel lists only enabled perks (filter(perkEnabled))', /\['E1', 'E2', 'E3', 'E4'\]\.filter\(perkEnabled\)/.test(SRC));
}

// ---------------------------------------------------------------- Borsa dalı
fresh();
const BASE = ['kod_1', 'kod_2', 'kod_3', 'ekip_1', 'ekip_2', 'ekip_3', 'musteri_1', 'musteri_2', 'musteri_3', 'yatirim_1', 'yatirim_2', 'yatirim_3'];
K.state.ipoShares = 100; K.state.tree = BASE.slice(0, 11);
check('borsa_1 locked until the 12 old nodes are owned', K.nodeState('borsa_1') === 'locked' && K.nodeStateText(K.NODE_BY_ID.borsa_1, 'locked') === 'Önce ağaçtaki diğer dalları tamamla.');
K.state.tree = BASE.slice();
check('12 old nodes -> borsa_1 ready; borsa_2 needs borsa_1', K.nodeState('borsa_1') === 'ready' && K.nodeState('borsa_2') === 'locked');
check('buy borsa_1/2/3 costs 4+5+5 = 14', K.buyNode('borsa_1') && K.buyNode('borsa_2') && K.buyNode('borsa_3') && K.state.ipoShares === 86);
check('tree_full stays the 12 old nodes (telemetry), BASE_TREE_COUNT 12', K.BASE_TREE_COUNT === 12 && K.treeFull());
K.state.tree = BASE.slice(0, 11).concat(['borsa_1']);
check('a save with borsa_1 but 11 old nodes: borsa effect still applies (owned)', K.nodeState('borsa_1') === 'owned' && near(K.growthF(), 0.8 * 0.14 / 0.15, 1e-12));
// borsa_2: Halka Arz sonrası başlangıç
function ipoWith(tree) {
  fresh(); Object.assign(K.state, { tree: tree, cycleRounds: 3, ipoCount: 0, ipoShares: 0, cycleStage: K.stageRank('teknoloji_devi'), stageBest: K.stageRank('teknoloji_devi'), ipoAt: 0 });
  K.doIpo(); return K.state;
}
{ const s1 = ipoWith(BASE.concat(['borsa_1', 'borsa_2']));
  check('borsa_2: after Halka Arz money >= 1e9 and senior 10 / tasarimci 10 / pm 5 (+ Hazır Kadro)', s1.money >= 1e9 && s1.gens.senior === 10 && s1.gens.tasarimci === 10 && s1.gens.pm === 5 && s1.gens.stajyer === 5, [s1.money, s1.gens]);
  const s2 = ipoWith(BASE.slice());
  check('without borsa_2: no start cash / employees', s2.money < 1e9 && s2.gens.senior === 0); }

// ---------------------------------------------------------------- asama_1e21
fresh();
check('asama_1e21: rank between YZ Lab and Mars, name/icon from Yazı r1, desc/msg from Yazı metinler r1', K.stageRank('asama_1e21') === 10 && K.stageRank('mars_ofisi') === 11
  && K.STAGE_BY_ID.asama_1e21.name === 'Yörünge Üssü' && K.STAGE_BY_ID.asama_1e21.icon === '🌌' && K.STAGE_BY_ID.asama_1e21.desc === 'Dünya pencerede, Mars ufukta.' && K.STAGE_BY_ID.asama_1e21.msg.startsWith('Tebrikler! Ofis yörüngeye çıktı.'));
K.state.runEarned = 2e21; K.state.totalEarned = 2e21; K.state.cycleEarned = 2e21;
check('earning 2e21 reaches asama_1e21 (stageIndex), 9.9e20 does not', K.stageIndex(2e21) === K.stageRank('asama_1e21') && K.stageIndex(9.9e20) === K.stageRank('yapay_zeka_lab') && K.stageIndex(1e23) === K.stageRank('mars_ofisi'));
check('Borsa Payı at asama_1e21 = 9', K.stagePay(K.stageRank('asama_1e21')) === 9);
K.state.stageBest = K.stageRank('asama_1e21'); K.checkAchievements();
check('achievement asama_1e21 granted (placeholder name), Mars achievement not', K.state.achievements.includes('asama_1e21') && !K.state.achievements.includes('asama_8'));
check('legacy (server) index of asama_1e21 = 7 (same as YZ Lab; Mars stays 8)', K.legacyStageIndex(K.stageRank('asama_1e21')) === 7 && K.legacyStageIndex(K.stageRank('mars_ofisi')) === 8);
{ const d = K.saveData(); check('save: stageBestId asama_1e21, saveVersion 6', d.stageBestId === 'asama_1e21' && d.saveVersion === 6 && d.version === 6); }

// ---------------------------------------------------------------- yer tutucular
const V45T = K.V45_TEXT;
check('no V45_TEXT placeholder left except rep.perk.E3 (E3 off, karar 3); no METIN BEKLENIYOR in game.js', Object.keys(V45T).filter((k) => V45T[k].startsWith('[')).join() === 'rep.perk.E3' && !/METIN BEKLENIYOR/.test(SRC), Object.keys(V45T).filter((k) => V45T[k].startsWith('[')));

// ---------------------------------------------------------------- F3 = yalnız config
const K3 = load('F3');
check('F3 selected via config: V45.name F3, growth H20 (100–299 x1.20)', K3.V45.name === 'F3' && JSON.stringify(K3.V45.growth) === '[[0,1.15],[100,1.2],[300,1.1],[500,1.05],[1000,1.025],[3000,1.0125]]');
check('F3: everything else identical to F2 (rep, borsa, 1e21, tier list, tierMult)', JSON.stringify(K3.V45.rep) === JSON.stringify(V.rep) && JSON.stringify(K3.V45.borsa) === JSON.stringify(V.borsa)
  && JSON.stringify(K3.V45.stage1e21) === JSON.stringify(V.stage1e21) && K3.V45.tierMult === V.tierMult && JSON.stringify(K3.GEN_TIERS.map((t) => [t[0], t[2], t[3]])) === JSON.stringify(K.GEN_TIERS.map((t) => [t[0], t[2], t[3]])));
K3.state = K3.newState();
const st3 = K3.GENERATORS[0];
K3.state.gens.stajyer = 100; const q100 = K3.genCost(st3, 1); K3.state.gens.stajyer = 101;
check('F3 curve: unit 101 costs x1.20 of unit 100 (F2: x1.15)', near(K3.genCost(st3, 1) / q100, 1.2, 1e-9));
K3.state.gens.stajyer = 99;
check('F3 below 100 identical to F2', (() => { K.state = K.newState(); K.state.gens.stajyer = 99; return near(K3.genCost(st3, 1), K.genCost(K.GENERATORS[0], 1), 1e-12); })());
const t3 = K3.GEN_TIERS.slice(5).map((t) => t[1]);
check('F3 tier costs follow the F3 curve: 150 tier = 1.15^100 x 1.20^49 (F2 1.15^149), higher than F2', near(t3[0], Math.pow(1.15, 100) * Math.pow(1.2, 49), 1e-9) && t3.every((c, i) => c > K.GEN_TIERS[5 + i][1]));
K3.state.gens[K3.GENERATORS[12].id] = 9999;
check('F3 1e308: 10,000th unit finite (sim 1e112.5)', Math.abs(Math.log10(K3.genCost(K3.GENERATORS[12], 1)) - 112.5) < 0.1, Math.log10(K3.genCost(K3.GENERATORS[12], 1)));
const K2 = load('nope');
check('unknown preset name ignored -> F2', K2.V45.name === 'F2');

console.log(`\n${pass}/${pass + fail} passed`);
process.exit(fail ? 1 : 0);
