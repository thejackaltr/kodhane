// Kodhane dağıtım listesi tutarlılığı (Node, tarayıcısız): servis çalışanının önbellek listesindeki (sw.js ASSETS) her dosya
// nginx imajına da kopyalanmalı (Dockerfile'daki 'cp ... /out/' satırı). Aksi halde GitHub Pages'te (tüm depo yayınlanır)
// görünen bir dosya kodhane.teserix.com'da (nginx) 404 olur ve iki kanal ayrışır. Ters yön de denetlenir: imaja kopyalanan
// her kök dosya ya ASSETS'te ya da bilinçli istisna listesinde olmalı.
// Çalıştır: node tests/test_sw_docker_assets.js
'use strict';
const path = require('path'), fs = require('fs');
const ROOT = path.join(__dirname, '..');
let pass = 0, fail = 0;
function check(name, cond, info) {
  if (cond) pass++; else fail++;
  console.log((cond ? 'PASS ' : 'FAIL ') + name + (info !== undefined && !cond ? ' ' + JSON.stringify(info) : ''));
}

// sw.js: var ASSETS = ['./', './index.html', ...];  (birden çok satıra yayılabilir)
const SW = fs.readFileSync(path.join(ROOT, 'sw.js'), 'utf8');
const m = SW.match(/var\s+ASSETS\s*=\s*\[([\s\S]*?)\];/);
check('sw.js: ASSETS list found', !!m);
const assets = m ? [...m[1].matchAll(/'([^']*)'/g)].map((x) => x[1]) : [];
check('sw.js: ASSETS is not empty and starts with "./"', assets.length > 1 && assets[0] === './', assets);
const files = assets.filter((a) => a !== './').map((a) => a.replace(/^\.\//, ''));
check('sw.js: every entry is a root-relative file path ("./name")', assets.filter((a) => a !== './').every((a) => /^\.\/[^/]+$/.test(a)), assets);

// Dockerfile: "cp a b c \ <newline> d e /out/" (satır devamlı tek komut)
const DF = fs.readFileSync(path.join(ROOT, 'Dockerfile'), 'utf8').replace(/\\\r?\n/g, ' ');
const cps = [...DF.matchAll(/\bcp\s+((?:(?!&&)[^\n])*?)\s+\/out\/?(?=\s|$)/g)].map((x) => x[1].trim().split(/\s+/)).filter((a) => a[0] !== '-r');
check('Dockerfile: exactly one "cp <files> /out/" command found', cps.length === 1, cps);
const copied = cps.length ? cps[0] : [];

for (const f of files) {
  check('sw.js ASSETS "' + f + '" is copied by the Dockerfile cp line', copied.indexOf(f) !== -1, copied);
}
// ASSETS'teki her dosya depoda var mı (PNG simgeler yayın sırasında tools/make_icons.py ile üretilir, depoda yok)
const GENERATED = ['icon-192.png', 'icon-512.png', 'apple-touch-icon.png'];
for (const f of files) {
  if (GENERATED.indexOf(f) !== -1) continue;
  check('sw.js ASSETS "' + f + '" exists in the repository', fs.existsSync(path.join(ROOT, f)));
}
// Ters yön: imaja kopyalanan kök dosyalar ASSETS'te (sw.js kendini önbelleğe almaz; tasarım gereği)
const NOT_CACHED = ['sw.js'];
for (const f of copied) {
  if (NOT_CACHED.indexOf(f) !== -1) continue;
  check('Dockerfile cp "' + f + '" is listed in sw.js ASSETS', files.indexOf(f) !== -1, files);
}
// index.html'in yüklediği yerel CSS/JS dosyaları hem ASSETS'te hem cp satırında
const HTML = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');
const local = [...HTML.matchAll(/<(?:link[^>]+href|script[^>]+src)="([^":]+\.(?:css|js))"/g)].map((x) => x[1].replace(/^\.\//, ''));
check('index.html loads at least style.css and game.js', local.indexOf('style.css') !== -1 && local.indexOf('game.js') !== -1, local);
for (const f of local) {
  check('index.html "' + f + '" is in sw.js ASSETS and in the Dockerfile cp line', files.indexOf(f) !== -1 && copied.indexOf(f) !== -1, { files, copied });
}

console.log(`\n${pass}/${pass + fail} passed`);
process.exit(fail ? 1 : 0);
