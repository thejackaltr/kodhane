// v4.3 isimsiz sayaç izni (Node, tarayıcısız): game.js'in arayüz bölümü sahte bir window/document ile vm içinde
// çalıştırılır (init() çalışmaz: document.readyState = 'loading'). Kontrol edilenler: izin kapısı, izinden önce gelen
// olayların ATILMASI (kuyruğa alınmaz), "Kapat", Gizlilik düğmesiyle kapatma (before-send + umami.disabled), yeniden
// açma, localhost/bilinmeyen alan adında asla yüklenmemesi, anonim Supabase sayacı kapısı (GATE_SUPABASE_COUNTER),
// metinler (TEL_TEXT/telText) ve yatırım turu / halka arz / yeni oyunun izin anahtarlarına dokunmaması.
// Çalıştır: node tests/test_consent.js
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const SRC = fs.readFileSync(path.join(__dirname, '..', 'game.js'), 'utf8');
let pass = 0, fail = 0;
function check(name, cond, info) {
  if (cond) pass++; else fail++;
  console.log((cond ? 'PASS ' : 'FAIL ') + name + (info !== undefined && !cond ? ' ' + JSON.stringify(info) : ''));
}
function memStorage() {
  const m = new Map();
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k), clear: () => m.clear(), m };
}
function env(host, protocol, storage) {
  const appended = [];
  const listeners = {};
  const mkEl = (tag) => ({ tagName: tag, attrs: {}, ev: {}, style: {}, setAttribute(k, v) { this.attrs[k] = String(v); }, getAttribute(k) { return this.attrs[k] || null; },
    addEventListener(t, f) { this.ev[t] = f; }, appendChild(c) { return c; } });
  const document = {
    readyState: 'loading', addEventListener() {}, createElement: mkEl, getElementById: () => null, querySelector: () => null, querySelectorAll: () => [],
    head: { appendChild: (el) => { appended.push(el); return el; } }, body: { appendChild: (el) => el }, documentElement: { style: { setProperty() {}, removeProperty() {} } }
  };
  const window = { location: { hostname: host, protocol, origin: protocol + '//' + host, pathname: '/' }, localStorage: storage, sessionStorage: memStorage(), document,
    addEventListener: (t, f) => { (listeners[t] = listeners[t] || []).push(f); }, matchMedia: () => ({ matches: false }), navigator: { onLine: true },
    setTimeout, clearTimeout, setInterval: () => 0, requestAnimationFrame: () => 0, cancelAnimationFrame() {} };
  window.window = window;
  const ctx = vm.createContext({ window, document, localStorage: storage, sessionStorage: window.sessionStorage, navigator: window.navigator, location: window.location,
    setTimeout, clearTimeout, setInterval: () => 0, console, getComputedStyle: () => ({ getPropertyValue: () => '' }), requestAnimationFrame: () => 0, cancelAnimationFrame() {} });
  vm.runInContext(SRC, ctx);
  return { K: window.Kodhane, window, appended, listeners };
}
const on = (st) => { st.setItem('kodhane_tel_notice', '1'); st.setItem('kodhane_tel', 'on'); };

// ---------------------------------------------------------------- metinler
{
  const { K } = env('kodhane.teserix.com', 'https:', memStorage());
  const keys = ['telemetry.title', 'telemetry.body', 'telemetry.ok', 'telemetry.off', 'telemetry.detailsLink', 'telemetry.detailsTitle', 'telemetry.details',
    'telemetry.detailsClose', 'telemetry.offToast', 'telemetry.onToast', 'settings.privacy', 'settings.telemetryOn', 'settings.telemetryOff', 'settings.telemetryHint'];
  check('TEL_TEXT: exactly the agreed keys', JSON.stringify(Object.keys(K.TEL_TEXT).sort()) === JSON.stringify(keys.slice().sort()), Object.keys(K.TEL_TEXT));
  check('TEL_TEXT: fixed labels (Tamam / Kapat / Ayrıntılar / Gizlilik / İsimsiz sayaç)', K.telText('telemetry.ok') === 'Tamam' && K.telText('telemetry.off') === 'Kapat' &&
    K.telText('telemetry.detailsLink') === 'Ayrıntılar' && K.telText('settings.privacy') === 'Gizlilik' && K.telText('telemetry.title') === 'İsimsiz sayaç' && K.telText('telemetry.detailsClose') === 'Kapat');
  check('TEL_TEXT: switch labels say "İsimsiz sayaç", never "İstatistik"', /İsimsiz sayaç/.test(K.telText('settings.telemetryOn')) && /İsimsiz sayaç/.test(K.telText('settings.telemetryOff')) &&
    !/İstatistik/.test(K.telText('settings.telemetryOn') + K.telText('settings.telemetryOff') + K.telText('telemetry.title') + K.telText('telemetry.body')));
  check('telText: details is a list of non-empty paragraphs (copy), unknown key -> ""', Array.isArray(K.telText('telemetry.details')) && K.telText('telemetry.details').length >= 1 &&
    K.telText('telemetry.details').every((p) => typeof p === 'string' && p.trim()) && K.telText('nope') === '');
  const approved = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'kodhane-telemetry-copy.json'), 'utf8'));
  // v4.4.3: kazanç kaydı paragrafı (Yazı kazanç kaydı r2, çeşit yaması) ayrı fixture'dan; onu çıkarınca metin onaylı kopyayla birebir aynı
  const kgv = Object.values(JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'kodhane-kazanc-kaydi-copy.json'), 'utf8')).variants);
  const telNoKg = JSON.parse(JSON.stringify(K.TEL_TEXT)); telNoKg['telemetry.details'] = telNoKg['telemetry.details'].filter((x) => !kgv.includes(x));
  check('TEL_TEXT: exactly the approved final copy (fixture, character for character; v4.4.3 kazanç kaydı paragraph aside)', JSON.stringify(telNoKg) === JSON.stringify(approved)
    && K.TEL_TEXT['telemetry.details'].length - telNoKg['telemetry.details'].length <= 1);
  check('TEL_TEXT: no [TASLAK] placeholders left', !/TASLAK/.test(JSON.stringify(K.TEL_TEXT)) && !/TASLAK/.test(fs.readFileSync(path.join(__dirname, '..', 'game.js'), 'utf8')));
  check('TEL_TEXT: curly quotes “Tamam” and emoji kept', K.telText('telemetry.details')[3].indexOf('“Tamam” dedikten') !== -1 && K.telText('settings.telemetryOn').indexOf('📊') === 0);
  check('reset copy: "Kalacaklar" names the privacy settings', K.RESET_TEXT['reset.keepList'].indexOf('Ses, titreşim ve gizlilik ayarların') !== -1 &&
    K.RESET_TEXT['reset.keepList'].indexOf('Ses ve titreşim ayarların') === -1);
  check('index.html: no Umami script tag (loaded at runtime only)', !/<script[^>]*analiz\.teserix\.com/.test(fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8')));
  check('constants: website id + domains moved from index.html into game.js', K.UMAMI.src === 'https://analiz.teserix.com/script.js' && K.UMAMI.websiteId === '6a036eb3-5974-482f-bcce-dbdf0a383f36' &&
    K.UMAMI.domains === 'kodhane.teserix.com,thejackaltr.github.io');
  check('keys: own localStorage keys, separate from the save and kodhane_ayarlar_v1', K.TEL_KEYS.pref === 'kodhane_tel' && K.TEL_KEYS.notice === 'kodhane_tel_notice' &&
    K.TEL_KEYS.pref !== K.SAVE_KEY && K.TEL_KEYS.pref !== K.SETTINGS_KEY);
}

// ---------------------------------------------------------------- izin kapısı
{
  const st = memStorage(); const E = env('kodhane.teserix.com', 'https:', st); const K = E.K;
  check('before the notice: noticeNeeded, no consent', K.tel.noticeNeeded() && !K.tel.consent());
  check('before the notice: track -> "off" (dropped, incl. game_start)', K.track('game_start') === 'off' && K.track('share_click') === 'off');
  check('before the notice: no script, nothing queued, nothing stored', E.appended.length === 0 && K.umamiQueue().length === 0 && K.tracked.length === 0 && st.m.size === 0);
  check('before the notice: Supabase counter not allowed', K.counterAllowed() === false);
  K.tel.answer(true);
  const s = E.appended[0] || { attrs: {} };
  check('"Tamam": script injected once, async, with website id / domains / before-send / DNT / exclude-search / exclude-hash', E.appended.length === 1 && s.async === true &&
    s.src === 'https://analiz.teserix.com/script.js' && s.attrs['data-website-id'] === K.UMAMI.websiteId && s.attrs['data-domains'] === K.UMAMI.domains &&
    s.attrs['data-before-send'] === '__kodhaneUmamiBeforeSend' && s.attrs['data-do-not-track'] === 'true' && s.attrs['data-exclude-search'] === 'true' && s.attrs['data-exclude-hash'] === 'true', s.attrs);
  check('"Tamam": pre-consent game_start is NOT sent later (queue empty right after the answer)', K.umamiQueue().length === 0);
  check('"Tamam": event while loading -> tiny in-memory queue', K.track('share_click') === 'queued' && JSON.stringify(K.umamiQueue()) === '["share_click"]');
  const calls = []; E.window.umami = { track: (...a) => calls.push(a) };
  s.ev.load();
  check('script load flushes only post-consent events (names only)', JSON.stringify(calls) === '[["share_click"]]', calls);
  check('consent on: sent directly', K.track('login_success') === 'sent' && JSON.stringify(calls[1]) === '["login_success"]');
  check('counter allowed after "Tamam"', K.counterAllowed() === true);
  // Gizlilik düğmesi: kapat
  K.tel.setEnabled(false);
  check('switch off: track -> off, nothing sent', K.track('reset_or_prestige') === 'off' && calls.length === 2);
  check('switch off: before-send drops every request (pageviews too)', E.window.__kodhaneUmamiBeforeSend('event', { name: 'x' }) === null);
  check('switch off: umami.disabled kill switch set', st.getItem('umami.disabled') === '1');
  check('switch off: Supabase counter not allowed', K.counterAllowed() === false);
  K.tel.setEnabled(true);
  check('switch back on: umami.disabled removed, before-send passes, events sent', st.getItem('umami.disabled') === null &&
    JSON.stringify(E.window.__kodhaneUmamiBeforeSend('event', { name: 'x' })) === '{"name":"x"}' && K.track('share_click') === 'sent' && E.appended.length === 1);
  // başka sekme kapattı (storage olayı): sync kapatır
  st.setItem('kodhane_tel', 'off');
  check('another tab switched off: next track is dropped at once', K.track('share_click') === 'off' && st.getItem('umami.disabled') === '1');
}
{
  const st = memStorage(); const E = env('thejackaltr.github.io', 'https:', st); const K = E.K;
  K.tel.answer(false);
  check('"Kapat": no script, events dropped, umami.disabled set, counter off', E.appended.length === 0 && K.track('game_start') === 'off' && st.getItem('umami.disabled') === '1' && !K.counterAllowed());
  const E2 = env('thejackaltr.github.io', 'https:', st);
  check('"Kapat" then a new session: still no script, notice not asked again', E2.K.tel.sync() === false && E2.appended.length === 0 && !E2.K.tel.noticeNeeded());
  E2.K.tel.setEnabled(true);
  check('re-enable after "Kapat": script loaded now (github.io)', E2.appended.length === 1);
}
{
  const st = memStorage(); on(st);
  const E = env('thejackaltr.github.io', 'https:', st);
  check('later session with consent on: game_start goes through the tracker (queued until load)', E.K.tel.sync() === true && E.K.track('game_start') === 'queued' && E.appended.length === 1);
}
for (const [host, proto] of [['localhost', 'http:'], ['127.0.0.1', 'http:'], ['0.0.0.0', 'http:'], ['', 'file:'], ['kodhane.example.com', 'https:']]) {
  const st = memStorage(); on(st);
  const E = env(host, proto, st);
  check('never on ' + (host || proto) + ' even with consent (no script, track off)', E.K.track('game_start') === 'off' && E.appended.length === 0 && E.K.tel.sync() === false);
}
{
  const st = memStorage(); on(st);
  const E = env('kodhane.teserix.com', 'https:', st);
  for (let i = 0; i < 40; i++) E.K.track('share_click');
  check('queue bounded (20) while the tracker loads', E.K.umamiQueue().length === 20);
  E.appended[0].ev.error();
  check('blocked tracker: queue cleared, track never throws', E.K.umamiQueue().length === 0 && (() => { try { E.K.track('share_click'); return true; } catch (e) { return false; } })());
  E.window.umami = { track: () => { throw new Error('boom'); } };
  check('throwing tracker is swallowed', (() => { try { E.K.track('login_success'); return true; } catch (e) { return false; } })());
}

// ---------------------------------------------------------------- Supabase sayacı bayrağı
{
  check('GATE_SUPABASE_COUNTER = true (one named constant in game.js)', /\n  var GATE_SUPABASE_COUNTER = true;\n/.test(SRC) && (SRC.match(/GATE_SUPABASE_COUNTER/g) || []).length >= 2);
  const flipped = SRC.replace('var GATE_SUPABASE_COUNTER = true;', 'var GATE_SUPABASE_COUNTER = false;');
  const st = memStorage();
  const ctx = env('kodhane.teserix.com', 'https:', st);            // for the window shape
  const c2 = vm.createContext({ window: ctx.window, document: ctx.window.document, localStorage: st, sessionStorage: memStorage(), navigator: ctx.window.navigator, location: ctx.window.location,
    setTimeout, clearTimeout, setInterval: () => 0, console, getComputedStyle: () => ({ getPropertyValue: () => '' }) });
  vm.runInContext(flipped, c2);
  check('flag false: counter independent of consent (Umami still gated)', ctx.window.Kodhane.counterAllowed() === true && ctx.window.Kodhane.track('game_start') === 'off');
  const lb = fs.readFileSync(path.join(__dirname, '..', 'leaderboard.js'), 'utf8');
  check('leaderboard.js countEvent refuses without K.counterAllowed() (the only kodhane_count_event call)', /function countEvent\(name\) \{\n    if \(typeof K\.counterAllowed !== 'function' \|\| !K\.counterAllowed\(\)\) return;/.test(lb) &&
    (lb.match(/COUNT_RPC/g) || []).length === 2);
  check('game.js countEvent wrapper checks tel.counterAllowed()', /function countEvent\(name\) \{ if \(!tel\.counterAllowed\(\)\) return;/.test(SRC));
}

// ---------------------------------------------------------------- tercih: yatırım turu / halka arz / yeni oyun anahtarlara dokunmaz
{
  const st = memStorage(); st.setItem('kodhane_tel_notice', '1'); st.setItem('kodhane_tel', 'off');
  const E = env('kodhane.teserix.com', 'https:', st); const K = E.K;
  const snap = () => st.getItem('kodhane_tel_notice') + '|' + st.getItem('kodhane_tel');
  K.state = K.newState(); K.state.runEarned = 1e12; K.state.totalEarned = 1e12; K.state.money = 1e12;
  K.doPrestige();
  check('[prefs] Yatırım Turu (doPrestige) keeps kodhane_tel / kodhane_tel_notice', snap() === '1|off' && K.state.prestigeCount === 1);
  K.state.stageBest = 8; K.state.stage = 8; K.state.runEarned = K.STAGES[8].at * 10; K.state.totalEarned = K.state.runEarned;
  const ipo = typeof K.doIpo === 'function' ? K.doIpo() : null;
  check('[prefs] Halka Arz (doIpo) keeps kodhane_tel / kodhane_tel_notice', snap() === '1|off' && typeof K.doIpo === 'function', ipo);
  K.state = K.newState();
  check('[prefs] new game state keeps kodhane_tel / kodhane_tel_notice', snap() === '1|off');
}

console.log('\n' + pass + '/' + (pass + fail) + ' passed');
process.exit(fail ? 1 : 0);
