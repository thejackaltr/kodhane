// Kodhane v4.4 çekirdek testleri (Node, tarayıcısız): Halka Arz'da hisseler korunur (keepShares 1.0 + bankPending), Borsa
// hızlandırıcısı (+%10 / pay, tavan 40 pay), iki Halka Arz arası 12 saat (saat oynamasına karşı), Unicorn ve Şirketler Grubu
// aşamaları, iki yeni çalışan, aşama ID'leri ve kayıt v5 (eski sıra -> ID), startedVersion / startedAt, iki Umami olayının alanları.
// Çalıştır: node tests/test_v44.js
'use strict';
const path = require('path'), fs = require('fs');
const K = require(path.join(__dirname, '..', 'game.js'));
let pass = 0, fail = 0;
function check(name, cond, info) {
  if (cond) pass++; else fail++;
  console.log((cond ? 'PASS ' : 'FAIL ') + name + (info !== undefined && !cond ? ' ' + JSON.stringify(info) : ''));
}
const clone = (o) => JSON.parse(JSON.stringify(o));
const H = K.CFG.halkaArz, R = K.stageRank, HOUR = 3600e3;
let NOW = Date.parse('2026-10-01T06:00:00Z');
K.nowMs = () => NOW;
function fresh() { K.state = K.newState(); return K.state; }
function round(earn) { K.earn(earn); return K.doPrestige(); }

// ---------------------------------------------------------------- ayarlar = denge simülasyonu E100cd12
check('version 4.4.1, save version 5 (unchanged)', K.VERSION === '4.4.1' && K.SAVE_VERSION === 5);
check('Halka Arz balance = E100cd12 (keep 1.0 floor, bankPending, +10%/pay, cap 40, 12 h)',
  H.keepShares === 1.0 && H.keepMode === 'floor' && H.bankPending === true && H.shareGainPerEarned === 0.10 && H.accelCap === 40 && H.cooldownSec === 43200, H);
check('stage pays by ID = [0,0,0,0,0,2,3,4,5,8,12]', K.STAGES.map((s, i) => K.stagePay(i)).join(',') === '0,0,0,0,0,2,3,4,5,8,12');
check('repeatMinStage = teknoloji_devi (rank 8)', H.repeatMinStage === 'teknoloji_devi' && R('teknoloji_devi') === 8);
check('unchanged: rounds 3, firstMin 1, unspent +1% (cap 50)', H.rounds === 3 && H.firstMin === 1 && H.unspentBonus === 0.01 && H.unspentCap === 50);
const IDS = K.STAGES.map((s) => s.id).join(',');
check('stage IDs', IDS === 'freelancer,ev_ofisi,butik_studyo,ajans,dev_ajans,global_holding,unicorn,sirketler_grubu,teknoloji_devi,yapay_zeka_lab,mars_ofisi', IDS);
check('Unicorn at 1e11, Şirketler Grubu at 1e13, others unchanged', K.STAGE_BY_ID.unicorn.at === 1e11 && K.STAGE_BY_ID.sirketler_grubu.at === 1e13 &&
  K.STAGES.map((s) => s.at).join(',') === [0, 1e3, 5e4, 1e6, 5e7, 2.5e9, 1e11, 1e13, 1e15, 1e19, 1e23].join(','));
check('new stage names + icons', K.STAGE_BY_ID.unicorn.name === 'Unicorn' && K.STAGE_BY_ID.sirketler_grubu.name === 'Şirketler Grubu');
const GI = K.GENERATORS.map((g) => g.id).join(',');
check('employee IDs (veri, cip new)', GI === 'stajyer,junior,senior,tasarimci,pm,ai,sunucu,ofis,veri,arge,cip,yzlab,mars', GI);
const G = (id) => K.GENERATORS.find((g) => g.id === id);
check('Veri Merkezi 1.5e9 / 1.2e5 at Unicorn', G('veri').base === 1.5e9 && G('veri').tps === 1.2e5 && G('veri').stage === 'unicorn');
check('Çip Fabrikası 2.5e10 / 8.0e5 at Teknoloji Devi', G('cip').base === 2.5e10 && G('cip').tps === 8.0e5 && G('cip').stage === 'teknoloji_devi');
check('Ar-Ge now at Şirketler Grubu, YZ Lab / Mars by ID', G('arge').stage === 'sirketler_grubu' && G('yzlab').stage === 'yapay_zeka_lab' && G('mars').stage === 'mars_ofisi');
check('cost and output ladder strictly increasing', K.GENERATORS.every((g, i) => i === 0 || (g.base > K.GENERATORS[i - 1].base && g.tps > K.GENERATORS[i - 1].tps)));
const UN = (id) => K.UPGRADES.filter((u) => u.target === id).map((u) => u.name);
check('veri upgrades (Yazı r3 names)', UN('veri').join('|') === 'Sıcak–Soğuk Koridor|Yedeğin Yedeği|Denizaltı Kablosu|Kutup Soğutması|Uzay Soğutması', UN('veri'));
check('cip upgrades (Yazı r3 names)', UN('cip').join('|') === 'Temiz Oda Tulumu|Silikon Gofret|Nanometre Yarışı|Çip Kıtlığına Son|Kendini Tasarlayan Çip', UN('cip'));
// simülasyon dosyası varsa sayıları oradan da karşılaştır (sert durak: fark varsa FAIL)
{
  const simFile = path.join(process.env.KODHANE_SIM || '/workspace/kodhane-sim44', 'tests', 'balance_v44.js');
  if (fs.existsSync(simFile)) {
    const B = require(simFile), E = B.SCEN.E100cd12.ha;
    check('sim E100cd12 == CFG.halkaArz (keep, bank, accel, cap, cooldown)', ['keepShares', 'bankPending', 'shareGainPerEarned', 'accelCap', 'cooldownSec'].every((k) => E[k] === H[k]) && (E.keepMode || 'floor') === H.keepMode);
    check('sim PAYS44 == stage pays', B.PAYS44.join(',') === K.STAGES.map((s, i) => K.stagePay(i)).join(','));
    check('sim repeatMinStage index == rank of repeatMinStage', E.repeatMinStage === R(H.repeatMinStage));
    check('sim GENS44 == veri/cip', B.GENS44.veri.base === G('veri').base && B.GENS44.veri.tps === G('veri').tps && B.GENS44.cip.base === G('cip').base && B.GENS44.cip.tps === G('cip').tps);
  } else console.log('SKIP sim cross-check (no ' + simFile + ')');
}

// ---------------------------------------------------------------- hızlandırıcı
fresh();
K.state.runEarned = 4e12; // sqrt(4e12 / 1e8) = 200
check('no pays: shares as before (200)', K.sharesGain() === 200 && K.shareAccel() === 1);
K.state.ipoSharesEarned = 5;
check('5 pays earned: x1.5 -> 300', K.sharesGain() === 300);
K.state.ipoSharesEarned = 40;
check('40 pays: x5 -> 1000 (cap)', K.sharesGain() === 1000 && K.shareAccel() === 5);
K.state.ipoSharesEarned = 400;
check('above cap still x5', K.sharesGain() === 1000 && K.shareAccel() === 5);
K.state.ipoSharesEarned = 3; K.state.ipoShares = 0;
check('spent pays still count (ipoSharesEarned, not ipoShares)', K.sharesGain() === Math.floor(200 * 1.3));
K.state.ipoSharesEarned = 7; K.state.runEarned = 1e9;
{ const n = K.sharesGain(), at = K.nextShareAt(); const s0 = K.state.runEarned;
  K.state.runEarned = at; const a = K.sharesGain(); K.state.runEarned = at * (1 - 1e-9); const b = K.sharesGain(); K.state.runEarned = s0;
  check('nextShareAt is the exact threshold with the accelerator', a === n + 1 && b === n, [n, a, b, at]); }

// ---------------------------------------------------------------- Halka Arz: hisseler korunur, bekleme
fresh();
round(1e9); round(1e9); round(1e9);
check('IPO unlocks after 3 rounds (first IPO, no cooldown)', K.ipoUnlocked() && K.ipoCooldownLeft() === 0);
K.earn(2e12); // bu tur
const sharesBefore = K.state.shares, pending = K.sharesGain(), cyc = K.state.cycleStage;
check('pending shares ({p}) = sharesGain; kept = shares + pending', K.ipoPendingShares() === pending && K.ipoKeptShares() === sharesBefore + pending && pending > 0);
check('cycle reached Unicorn (2e12 run + earlier rounds): first IPO pays 3', K.STAGES[cyc].id === 'unicorn' && K.ipoGain() === 3, [K.STAGES[cyc].id, K.ipoGain()]);
const g1 = K.doIpo();
check('IPO: shares kept + pending banked, pays +3, ipoAt = now', g1 === 3 && K.state.shares === sharesBefore + pending && K.state.ipoShares === 3 && K.state.ipoSharesEarned === 3 && K.state.ipoAt === NOW && K.state.ipoCount === 1);
check('IPO resets rounds/cycle, money, employees', K.state.cycleRounds === 0 && K.state.cycleEarned === 0 && K.state.cycleStage === 0 && K.state.money === 0 && K.totalOwned() === 0);
round(1e9); round(1e9); round(1e9);
K.earn(2e15); // Teknoloji Devi bu döngüde
check('after 3 rounds but within 12 h: locked by cooldown (rounds ok)', K.ipoRoundsOk() && !K.ipoUnlocked() && K.doIpo() === 0 && Math.abs(K.ipoCooldownLeft() - 43200) < 1e-6);
NOW += 11 * HOUR;
check('11 h later: 1 h left', Math.abs(K.ipoCooldownLeft() - 3600) < 1e-6 && !K.ipoUnlocked());
NOW += HOUR;
check('12 h later: open again', K.ipoCooldownLeft() === 0 && K.ipoUnlocked() && K.ipoGain() === 5);
// saat geri alınırsa: ipoAt gelecekte kalır -> şimdiye çekilir, bekleme en fazla 12 saat
NOW -= 48 * HOUR;
check('clock moved back 48 h: wait clamped to at most 12 h (ipoAt pulled to now)', Math.abs(K.ipoCooldownLeft() - 43200) < 1e-6 && K.state.ipoAt === NOW);
NOW += 48 * HOUR;
check('clock back to normal: open again', K.ipoCooldownLeft() === 0 && K.ipoUnlocked());
// ileri tarihli ipoAt kayıttan gelir
{ fresh(); K.state.ipoCount = 1; K.state.cycleRounds = 3; K.state.ipoAt = NOW + 365 * 24 * HOUR;
  const str = K.serialize(); K.deserialize(str);
  check('future-dated ipoAt in a save: clamped on load (wait <= 12 h)', K.state.ipoAt === NOW && Math.abs(K.ipoCooldownLeft() - 43200) < 1e-6); }
{ fresh(); K.state.ipoCount = 2; K.state.cycleRounds = 3; K.state.ipoAt = NOW + 5 * HOUR;
  check('future ipoAt set at runtime: clamped on check', Math.abs(K.ipoCooldownLeft() - 43200) < 1e-6 && K.state.ipoAt === NOW); }
{ const old = { version: 4, saveVersion: 4, ipoCount: 2, cycleRounds: 3, stage: 6, stageBest: 6, cycleStage: 6, runEarned: 2e15, totalEarned: 3e16, cycleEarned: 3e15, startedAt: NOW - 50 * 24 * HOUR };
  K.deserialize(JSON.stringify(old));
  check('old save without ipoAt: no cooldown (open immediately)', K.state.ipoAt === 0 && K.ipoCooldownLeft() === 0 && K.ipoUnlocked() && K.ipoGain() === 5); }
{ fresh(); K.state.ipoCount = 1; K.state.ipoAt = -5; check('negative ipoAt -> 0, no cooldown', K.ipoCooldownLeft() === 0 && K.state.ipoAt === 0); }
{ const c = H.cooldownSec; H.cooldownSec = 0; fresh(); K.state.ipoCount = 1; K.state.ipoAt = NOW; K.state.cycleRounds = 3;
  check('cooldownSec is a setting (0 = off)', K.ipoCooldownLeft() === 0 && K.ipoUnlocked()); H.cooldownSec = c; }
{ fresh(); K.state.ipoAt = NOW - HOUR; K.state.ipoCount = 1; K.state.cycleRounds = 3; K.earn(1e9); K.doPrestige();
  check('ipoAt survives a Yatırım Turu', K.state.ipoAt === NOW - HOUR); }
{ fresh(); K.state.ipoAt = NOW - HOUR; K.state.ipoCount = 1; const st = K.newState(); check('reset (newState): ipoAt 0', st.ipoAt === 0); }

// ---------------------------------------------------------------- aşamalar, başarımlar, 2. Halka Arz kuralı
fresh(); K.earn(2e11);
check('2e11 run: Unicorn stage', K.STAGES[K.stageIndex(K.state.runEarned)].id === 'unicorn');
K.state.stageBest = R('unicorn'); K.checkAchievements();
check('reaching Unicorn gives Tek Boynuzlu, NOT asama_6 (Teknoloji Devi)', K.state.achievements.includes('asama_unicorn') && !K.state.achievements.includes('asama_6') && !K.state.achievements.includes('asama_grup'));
K.state.stageBest = R('sirketler_grubu'); K.checkAchievements();
check('Şirketler Grubu gives Organizasyon Şeması, still not asama_6', K.state.achievements.includes('asama_grup') && !K.state.achievements.includes('asama_6'));
const A = (id) => K.ACHIEVEMENTS.find((a) => a.id === id);
check('achievement copy', A('asama_unicorn').name === 'Tek Boynuzlu' && A('asama_unicorn').icon === '🦄' && A('asama_grup').name === 'Organizasyon Şeması' && A('asama_grup').icon === '🏬');
fresh(); K.state.ipoCount = 1; K.state.cycleRounds = 3;
check('2nd IPO: Unicorn / ŞG pay nothing (repeat needs Teknoloji Devi)', ['global_holding', 'unicorn', 'sirketler_grubu'].every((id) => { K.state.cycleStage = R(id); return K.ipoGain() === 0; }) &&
  (K.state.cycleStage = R('teknoloji_devi'), K.ipoGain() === 5));

// ---------------------------------------------------------------- kayıt v5: ID + eski sıra
const LEG = (n) => { K.deserialize(JSON.stringify({ version: 4, saveVersion: 4, stage: n, stageBest: n, cycleStage: n, runEarned: 0, totalEarned: 1e30, cycleEarned: 1e30 })); return K.STAGES[K.state.stageBest].id; };
check('legacy index 5 -> global_holding', LEG(5) === 'global_holding');
check('legacy index 6 -> teknoloji_devi (not Unicorn)', LEG(6) === 'teknoloji_devi');
check('legacy index 7 -> yapay_zeka_lab', LEG(7) === 'yapay_zeka_lab');
check('legacy index 8 -> mars_ofisi', LEG(8) === 'mars_ofisi');
check('legacy index 0..4 unchanged', [0, 1, 2, 3, 4].every((n) => R(LEG(n)) === n));
check('legacy index out of range -> clamped (99 -> mars, -3 -> freelancer)', LEG(99) === 'mars_ofisi' && LEG(-3) === 'freelancer');
{ const old = { version: 4, saveVersion: 4, stage: 6, stageBest: 6, cycleStage: 6, runEarned: 2e15, totalEarned: 3e16, cycleEarned: 3e15, achievements: ['asama_5', 'asama_6'] };
  K.deserialize(JSON.stringify(old)); K.checkAchievements();
  check('old TD player: gets Unicorn + ŞG achievements retroactively, keeps asama_6', ['asama_5', 'asama_unicorn', 'asama_grup', 'asama_6'].every((x) => K.state.achievements.includes(x)) && !K.state.achievements.includes('asama_7')); }
fresh(); K.state.stage = R('sirketler_grubu'); K.state.stageBest = R('teknoloji_devi'); K.state.cycleStage = R('unicorn');
{ const d = K.saveData();
  check('saveData: ID fields', d.stageId === 'sirketler_grubu' && d.stageBestId === 'teknoloji_devi' && d.cycleStageId === 'unicorn');
  check('saveData: legacy numbers on the old scale (ŞG/Unicorn -> 5 = GH, TD -> 6) for the server best_stage and old clients', d.stage === 5 && d.stageBest === 6 && d.cycleStage === 5, [d.stage, d.stageBest, d.cycleStage]);
  check('saveData: version/saveVersion 5', d.version === 5 && d.saveVersion === 5);
  K.deserialize(JSON.stringify(d));
  check('v5 round trip: ID wins over the legacy number', K.state.stage === R('sirketler_grubu') && K.state.stageBest === R('teknoloji_devi') && K.state.cycleStage === R('unicorn') && K.loadedVersion === 5); }
check('legacyStageIndex for every rank', K.STAGES.map((s, i) => K.legacyStageIndex(i)).join(',') === '0,1,2,3,4,5,5,5,6,7,8');
{ K.deserialize(JSON.stringify({ version: 5, saveVersion: 5, stageId: 'yok', stage: 7, stageBestId: 42, stageBest: 7 }));
  check('unknown/invalid ID -> falls back to the legacy number', K.STAGES[K.state.stage].id === 'yapay_zeka_lab' && K.STAGES[K.state.stageBest].id === 'yapay_zeka_lab'); }
// sunucunun sıfırlama yükü (stage 0, sürüm kopyalanmış) ve newState kopyası
{ K.deserialize(JSON.stringify({ version: 5, saveVersion: 5, stage: 0, stageBest: 0, cycleStage: 0, startedAt: NOW }));
  check('server reset payload loads as a fresh Freelancer', K.state.stageBest === 0 && K.state.stage === 0); }

// ---------------------------------------------------------------- startedVersion / startedAt
fresh();
check('new game: startedVersion = VERSION, startedAt set', K.state.startedVersion === K.VERSION && K.state.startedAt > 0);
{ K.deserialize(JSON.stringify({ version: 4, saveVersion: 4, startedAt: NOW - 10 * HOUR }));
  check('old save: startedVersion empty', K.state.startedVersion === '');
  K.state.cycleRounds = 3; K.state.ipoCount = 0; K.earn(3e9); K.state.cycleStage = R('global_holding'); K.state.cycleRounds = 3;
  K.doIpo();
  check('startedVersion + startedAt kept on Halka Arz', K.state.startedVersion === '' && K.state.startedAt === NOW - 10 * HOUR && K.state.ipoCount === 1);
  K.state.cycleRounds = 0; K.earn(1e9); K.doPrestige();
  check('startedVersion + startedAt kept on Yatırım Turu', K.state.startedVersion === '' && K.state.startedAt === NOW - 10 * HOUR);
  K.state = K.newState();
  check('Kaydı sıfırla (fresh newState): startedVersion set again, startedAt now', K.state.startedVersion === K.VERSION && Math.abs(K.state.startedAt - Date.now()) < 5000); }
{ K.deserialize(JSON.stringify({ version: 5, saveVersion: 5, startedVersion: '4.4.0', startedAt: NOW - 30 * HOUR }));
  const s2 = JSON.parse(K.serialize()); check('startedVersion saved', s2.startedVersion === '4.4.0' && s2.startedAt === NOW - 30 * HOUR); }
[['missing', undefined], ['zero', 0], ['negative', -1], ['string', 'x'], ['NaN-ish', null]].forEach(([n, v]) => {
  const d = { version: 4, saveVersion: 4 }; if (v !== undefined) d.startedAt = v;
  K.deserialize(JSON.stringify(d));
  check('startedAt ' + n + ' -> 0 (unknown)', K.state.startedAt === 0);
});

// ---------------------------------------------------------------- olay alanları
{ fresh(); K.state.ipoCount = 3;
  const d = K.ipoEventData(R('teknoloji_devi'), 5);
  check('ipo_complete fields exactly {stage_id, pays, ipo_number}', JSON.stringify(Object.keys(d)) === '["stage_id","pays","ipo_number"]' && d.stage_id === 'teknoloji_devi' && d.pays === 5 && d.ipo_number === 3, d); }
{ fresh(); K.state.startedAt = NOW - 50.4 * HOUR; K.state.ipoCount = 4;
  const d = K.treeEventData(NOW);
  check('tree_full fields exactly {hours_since_start, ipo_number, started_v44}', JSON.stringify(Object.keys(d)) === '["hours_since_start","ipo_number","started_v44"]' && d.hours_since_start === 50 && d.ipo_number === 4 && d.started_v44 === 'yes', d);
  K.state.startedAt = NOW - 50.6 * HOUR; check('hours rounded to whole hours', K.treeEventData(NOW).hours_since_start === 51);
  K.state.startedVersion = ''; check('old save -> started_v44 no', K.treeEventData(NOW).started_v44 === 'no');
  K.state.startedAt = 0; const e = K.treeEventData(NOW);
  check('startedAt unknown -> hours field omitted', !('hours_since_start' in e) && JSON.stringify(Object.keys(e)) === '["ipo_number","started_v44"]', e);
  K.state.startedAt = NOW + HOUR; check('startedAt in the future -> hours field omitted', !('hours_since_start' in K.treeEventData(NOW))); }
{ fresh(); check('treeFull false with 11 nodes', (K.state.tree = K.TREE.flatMap((b) => b.nodes.map((n) => n.id)).slice(0, 11), !K.treeFull()));
  K.state.tree = K.TREE.flatMap((b) => b.nodes.map((n) => n.id)); check('treeFull true with 12 nodes', K.treeFull()); }

// ---------------------------------------------------------------- metinler (Yazı r3) ve süre biçimi
check('fmtDur', K.fmtDur(43200) === '12 saat' && K.fmtDur(21600) === '6 saat' && K.fmtDur(5400) === '1 saat 30 dakika' && K.fmtDur(90) === '1 dakika 30 saniye' && K.fmtDur(0) === '0 saniye' && K.fmtDur(86400) === '1 gün',
  [K.fmtDur(43200), K.fmtDur(5400), K.fmtDur(90)]);
const U = K.UI_TEXT;
check('prestige.confirm (r3)', U['prestige.confirm'] === "Yatırımcılar şirketine <b>{g} hisse</b> karşılığında yatırım yapacak. Paran, çalışanların ve geliştirmelerin sıfırlanır; karşılığında tüm kazançlara <b>+%{b}</b> bonus alırsın. Bu bonus Halka Arz'da da silinmez. Başarımların, itibarın ve günlük serin korunur.");
check('ipo.confirm (r3, p >= 1)', U['ipo.confirm'] === "Kasa, çalışanlar ve geliştirmeler sıfırlanacak. Yatırımcı hisselerin korunur, bu turda biriken <b>{p} hisse</b> de eklenir. Borsa Payı Ağacı, başarımların ve sıralamadaki puanın da kalır.<br>Kazanacağın: <b>{n} Borsa Payı</b>. Sonraki Yatırım Turlarında hisselerin %{z} fazla gelir.<br><small>Harcamadığın her Borsa Payı +%{u} üretim verir. Sonraki Halka Arz için en az {h} beklemen gerekir.</small>");
check('wait / accelerator texts (r3)', U['ipo.btnWait'] === 'Halka arz et ({s})' && U['ipo.lockWait'] === '⏳ Sonraki Halka Arz için {s} kaldı.' && U['ipo.lockWaitNote'] === 'İki Halka Arz arasında en az {h} olmalı.' &&
  U['ipo.reopened'] === '🔔 Halka Arz yeniden açık.' && U['ipo.accelLabel'] === 'Hisse hızlandırıcısı' && U['ipo.accelValue'] === '+%{z}' && U['ipo.accelValueMax'] === '+%{z} (en fazla)' &&
  U['ipo.accelNote'] === 'Kazandığın her Borsa Payı yeni hisseleri +%{k} artırır, harcasan da sayılır. En fazla {max} kat.' && U['ipo.done'] === 'Artık halka açık bir şirketsin. Hisselerin yerinde duruyor. Borsa Payların: <b>{x}</b>');
check('no "kalıcı" in the new Halka Arz / Yatırım Turu texts', ['prestige.confirm', 'ipo.confirm', 'ipo.confirm.noPending', 'ipo.done', 'ipo.accelNote'].every((k) => !/kalıcı/i.test(U[k])));
check('telemetry.body (final)', K.TEL_TEXT['telemetry.body'] === 'Oyunu geliştirmek için ziyaretleri ve bazı oyun olaylarını isimsiz olarak sayıyoruz. Hesap bilgilerin ve takma adın gönderilmez. İstemezsen kapatabilirsin.');
const DET = K.TEL_TEXT['telemetry.details'];
const P_EVENTS = DET.find((x) => x.includes('Sayılan olaylar şunlar')) || '';
check('events paragraph (found by content) is still the first details paragraph', DET.indexOf(P_EVENTS) === 0);
check('events paragraph lists the tree event and the exact event fields (final sentence)', P_EVENTS.includes("Halka Arz, Borsa Payı ağacının dolması, paylaşım") &&
  P_EVENTS.includes("İki olayda oyundaki ilerlemenden birkaç bilgi de gider: Halka Arz'da ulaştığın aşama, kazandığın Borsa Payı ve kaçıncı Halka Arz olduğu; ağaç dolduğunda oyuna başladığından bu yana geçen süre (tam saat olarak), kaçıncı Halka Arz olduğu ve oyuna v4.4 güncellemesinden önce mi, sonra mı başladığın."));
check('reset.prestigeHint (r3)', K.RESET_TEXT['reset.prestigeHint'] === "Başarımlarını, itibarını ve günlük serini korumak istiyorsan sıfırlamak yerine yatırım turuna çık. Yatırım turunda bunlar korunur, üstüne bir üretim bonusu kazanırsın. Bu bonus Halka Arz'da da silinmez.");

// onay penceresi birleşimi
{ fresh(); K.state.cycleRounds = 3; K.state.shares = 120; K.state.ipoCount = 0; K.state.ipoSharesEarned = 0; K.earn(4e12); K.state.cycleRounds = 3;
  const p = K.sharesGain(), n = K.ipoGain(), html = K.ipoConfirmHtml();
  const exp = "Kasa, çalışanlar ve geliştirmeler sıfırlanacak. Yatırımcı hisselerin korunur, bu turda biriken <b>" + K.fmt(p) + " hisse</b> de eklenir. Borsa Payı Ağacı, başarımların ve sıralamadaki puanın da kalır.<br>" +
    "Yatırımcı bonusun +%" + K.pctText(K.investorBonus(120 + p)) + " olur. Kazanacağın: <b>" + n + " Borsa Payı</b>. Sonraki Yatırım Turlarında hisselerin %" + K.num(n * 10) + " fazla gelir.<br>" +
    "<small>Harcamadığın her Borsa Payı +%1 üretim verir. Sonraki Halka Arz için en az 12 saat beklemen gerekir.</small>";
  check('IPO confirm (p >= 1): bonus line before Kazanacağın, {z} includes this IPO', html === exp, [html, exp]);
  K.state.runEarned = 0; const h0 = K.ipoConfirmHtml();
  check('IPO confirm (p < 1): first sentence without pending, no bonus line', h0.startsWith(U['ipo.confirm.noPending'] + '<br>Kazanacağın:') && !h0.includes('Yatırımcı bonusun'), h0);
  K.state.ipoSharesEarned = 38; const hc = K.ipoConfirmHtml();
  check('IPO confirm at the accelerator cap: "(en fazla)" and %400', hc.includes('Sonraki Yatırım Turlarında hisselerin %400 fazla gelir (en fazla).'), hc); }

// ---------------------------------------------------------------- v4.4: kayıt içi olay listesi
{
  const LOGP = "Kaydın, son 20 önemli olayı da kendi içinde tutar: Halka Arz, Yatırım turu ve sıfırlama, ayrıca bu olaylardan önceki ve sonraki hisse ve Borsa Payı sayıların. Bu liste yalnızca kaydının içinde durur. Bulut kaydı kullanıyorsan kaydınla birlikte buluta gider, başka hiçbir yere gönderilmez. Bir destek talebinde neyin ne zaman olduğunu görmek için kullanılır. Kaydını sıfırlasan da bu liste kalır. Hesabın silinirse liste sunucudan silinir, bu cihazdaki kaydınla birlikte cihazında kalır.";
  const iLog = DET.indexOf(LOGP), iCtl = DET.findIndex((x) => x.startsWith('Bu bilgilerin veri sorumlusu'));
  check('privacy: event-log paragraph (Yazı r1 cümle 1 + reset/deletion sentences) right before the data-controller paragraph, no server-copies paragraph', iLog > 0 && iCtl === iLog + 1 && !DET.some((x) => x.includes('kopyaları')), [iLog, iCtl]);
  check('privacy: Cloudflare paragraph = one sentence (Yazı süresiz r1), no "çerez kullanmaz" / "tanımaya" claim', DET[2] === 'Site Cloudflare üzerinden sunulduğu için sayfa açılışlarını Cloudflare de kendi aracıyla ayrıca sayar.'
    && !DET.some((x) => /çerez|tanımaya/.test(x)));
  check('CFG.eventLog.max = 20 (matches "son 20" in the privacy text)', K.CFG.eventLog.max === 20 && LOGP.includes('son 20'));
  const KEYS = '["type","at","sharesBefore","sharesAfter","paysBefore","paysAfter"]';
  fresh();
  check('new state: empty event log', Array.isArray(K.state.eventLog) && K.state.eventLog.length === 0);
  // Yatırım Turu
  K.state.shares = 7; K.state.ipoShares = 2; K.earn(4e10);
  const gP = K.sharesGain(); NOW += 1000; K.doPrestige();
  let e = K.state.eventLog[K.state.eventLog.length - 1];
  check('Yatırım Turu entry: exact fields, time, shares 7 -> 7+g, pays unchanged', JSON.stringify(Object.keys(e)) === KEYS && e.type === 'prestige' && e.at === NOW &&
    e.sharesBefore === 7 && e.sharesAfter === 7 + gP && e.paysBefore === 2 && e.paysAfter === 2, e);
  // Halka Arz
  K.state.cycleRounds = 3; K.state.ipoCount = 0; K.state.ipoAt = 0; K.earn(4e12);
  const sb = K.state.shares, pnd2 = K.sharesGain(), gI = K.ipoGain(); NOW += 1000; K.doIpo();
  e = K.state.eventLog[K.state.eventLog.length - 1];
  check('Halka Arz entry: shares kept + pending, pays 2 -> 2+n, time', e.type === 'ipo' && e.at === NOW && e.sharesBefore === sb && e.sharesAfter === sb + pnd2 && e.paysBefore === 2 && e.paysAfter === 2 + gI && gI >= 1, e);
  check('log survives Yatırım Turu and Halka Arz (2 entries)', K.state.eventLog.length === 2 && K.state.eventLog[0].type === 'prestige');
  // FIFO
  fresh(); K.state.ipoShares = 0;
  for (let i = 0; i < 21; i++) { K.state.shares = i; K.state.runEarned = 1e8; NOW += 1; K.doPrestige(); }
  const L = K.state.eventLog;
  check('21st event drops the oldest (20 kept, first is the 2nd event)', L.length === 20 && L[0].sharesBefore === 1 && L[19].sharesBefore === 20 && L.every((x, i) => i === 0 || x.at > L[i - 1].at), [L.length, L[0].sharesBefore]);
  // kayıt / taşıma
  const rt = JSON.parse(K.serialize());
  check('event log saved (part of the save; 20 entries, exact keys)', Array.isArray(rt.eventLog) && rt.eventLog.length === 20 && rt.eventLog.every((x) => JSON.stringify(Object.keys(x)) === KEYS));
  K.deserialize(JSON.stringify(rt));
  check('event log round trip', JSON.stringify(K.state.eventLog) === JSON.stringify(rt.eventLog));
  K.deserialize(JSON.stringify({ version: 4, saveVersion: 4, shares: 5, stage: 6, stageBest: 6 }));
  check('migrated old save (v4) starts with an empty log', Array.isArray(K.state.eventLog) && K.state.eventLog.length === 0);
  K.deserialize(JSON.stringify({ version: 2, money: 1 }));
  check('migrated very old save (v2) starts with an empty log', K.state.eventLog.length === 0);
  const dirty = Object.assign(clone(rt), { eventLog: [{ type: 'ipo', at: NOW, sharesBefore: 1, sharesAfter: 2, paysBefore: 0, paysAfter: 3, email: 'x@y', nick: 'z' },
    { type: 'hack', at: NOW }, { type: 'reset', at: -1 }, 'x', null, { type: 'reset', at: NOW, sharesBefore: -5, sharesAfter: 'a' }].concat(Array(30).fill({ type: 'prestige', at: NOW, sharesBefore: 1, sharesAfter: 1, paysBefore: 0, paysAfter: 0 })) });
  K.deserialize(JSON.stringify(dirty));
  check('loaded log sanitised: only known types/fields, no extra fields, numbers >= 0, at most 20', K.state.eventLog.length === 20 && K.state.eventLog.every((x) => JSON.stringify(Object.keys(x)) === KEYS && K.EVENT_TYPES.includes(x.type) && x.sharesBefore >= 0 && x.sharesAfter >= 0));
  K.deserialize(JSON.stringify(Object.assign(clone(rt), { eventLog: dirty.eventLog.slice(0, 6) })));
  check('extra fields (email/nick) dropped, bad entries dropped', K.state.eventLog.length === 2 && !('email' in K.state.eventLog[0]) && K.state.eventLog[1].sharesBefore === 0 && K.state.eventLog[1].sharesAfter === 0, K.state.eventLog);
  // newState (Kaydı sıfırla çekirdeği) boş; taşıma game.js performReset/load() içinde (UI testinde)
  check('Umami event field sets unchanged by the log', JSON.stringify(Object.keys(K.ipoEventData(0, 1))) === '["stage_id","pays","ipo_number"]' &&
    (() => { fresh(); K.state.startedAt = NOW - HOUR; return JSON.stringify(Object.keys(K.treeEventData(NOW))) === '["hours_since_start","ipo_number","started_v44"]'; })());
  check('no event-log field reaches track(): trackLog data never has log keys', (K.trackLog || []).every((x) => !x[2] || !('eventLog' in x[2]) && !('sharesBefore' in x[2])));
  // Kaydı sıfırla: liste korunur + sıfırlama girdisi, tavan aşılmaz (20 girdi + sıfırlama -> 20, en eski düşer, son girdi reset)
  {
    fresh(); for (let i = 0; i < 20; i++) { K.state.shares = i; K.state.runEarned = 1e8; NOW += 1; K.doPrestige(); }
    const first = K.state.eventLog[0], second = K.state.eventLog[1];
    K.state.shares = 777; K.state.ipoShares = 9; NOW += 5;
    const C2 = K.resetCarryLog(K.state), last = C2[C2.length - 1];
    check('reset with 20 entries: still 20 (cap), oldest dropped, last is reset', K.state.eventLog.length === 20 && C2.length === 20 &&
      JSON.stringify(C2[0]) === JSON.stringify(second) && !C2.some((x) => JSON.stringify(x) === JSON.stringify(first)) && last.type === 'reset', [C2.length, C2[0], last]);
    check('reset entry: exact fields, time now, shares 777 -> 0, pays 9 -> 0', JSON.stringify(Object.keys(last)) === KEYS && last.at === NOW &&
      last.sharesBefore === 777 && last.sharesAfter === 0 && last.paysBefore === 9 && last.paysAfter === 0, last);
    check('reset carry does not modify the live log (built as a copy)', K.state.eventLog.length === 20 && K.state.eventLog[19].type === 'prestige');
    fresh(); K.state.shares = 3;
    const C1 = K.resetCarryLog(K.state);
    check('reset with empty log: one reset entry', C1.length === 1 && C1[0].type === 'reset' && C1[0].sharesBefore === 3);
    let big = []; for (let i = 0; i < 25; i++) big.push({ type: 'ipo', at: NOW - 100 + i, sharesBefore: i, sharesAfter: i, paysBefore: 0, paysAfter: 1 });
    K.state.eventLog = big;
    const C3 = K.resetCarryLog(K.state);
    check('reset on an over-long (hand-edited) log: capped at 20, last is reset', C3.length === 20 && C3[19].type === 'reset' && C3[0].sharesBefore === 6, [C3.length, C3[0]]);
  }
  // Kaydı sıfırla = newState: startedVersion bu sürüm (tree_full'da started_v44 = yes), başlangıç zamanı yeni
  {
    fresh(); K.deserialize(JSON.stringify({ version: 4, saveVersion: 4, shares: 5, stage: 6, stageBest: 6, startedAt: NOW - 90 * 24 * HOUR }));
    check('old save before reset: startedVersion "" -> started_v44 no', K.state.startedVersion === '' && K.treeEventData(NOW).started_v44 === 'no');
    K.state = K.newState();
    check('after Kaydı sıfırla (newState): startedVersion = ' + K.VERSION + ', started_v44 yes, startedAt now', K.state.startedVersion === K.VERSION &&
      K.treeEventData(Date.now()).started_v44 === 'yes' && Math.abs(K.state.startedAt - Date.now()) < 5000, [K.state.startedVersion, K.state.startedAt]);
  }
  // Yazı r2: "Kaydı sıfırla" penceresi (liste korunur)
  check('reset.body (Yazı r2) exact', K.RESET_TEXT['reset.body'] === 'Oyuna en baştan başlarsın. Kalacaklar dışında her şey silinir, silinecekleri seçemezsin.');
  check('reset.keepList: "Son olayların listesi" between "Kodhane hesabın" and the settings line', JSON.stringify(K.RESET_TEXT['reset.keepList']) ===
    JSON.stringify(['Tüm Zamanlar puanın ve sıradaki yerin', 'Takma adın', 'Kodhane hesabın', 'Son olayların listesi', 'Ses, titreşim ve gizlilik ayarların']));
  check('no hidden placeholder key left (reset.keepEventLog)', !('reset.keepEventLog' in K.RESET_TEXT));
  // yazma kapalıyken girdi yok
  fresh(); K.state.runEarned = 4e10; K.guardFuture({ version: K.SAVE_VERSION + 1 }, 'test');
  const before = K.state.eventLog.length; K.doPrestige();
  check('writesBlocked: no log entry written', K.writesBlocked() && K.state.eventLog.length === before);
}

// ---- v4.4: bulut 426 (eski sekme): markOlderTab yazmayı kapatır; metinler Yazı eski-sekme r1 ile birebir (temiz modül)
{
  const gp = require.resolve(path.join(__dirname, '..', 'game.js'));
  delete require.cache[gp];
  const K2 = require(gp);
  check('olderTab: fresh module writes open, no flag', !K2.writesBlocked() && K2.olderTab === null && K2.futureSave === null);
  K2.markOlderTab({ detail: 'sent saveVersion 5, stored saveVersion 6' });
  K2.markOlderTab({ detail: 'ikinci' });
  check('olderTab: markOlderTab blocks writes (same flag as newerSave), first detail kept', K2.writesBlocked() && K2.olderTab && K2.olderTab.detail === 'sent saveVersion 5, stored saveVersion 6', K2.olderTab);
  K2.state.runEarned = 4e10; const n = K2.state.eventLog.length; K2.doPrestige();
  check('olderTab: prestige / event log blocked', K2.state.eventLog.length === n);
  const T = { title: 'Oyunun yeni sürümü var', text: 'Hesabına oyunun yeni sürümünden kayıt yapıldı, bu sekmede oynadıkların artık kaydedilmiyor.',
    btn: 'Sayfayı yenile', textShort: 'Bu sekmede oynadıkların kaydedilmiyor.' };
  check('olderTab texts verbatim (update.olderTab.title/text/btn/textShort)', Object.keys(T).every((k) => K2.UI_TEXT['update.olderTab.' + k] === T[k]));
  const keys = Object.keys(K2.UI_TEXT), i = keys.indexOf('update.newerSave.btn');
  check('olderTab keys placed right below update.newerSave.*', JSON.stringify(keys.slice(i + 1, i + 5)) === JSON.stringify(['update.olderTab.title', 'update.olderTab.text', 'update.olderTab.btn', 'update.olderTab.textShort']), keys.slice(i - 2, i + 5));
}

// ---------------------------------------------------------------- v4.4.1: investment_round alanları
{ fresh();
  const d = K.roundEventData(R('teknoloji_devi'));
  check('v4.4.1 investment_round fields exactly {stage_id}', JSON.stringify(d) === '{"stage_id":"teknoloji_devi"}', d);
  check('v4.4.1 investment_round: out-of-range rank clamps to a known stage ID', K.roundEventData(-3).stage_id === 'freelancer' && K.roundEventData(99).stage_id === 'mars_ofisi' && K.roundEventData(undefined).stage_id === 'freelancer'); }
{ const fs = require('fs'), src = fs.readFileSync(path.join(__dirname, '..', 'game.js'), 'utf8');
  const calls = [...src.matchAll(/\btrack\('([a-z_]+)'/g)].map((m) => m[1]);
  check('v4.4.1: reset_or_prestige is gone; investment_round / ipo_complete / hard_reset wired once each',
    !calls.includes('reset_or_prestige') && ['investment_round', 'ipo_complete', 'hard_reset'].every((n) => calls.filter((x) => x === n).length === 1), calls);
  check('v4.4.1: investment_round carries roundEventData only, hard_reset name only',
    /track\('investment_round', roundEventData\(roundStage\)\)/.test(src) && /track\('hard_reset'\);/.test(src)); }

// ---------------------------------------------------------------- v4.4.1: kayıt biçimi değişmedi (v4.4.0 kaydı yükle + kaydet)
{ // v4.4.0 (879f67b) serialize() anahtarları, sırasıyla
  const KEYS440 = ["version","money","runEarned","totalEarned","clicks","clickEarned","playTime","startedAt","lastSaved","gens","upgrades","shares","prestigeCount","boostLeft","eventsClicked","offlineEarned","stage","buffs","achievements","critClicks","eventsResolved","logoAccepted","revisions","meetings","serverCrashes","reputation","noMeetingSec","daily","ipoShares","ipoSharesEarned","ipoCount","cycleEarned","cycleRounds","tree","stageBest","newsSeen","newsPending","cycleStage","sectorCool","followUps","pendingPay","ipoAt","startedVersion","eventLog","stageId","stageBestId","cycleStageId","saveVersion","epoch","resetAt"];
  const keysDeep = (o, p = '') => Object.keys(o).flatMap((k) => { const v = o[k], q = p + k; return v && typeof v === 'object' && !Array.isArray(v) ? [q].concat(keysDeep(v, q + '.')) : [q]; });
  const S = K.newState();
  const fresh441 = (K.state = S, JSON.parse(K.serialize()));
  check('v4.4.1 fresh save: same keys, same order as v4.4.0', JSON.stringify(Object.keys(fresh441)) === JSON.stringify(KEYS440), Object.keys(fresh441).filter((k) => !KEYS440.includes(k)));
  check('v4.4.1: no clientVersion in the save', !('clientVersion' in fresh441));
  // dolu bir v4.4.0 kaydı (gerçek 879f67b çıktısıyla aynı biçim): yükle -> kaydet; alan kümesi (iç içe) ve değerler aynı (lastSaved hariç)
  let src440 = null;
  try { src440 = require('child_process').execFileSync('git', ['show', '879f67b:game.js'], { cwd: path.join(__dirname, '..'), stdio: ['ignore', 'pipe', 'ignore'] }).toString(); } catch (e) { src440 = null; }
  if (!src440) console.log('NOTE git show 879f67b:game.js yok: v4.4.0 çekirdeğiyle gidiş-dönüş testi atlandı (anahtar listesi testi yine koştu)');
  else {
    const m = { exports: {} }; new Function('module', 'exports', 'require', src440).call({}, m, m.exports, require); const K0 = m.exports;
    check('reference core is v4.4.0', K0.VERSION === '4.4.0');
    K0.state = K0.newState(); const s0 = K0.state;
    Object.assign(s0, { money: 1.5e20, runEarned: 2e21, totalEarned: 3e22, cycleEarned: 2.5e21, clicks: 1234, shares: 77, prestigeCount: 12, cycleRounds: 4, reputation: 64,
      ipoShares: 5, ipoSharesEarned: 30, ipoCount: 4, tree: ['kod_1', 'ekip_1'], achievements: ['tik_1', 'kazanc_1m'], upgrades: ['click_1', 'stajyer_1'], startedVersion: '4.4.0', ipoAt: NOW - 20 * HOUR,
      buffs: [{ id: 'gece', kind: 'prod', mult: 0.8, left: 30, total: 60, label: 'Gece mesaisi' }], pendingPay: [{ amount: 5e9, left: 100, total: 300, label: 'İhale' }],
      sectorCool: { kamu: 120 }, newsSeen: ['yeni_asama'], eventLog: [{ type: 'ipo', at: NOW - 20 * HOUR, sharesBefore: 70, sharesAfter: 70, paysBefore: 0, paysAfter: 5 }] });
    s0.gens.stajyer = 150; s0.gens.veri = 12; s0.stageBest = 9; s0.stage = 9; s0.cycleStage = 9;
    const raw0 = K0.serialize(), o0 = JSON.parse(raw0);
    K.deserialize(raw0); const o1 = JSON.parse(K.serialize());
    check('v4.4.0 save -> v4.4.1 load+save: identical nested key set and order', JSON.stringify(keysDeep(o1)) === JSON.stringify(keysDeep(o0)),
      [keysDeep(o1).filter((k) => !keysDeep(o0).includes(k)), keysDeep(o0).filter((k) => !keysDeep(o1).includes(k))]);
    const strip = (o) => { const c = JSON.parse(JSON.stringify(o)); delete c.lastSaved; return c; };
    check('v4.4.0 save -> v4.4.1 load+save: all values identical (except lastSaved)', JSON.stringify(strip(o1)) === JSON.stringify(strip(o0)),
      Object.keys(o0).filter((k) => k !== 'lastSaved' && JSON.stringify(o0[k]) !== JSON.stringify(o1[k])));
    check('v4.4.0 save -> v4.4.1: still saveVersion 5 / version 5, no clientVersion', o1.saveVersion === 5 && o1.version === 5 && !('clientVersion' in o1));
    K0.deserialize(K.serialize()); const o2 = JSON.parse(K0.serialize());
    check('v4.4.1 save -> v4.4.0 load+save (rollback): identical (except lastSaved), not blocked as a future save', JSON.stringify(strip(o2)) === JSON.stringify(strip(o0)) && !K0.writesBlocked());
  }
}

console.log(`\n${pass}/${pass + fail} passed`);
process.exit(fail ? 1 : 0);
