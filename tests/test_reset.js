// Kodhane v4.2 "Kaydı sıfırla" çekirdek testleri (Node, tarayıcısız): metinler (copy dosyasıyla birebir, {s}/{d} ayardan),
// misafir metin süzgeci, Yatırım Turu / Halka Arz regresyonu (v4-local ile birebir karşılaştırma), sıfırlamanın sildikleri,
// sahte sunucunun (cloud.js createSaveMock) v2.2 sözleşmesine uyumu ve iki istemcili bayat yazma senaryosu.
// Çalıştır: node tests/test_reset.js
'use strict';
const path = require('path');
const fs = require('fs');
const { execFileSync } = require('child_process');
const ROOT = path.join(__dirname, '..');
const K = require(path.join(ROOT, 'game.js'));
const { createSaveMock, RPC } = require(path.join(ROOT, 'cloud.js'));
let pass = 0, fail = 0;
function check(name, cond, info) {
  if (cond) pass++; else fail++;
  console.log((cond ? 'PASS ' : 'FAIL ') + name + (info !== undefined && !cond ? ' ' + JSON.stringify(info) : ''));
}
const clone = (o) => JSON.parse(JSON.stringify(o));

(async function main() {
  // ---------------------------------------------------------------- metinler
  const copy = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'kodhane-reset-copy.json'), 'utf8'));
  const T = K.RESET_TEXT;
  check('every copy key present with verbatim wording', Object.keys(copy).every((k) => JSON.stringify(T[k]) === JSON.stringify(copy[k])),
    Object.keys(copy).filter((k) => JSON.stringify(T[k]) !== JSON.stringify(copy[k])));
  const extra = Object.keys(T).filter((k) => !(k in copy));
  check('only the two flagged non-copy keys added', extra.join(',') === 'reset.cloudFailed,reset.restoreFailed', extra);
  const src = fs.readFileSync(path.join(ROOT, 'game.js'), 'utf8');
  check('old hardcoded reset texts removed', !/kalıcı olarak silinecek|buluttaki kaydın da silinecek|Kaydı sıfırla\?|Evet, sıfırla/.test(src));
  check('copy strings appear only once in game.js (single RESET_TEXT object)', Object.keys(copy).every((k) => typeof copy[k] !== 'string' || copy[k].length < 20 || src.split(copy[k]).length === 2));
  check('default config: undo 10 s, backup 30 days', K.CFG.reset.undoSeconds === 10 && K.CFG.reset.backupDays === 30);
  check('{s} and {d} substituted from default config', K.resetText('reset.undo') === 'Geri al (10)' &&
    K.resetText('reset.backup') === 'Silinen kayıt 30 gün boyunca yedekte kalır. Bu süre içinde geri yükleyebilirsin.');
  K.CFG.reset.undoSeconds = 7; K.CFG.reset.backupDays = 14;
  check('{s} and {d} follow config changes', K.resetText('reset.undo') === 'Geri al (7)' && K.resetText('reset.backup').startsWith('Silinen kayıt 14 gün '));
  check('countdown value overrides {s}', K.resetText('reset.undo', { s: 3 }) === 'Geri al (3)');
  K.CFG.reset.undoSeconds = 10; K.CFG.reset.backupDays = 30;
  check('no unsubstituted placeholder in any text', Object.keys(T).every((k) => typeof T[k] !== 'string' || !/\{[sd]\}/.test(K.resetText(k))));
  check('no hardcoded 10/30 in copy texts', Object.keys(T).every((k) => typeof T[k] !== 'string' || !/\b(10|30)\b/.test(T[k])));
  check('otherDevice (signed in) keeps restore sentence', K.otherDeviceText(true) === copy['reset.otherDevice']);
  check('otherDevice (guest) drops restore sentence', K.otherDeviceText(false) === 'Kaydın başka bir cihazda sıfırlandı. Bu cihazda da oyun baştan başlıyor.' &&
    !/yede|geri yükle/i.test(K.otherDeviceText(false)), K.otherDeviceText(false));
  check('backup/restore texts are signed-in only', ['reset.backup', 'reset.restoreTitle', 'reset.restoreBody', 'reset.restoreBtn', 'reset.restoreDone']
    .every((k) => K.RESET_SIGNED_ONLY.indexOf(k) !== -1));

  // ---------------------------------------------------------------- Yatırım Turu / Halka Arz regresyonu (v4-local ile)
  let OLD = null;
  try {
    const f = path.join(__dirname, '.cache', 'game_v4_local.js');
    if (!fs.existsSync(f)) { fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, execFileSync('git', ['show', 'v4-local:game.js'], { cwd: ROOT })); }
    OLD = require(f);
  } catch (e) { OLD = null; }
  function seeded(M) {
    M.rng = (() => { let x = 42; return () => (x = (x * 16807) % 2147483647) / 2147483647; })();
    M.setToday('2026-09-28');
    const s = M.newState();
    Object.assign(s, { money: 5e9, runEarned: 4e12, totalEarned: 9e12, cycleEarned: 6e12, clicks: 1234, shares: 17, prestigeCount: 4, cycleRounds: 3,
      reputation: 42, achievements: ['ilk_tik', 'itibar_25'].filter((id) => M.ACHIEVEMENTS.some((a) => a.id === id)), ipoShares: 3, ipoSharesEarned: 5, ipoCount: 1,
      tree: ['kod_1'], stage: 6, stageBest: 7, cycleStage: 6, startedAt: 1000, lastSaved: 2000, upgrades: ['stajyer_1'] });
    s.gens.stajyer = 50; s.gens.junior = 20;
    s.daily = { date: '2026-09-28', tasks: [], streak: 5, best: 9, lastComplete: '2026-09-27', allDone: false, daysCompleted: 12 };
    M.state = s;
    return s;
  }
  function strip(s) { const o = clone(s); delete o.startedAt; delete o.lastSaved; return o; }
  seeded(K); const before = clone(K.state);
  K.meta.epoch = 777; K.meta.resetAt = 555;
  const gNew = K.doPrestige(); const afterNew = strip(K.state);
  check('prestige keeps achievements, reputation, streak', JSON.stringify(K.state.achievements) === JSON.stringify(before.achievements) &&
    K.state.reputation === 42 && K.state.daily.streak === 5 && K.state.daily.best === 9);
  check('prestige: shares/prestigeCount/cycleRounds as before', K.state.shares === before.shares + gNew && K.state.prestigeCount === 5 && K.state.cycleRounds === 4 && gNew > 0);
  check('prestige does not touch save generation (epoch/resetAt)', K.meta.epoch === 777 && K.meta.resetAt === 555);
  check('state keys unchanged (no new field inside the game state)', Object.keys(K.newState()).join() === (OLD ? Object.keys(OLD.newState()).join() : Object.keys(K.newState()).join()));
  if (OLD) {
    seeded(OLD); const gOld = OLD.doPrestige();
    check('prestige identical to v4-local (gain + full state)', gOld === gNew && JSON.stringify(strip(OLD.state)) === JSON.stringify(afterNew));
    seeded(K); seeded(OLD);
    K.state.cycleRounds = OLD.state.cycleRounds = 3;
    const iNew = K.doIpo(), iOld = OLD.doIpo();
    check('Halka Arz identical to v4-local (gain + full state)', iNew === iOld && iNew > 0 && JSON.stringify(strip(K.state)) === JSON.stringify(strip(OLD.state)));
    seeded(K); seeded(OLD);
    check('multipliers identical to v4-local', K.tps() === OLD.tps() && K.clickValue() === OLD.clickValue() && K.sharesGain() === OLD.sharesGain() && K.ipoGain() === OLD.ipoGain());
    check('reset result identical to v4-local (fresh newState: achievements, reputation, streak wiped as before)',
      JSON.stringify(strip(K.newState())) === JSON.stringify(strip(OLD.newState())));
  } else check('v4-local game.js available for comparison', false);
  const fresh = K.newState();
  check('reset wipes achievements, reputation, streak, prestige (same as v4.1.1 and the copy deleteList)',
    fresh.achievements.length === 0 && fresh.reputation === 0 && fresh.daily.streak === 0 && fresh.shares === 0 && fresh.prestigeCount === 0 && fresh.ipoShares === 0);

  // save round trip: epoch/resetAt carried in the save, outside the game state
  seeded(K); K.meta.epoch = 123; K.meta.resetAt = 45;
  const raw = K.serialize(); const parsed = JSON.parse(raw);
  check('serialize carries epoch/resetAt, not a data.revision', parsed.epoch === 123 && parsed.resetAt === 45 && !('revision' in parsed) && !('epoch' in K.state));
  K.meta.epoch = 0; K.meta.resetAt = 0; K.deserialize(raw);
  check('deserialize restores epoch/resetAt', K.meta.epoch === 123 && K.meta.resetAt === 45);
  K.deserialize(JSON.stringify(K.newState()));
  check('old saves without epoch -> 0', K.meta.epoch === 0 && K.meta.resetAt === 0);

  // ---------------------------------------------------------------- sahte sunucu: v2.2 sözleşmesi
  function memStorage() { const m = new Map(); return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k) }; }
  let clock = Date.parse('2026-09-28T12:00:00Z');
  const storage = memStorage();
  const M = createSaveMock({ storage, channel: false, now: () => clock });
  const U = 'u-1';
  const save = (te, extraObj) => Object.assign({ version: 4, totalEarned: te, money: 1, newsSeen: ['siralama'] }, extraObj || {});
  const row = (data, rev) => ({ user_id: U, data, save_version: 4, updated_at: new Date(clock).toISOString(), revision: rev });
  let r = await M.upsert(U, row(save(100), 1));
  check('insert with revision 1 -> 201', !r.error && r.status === 201);
  r = await M.select(U); check('select returns data/revision/best_score', r.data.revision === 1 && r.data.best_score === 100 && r.data.data.totalEarned === 100);
  r = await M.upsert(U, row(save(200), 2)); check('revision + 1 accepted', !r.error);
  r = await M.upsert(U, row(save(300), 1));
  check('lower revision -> 409 PT409 stale_revision (PostgREST shape)', r.status === 409 && r.error.code === 'PT409' && r.error.message === 'stale_revision' &&
    r.error.details === 'sent revision 1, server revision 2' && typeof r.error.hint === 'string', r);
  r = await M.upsert(U, row(save(300), 2)); check('equal revision on strict row -> stale_revision', r.status === 409 && r.error.message === 'stale_revision');
  r = await M.upsert(U, { user_id: U, data: save(1), best_score: 1e9, revision: 3 }); check('best_score not writable -> 403 42501', r.status === 403 && r.error.code === '42501');
  r = await M.upsert(U, { user_id: U, data: save(1), best_stage: 9, revision: 3 }); check('best_stage not writable -> 403 42501', r.status === 403 && r.error.code === '42501');
  r = await M.remove(U); check('DELETE -> 403 42501 permission denied', r.status === 403 && r.error.code === '42501' && /permission denied for table kodhane_saves/.test(r.error.message));
  // lenient legacy path (row never strict): a separate user whose row was written without revision
  r = await M.upsert('u-legacy', { user_id: 'u-legacy', data: save(500) });
  r = await M.upsert('u-legacy', { user_id: 'u-legacy', data: save(600) });
  check('lenient: legacy write without revision accepted, server assigns +1', !r.error && (await M.select('u-legacy')).data.revision === 1);
  r = await M.upsert('u-legacy', { user_id: 'u-legacy', data: save(0) });
  check('lenient: legacy write lowering totalEarned -> 409 PT409 stale_write', r.status === 409 && r.error.code === 'PT409' && r.error.message === 'stale_write');
  // oyuna özel RPC adları tek yerde (cloud.js RPC)
  check('RPC names in one place: kodhane_reset_save / kodhane_restore_save / kodhane_list_save_backups',
    RPC.reset === 'kodhane_reset_save' && RPC.restore === 'kodhane_restore_save' && RPC.listBackups === 'kodhane_list_save_backups');
  const csrc = fs.readFileSync(path.join(ROOT, 'cloud.js'), 'utf8');
  const code = csrc.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '');
  check('RPC names not hardcoded at call sites (only in the RPC constant)', (code.match(/'kodhane_(reset|restore|list_save_backups|list)_save'|'kodhane_list_save_backups'/g) || []).length === 3 &&
    !/\.rpc\(\s*['"]/.test(code) && (code.match(/T\.rpc\(CFG\.rpc\.(reset|restore|listBackups)/g) || []).length === 3);
  r = await M.rpc(U, 'reset_save', { p_game: 'kodhane' });
  check('old generic reset_save name unknown (PGRST202)', r.status === 404 && r.error.code === 'PGRST202');
  r = await M.rpc(U, RPC.reset, {});
  check('kodhane_reset_save -> {revision, backup_id, best_score, best_stage} (no game field, like the Kodhane migration)', !('game' in r.data) && 'best_stage' in r.data && r.data.revision === 3 && /^[0-9a-f-]{36}$/.test(r.data.backup_id) && r.data.best_score === 200, r.data);
  const bid = r.data.backup_id;
  let cur = (await M.select(U)).data;
  check('reset keeps the row: reset payload, revision+1, best_score kept, newsSeen kept', cur.revision === 3 && cur.data.totalEarned === 0 && cur.data.resetAt === clock &&
    cur.data.achievements.length === 0 && cur.best_score === 200 && cur.data.newsSeen.join() === 'siralama');
  r = await M.rpc('u-none', RPC.reset, {}); check('reset without row -> revision 0, backup_id null', r.data.revision === 0 && r.data.backup_id === null);
  r = await M.rpc(null, RPC.reset, {}); check('reset anon -> 42501', r.error && r.error.code === '42501');
  r = await M.rpc(U, RPC.listBackups, {});
  check('kodhane_list_save_backups fields', r.data.length === 1 && ['id', 'revision', 'reason', 'score', 'best_score', 'stage', 'best_stage', 'created_at', 'expires_at'].every((k) => k in r.data[0]) && !('game' in r.data[0]) &&
    r.data[0].reason === 'reset' && r.data[0].score === 200 && Date.parse(r.data[0].expires_at) - Date.parse(r.data[0].created_at) === 30 * 86400000, r.data);
  r = await M.rpc(U, RPC.restore, { p_backup_id: bid });
  check('kodhane_restore_save -> {revision, backup_id, restored_from, best_score, best_stage} (no data)', 'best_stage' in r.data && r.data.revision === 4 && r.data.restored_from === bid && r.data.backup_id && !('data' in r.data), r.data);
  cur = (await M.select(U)).data;
  check('restore writes the backup payload with revision+1', cur.revision === 4 && cur.data.totalEarned === 200);
  r = await M.rpc('u-2', RPC.restore, { p_backup_id: bid }); check('other user cannot restore -> 404 PT404 backup_not_found', r.status === 404 && r.error.code === 'PT404' && r.error.message === 'backup_not_found');
  clock += 31 * 86400000;
  r = await M.rpc(U, RPC.restore, { p_backup_id: bid }); check('expired (31 d) backup -> 404 PT404', r.status === 404 && r.error.code === 'PT404');
  r = await M.rpc(U, RPC.listBackups, {}); check('expired backups not listed', r.data.length === 0);

  // ---------------------------------------------------------------- iki istemci (aynı depo): A sıfırlar, B'nin bayat yazması reddedilir; sonra tersi
  const st2 = memStorage();
  const S2 = createSaveMock({ storage: st2, channel: false });
  const V = 'u-v';
  function client(name) {
    return {
      name, rev: 0, state: save(0),
      async pull() { const x = (await S2.select(V)).data; this.rev = x ? x.revision : 0; if (x) this.state = x.data; return x; },
      async push() { const x = await S2.upsert(V, { user_id: V, data: this.state, save_version: 4, updated_at: new Date().toISOString(), revision: this.rev + 1 }); if (!x.error) this.rev += 1; return x; },
      async reset() { const x = await S2.rpc(V, RPC.reset, {}); this.rev = x.data.revision; this.state = save(0, { resetAt: Date.now() }); return x; }
    };
  }
  const A = client('A'), B = client('B');
  A.state = save(1000); await A.push(); await B.pull();
  B.state = save(1500); r = await B.push(); check('B writes normally', !r.error && B.rev === 2);
  await A.pull();
  r = await A.reset(); check('A resets', r.data.revision === 3);
  B.state = save(1700);
  r = await B.push(); check('B stale write rejected (409 PT409 stale_revision)', r.status === 409 && r.error.code === 'PT409' && r.error.message === 'stale_revision');
  cur = (await S2.select(V)).data; check('reset not overwritten by B', cur.data.totalEarned === 0 && cur.revision === 3);
  await B.pull(); check('B loads the current (reset) save and revision', B.state.totalEarned === 0 && B.rev === 3);
  r = await B.push(); check('B can write again after pull', !r.error);
  // reverse
  await A.pull(); A.state = save(50); r = await A.push(); check('A writes', !r.error);
  await B.pull();
  r = await B.reset(); check('B resets', !r.error);
  A.state = save(80); r = await A.push(); check('A stale write rejected after B reset', r.status === 409 && r.error.message === 'stale_revision');
  await A.pull(); check('A loads current save', A.state.totalEarned === 0 && A.rev === B.rev);

  console.log('\n' + pass + '/' + (pass + fail) + ' passed');
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
