// Hosta göre ortam (dev dalı, Node, tarayıcısız): game.js + cloud.js + leaderboard.js sahte bir window/document ile vm içinde
// çalıştırılır (init()/start() çalışmaz: document.readyState = 'loading'). Kontrol edilenler: hostEnv tablosu (küçük harf, port yok),
// canlı iki hostta bugünkü davranış (configured true, canlı Supabase adresi/anahtarı, canlı Umami), kodhane-dev.teserix.com ve
// bilinmeyen hostlarda bulut kapalı (configured false, adres/anahtar boş) ve izin açıkken bile Umami betiği / Supabase isteği 0,
// TEST işareti bayrağı yalnız kodhane-dev.teserix.com, TEST_CLOUD'un boş olduğu ve doldurulunca yalnız kodhane-dev'i açtığı.
// Gerçek tarayıcıda istek sayımı ve TEST işareti: tests/test_env_ui.py.
// Çalıştır: node tests/test_env.js
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const ROOT = path.join(__dirname, '..');
const GAME = fs.readFileSync(path.join(ROOT, 'game.js'), 'utf8');
const CLOUD = fs.readFileSync(path.join(ROOT, 'cloud.js'), 'utf8');
const LB = fs.readFileSync(path.join(ROOT, 'leaderboard.js'), 'utf8');
const LIVE_URL = 'https://kodhane-api.teserix.com';
const LIVE_KEY = /key: '([^']+)'/.exec(CLOUD)[1];
let pass = 0, fail = 0;
function check(name, cond, info) {
  if (cond) pass++; else fail++;
  console.log((cond ? 'PASS ' : 'FAIL ') + name + (info !== undefined && !cond ? ' ' + JSON.stringify(info) : ''));
}
function memStorage() {
  const m = new Map();
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k), clear: () => m.clear(), m };
}
function env(host, protocol, opts) {
  opts = opts || {};
  const storage = memStorage();
  if (opts.consent) { storage.setItem('kodhane_tel_notice', '1'); storage.setItem('kodhane_tel', 'on'); }
  const appended = [], fetches = [];
  const mkEl = (tag) => ({ tagName: tag, attrs: {}, ev: {}, style: {}, classList: { add() {}, remove() {}, contains: () => false, toggle() {} },
    setAttribute(k, v) { this.attrs[k] = String(v); }, getAttribute(k) { return this.attrs[k] || null; }, addEventListener(t, f) { this.ev[t] = f; }, appendChild(c) { return c; } });
  const add = (el) => { appended.push(el); return el; };
  const document = {
    readyState: 'loading', addEventListener() {}, createElement: mkEl, getElementById: () => null, querySelector: () => null, querySelectorAll: () => [],
    head: { appendChild: add }, body: { appendChild: add }, documentElement: { style: { setProperty() {}, removeProperty() {} }, appendChild: add }, title: 'Kodhane'
  };
  const location = { hostname: host, protocol, origin: protocol + '//' + host, pathname: '/', hash: '', search: '', href: protocol + '//' + host + '/' };
  const fetch = (url, init) => { fetches.push(String(url)); return new Promise(() => {}); };
  const window = { location, localStorage: storage, sessionStorage: memStorage(), document, addEventListener() {}, removeEventListener() {},
    matchMedia: () => ({ matches: false }), navigator: { onLine: true }, fetch, setTimeout, clearTimeout, setInterval: () => 0, clearInterval() {},
    requestAnimationFrame: () => 0, cancelAnimationFrame() {} };
  window.window = window;
  if (opts.cloudConfig) window.KODHANE_CLOUD_CONFIG = opts.cloudConfig;
  const ctx = vm.createContext({ window, document, localStorage: storage, sessionStorage: window.sessionStorage, navigator: window.navigator, location, fetch,
    setTimeout, clearTimeout, setInterval: () => 0, clearInterval() {}, console, getComputedStyle: () => ({ getPropertyValue: () => '' }),
    requestAnimationFrame: () => 0, cancelAnimationFrame() {}, history: { replaceState() {} }, URL, Promise });
  vm.runInContext(GAME, ctx);
  vm.runInContext(opts.cloudSrc || CLOUD, ctx);
  vm.runInContext(LB, ctx);
  return { K: window.Kodhane, window, appended, fetches };
}
const umamiScripts = (E) => E.appended.filter((s) => /analiz\.teserix\.com/.test(s.src || ''));
const liveHits = (E) => E.fetches.filter((u) => u.indexOf(LIVE_URL) === 0 || /supabase\.teserix\.com/.test(u));

// ---------------------------------------------------------------- hostEnv tablosu (tek yer: game.js)
{
  const { K } = env('kodhane.teserix.com', 'https:');
  const T = [
    ['kodhane.teserix.com', 'live'], ['thejackaltr.github.io', 'live'], ['KODHANE.TESERIX.COM', 'live'], ['TheJackalTR.github.io', 'live'], ['kodhane.teserix.com:443', 'live'],
    ['kodhane-dev.teserix.com', 'dev'], ['KODHANE-DEV.teserix.com', 'dev'], ['kodhane-dev.teserix.com:8443', 'dev'],
    ['localhost', 'local'], ['127.0.0.1', 'local'], ['', 'local'], [null, 'local'], [undefined, 'local'], ['kodhane.test', 'local'],
    ['x.kodhane-dev.teserix.com', 'local'], ['kodhane-dev.teserix.com.evil.io', 'local'], ['kodhane.teserix.com.evil.io', 'local'], ['xkodhane.teserix.com', 'local'],
    ['acikofis.teserix.com', 'local'], ['kodhane-api.teserix.com', 'local'], ['preview.kodhane.pages.dev', 'local']
  ];
  const bad = T.filter(([h, want]) => K.hostEnv(h).name !== want).map(([h, want]) => [h, want, K.hostEnv(h).name]);
  check('hostEnv: live = kodhane.teserix.com + thejackaltr.github.io, dev = kodhane-dev.teserix.com, everything else local (case-insensitive, port ignored)', bad.length === 0, bad);
  check('hostEnv: TEST badge flag only for dev, live flag only for live', T.every(([h]) => K.hostEnv(h).badge === (K.hostEnv(h).name === 'dev') && K.hostEnv(h).live === (K.hostEnv(h).name === 'live')));
  check('one list: LIVE_HOSTS = Umami domains (unchanged string)', JSON.stringify(K.LIVE_HOSTS) === '["kodhane.teserix.com","thejackaltr.github.io"]' &&
    K.UMAMI.domains === 'kodhane.teserix.com,thejackaltr.github.io' && K.DEV_HOST === 'kodhane-dev.teserix.com');
}

// ---------------------------------------------------------------- canlı iki host: bugünkü davranış birebir
for (const host of ['kodhane.teserix.com', 'thejackaltr.github.io']) {
  const E = env(host, 'https:', { consent: true }); const K = E.K;
  check('[' + host + '] ENV live, no TEST badge', K.ENV.name === 'live' && K.ENV.live === true && K.ENV.badge === false);
  check('[' + host + '] configured() true with the live Supabase (kodhane-api.teserix.com + embedded anon key)', K.cloud.isConfigured() === true &&
    K.cloud.config.url === LIVE_URL && K.cloud.config.key === LIVE_KEY && K.newsNeedsLeaderboard() === true);
  check('[' + host + '] consent on: live Umami script injected once (same src / website id / domains)', K.tel.sync() === true && umamiScripts(E).length === 1 &&
    umamiScripts(E)[0].src === 'https://analiz.teserix.com/script.js' && umamiScripts(E)[0].attrs['data-website-id'] === '6a036eb3-5974-482f-bcce-dbdf0a383f36' &&
    umamiScripts(E)[0].attrs['data-domains'] === 'kodhane.teserix.com,thejackaltr.github.io');
  K.countEvent('news_show');
  check('[' + host + '] consent on: anonymous counter goes to the live API (as before)', E.fetches.length === 1 && E.fetches[0] === LIVE_URL + '/rest/v1/rpc/kodhane_count_event', E.fetches);
}

// ---------------------------------------------------------------- kodhane-dev + bilinmeyen hostlar: bulut kapalı, Umami yok
for (const [host, proto] of [['kodhane-dev.teserix.com', 'https:'], ['localhost', 'http:'], ['127.0.0.1', 'http:'], ['', 'file:'], ['kodhane-preview.example.com', 'https:'], ['acikofis.teserix.com', 'https:']]) {
  const tag = '[' + (host || proto) + ']';
  const E = env(host, proto, { consent: true }); const K = E.K;
  const dev = host === 'kodhane-dev.teserix.com';
  check(tag + ' ENV ' + (dev ? 'dev, TEST badge on' : 'local, no TEST badge'), K.ENV.name === (dev ? 'dev' : 'local') && K.ENV.live === false && K.ENV.badge === dev);
  check(tag + ' configured() false, no live address/key in the runtime config', K.cloud.isConfigured() === false && K.cloud.config.url === '' && K.cloud.config.key === '' &&
    K.newsNeedsLeaderboard() === false);
  K.tel.sync(); K.track('game_start'); K.countEvent('news_show'); K.countEvent('news_click');
  check(tag + ' consent on: Umami script 0, track off, Supabase/fetch requests 0', umamiScripts(E).length === 0 && E.appended.length === 0 && K.track('share_click') === 'off' &&
    E.fetches.length === 0 && liveHits(E).length === 0, { scripts: E.appended.map((s) => s.src), fetches: E.fetches });
  let rej = '';
  K.cloud.getClient().catch((e) => { rej = e.message; });
  setTimeout(() => check(tag + ' getClient() rejects not-configured (no SDK script)', rej === 'not-configured' && E.appended.length === 0, rej), 0);
}

// ---------------------------------------------------------------- TEST_CLOUD: tek yer, şu an boş; doldurulunca yalnız kodhane-dev açılır
{
  check('cloud.js: TEST_CLOUD is empty (no test address / key committed)', /\n  var TEST_CLOUD = \{ url: '', key: '' \};\n/.test(CLOUD) && (CLOUD.match(/TEST_CLOUD = /g) || []).length === 1);
  check('cloud.js: the live block is unchanged (url + one embedded key)', /url: 'https:\/\/kodhane-api\.teserix\.com',/.test(CLOUD) && (CLOUD.match(/key: 'eyJ/g) || []).length === 1);
  const filled = CLOUD.replace("var TEST_CLOUD = { url: '', key: '' };", "var TEST_CLOUD = { url: 'https://kodhane-test.example.com', key: 'sb_publishable_dummy' };");
  const D = env('kodhane-dev.teserix.com', 'https:', { cloudSrc: filled });
  check('TEST_CLOUD filled (simulated): kodhane-dev uses it (configured true, test address, never the live one)', D.K.cloud.isConfigured() === true &&
    D.K.cloud.config.url === 'https://kodhane-test.example.com' && D.K.cloud.config.key === 'sb_publishable_dummy');
  const L = env('localhost', 'http:', { cloudSrc: filled });
  const P = env('kodhane.teserix.com', 'https:', { cloudSrc: filled });
  check('TEST_CLOUD filled (simulated): localhost stays off, live hosts keep the live Supabase', L.K.cloud.isConfigured() === false && L.K.cloud.config.url === '' &&
    P.K.cloud.isConfigured() === true && P.K.cloud.config.url === LIVE_URL);
  const half = CLOUD.replace("var TEST_CLOUD = { url: '', key: '' };", "var TEST_CLOUD = { url: 'https://kodhane-test.example.com', key: '' };");
  check('TEST_CLOUD with an address but no key: still off on kodhane-dev', env('kodhane-dev.teserix.com', 'https:', { cloudSrc: half }).K.cloud.isConfigured() === false);
}

// ---------------------------------------------------------------- test geçersiz kılması (KODHANE_CLOUD_CONFIG) eskisi gibi
{
  const E = env('127.0.0.1', 'http:', { cloudConfig: { url: 'https://kodhane-test.supabase.co', key: 'sb_publishable_test_key' } });
  check('localhost + KODHANE_CLOUD_CONFIG (tests): configured with the fake address', E.K.cloud.isConfigured() === true && E.K.cloud.config.url === 'https://kodhane-test.supabase.co');
  const N = env('127.0.0.1', 'http:', { cloudConfig: { url: '', key: '__NOT_CONFIGURED__' } });
  check('localhost + empty override: off', N.K.cloud.isConfigured() === false);
}

setTimeout(() => {
  console.log('\n' + pass + '/' + (pass + fail) + ' passed');
  process.exit(fail ? 1 : 0);
}, 20);
