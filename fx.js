/* Kodhane görsel katman v1 (fx.js) — yalnız sunum efektleri.
 * Oyun durumunu okumaz/yazmaz, ağ isteği yapmaz, metin eklemez. game.js'deki tek kanca: sfx() her çağrıldığında
 * document üzerinde 'kodhane:fx' olayı (detail: 'click' | 'crit' | 'buy' | 'stage' | 'ach' | 'offer').
 * prefers-reduced-motion: reduce iken hiçbir hareketli öğe üretilmez. */
(function () {
  'use strict';
  var mq = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null;
  function still() { return !!(mq && mq.matches); }
  var MAX_BITS = 28, live = 0, layer = null;
  var COLORS = ['var(--accent)', 'var(--accent2)', 'var(--gold)', 'var(--stage-tint)', '#ffffff'];

  function restart(node, cls, ms) {
    if (!node || still()) return;
    node.classList.remove(cls); void node.offsetWidth; node.classList.add(cls);
    clearTimeout(node['_fx_' + cls]);
    node['_fx_' + cls] = setTimeout(function () { node.classList.remove(cls); }, ms);
  }
  function getLayer() {
    if (!layer) { layer = document.createElement('div'); layer.className = 'fx-layer'; layer.setAttribute('aria-hidden', 'true'); document.body.appendChild(layer); }
    return layer;
  }
  // Konfeti: ekranın üst ortasından yelpaze; yalnız transform/opacity
  function confetti(n, originY) {
    if (still()) return;
    var L = getLayer(), W = window.innerWidth, H = window.innerHeight;
    n = Math.min(n, MAX_BITS - live);
    for (var i = 0; i < n; i++) {
      var b = document.createElement('i');
      b.className = 'fx-bit';
      var x0 = W / 2 + (Math.random() - .5) * W * .2, y0 = H * (originY || .3);
      var x1 = x0 + (Math.random() - .5) * W * .9, y1 = y0 + H * (.35 + Math.random() * .5);
      b.style.cssText = '--x0:' + x0.toFixed(0) + 'px;--y0:' + y0.toFixed(0) + 'px;--x1:' + x1.toFixed(0) + 'px;--y1:' + y1.toFixed(0) +
        'px;--r:' + (Math.random() * 720 - 360).toFixed(0) + 'deg;--t:' + (1.2 + Math.random() * .8).toFixed(2) + 's;--d:' + (Math.random() * .15).toFixed(2) +
        's;background:' + COLORS[i % COLORS.length];
      live++;
      b.addEventListener('animationend', function () { this.remove(); live--; });
      L.appendChild(b);
    }
  }

  var lastBuyTarget = null;
  document.addEventListener('pointerdown', function (e) {
    var t = e.target && e.target.closest ? e.target.closest('.gen, .upg, .tree-node') : null;
    if (t) lastBuyTarget = t;
  }, true);
  document.addEventListener('keydown', function (e) {
    var t = document.activeElement;
    if (t && t.closest && t.closest('.gen, .upg, .tree-node')) lastBuyTarget = t.closest('.gen, .upg, .tree-node');
  }, true);

  document.addEventListener('kodhane:fx', function (e) {
    var kind = e.detail;
    if (kind === 'click' || kind === 'crit') {
      restart(document.getElementById('clickBtn'), kind === 'crit' ? 'fx-crit' : 'fx-tap', kind === 'crit' ? 620 : 440);
    } else if (kind === 'buy') {
      if (lastBuyTarget && document.contains(lastBuyTarget)) restart(lastBuyTarget, 'fx-bought', 480);
      lastBuyTarget = null;
      restart(document.querySelector('#stageCard .progress'), 'fx-shine', 950);
    } else if (kind === 'ach') {
      restart(document.getElementById('achChip'), 'fx-pop', 520);
    } else if (kind === 'stage') {
      restart(document.getElementById('stageIcon'), 'fx-pop', 720);
      restart(document.querySelector('#stageCard .progress'), 'fx-shine', 950);
      var su = document.getElementById('stageUp');
      confetti(su && !su.classList.contains('hidden') ? 28 : 14, .28);
    }
  });

  // Görünüm geçişi: sekme / alt menü değişince yeni görünen panel yumuşak girer
  document.addEventListener('click', function (e) {
    var nb = e.target && e.target.closest ? e.target.closest('.tabs button, .bottom-nav button') : null;
    if (!nb || still()) return;
    requestAnimationFrame(function () {
      var tab = document.querySelector('#panelSide .tab:not(.hidden)');
      if (tab) restart(tab, 'fx-in', 260);
    });
  });
})();
