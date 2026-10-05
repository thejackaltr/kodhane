// Kodhane v4.5 sıralama aşama adı testleri (Node, tarayıcısız): leaderboard.js stageIdLabel / rowStageLabel.
// v4.5 skor kuralıyla sıralama RPC'si aşama kimliği olarak 'asama_1e21' döndürebilir; istemci tanımadığı kimlikte çökmez,
// ham kimliği göstermez, genel yer tutucu ada düşer. Metinler Yazı'dan bekleniyor (METIN BEKLENIYOR).
// Çalıştır: node tests/test_v45_stage.js
'use strict';
const path = require('path'), fs = require('fs'), vm = require('vm');
const ROOT = path.join(__dirname, '..');
const K = require(path.join(ROOT, 'game.js'));
let pass = 0, fail = 0;
function check(name, cond, info) {
  if (cond) pass++; else fail++;
  console.log((cond ? 'PASS ' : 'FAIL ') + name + (info !== undefined && !cond ? ' ' + JSON.stringify(info) : ''));
}
// leaderboard.js tarayıcı betiği: en küçük window/document taklidiyle yüklenir (DOM öğesi yok -> start() hiçbir şey çizmez)
const win = { Kodhane: K, addEventListener() {}, location: { origin: 'https://kodhane.teserix.com', pathname: '/' } };
const sandbox = { window: win, document: { readyState: 'complete', getElementById: () => null, addEventListener() {} }, navigator: {}, console };
vm.createContext(sandbox);
const SRC = fs.readFileSync(path.join(ROOT, 'leaderboard.js'), 'utf8');
vm.runInContext(SRC, sandbox, { filename: 'leaderboard.js' });
const LB = K.leaderboard;
check('leaderboard.js loads in Node (stub DOM), exposes stageIdLabel / rowStageLabel / stageText', !!LB && typeof LB.stageIdLabel === 'function' && typeof LB.rowStageLabel === 'function' && !!LB.stageText);
const T = LB.stageText, GEN = T['leaderboard.stageUnknown'], E21 = '🌌 Yörünge Üssü';
check('stage texts: only leaderboard.stageUnknown = "Yeni aşama" (Yazı asama-1e21 r1, no emoji); old placeholders removed',
  JSON.stringify(Object.keys(T)) === '["leaderboard.stageUnknown"]' && GEN === 'Yeni aşama' && !/METIN BEKLENIYOR/.test(SRC) && !/leaderboard\.stage\.(asama_1e21|unknown)/.test(SRC), T);
check('asama_1e21 is a real stage in game.js (Yazı r1: 🌌 Yörünge Üssü, between Yapay Zekâ Laboratuvarı and Mars Ofisi)',
  K.STAGE_BY_ID.asama_1e21 && K.STAGE_BY_ID.asama_1e21.name === 'Yörünge Üssü' && K.STAGE_BY_ID.asama_1e21.icon === '🌌'
  && K.stageRank('asama_1e21') === K.stageRank('yapay_zeka_lab') + 1 && K.stageRank('mars_ofisi') === K.stageRank('asama_1e21') + 1);

// ---------------------------------------------------------------- bilinen kimlikler: mevcut adlar
const known = K.STAGES.map((s) => [s.id, s.icon + ' ' + s.name]);
check('every known stage id -> its current name (icon + name), e.g. mars_ofisi -> 🔴 Mars Ofisi, unicorn -> 🦄 Unicorn',
  known.length === 12 && known.every(([id, lab]) => LB.stageIdLabel(id) === lab) && LB.stageIdLabel('mars_ofisi') === '🔴 Mars Ofisi' && LB.stageIdLabel('unicorn') === '🦄 Unicorn',
  known.filter(([id, lab]) => LB.stageIdLabel(id) !== lab));
check('known id label = legacy stageLabel for the same stage (one naming source)', K.LEGACY_STAGE_IDS.every((id, i) => LB.stageIdLabel(id) === LB.stageLabel(i)));

// ---------------------------------------------------------------- asama_1e21 ve bilinmeyenler
check('asama_1e21 -> 🌌 Yörünge Üssü (its stage name, not the generic one, not the raw id)', LB.stageIdLabel('asama_1e21') === E21 && E21 !== GEN && !/asama|1e21/.test(E21));
const odd = ['asama_bilinmeyen_x', 'uzay_istasyonu', 'ASAMA_1E21', ' mars_ofisi', '__proto__', 'constructor', 'toString', 'hasOwnProperty', '<img src=x onerror="window.__xss=1">'];
const oddOut = odd.map((id) => { try { return LB.stageIdLabel(id); } catch (e) { return 'THROW ' + e.message; } });
check('unknown string ids (asama_bilinmeyen_x, prototype names, case/space variants, <img onerror>) -> generic name', oddOut.every((x) => x === GEN), oddOut);
check('raw id never shown to the player', odd.every((id, i) => !oddOut[i].includes(id.trim())) && !/[<>]/.test(GEN));
const bad = [null, undefined, '', 0, 5, 8, NaN, Infinity, -1, true, false, {}, [], ['mars_ofisi'], { id: 'mars_ofisi' }, () => 'mars_ofisi', Symbol('x'), 10n];
const badOut = bad.map((v) => { try { return LB.stageIdLabel(v); } catch (e) { return 'THROW ' + e.message; } });
check('null / undefined / "" / numbers / booleans / objects / arrays / functions / Symbol / BigInt -> generic name, no exception', badOut.every((x) => x === GEN), badOut);
check('stageIdLabel with no argument -> generic', LB.stageIdLabel() === GEN);
const hostile = {}; Object.defineProperty(hostile, 'stage_id', { enumerable: true, get() { throw new Error('boom'); } });
let hostileOut; try { hostileOut = LB.rowStageLabel(hostile); } catch (e) { hostileOut = 'THROW ' + e.message; }
check('rowStageLabel: a row whose stage_id getter throws -> generic, no exception', hostileOut === GEN, hostileOut);

// ---------------------------------------------------------------- satır: stage_id (v7) / stage (v6); best_stage_id okunmaz
const row = (o) => Object.assign({ rank: 1, nickname: 'x', score: 10, is_me: false, status: 'ok' }, o);
check('row: known stage_id -> its name (Unicorn, not the legacy Global Holding)', LB.rowStageLabel(row({ stage: 5, stage_id: 'unicorn' })) === '🦄 Unicorn');
check('row: stage_id asama_1e21 -> 🌌 Yörünge Üssü (not the legacy Mars Ofisi)', LB.rowStageLabel(row({ stage: 8, stage_id: 'asama_1e21' })) === E21);
check('row: unknown stage_id -> generic name (no longer the legacy stage label)', LB.rowStageLabel(row({ stage: 5, stage_id: 'asama_bilinmeyen_x' })) === GEN);
check('row: non-string stage_id (number / "" / object) -> generic', [5, '', {}, true].every((v) => LB.rowStageLabel(row({ stage: 5, stage_id: v })) === GEN));
check('row: best_stage_id is not read (table column only, no RPC returns it): a row with only best_stage_id -> legacy label from stage',
  LB.rowStageLabel(row({ stage: 8, best_stage_id: 'asama_1e21' })) === '🔴 Mars Ofisi' && LB.rowStageLabel(row({ stage: 5, best_stage_id: 'sirketler_grubu' })) === '🌐 Global Holding'
  && LB.rowStageLabel(row({ stage: 5, best_stage_id: 'asama_bilinmeyen_x' })) === '🌐 Global Holding' && LB.rowStageLabel(row({ best_stage_id: 'unicorn' })) === GEN);
check('row: stage_id wins over a stray best_stage_id', LB.rowStageLabel(row({ stage: 5, stage_id: 'unicorn', best_stage_id: 'asama_1e21' })) === '🦄 Unicorn');
check('row: v6 row (no stage_id key, legacy rank only) -> legacy view for every legacy rank 0..8 + "Aşama N" beyond',
  K.LEGACY_STAGE_IDS.every((id, i) => { const v6 = { rank: 1, nickname: 'x', score: 10, stage: i, is_me: false, status: 'ok' }; return !('stage_id' in v6) && LB.rowStageLabel(v6) === LB.stageLabel(i); })
  && LB.rowStageLabel({ rank: 1, nickname: 'x', score: 10, stage: 9, is_me: false }) === 'Aşama 10');
check('row: stage_id null / missing (v6, own row) -> legacy stage label as before', LB.rowStageLabel(row({ stage: 5, stage_id: null })) === '🌐 Global Holding'
  && LB.rowStageLabel(row({ stage: 6 })) === '🛰️ Teknoloji Devi' && LB.rowStageLabel(row({ stage: 12 })) === 'Aşama 13');
check('row: no stage information at all -> generic, no exception', [row({}), row({ stage: null, stage_id: null }), null, undefined, 'x', 5].every((r) => LB.rowStageLabel(r) === GEN));
check('legacy stageLabel(number) unchanged (5, 8, 12, null)', LB.stageLabel(5) === '🌐 Global Holding' && LB.stageLabel(8) === '🔴 Mars Ofisi' && LB.stageLabel(12) === 'Aşama 13' && LB.stageLabel(null) === '');
check('buildView keeps rows with unknown / odd stage ids (only nickname/score/rank decide validity)', LB.buildView([row({ stage_id: 'asama_1e21' }), row({ rank: 2, stage_id: 'asama_bilinmeyen_x' }), row({ rank: 3, stage_id: 42 })], 50).top.length === 3);
check('stage label is written with textContent only (rowNode -> node(), no innerHTML with data)', /var st = rowStageLabel\(r\);\s*if \(st\) who\.appendChild\(node\('div', 'lb-stage', st\)\);/.test(SRC)
  && /n\.textContent = text;/.test(SRC) && (SRC.match(/innerHTML\s*=/g) || []).length === (SRC.match(/innerHTML = '';/g) || []).length);

console.log(`\n${pass}/${pass + fail} passed`);
process.exit(fail ? 1 : 0);
