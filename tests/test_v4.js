// Kodhane v4 çekirdek testleri (Node, tarayıcısız): aşamalar, yeni çalışanlar, Halka Arz, Borsa Payı Ağacı,
// büyük sayı biçimi, kayıt taşıma (v3 -> v4) ve haber kuyruğu. Çalıştır: node tests/test_v4.js
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
const CFG = K.CFG, H = CFG.halkaArz, T = CFG.tree;

// ---------------------------------------------------------------- sürüm, aşamalar
check('version 4.4.2 / save version 5', K.VERSION === '4.4.2' && K.SAVE_VERSION === 5 && fresh().version === 5);
const names = K.STAGES.map((s) => s.name);
check('11 stages: Unicorn and Şirketler Grubu between Global Holding and Teknoloji Devi (v4.4)', names.length === 11 && names.slice(5).join('|') === 'Global Holding|Unicorn|Şirketler Grubu|Teknoloji Devi|Yapay Zekâ Laboratuvarı|Mars Ofisi', names);
check('stage thresholds strictly increasing', K.STAGES.every((s, i) => i === 0 || s.at > K.STAGES[i - 1].at));
check('new stage messages (spec copy)',
  K.STAGE_BY_ID.teknoloji_devi.msg === "Tebrikler! Artık müşteri aramıyorsunuz, müşteriler sizi arıyor. Hepsi de 'acil' diyor." &&
  K.STAGE_BY_ID.yapay_zeka_lab.msg === "Tebrikler! Kodu artık yapay zekâ yazıyor, siz de ona 'biraz daha büyüt' diyorsunuz." &&
  K.STAGE_BY_ID.mars_ofisi.msg === "Tebrikler! Mars'tasınız. Mesajlar 20 dakikada geliyor, revize talepleri yine de anında.");
check('one tint per stage', K.STAGE_TINTS.length === K.STAGES.length && K.STAGE_TINTS.every((c) => /^#[0-9a-f]{6}$/i.test(c)));

// ---------------------------------------------------------------- yeni çalışanlar
const newGens = K.GENERATORS.filter((g) => g.stage);
check('5 stage-bound employee types, bound by stage ID (v4.4: veri, cip new; arge moves to Şirketler Grubu)', newGens.map((g) => g.id + ':' + g.stage).join(',') === 'veri:unicorn,arge:sirketler_grubu,cip:teknoloji_devi,yzlab:yapay_zeka_lab,mars:mars_ofisi', newGens.map((g) => g.id + ':' + g.stage));
check('new employees get stronger and pricier', newGens.every((g, i) => i === 0 || (g.base > newGens[i - 1].base && g.tps > newGens[i - 1].tps)));
check('each new employee has upgrades', newGens.every((g) => K.UPGRADES.filter((u) => u.target === g.id).length >= 3));
fresh();
check('new employees locked before their stage', newGens.every((g) => !K.genUnlocked(g)));
K.state.money = 1e40;
check('locked employee cannot be bought', !K.buyGen('arge', 1) && K.state.gens.arge === 0);
K.state.stageBest = K.stageRank('unicorn');
check('Unicorn unlocks Veri Merkezi only', K.genUnlocked(newGens[0]) && !K.genUnlocked(newGens[1]));
check('unlocked employee can be bought', K.buyGen('veri', 1) && K.state.gens.veri === 1);
K.state.stageBest = K.stageRank('sirketler_grubu');
check('Şirketler Grubu unlocks Ar-Ge', K.genUnlocked(newGens[1]) && !K.genUnlocked(newGens[2]) && K.buyGen('arge', 1) && K.state.gens.arge === 1);
K.state.stageBest = K.stageRank('mars_ofisi');
check('Mars Ofisi unlocks all', newGens.every((g) => K.genUnlocked(g)));

// ---------------------------------------------------------------- büyük sayılar
// v4.4.1: tam adlar Bin ... Vigintilyon (1e63), Yazı r2 (kodhane-v4.5-sayi-adlari-yazi-r2.md) ile birebir; 1e66 ve ötesi bilimsel
const R2 = ['', 'Bin', 'Milyon', 'Milyar', 'Trilyon', 'Katrilyon', 'Kentilyon', 'Sekstilyon', 'Septilyon', 'Oktilyon', 'Nonilyon', 'Desilyon', 'Undesilyon', 'Dodesilyon', 'Tredesilyon', 'Katordesilyon', 'Kendesilyon', 'Seksdesilyon', 'Septendesilyon', 'Oktodesilyon', 'Novemdesilyon', 'Vigintilyon'];
check('v4.4.1 SUFFIXES = Yazı r2 list exactly (22 items, k = 21 is Vigintilyon)', JSON.stringify(K.SUFFIXES) === JSON.stringify(R2) && K.SUFFIXES.length === 22 && K.SUFFIXES[21] === 'Vigintilyon', K.SUFFIXES);
check('no abbreviation left in SUFFIXES (full names only)', K.SUFFIXES.slice(1).every((x) => !/^(Mn|Mr|Tn|Kat|Kent)$/.test(x) && x.length >= 3));
{ const got = R2.map((nm, k) => k ? K.fmt(Math.pow(10, 3 * k)) : null).slice(1), want = R2.slice(1).map((nm) => '1 ' + nm);
  check('every step 1e3 ... 1e63 shows "1 <ad>"', JSON.stringify(got) === JSON.stringify(want), got); }
check('names with decimals (Turkish comma)', [2.5e6, 3.75e9, 1.2e12, 1e15, 2.5e18, 9.99e20, 1.234e24, 4.56e36, 7e45].map(K.fmt).join('|') ===
  '2,5 Milyon|3,75 Milyar|1,2 Trilyon|1 Katrilyon|2,5 Kentilyon|999 Kentilyon|1,23 Septilyon|4,56 Undesilyon|7 Katordesilyon', [2.5e6, 3.75e9, 1.2e12, 1e15, 2.5e18, 9.99e20, 1.234e24, 4.56e36, 7e45].map(K.fmt));
check('1e21 Sekstilyon, 1e36 Undesilyon, 1e45 Katordesilyon (Product kararı)', K.fmt(1e21) === '1 Sekstilyon' && K.fmt(1e36) === '1 Undesilyon' && K.fmt(1e45) === '1 Katordesilyon');
check('boundary: fmt(999.99e63) = "999,99 Vigintilyon"', K.fmt(999.99e63) === '999,99 Vigintilyon', K.fmt(999.99e63));
check('boundary: fmt(1e63) = "1 Vigintilyon", fmt(1.5e65) = "150 Vigintilyon"', K.fmt(1e63) === '1 Vigintilyon' && K.fmt(1.5e65) === '150 Vigintilyon', [K.fmt(1e63), K.fmt(1.5e65)]);
check('boundary: fmt(1e66) = "1e66" (sciTR unchanged)', K.fmt(1e66) === '1e66', K.fmt(1e66));
check('scientific beyond Vigintilyon (format unchanged: comma, no "+")', [1.234e70, 5e100, 1.5e300].map(K.fmt).join('|') === '1,23e70|5e100|1,5e300', [1.234e70, 5e100, 1.5e300].map(K.fmt));
check('rounding at the top name goes scientific: 999.999e63 -> "1e66"', K.fmt(999.999e63) === '1e66', K.fmt(999.999e63));
check('rounding at a lower name goes to the next name: 999.999e18 -> "1 Sekstilyon"', K.fmt(999.999e18) === '1 Sekstilyon', K.fmt(999.999e18));
check('tl(): "999,99 Septendesilyon TL" is 24 characters (longest value)', K.tl(999.99e54) === '999,99 Septendesilyon TL' && K.tl(999.99e54).length === 24, K.tl(999.99e54));
{ // her kademede 999,995 x 10^(3k) ve hemen altı/üstü: hiçbir zaman "1000" / "1.000" görünmez
  const bad = [];
  for (let k = 0; k <= 22; k++) for (const m of [999.5, 999.9, 999.99, 999.994, 999.995, 999.9951, 999.999, 999.99999999]) {
    const f = K.fmt(m * Math.pow(10, 3 * k)); if (/^1\.?000\b|1000/.test(f)) bad.push([m, k, f]); }
  check('rounding boundary 999,995 x 10^(3k), k = 0..22: never "1000 <ad>" or "1.000"', bad.length === 0, bad); }
check('v4.4.1 fix: 999,5 ... 999,99 TL shows "1 Bin" (was "1.000")', K.fmt(999.5) === '1 Bin' && K.fmt(999.99) === '1 Bin' && K.fmt(999.4) === '999' && K.fmt(9.5) === '9,5', [K.fmt(999.5), K.fmt(999.99), K.fmt(999.4)]);
check('small numbers unchanged', [0, 5, 12.4, 999, 1000, 1234.5, -2.5e6].map(K.fmt).join('|') === '0|5|12|999|1 Bin|1,23 Bin|-2,5 Milyon', [0, 5, 12.4, 999, 1000, 1234.5, -2.5e6].map(K.fmt));
{ const d = (id) => K.ACHIEVEMENTS.find((a) => a.id === id).desc;
  check('achievement texts: full names (Yazı r2)', d('kazanc_1k') === 'Toplam 1 Bin TL kazan' && d('kazanc_1m') === 'Toplam 1 Milyon TL kazan' &&
    d('kazanc_1b') === 'Toplam 1 Milyar TL kazan' && d('kazanc_1t') === 'Toplam 1 Trilyon TL kazan', ['kazanc_1k', 'kazanc_1m', 'kazanc_1b', 'kazanc_1t'].map(d));
  check('no abbreviation in any achievement / upgrade text', ![...K.ACHIEVEMENTS, ...K.UPGRADES].some((a) => /\d\s*(Mn|Mr|Tn|Kat|Kent)\b/.test(a.desc + ' ' + a.name))); }
{ const fs = require('fs'), html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
  check('index.html Yatırım Turu note: "100 Milyon TL" (= tl(PRESTIGE 1e8)), no Mn/Mr/Tn', html.includes('İlk hisse için bu turda en az ' + K.tl(1e8) + ' kazanmalısın.') &&
    K.tl(1e8) === '100 Milyon TL' && !/\d\s*(Mn|Mr|Tn)\b/.test(html));
  const sw = fs.readFileSync(path.join(__dirname, '..', 'sw.js'), 'utf8');
  check('sw.js cache name moves forward with the version (v4.4.2)', /var CACHE_VERSION = 'v4\.4\.2';/.test(sw)); }

// ---------------------------------------------------------------- Halka Arz
fresh();
check('IPO locked with 0 rounds', !K.ipoUnlocked() && K.doIpo() === 0);
function round(earn) { K.earn(earn); return K.doPrestige(); }
round(1e9); round(1e9);
check('IPO locked after 2 rounds', K.state.cycleRounds === 2 && !K.ipoUnlocked());
round(1e9);
check('IPO unlocks after CFG.halkaArz.rounds rounds', K.state.cycleRounds === H.rounds && K.ipoUnlocked());
check('first IPO gives at least firstMin even with a small cycle', K.state.cycleEarned === 3e9 && K.state.cycleStage === 4 && K.ipoGain() === H.firstMin);
K.earn(5e10 - 3e9);
check('gain = stagePays[ID of highest stage this cycle] (Global Holding -> 2)', K.STAGES[K.state.cycleStage].id === 'global_holding' && K.ipoGain() === H.stagePays.global_holding && K.ipoGain() === 2, [K.state.cycleStage, K.ipoGain()]);
K.state.upgrades = ['click_2']; K.state.tree = []; K.state.achievements.push('tik_1');
const before = clone(K.state), pendingBefore = K.sharesGain();
const g1 = K.doIpo();
const s = K.state;
check('IPO pays Borsa Payı', g1 === 2 && s.ipoShares === 2 && s.ipoSharesEarned === 2 && s.ipoCount === 1);
check('IPO keeps totalEarned (leaderboard score)', s.totalEarned === before.totalEarned);
check('IPO resets money, employees, upgrades; v4.4 keeps Yatırımcı Hissesi and adds this round\'s pending shares', s.money === 0 && K.totalOwned() === 0 && s.upgrades.length === 0 && s.runEarned === 0 &&
  pendingBefore > 0 && s.shares === before.shares + pendingBefore, [before.shares, pendingBefore, s.shares]);
check('IPO resets cycle (rounds, earnings) but keeps prestige count', s.cycleRounds === 0 && s.cycleEarned === 0 && s.prestigeCount === before.prestigeCount);
check('IPO keeps achievements and stageBest', s.achievements.indexOf('tik_1') !== -1 && s.stageBest === before.stageBest);
K.checkAchievements();
check('Borsa Zili achievement', s.achievements.indexOf('borsa_zili') !== -1 && K.ACHIEVEMENTS.find((a) => a.id === 'borsa_zili').desc === 'İlk halka arzını yaptın.');
check('IPO locked again right after', !K.ipoUnlocked());
round(1e9); round(1e9); round(1e9);
check('second IPO has no minimum (gain 0 -> refused)', K.ipoGain() === 0 && K.doIpo() === 0 && K.state.ipoCount === 1);
// save round trip after IPO must not re-run the v3 migration
const rt = JSON.parse(K.serialize()); K.deserialize(JSON.stringify(rt));
check('post-IPO save reload keeps cycle fields', K.state.version === 5 && K.state.cycleRounds === 3 && K.state.cycleEarned === 3e9 && K.state.ipoCount === 1);
const sv = H.rounds; H.rounds = 5;
check('IPO round requirement is a setting', !K.ipoUnlocked()); H.rounds = sv;
const sm = H.mode; H.mode = 'root'; K.state.cycleEarned = H.threshold * Math.pow(2, H.root); K.state.ipoCount = 1;
check('IPO root mode (alternative) is a setting: floor(k*(cycle/T)^(1/root))', K.ipoGain() === 2, K.ipoGain());
const sk = H.k; H.k = 2; check('IPO k is a setting (root mode)', K.ipoGain() === 4); H.k = sk; H.mode = sm;

// ---------------------------------------------------------------- Borsa Payı Ağacı
fresh();
check('tree: 4 branches x 3 nodes', K.TREE.length === 4 && K.TREE.every((b) => b.nodes.length === 3) && K.TREE.map((b) => b.name).join(',') === 'Kod,Ekip,Müşteri,Yatırım');
check('tree: node costs 1/3/6 from settings', K.TREE.every((b) => b.nodes.map(K.nodeCost).join(',') === '1,3,6'));
check('tree: full tree costs 40', K.TREE.reduce((a, b) => a + b.nodes.reduce((x, n) => x + K.nodeCost(n), 0), 0) === 40);
check('tree: poor without pays, second node locked', K.nodeState('kod_1') === 'poor' && K.nodeState('kod_2') === 'locked');
K.state.ipoShares = 10;
check('tree: locked node cannot be bought', !K.buyNode('kod_2') && K.state.ipoShares === 10);
check('tree: buy first node', K.buyNode('kod_1') && K.state.ipoShares === 9 && K.nodeState('kod_1') === 'owned' && K.nodeState('kod_2') === 'ready');
check('tree: owned node cannot be bought twice', !K.buyNode('kod_1') && K.state.ipoShares === 9);
check('tree: sequential buy 3 then 6', K.buyNode('kod_2') && K.state.ipoShares === 6 && K.buyNode('kod_3') && K.state.ipoShares === 0);
check('tree: poor again', K.nodeState('ekip_1') === 'poor');
// effects
fresh(); K.state.gens.stajyer = 10;
const c0 = K.clickBase(), t0 = K.baseTps(), g0 = K.genCost(K.GENERATORS[0], 1);
K.state.tree = ['kod_1']; check('Parmak Hızı doubles click', Math.abs(K.clickBase() - c0 * T.clickMult) < 1e-9);
K.state.tree = ['kod_1', 'kod_2', 'kod_3']; check('Kas Hafızası adds 1% of tps to click', Math.abs(K.clickBase() - (c0 * T.clickMult + T.clickPct * K.baseTps())) < 1e-9);
K.state.tree = ['ekip_1']; check('İyi Referans x1.5 production', Math.abs(K.baseTps() - t0 * T.genMult) < 1e-9);
K.state.tree = ['ekip_1', 'ekip_2', 'ekip_3']; check('İK Anlaşması cost growth 1.15 -> 1.14', K.costGrowth() === 1.14);
K.state.gens.stajyer = 30;
const cA = K.genCost(K.GENERATORS[0], 1); K.state.tree = []; const cB = K.genCost(K.GENERATORS[0], 1);
check('İK Anlaşması makes the 31st Stajyer cheaper', cA < cB, [cA, cB]);
fresh(); K.state.tree = ['ekip_1', 'ekip_2']; K.state.ipoCount = 1; K.state.cycleRounds = 3; K.earn(1e12); K.doPrestige();
check('Hazır Kadro: starts with 5 Stajyer + 2 Junior after a reset', K.state.gens.stajyer === 5 && K.state.gens.junior === 2);
fresh();
check('offline cap 8 h by default', K.offlineCapSec() === 8 * 3600);
K.state.tree = ['yatirim_1']; check('Uzaktan Çalışma: 12 h', K.offlineCapSec() === 12 * 3600);
K.state.tree = ['yatirim_1', 'yatirim_2']; check('Yatırımcı Güveni: share bonus +25%', Math.abs(K.shareBonus() - 0.125) < 1e-12);
K.state.tree = ['yatirim_1', 'yatirim_2', 'yatirim_3']; check('Gece Vardiyası: 24 h', K.offlineCapSec() === 24 * 3600);
K.state.tree = []; check('offer: 10 s, normal frequency and pay', K.offerSec() === 10 && K.offerFreq() === 1 && K.offerPayMult() === 1);
K.state.tree = ['musteri_1', 'musteri_2', 'musteri_3'];
check('Müşteri branch: 25% more offers, 15 s, x2 pay', Math.abs(K.offerFreq() - 1 / (1 + T.offerMore)) < 1e-12 && T.offerMore === 0.25 && K.offerSec() === 15 && K.offerPayMult() === 2);
// Akış Hâli
fresh(); K.state.tree = ['kod_1', 'kod_2']; K.rng = () => 0.01; K.state.money = 0;
const base = K.clickValue ? K.clickBase() : 0; K.doClick();
check('Akış Hâli: x10 on a lucky click', K.lastFlow === true && K.state.money >= base * T.flowMult - 1e-9, [K.state.money, base]);
K.state.tree = ['kod_1']; K.doClick(); check('no flow without the node', K.lastFlow === false);
K.rng = Math.random;

// descriptions come from settings (spec copy)
const D = {}; K.TREE.forEach((b) => b.nodes.forEach((n) => { D[n.id] = n.desc(); }));
check('desc: Parmak Hızı', D.kod_1 === "Klavye alev aldı. 'Kod yaz' kazancı ×2.", D.kod_1);
check('desc: Akış Hâli', D.kod_2 === 'Kulaklık takıldı, dünya sustu. Her tıklamada %5 ihtimalle ×10 kazanç.', D.kod_2);
check('desc: Kas Hafızası', D.kod_3 === "Parmaklar artık kendi kendine yazıyor. Her tıklama saniyelik gelirinin %1'ini de getirir.", D.kod_3);
check('name: Kas Hafızası', K.TREE[0].nodes[2].name === 'Kas Hafızası');
check('desc: Sadık Müşteri (number from settings)', D.musteri_1 === 'Aynı müşteri, yine aynı logo. Proje teklifleri %25 daha sık gelir.', D.musteri_1);
check('desc: İyi Referans', D.ekip_1 === 'Eski çalışanların seni her yerde övüyor. Tüm çalışanlar ×1,5 üretir.', D.ekip_1);
check('desc: Hazır Kadro', D.ekip_2 === 'Kapıda sıra var. Her sıfırlamadan sonra 5 Stajyer ve 2 Junior ile başlarsın.', D.ekip_2);
check('desc: İK Anlaşması', D.ekip_3 === "Maaş pazarlığı artık çay eşliğinde. Her yeni çalışanın fiyat artışı %15'ten %14'e iner.", D.ekip_3);
check('desc: Esnek Teslim', D.musteri_2 === "'Yarına yetişir mi?' artık 'Öbür güne olur mu?' oldu. Teklif süresi 10 saniyeden 15 saniyeye çıkar.", D.musteri_2);
check('desc: Referans Zinciri', D.musteri_3 === 'Her müşteri bir müşteri daha getiriyor. Proje ödülleri ×2.', D.musteri_3);
check('desc: Uzaktan Çalışma', D.yatirim_1 === 'Ekip evden de çalışıyor. Çevrimdışı kazanç sınırı 8 saatten 12 saate çıkar.', D.yatirim_1);
check('desc: Yatırımcı Güveni', D.yatirim_2 === 'Sunum slaytları artık animasyonlu. Yatırım turu bonusu %25 güçlenir.', D.yatirim_2);
check('desc: Gece Vardiyası', D.yatirim_3 === 'Ofisin ışığı hiç sönmüyor. Çevrimdışı kazanç sınırı 24 saate çıkar.', D.yatirim_3);
const keep = clone(T);
T.clickMult = 3; T.flowChance = 0.1; T.clickPct = 0.03; T.costGrowth = 1.12; T.offerSec = 20; T.offerMore = 0.5; T.offlineHours1 = 16; T.shareBoost = 0.4; T.startGens = [['stajyer', 10]];
const find = (id) => K.TREE.flatMap((b) => b.nodes).find((n) => n.id === id).desc();
check('desc follows settings (click, flow, pct)', find('kod_1').endsWith('×3.') && find('kod_2').includes('%10 ihtimalle') && find('kod_3').includes("%3'ünü de"), [find('kod_1'), find('kod_2'), find('kod_3')]);
check('desc follows settings (growth, offer, offline, boost, start)', find('ekip_3').endsWith("%15'ten %12'ye iner.") && find('musteri_2').includes('15 saniyeye') === false && find('musteri_2').includes('20 saniyeye') &&
  find('yatirim_1').includes('16 saate') && find('yatirim_2').includes('%40') && find('ekip_2').includes('10 Stajyer ile') && find('musteri_1').includes('%50 daha sık'), [find('ekip_3'), find('ekip_2')]);
Object.assign(T, keep);
check('Turkish suffix helpers', [1, 3, 4, 6, 9, 10, 12, 20, 25, 40, 50, 60, 100].map(K.sfxAcc3).join(',') === 'ini,ünü,ünü,sını,unu,unu,sini,sini,ini,ını,sini,ını,ünü', [1, 3, 4, 6, 9, 10, 12, 20, 25, 40, 50, 60, 100].map(K.sfxAcc3));

// ---------------------------------------------------------------- kayıt taşıma (oyun v3 kaydı, kayıt sürümü 2)
function v3Save(over) {
  const gens = { stajyer: 150, junior: 120, senior: 100, tasarimci: 80, pm: 60, ai: 45, sunucu: 30, ofis: 12 };
  return Object.assign({
    version: 2, money: 1.25e9, runEarned: 3.1e9, totalEarned: 8.4e11, clicks: 4321, clickEarned: 9.9e7, playTime: 50000,
    startedAt: Date.now() - 5 * 86400000, lastSaved: Date.now(), gens, upgrades: ['stajyer_1', 'junior_1', 'stajyer_2'],
    shares: 57, prestigeCount: 4, boostLeft: 12, eventsClicked: 40, offlineEarned: 2e10, stage: 5,
    buffs: [{ kind: 'prod', mult: 2, left: 30 }], achievements: ['tik_1', 'kazanc_1m', 'asama_3', 'asama_5'], critClicks: 70, eventsResolved: 22,
    logoAccepted: 3, revisions: 4, meetings: 5, serverCrashes: 1, reputation: 18, noMeetingSec: 100,
    daily: { day: '2026-09-28', tasks: [{ kind: 'clicks', target: 200, base: 0, reward: 1000, done: false }], streak: 3, lastDone: '2026-09-27' }
  }, over || {});
}
const old = v3Save();
K.deserialize(JSON.stringify(old));
const m = K.state;
check('migration: version bumped to 5, loadedVersion 2', m.version === 5 && K.loadedVersion === 2);
check('migration: money, run and total earnings unchanged', m.money === old.money && m.runEarned === old.runEarned && m.totalEarned === old.totalEarned);
check('migration: all old employees kept, new ones 0', Object.keys(old.gens).every((k) => m.gens[k] === old.gens[k]) && m.gens.veri === 0 && m.gens.arge === 0 && m.gens.cip === 0 && m.gens.yzlab === 0 && m.gens.mars === 0);
check('migration: upgrades, achievements, shares, prestige kept', JSON.stringify(m.upgrades) === JSON.stringify(old.upgrades) && JSON.stringify(m.achievements) === JSON.stringify(old.achievements) && m.shares === 57 && m.prestigeCount === 4);
check('migration: stats kept', ['clicks', 'clickEarned', 'playTime', 'startedAt', 'eventsClicked', 'offlineEarned', 'critClicks', 'eventsResolved', 'reputation', 'boostLeft'].every((k) => m[k] === old[k]));
check('migration: daily + buffs kept', m.daily.streak === 3 && m.daily.tasks.length === 1 && m.buffs.length === 1);
check('migration: cycle = all-time, rounds = prestige count (Halka Arz can unlock)', m.cycleEarned === old.totalEarned && m.cycleRounds === 4 && K.ipoUnlocked());
check('migration: no IPO / tree yet', m.ipoShares === 0 && m.ipoCount === 0 && m.tree.length === 0);
check('migration: Global Holding player gets the new-stage news', m.stageBest === 5 && JSON.stringify(m.newsPending) === '["yeni_asama"]');
K.deserialize(K.serialize());
check('migration: reload of migrated save is stable (no second migration, news still pending)', K.loadedVersion === 5 && K.state.cycleRounds === 4 && JSON.stringify(K.state.newsPending) === '["yeni_asama"]');
K.deserialize(JSON.stringify(v3Save({ stage: 3, runEarned: 2e6, totalEarned: 5e6, prestigeCount: 0, shares: 0 })));
check('migration: early player gets no new-stage news', K.state.newsPending.length === 0 && K.state.stageBest === 3 && K.state.cycleRounds === 0);
K.deserialize(JSON.stringify({ version: 1, money: 10, runEarned: 50, totalEarned: 50, gens: { stajyer: 2 } }));
check('migration: very old v1 save loads', K.state.version === 5 && K.state.gens.stajyer === 2 && K.state.totalEarned === 50);
K.deserialize(JSON.stringify(Object.assign(v3Save({ version: 3 }), { tree: ['kod_2', 'kod_1', 'kod_1', 'yok', 'ekip_2'], newsSeen: ['siralama', 'x', 'siralama'], ipoShares: -3, cycleEarned: 1e30 })));
check('v4 save sanitised: tree order/prefix, known news, no negatives, cycle <= total',
  JSON.stringify(K.state.tree) === '["kod_1"]' && JSON.stringify(K.state.newsSeen) === '["siralama"]' && K.state.ipoShares === 0 && K.state.cycleEarned === K.state.totalEarned, [K.state.tree, K.state.newsSeen]);

// ---------------------------------------------------------------- haber kuyruğu
fresh();
check('news order: Global Holding, Sıralama, then Açık Ofis', K.NEWS.map((n) => n.id).join(',') === 'yeni_asama,siralama,acik_ofis');
check('Açık Ofis news copy + link', K.NEWS[2].title === 'Kodhane ailesine yeni oyun: Açık Ofis!' && K.NEWS[2].text() === 'Kendi ofisini kur, masaları yerleştir, ekibini büyüt. E-postana gelen 6 haneli kodla giriş yap, ilerlemen buluta kaydolsun.' &&
  K.NEWS[2].action === "Açık Ofis'i dene" && K.NEWS[2].count === 'news_acikofis' && K.NEWS[2].url === 'https://acikofis.teserix.com/?utm_source=kodhane&utm_medium=news&utm_campaign=acikofis_v1');
check('news copy', K.NEWS[1].title === 'Yeni: Sıralama!' && K.NEWS[1].text() === 'Toplam kazancınla listeye gir. Yatırım turu yapsan da yerin korunur.' && K.NEWS[1].action === 'Sıralamaya bak' &&
  K.NEWS[0].title === 'Global Holding son durak değilmiş.' && K.NEWS[0].text() === 'Yeni aşama açıldı: Teknoloji Devi.');
check('no Sıralama news when the leaderboard is not configured (Açık Ofis still)', K.nextNews().id === 'acik_ofis');
K.newsNeedsLeaderboard = () => true;
check('new player: Sıralama news', K.nextNews().id === 'siralama');
K.state.newsPending = ['yeni_asama'];
check('Global Holding player: new-stage news first', K.nextNews().id === 'yeni_asama');
K.markNewsSeen('yeni_asama');
check('then Sıralama', K.nextNews().id === 'siralama' && K.state.newsPending.length === 0);
K.markNewsSeen('siralama'); K.markNewsSeen('siralama');
check('then Açık Ofis', K.nextNews().id === 'acik_ofis');
K.markNewsSeen('acik_ofis');
check('once only: nothing after all are seen (no duplicates)', K.nextNews() === null && JSON.stringify(K.state.newsSeen) === '["yeni_asama","siralama","acik_ofis"]');
K.earn(1e12); K.doPrestige();
check('seen flags survive a Yatırım Turu', K.state.newsSeen.length === 3);
K.state.cycleRounds = 3; K.doIpo();
check('seen flags survive a Halka Arz', K.state.newsSeen.length === 3 && K.nextNews() === null);
K.deserialize(K.serialize());
check('seen flags survive save/load', K.state.newsSeen.length === 3 && K.nextNews() === null);
check('news settings', CFG.newsPerSession === 1 && CFG.newsDelaySec > 0);

console.log(`\n${pass}/${pass + fail} passed`);
process.exit(fail ? 1 : 0);
