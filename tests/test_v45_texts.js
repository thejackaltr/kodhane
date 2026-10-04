// Kodhane v4.5 metinleri (Node, tarayıcısız): Yazı kodhane-v4.5-metinler-yazi-r1.json ile koddaki metinlerin birebir karşılaştırması.
// V45_TEXT (18), LOSS_TEXT_PENDING (2), GEN_UPG_NAMES (çalışan başına 19 [ad, emoji]: 5 v4 + 14 v4.5 kademesi).
// Çalıştır: node tests/test_v45_texts.js
'use strict';
const path = require('path'), fs = require('fs');
const ROOT = path.join(__dirname, '..');
const K = require(path.join(ROOT, 'game.js'));
const SRC = fs.readFileSync(path.join(ROOT, 'game.js'), 'utf8');
const LSRC = fs.readFileSync(path.join(ROOT, 'lossreport.js'), 'utf8');
const m = { exports: {} };
new Function('module', 'exports', 'require', LSRC).call({ Kodhane: K }, m, m.exports, require);
const L = m.exports;
let pass = 0, fail = 0;
function check(name, cond, info) {
  if (cond) pass++; else fail++;
  console.log((cond ? 'PASS ' : 'FAIL ') + name + (info !== undefined && !cond ? ' ' + JSON.stringify(info) : ''));
}
const Y_PATH = '/workspace/plans/kodhane-v4.5-metinler-yazi-r1.json';
const diffs = (a, b) => { const out = []; new Set([...Object.keys(a), ...Object.keys(b)]).forEach((k) => { if (JSON.stringify(a[k]) !== JSON.stringify(b[k])) out.push(k); }); return out; };
if (fs.existsSync(Y_PATH)) {
  const Y = JSON.parse(fs.readFileSync(Y_PATH, 'utf8'));
  const dV = diffs(K.V45_TEXT, Y.V45_TEXT);
  check('V45_TEXT = Yazı r1 V45_TEXT: 18 keys, same order, 0 differences', dV.length === 0 && Object.keys(K.V45_TEXT).length === 18 && JSON.stringify(Object.keys(K.V45_TEXT)) === JSON.stringify(Object.keys(Y.V45_TEXT)), dV);
  const dL = diffs(L.TEXT_PENDING, Y.LOSS_TEXT_PENDING);
  check('LOSS_TEXT_PENDING = Yazı r1: 2 keys, 0 differences', dL.length === 0 && Object.keys(L.TEXT_PENDING).length === 2, dL);
  const dG = diffs(K.GEN_UPG_NAMES, Y.GEN_UPG_NAMES);
  check('GEN_UPG_NAMES = Yazı r1: 13 workers x 19 [name, emoji], 0 differences', dG.length === 0 && Object.keys(K.GEN_UPG_NAMES).length === 13 && Object.values(K.GEN_UPG_NAMES).every((a) => a.length === 19), dG);
  let total = 0; Object.keys(Y.GEN_UPG_NAMES).forEach((g) => { total += Y.GEN_UPG_NAMES[g].length; });
  check('Yazı file: 13 x 19 = 247 names (65 v4 + 182 new)', total === 247);
} else console.log('NOTE Yazı JSON yok: birebir karşılaştırma atlandı');
// kademe sayısı ile ad sayısı eşleşiyor; yedek ad/emoji hiç kullanılmıyor
check('tiers per worker = 19 (5 v4 + 14 newTiers) = names per worker', K.GEN_TIERS.length === 19 && K.GENERATORS.every((g) => K.GEN_UPG_NAMES[g.id].length === K.GEN_TIERS.length));
const genUpg = K.UPGRADES.filter((u) => u.type === 'gen');
check('every worker upgrade has a Yazı name + emoji (no "Kademe {n}" fallback, no ⭐ fallback)', genUpg.length === 13 * 19 && genUpg.every((u) => u.name && !/^Kademe /.test(u.name) && u.icon && u.icon !== '⭐'),
  genUpg.filter((u) => /^Kademe /.test(u.name) || u.icon === '⭐').map((u) => u.id));
check('upgrade order = tier order (stajyer_6 = 150 Kendi Kupası ☕, stajyer_19 = 10000 Zaman Yolcusu Stajyer ⏳)', (() => { const u6 = K.UPGRADES.find((u) => u.id === 'stajyer_6'), u19 = K.UPGRADES.find((u) => u.id === 'stajyer_19');
  return u6.req.count === 150 && u6.name === 'Kendi Kupası' && u6.icon === '☕' && u19.req.count === 10000 && u19.name === 'Zaman Yolcusu Stajyer' && u19.icon === '⏳'; })());
check('v4 names untouched (e.g. senior_4 Kıdemli Maaş Paketi 💼, junior_5 Kendi Framework’ü)', K.UPGRADES.find((u) => u.id === 'senior_4').name === 'Kıdemli Maaş Paketi' && K.UPGRADES.find((u) => u.id === 'senior_4').icon === '💼'
  && K.UPGRADES.find((u) => u.id === 'junior_5').name === 'Kendi Framework’ü');
check('fallback "Kademe {n}" still renders with the threshold', K.v45Text('upg.genTier.name', { n: 150 }) === 'Kademe 150');
check('offer.big prefix 💎 (Yazı)', K.v45Text('offer.big') === '💎 Büyük müşteri:');
// kalan yer tutucular: yalnız rep.perk.E3 (E3 kapalı, karar 3)
const ph = Object.keys(K.V45_TEXT).filter((k) => /^\[/.test(K.V45_TEXT[k]));
check('remaining placeholders: only rep.perk.E3 (E3 off, never shown)', ph.join() === 'rep.perk.E3' && K.repPerk('E3') === false, ph);
check('no "METIN BEKLENIYOR" left in game.js / lossreport.js', !/METIN BEKLENIYOR/.test(SRC) && !/METIN BEKLENIYOR/.test(LSRC));
console.log('\n' + pass + '/' + (pass + fail) + ' passed');
process.exit(fail ? 1 : 0);
