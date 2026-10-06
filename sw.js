/* Kodhane servis çalışanı (v4.3.1): çevrimdışı oynanış + sürüm güncelleme.
 * BUILD değeri yayın sırasında (GitHub Actions) commit kimliğiyle değiştirilir;
 * böylece her yayında yeni bir önbellek oluşur ve oyuncuya "Yeni sürüm hazır" bildirimi gider.
 */
var BUILD = '__BUILD__';
var CACHE_VERSION = 'v4.5.0';
var CACHE = 'kodhane-' + CACHE_VERSION + '-' + BUILD;
var ASSETS = ['./', './index.html', './style.css', './game.js', './cloud.js', './leaderboard.js', './lossreport.js', './theme.css', './fx.js', './scene.css', './scene.js', './manifest.webmanifest',
  './icon.svg', './icon-192.png', './icon-512.png', './apple-touch-icon.png'];

self.addEventListener('install', function (e) {
  e.waitUntil(caches.open(CACHE).then(function (cache) {
    return Promise.all(ASSETS.map(function (url) {
      return fetch(new Request(url, { cache: 'reload' })).then(function (res) {
        if (res.ok) return cache.put(url, res);
      }).catch(function () {});
    }));
  }));
});

self.addEventListener('message', function (e) {
  if (e.data === 'skipWaiting') self.skipWaiting();
});

self.addEventListener('activate', function (e) {
  e.waitUntil(caches.keys().then(function (keys) {
    return Promise.all(keys.filter(function (k) {
      return k.indexOf('kodhane-') === 0 && k !== CACHE;
    }).map(function (k) { return caches.delete(k); }));
  }).then(function () { return self.clients.claim(); }));
});

self.addEventListener('fetch', function (e) {
  var req = e.request;
  var url = new URL(req.url);
  // Supabase (giriş/bulut kaydı), jsDelivr CDN, Umami (analiz.teserix.com/script.js ve /api/send) ve diğer tüm dış istekler hiçbir zaman
  // önbelleğe alınmaz ve yakalanmaz; yalnızca GET ile istenen kendi dosyalarımız önbellekten sunulur.
  if (req.method !== 'GET' || url.origin !== self.location.origin) return;
  if (/(^|\.)supabase\.(co|in)$/.test(url.hostname) || url.hostname === 'kodhane-api.teserix.com' || url.hostname === 'supabase.teserix.com' || url.hostname === 'cdn.jsdelivr.net' || url.hostname === 'analiz.teserix.com') return;
  // Giriş bağlantısından dönüşte (?code=, ?error=) sayfa doğrudan ağdan gelsin.
  if (req.mode === 'navigate' && /[?&](code|error|error_code|error_description|token_hash)=/.test(url.search)) return;
  var isApp = req.mode === 'navigate' && /\/(index\.html)?$/.test(url.pathname);
  e.respondWith(caches.open(CACHE).then(function (cache) {
    var key = isApp ? './index.html' : req;
    return cache.match(key, { ignoreSearch: true }).then(function (hit) {
      if (hit) return hit;
      return fetch(req).then(function (res) {
        if (res.ok && req.mode !== 'navigate') cache.put(req, res.clone());
        return res;
      }).catch(function () {
        return isApp ? cache.match('./') : Response.error();
      });
    });
  }));
});
