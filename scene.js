/* Kodhane ofis sahnesi (yalnız sunum) — düz, sevimli izometrik vektör.
   window.Kodhane'den yalnız OKUR (state.stage, state.gens, state.upgrades); oyun durumuna, localStorage'a ve oyun öğelerine
   yazmaz, ağ isteği yapmaz, metin eklemez. #panelEkip içinde .panel-head'den sonra tek bir kapsayıcı kurar; 1 sn'de bir imza
   (katman + görünen çalışan sayıları + tesisler + görünen geliştirmeler) karşılaştırılır, değişmedikçe hiçbir şey yapılmaz.
   Çizimler bu dosyada el yazımı SVG (<symbol>/<use>); <text>, <image>, filtre yok.
   Animasyonlar scene.css'te ve yalnız transform/opacity: boşta (yazma, kahve, kod balonu, kedi, LED, buhar), işe alım (yeni
   çalışan masasına oturur), yeni geliştirme/tesis (zıplayarak belirir), aşama geçişi (eski ofis söner, yenisi belirir).
   prefers-reduced-motion: reduce iken hiçbiri yok; sekme gizli, sahne görünmüyor ya da pencere açıkken duraklar. */
(function () {
  'use strict';
  var K = typeof window !== 'undefined' ? window.Kodhane : null;
  if (!K || typeof document === 'undefined') return;

  var OL = '#1b1f3a';                  // ince koyu kontur
  var WALL = 56, SLAB = 8;             // duvar yüksekliği, zemin dilimi kalınlığı (taban birim: karo 40x20)
  // masada çalışan türler (Kodhane.GENERATORS id'leri); yzlab = Yapay Zekâ Araştırmacısı, mars = Mars Ekibi
  var TYPES = ['stajyer', 'junior', 'senior', 'tasarimci', 'pm', 'ai', 'yzlab', 'mars'];
  var FACS = ['sunucu', 'veri', 'arge', 'cip', 'yzlab', 'mars', 'ofis'];
  var UPS = ['click_1', 'click_2', 'click_4', 'junior_6', 'cay_ocagi', 'all_1', 'all_2', 'stajyer_2', 'all_4', 'standup'];
  var SLOTS = [4, 6, 9, 12, 16];
  var GRID = [[2, 2], [3, 2], [3, 3], [4, 3], [4, 4]];   // [sütun (gx), sıra (gy)]

  // katman renkleri: duvar sağ/sol/üst kapak, zemin karo A/B, zemin dilimi sol/sağ, süpürgelik
  var ROOM = [
    { wr: '#f7e8d4', wl: '#e9d3b9', cap: '#b98f66', fa: '#dcaa72', fb: '#d09d63', sl: '#9a6a3d', sr: '#82582f', base: '#c49a6c' },
    { wr: '#eef0ff', wl: '#d9ddf7', cap: '#8e96cc', fa: '#c9cef0', fb: '#bec4ec', sl: '#6f78b3', sr: '#5c649c', base: '#aab1e0' },
    { wr: '#e8ebff', wl: '#d1d6f4', cap: '#7c85c2', fa: '#b6bfe7', fb: '#abb4e0', sl: '#5e67a3', sr: '#4d558c', base: '#9aa2d8' },
    { wr: '#e6f8f1', wl: '#cdeee2', cap: '#6fae98', fa: '#d9f0e7', fb: '#cbe8dc', sl: '#4f8c78', sr: '#3f7564', base: '#a6dcc8' },
    { wr: '#3b4374', wl: '#313862', cap: '#20264a', fa: '#4b5389', fb: '#444b7d', sl: '#252b52', sr: '#1d2245', base: '#2a3158' },
    { wr: '#4a3a5e', wl: '#3e3050', cap: '#2a2038', fa: '#8a4c45', fb: '#7e443e', sl: '#5a2d2a', sr: '#4a2422', base: '#33263f' }  // Mars
  ];

  // ---------------------------------------------------------------- izometrik yardımcılar
  function r1(n) { return Math.round(n * 10) / 10; }
  function P(gx, gy, z) { return r1((gx - gy) * 20) + ',' + r1((gx + gy) * 10 - (z || 0)); }
  function XY(gx, gy, z) { return [r1((gx - gy) * 20), r1((gx + gy) * 10 - (z || 0))]; }
  // CLIP: oda yapısı (zemin, duvar) kamera kadrajına kırpılır; kadraj dışına taşan SVG öğesi sayfa genişliğini aşmış görünmesin
  var CLIP = null;
  function clipPts(pts) {
    var v = pts.map(function (q) { return q.split(',').map(Number); }), e, k, a, b, ia, ib, out, t;
    for (e = 0; e < 4 && v.length; e++) {
      out = [];
      for (k = 0; k < v.length; k++) {
        a = v[k]; b = v[(k + 1) % v.length];
        ia = e === 0 ? a[0] >= CLIP[0] : e === 1 ? a[0] <= CLIP[2] : e === 2 ? a[1] >= CLIP[1] : a[1] <= CLIP[3];
        ib = e === 0 ? b[0] >= CLIP[0] : e === 1 ? b[0] <= CLIP[2] : e === 2 ? b[1] >= CLIP[1] : b[1] <= CLIP[3];
        if (ia) out.push(a);
        if (ia !== ib) {
          var c = CLIP[[0, 2, 1, 3][e]], ax = e < 2 ? 0 : 1;
          t = (c - a[ax]) / (b[ax] - a[ax]);
          out.push(ax === 0 ? [c, a[1] + t * (b[1] - a[1])] : [a[0] + t * (b[0] - a[0]), c]);
        }
      }
      v = out;
    }
    return v.map(function (q) { return r1(q[0]) + ',' + r1(q[1]); });
  }
  function poly(pts, fill, ex) {
    if (CLIP) { pts = clipPts(pts); if (pts.length < 3) return ''; }
    return '<polygon points="' + pts.join(' ') + '" fill="' + fill + '"' + (ex || '') + '/>';
  }
  // kutu: görünen yüzler sol-ön (gy=y1), sağ-ön (gx=x1), üst
  function box(x0, x1, y0, y1, z0, z1, top, left, right) {
    return poly([P(x0, y1, z0), P(x1, y1, z0), P(x1, y1, z1), P(x0, y1, z1)], left) +
      poly([P(x1, y0, z0), P(x1, y1, z0), P(x1, y1, z1), P(x1, y0, z1)], right) +
      poly([P(x0, y0, z1), P(x1, y0, z1), P(x1, y1, z1), P(x0, y1, z1)], top);
  }
  function sym(id, body) { return '<symbol id="' + id + '" overflow="visible">' + body + '</symbol>'; }
  function path(d, fill, ex) { return '<path d="' + d + '" fill="' + fill + '"' + (ex || '') + '/>'; }
  function circ(x, y, r, fill, ex) { return '<circle cx="' + x + '" cy="' + y + '" r="' + r + '" fill="' + fill + '"' + (ex || '') + '/>'; }
  function rect(x, y, w, h, fill, ex) { return '<rect x="' + r1(x) + '" y="' + r1(y) + '" width="' + r1(w) + '" height="' + r1(h) + '" fill="' + fill + '"' + (ex || '') + '/>'; }
  var NS = ' stroke="none"';

  // ---------------------------------------------------------------- karakterler (köken: oturduğu zemin noktası; yüz sol-aşağı)
  var CH = {
    stajyer:   { shirt: '#22d3a6', shade: '#17a582', skin: '#ffd9b8' },
    junior:    { shirt: '#7c5cff', shade: '#5f43d6', skin: '#f2c29c' },
    senior:    { shirt: '#3f6fd8', shade: '#2f55ad', skin: '#e9b48c' },
    tasarimci: { shirt: '#ff5c7a', shade: '#d9435f', skin: '#c98f68' },
    pm:        { shirt: '#ffc857', shade: '#e0a83a', skin: '#ffd2ae' },
    ai:        { shirt: '#9aa6d6', shade: '#7783b8', skin: '#b8c1e8' },
    yzlab:     { shirt: '#f7f8ff', shade: '#cfd4f2', skin: '#f0c09a' },
    mars:      { shirt: '#ff8a4c', shade: '#e06a2c', skin: '#ffd9b8' }
  };
  var TORSO = 'M-7,-10 L-6.2,-20 Q-5.5,-25 0,-25 Q5.5,-25 6.2,-20 L7,-10 Z';
  var TSHADE = 'M2.5,-24.6 Q5.5,-24.5 6.2,-20 L7,-10 L3,-10 Z';
  function face(skin) {
    return circ(8.6, -33, 2.3, skin) + circ(-0.5, -34, 9.5, skin) +
      '<ellipse cx="-5.6" cy="-33.4" rx="1.2" ry="1.7" fill="' + OL + '"' + NS + '/>' +
      '<ellipse cx="-0.6" cy="-33.7" rx="1.2" ry="1.7" fill="' + OL + '"' + NS + '/>' +
      circ(-7.6, -29.8, 1.5, '#ff8fa3', NS + ' opacity=".6"') + circ(1.6, -30, 1.4, '#ff8fa3', NS + ' opacity=".6"') +
      path('M-4.6,-29.4 Q-3.1,-27.9 -1.6,-29.4', 'none', ' stroke-width=".9"');
  }
  function human(t, before, after) {
    var c = CH[t];
    return (before || '') + path(TORSO, c.shirt) + path(TSHADE, c.shade, NS) + face(c.skin) + (after || '');
  }
  var CHAR = {
    // şapka + sırt çantası
    stajyer: human('stajyer',
      rect(4, -24, 7, 12, '#8a5a35', ' rx="2"'),
      path('M5.6,-24.2 L-4.2,-10.8', 'none', ' stroke="#8a5a35" stroke-width="2"') +
      path('M-10.2,-36 Q-9.5,-45.5 -0.5,-45 Q8.8,-44.5 9.4,-36 Z', '#ffc857') +
      path('M-10.4,-36.6 Q-14.5,-36.4 -17.5,-34.4 Q-14,-33 -9,-34.6 Z', '#e0a83a')),
    // kulaklık
    junior: human('junior', '',
      path('M-10,-35 Q-10.5,-45 -0.5,-44.5 Q9.5,-44.5 9.2,-34 Q7,-39 3,-39.5 Q-1,-37 -4,-39.5 Q-7,-38 -10,-35 Z', '#4a3426') +
      path('M-11,-34 Q-11,-47.5 -0.5,-47 Q10,-47 10,-34', 'none', ' stroke="#22d3a6" stroke-width="2.2"') +
      rect(6.6, -38, 5, 8.5, '#22d3a6', ' rx="2"') + rect(-12.8, -37, 3.2, 7, '#17a582', ' rx="1.5"')),
    // sakal + gözlük
    senior: human('senior', '',
      path('M-10,-35 Q-9,-44 -0.5,-43.6 Q8.5,-43.6 9.3,-34 Q5,-39.5 -1,-38.2 Q-6,-39.5 -10,-35 Z', '#a7adc4') +
      path('M-9.6,-31 Q-9,-23.2 -1,-23 Q6.5,-23.2 7.6,-30 Q3,-27 -1.2,-27.6 Q-6,-27 -9.6,-31 Z', '#8a8fa6') +
      circ(-5.6, -33.4, 2.6, '#ffffff', ' fill-opacity=".35" stroke-width=".9"') + circ(-0.4, -33.7, 2.6, '#ffffff', ' fill-opacity=".35" stroke-width=".9"') +
      path('M2.2,-34 L8,-35', 'none', ' stroke-width=".9"')),
    // bere + tablet
    tasarimci: human('tasarimci',
      path('M-9,-36 Q-10.5,-24 -6.5,-20 L7.5,-20 Q11,-26 10,-36 Z', '#3b2a4a'),
      path('M-10,-34 Q-8,-44 -0.5,-44 Q9,-44 9.6,-34 Q5,-39 -1,-38.5 Q-6,-37 -10,-34 Z', '#3b2a4a') +
      '<ellipse cx="-1" cy="-43.6" rx="9.6" ry="3.6" transform="rotate(-10 -1 -43.6)" fill="#7c5cff"/>' +
      circ(-1.5, -47.6, 1.2, '#7c5cff') +
      rect(4, -23.5, 9, 11.5, '#e8ebff', ' rx="1.6"') + rect(5.5, -22, 6, 8.5, '#22d3a6', NS + ' rx="1"') +
      circ(4.5, -14.5, 2, '#c98f68')),
    // kravat + pano
    pm: human('pm', '',
      path('M-1.6,-24.6 L0.4,-24.6 L1.2,-18 L-0.6,-15.4 L-2.4,-18 Z', '#ff5c7a', ' stroke-width=".8"') +
      path('M-10,-34 Q-9,-44.5 0,-44 Q9,-43.6 9.2,-34 Q5,-40.5 -2.5,-38.6 Q-7,-38 -10,-34 Z', '#5a3a22') +
      rect(4, -24, 9.5, 12.5, '#b07a45', ' rx="1.2"') + rect(5.4, -22, 6.7, 9.2, '#ffffff', NS) +
      path('M6.5,-19.5 H11 M6.5,-17 H10 M6.5,-14.5 H11', 'none', ' stroke="#7c5cff" stroke-width=".9"') +
      rect(7, -25.2, 3.6, 2.4, OL, NS + ' rx=".6"')),
    // araştırmacı: beyaz önlük, alında koruyucu gözlük
    yzlab: human('yzlab', '',
      path('M-1.8,-24.8 L0,-17 L1.8,-24.8 Z', '#22d3a6', ' stroke-width=".8"') +
      path('M-10,-34 Q-9.5,-44.5 -0.5,-44 Q9,-44 9.4,-34 Q4,-40 -1,-39.6 Q-6,-40 -10,-34 Z', '#2b2b3d') +
      rect(-10, -42.5, 19, 4.6, '#22d3a6', ' rx="2.2"') + circ(-5, -40.2, 2.6, '#bff7e6') + circ(2, -40.2, 2.6, '#bff7e6') +
      rect(4.6, -23, 4, 6, '#7c5cff', NS + ' rx="1"')),
    // Mars ekibi: turuncu uzay giysisi, cam kask
    mars: human('mars', '',
      rect(-4, -23, 8, 5, '#f7f8ff', ' rx="1.2"') + circ(0, -20.5, 1.4, '#ff5c7a', NS) +
      path('M-10,-35 Q-9,-43.5 -0.5,-43 Q8.5,-43 9.2,-35 Q4,-39.5 -1,-39 Q-6,-39.5 -10,-35 Z', '#c0603a') +
      circ(-0.5, -34, 12.6, '#bfe6ff', ' fill-opacity=".35" stroke-width="1.4"') +
      path('M-8,-41 Q-4,-45 1,-44.6', 'none', ' stroke="#ffffff" stroke-width="1.6" stroke-linecap="round" opacity=".8"') +
      rect(-9, -23, 18, 3.4, '#e8ebff', ' rx="1.4"')),
    // robot
    ai: path('M-7,-10 L-7,-22.5 Q-7,-25 -4.5,-25 L4.5,-25 Q7,-25 7,-22.5 L7,-10 Z', '#9aa6d6') +
      rect(3, -24.4, 3.6, 14.2, '#7783b8', NS) + circ(-2, -18, 2, '#22d3a6') +
      path('M-0.5,-44 V-49', 'none', ' stroke-width="1.2"') + circ(-0.5, -50, 1.9, '#ff5c7a') +
      rect(-10.5, -44, 20, 18.5, '#c9d1f2', ' rx="5.5"') + rect(4.5, -43.2, 4.2, 16.8, '#a9b3e0', NS + ' rx="3"') +
      rect(-9.5, -39, 13, 8.5, '#1d2340', ' rx="3.2"') +
      circ(-6.2, -34.8, 1.6, '#22d3a6', NS) + circ(-1, -34.8, 1.6, '#22d3a6', NS)
  };

  // ---------------------------------------------------------------- iş istasyonu parçaları (köken: masa merkezi, zemin)
  // Yerleşim: masa gy boyunca uzun; çalışan masanın -gx tarafında oturur ve +gx'e (ekranda sağ-aşağı) bakar; monitör masanın +gx
  // kenarında, çalışanın YANINDA durur. Böylece yüz hiçbir zaman kendi monitörünün ya da ön sıranın arkasında kalmaz.
  var SEAT = XY(-0.8, 0, 0);             // çalışanın oturduğu zemin noktası (masa merkezine göre)
  var CSC = 1.12;                        // karakter ölçeği (okunaklılık)
  function chair(ergo) {
    var seat = ergo ? ['#22d3a6', '#17a582', '#128a6c'] : ['#9aa2d8', '#7c85c2', '#6a72ad'];
    var s = '';
    if (ergo) s += poly([P(-1.15, -0.35, 0), P(-0.45, 0.35, 0)], 'none', ' stroke-width="2.4"') + poly([P(-1.15, 0.35, 0), P(-0.45, -0.35, 0)], 'none', ' stroke-width="2.4"');
    s += box(-0.84, -0.76, -0.04, 0.04, 0, 8, '#555d8f', '#454c7a', '#3b416b');
    s += box(-1.1, -0.5, -0.32, 0.32, 8, 10.5, seat[0], seat[1], seat[2]);
    s += box(-1.24, -1.1, -0.32, 0.32, 10.5, ergo ? 33 : 24, seat[0], seat[1], seat[2]);
    if (ergo) s += box(-1.24, -1.1, -0.2, 0.2, 33, 39, seat[0], seat[1], seat[2]);
    return s;
  }
  function desk(wood) {
    return wood ? box(-0.42, 0.42, -0.82, 0.82, 0, 12, '#f2cf9c', '#d9ab72', '#c39461')
      : box(-0.42, 0.42, -0.82, 0.82, 0, 12, '#f7f8ff', '#cfd4f2', '#b6bce4');
  }
  function monitor(gyc, hw) {
    var c = XY(0.29, gyc, 23);
    return box(0.16, 0.26, gyc - 0.05, gyc + 0.05, 12, 16, '#4b5389', '#3a4170', '#2a3158') +
      box(0.2, 0.29, gyc - hw, gyc + hw, 15, 31, '#4b5389', '#2a3158', '#3a4170') + circ(c[0], c[1], 1.7, '#7c5cff', NS);
  }
  var MON = monitor(0, 0.42);
  var MON2 = monitor(-0.42, 0.38) + monitor(0.42, 0.38);
  var KB = box(-0.34, -0.16, -0.3, 0.3, 12, 13.4, '#e8ebff', '#b6bce4', '#9aa2d8');
  var KB2 = box(-0.38, -0.1, -0.38, 0.38, 12, 15.4, '#7c5cff', '#5f43d6', '#4b35b0') +
    poly([P(-0.32, -0.32, 15.5), P(-0.32, 0.32, 15.5)], 'none', ' stroke="#22d3a6" stroke-width="1.6" stroke-dasharray="2 1.2"') +
    poly([P(-0.24, -0.32, 15.5), P(-0.24, 0.32, 15.5)], 'none', ' stroke="#ffc857" stroke-width="1.6" stroke-dasharray="2 1.2"') +
    poly([P(-0.16, -0.32, 15.5), P(-0.16, 0.32, 15.5)], 'none', ' stroke="#ff8fa3" stroke-width="1.6" stroke-dasharray="2 1.2"');
  var HANDS = (function () { var h1 = XY(-0.3, -0.13, 15), h2 = XY(-0.3, 0.13, 15);
    return '<circle cx="' + h1[0] + '" cy="' + h1[1] + '" r="2.3"/><circle cx="' + h2[0] + '" cy="' + h2[1] + '" r="2.3"/>'; })();  // dolgu <use fill> ile
  var MUG = rect(-2.4, -6, 4.8, 6, '#ffffff', ' rx="1.2"') + path('M2.4,-4.8 q2.6,0 2.6,2 q0,2 -2.6,2', 'none', ' stroke-width="1"') +
    '<ellipse cx="0" cy="-6" rx="2.4" ry="1" fill="#6b3f22" stroke-width=".8"/>';
  var CODE = path('M-9,-7 H9 Q12,-7 12,-4 V2 Q12,5 9,5 H-2 L-5,8.5 L-4.5,5 H-9 Q-12,5 -12,2 V-4 Q-12,-7 -9,-7 Z', '#ffffff') +
    path('M-4,-3.5 L-7,-1 L-4,1.5 M4,-3.5 L7,-1 L4,1.5 M1.6,-4.6 L-1.6,2.6', 'none', ' stroke="#7c5cff" stroke-width="1.7" stroke-linecap="round"');

  // ---------------------------------------------------------------- tesis / geliştirme dekorları (köken: zemin merkezi)
  var DECO = {
    sunucu: box(-0.45, 0.45, -0.35, 0.35, 0, 40, '#4b5389', '#2a3158', '#20264a') +
      poly([P(-0.38, 0.35, 30), P(0.38, 0.35, 30)], 'none', ' stroke="#4b5389" stroke-width="1"') +
      poly([P(-0.38, 0.35, 20), P(0.38, 0.35, 20)], 'none', ' stroke="#4b5389" stroke-width="1"') +
      poly([P(-0.38, 0.35, 10), P(0.38, 0.35, 10)], 'none', ' stroke="#4b5389" stroke-width="1"'),
    veri: box(-0.5, -0.04, -0.4, 0.4, 0, 46, '#3a4170', '#1d2340', '#171c33') +
      box(0.04, 0.5, -0.4, 0.4, 0, 46, '#3a4170', '#1d2340', '#171c33') +
      poly([P(-0.44, 0.4, 38), P(-0.1, 0.4, 38)], 'none', ' stroke="#22d3a6" stroke-width="1.6"') +
      poly([P(-0.44, 0.4, 26), P(-0.1, 0.4, 26)], 'none', ' stroke="#22d3a6" stroke-width="1.6"') +
      poly([P(0.1, 0.4, 38), P(0.44, 0.4, 38)], 'none', ' stroke="#7c5cff" stroke-width="1.6"') +
      poly([P(0.1, 0.4, 26), P(0.44, 0.4, 26)], 'none', ' stroke="#7c5cff" stroke-width="1.6"'),
    arge: box(-0.55, 0.55, -0.35, 0.35, 0, 13, '#ffd99a', '#e0b06a', '#c99752') +
      box(-0.35, 0.05, -0.2, 0.15, 13, 25, '#e8ebff', '#9aa2d8', '#7c85c2') +
      box(-0.28, -0.02, -0.12, 0.08, 17, 19, '#ff5c7a', '#d9435f', '#b8364f') +
      circ(XY(0.3, 0, 19)[0], XY(0.3, 0, 19)[1], 4.2, '#22d3a6') + circ(XY(0.3, 0, 19)[0], XY(0.3, 0, 19)[1], 1.6, OL, NS),
    cip: box(-0.35, 0.35, -0.35, 0.35, 0, 14, '#cfd4f2', '#9aa2d8', '#7c85c2') +
      box(-0.28, 0.28, -0.28, 0.28, 14, 17, '#2a3158', '#1d2340', '#171c33') +
      poly([P(-0.12, -0.12, 17.2), P(0.12, -0.12, 17.2), P(0.12, 0.12, 17.2), P(-0.12, 0.12, 17.2)], '#ffc857') +
      poly([P(-0.2, 0.36, 15.5), P(0.2, 0.36, 15.5)], 'none', ' stroke="#ffc857" stroke-width="1.4" stroke-dasharray="1.2 1.6"') +
      poly([P(0.36, -0.2, 15.5), P(0.36, 0.2, 15.5)], 'none', ' stroke="#ffc857" stroke-width="1.4" stroke-dasharray="1.2 1.6"'),
    yzlab: box(-0.55, 0.55, -0.3, 0.3, 0, 13, '#f7f8ff', '#cfd4f2', '#b6bce4') +
      path('M-9,-12 h3 v4 l3,7 h-9 l3,-7 Z', '#22d3a6') + path('M0,-16 h3 v6 l3.5,8 h-10 l3.5,-8 Z', '#ff5c7a') +
      path('M8,-9 h2.6 v3 l2.6,5.5 h-7.8 l2.6,-5.5 Z', '#7c5cff'),
    mars: box(-0.5, 0.5, -0.5, 0.5, 0, 4, '#9aa2d8', '#6f78b3', '#5c649c') +
      path('M-5,-46 Q0,-60 5,-46 L5.5,-14 L-5.5,-14 Z', '#f7f8ff') + path('M-5,-46 Q0,-60 5,-46 Q0,-48 -5,-46 Z', '#ff5c7a') +
      path('M-5.5,-24 L-10,-10 L-5.5,-14 Z', '#ff5c7a') + path('M5.5,-24 L10,-10 L5.5,-14 Z', '#d9435f') +
      circ(0, -36, 2.6, '#22d3a6') + path('M-3,-14 L0,-7 L3,-14 Z', '#ffc857'),
    // çay ocağı: tezgâh + iki katlı çaydanlık + ince belli çay bardakları
    cay: box(-0.5, 0.5, -0.36, 0.36, 0, 16, '#f2cf9c', '#d9ab72', '#c39461') +
      path('M-7,-18 Q-10,-30 -4.5,-32 L4.5,-32 Q10,-30 7,-18 Z', '#dfe3f5') + path('M3,-31.6 Q9.5,-30 7,-18 L3.5,-18 Z', '#b6bce4', NS) +
      path('M7,-26 L13.5,-31.5 L12,-26 Z', '#dfe3f5') + path('M-7.5,-26 Q-12,-26 -11,-21', 'none', ' stroke-width="1.6"') +
      path('M-4.6,-32 Q-6,-41 -2,-42 L2,-42 Q6,-41 4.6,-32 Z', '#ff5c7a') + path('M4.6,-32 L9,-37 L8,-33.6 Z', '#ff5c7a') + circ(0, -43.5, 1.6, '#d9435f') +
      path('M-17,-15 q-1.4,-3.4 0.5,-5 q-1.6,-1.8 -0.8,-4 h4.6 q0.8,2.2 -0.8,4 q1.9,1.6 0.5,5 Z', '#d2401d', ' stroke-width=".9"') +
      '<ellipse cx="-15" cy="-14.6" rx="3.6" ry="1.4" fill="#ffffff" stroke-width=".8"/>' +
      path('M13,-11 q-1.4,-3.4 0.5,-5 q-1.6,-1.8 -0.8,-4 h4.6 q0.8,2.2 -0.8,4 q1.9,1.6 0.5,5 Z', '#d2401d', ' stroke-width=".9"') +
      '<ellipse cx="15" cy="-10.6" rx="3.6" ry="1.4" fill="#ffffff" stroke-width=".8"/>',
    // Türk kahvesi makinesi: tezgâh + makine + fincan
    kahve: box(-0.5, 0.5, -0.36, 0.36, 0, 16, '#cfd4f2', '#9aa2d8', '#7c85c2') +
      box(-0.32, 0.18, -0.26, 0.14, 16, 38, '#ff5c7a', '#d9435f', '#b8364f') +
      box(-0.3, 0.16, -0.24, 0.12, 38, 41, '#3a4170', '#2a3158', '#20264a') +
      box(-0.16, 0.06, 0.14, 0.24, 24, 28, '#555d8f', '#454c7a', '#3b416b') +
      circ(XY(0.18, -0.06, 32)[0], XY(0.18, -0.06, 32)[1], 1.8, '#22d3a6', NS) +
      rect(4, -23, 5, 4.6, '#ffffff', ' rx="1" stroke-width=".9"') + '<ellipse cx="6.5" cy="-23" rx="2.5" ry="1" fill="#6b3f22" stroke-width=".7"/>',
    // simit tepsisi: tezgâh + üç susamlı simit
    simit: box(-0.5, 0.5, -0.36, 0.36, 0, 14, '#f2cf9c', '#d9ab72', '#c39461') +
      '<ellipse cx="0" cy="-15" rx="15" ry="7" fill="#c0c6e8"/><ellipse cx="0" cy="-16" rx="15" ry="7" fill="#e8ebff"/>' +
      '<ellipse cx="-5.5" cy="-16.5" rx="5.6" ry="3" fill="none" stroke="' + OL + '" stroke-width="4.6"/><ellipse cx="-5.5" cy="-16.5" rx="5.6" ry="3" fill="none" stroke="#c4772c" stroke-width="3"/>' +
      '<ellipse cx="5.5" cy="-15" rx="5.6" ry="3" fill="none" stroke="' + OL + '" stroke-width="4.6"/><ellipse cx="5.5" cy="-15" rx="5.6" ry="3" fill="none" stroke="#c4772c" stroke-width="3"/>' +
      '<ellipse cx="0" cy="-20" rx="5.6" ry="3" fill="none" stroke="' + OL + '" stroke-width="4.6"/><ellipse cx="0" cy="-20" rx="5.6" ry="3" fill="none" stroke="#d98a3a" stroke-width="3"/>' +
      path('M-3,-22.6 h.8 M2,-22.4 h.8 M-5,-18.6 h.8 M4.4,-18.4 h.8 M-9,-15 h.8 M9.6,-13.2 h.8 M-1,-12.6 h.8', 'none', ' stroke="#fff3d6" stroke-width="1" stroke-linecap="round"'),
    toplanti: box(-0.62, -0.42, -0.72, -0.52, 0, 9, '#ffc857', '#e0a83a', '#c48d28') +
      box(-0.05, 0.05, -0.05, 0.05, 0, 11, '#555d8f', '#454c7a', '#3b416b') +
      '<ellipse cx="0" cy="-11" rx="17" ry="8.5" fill="#b6bce4"/>' + '<ellipse cx="0" cy="-13" rx="17" ry="8.5" fill="#f7f8ff"/>' +
      box(0.42, 0.62, 0.52, 0.72, 0, 9, '#ffc857', '#e0a83a', '#c48d28') +
      rect(-6, -15.5, 5, 2.6, '#7c5cff', NS + ' rx="1" transform="skewX(-30)"') + rect(2, -14, 4, 2.2, '#22d3a6', NS + ' rx="1"'),
    minder: '<ellipse cx="-7" cy="-2" rx="8" ry="4" fill="#5f43d6"/><ellipse cx="-7" cy="-4" rx="8" ry="4" fill="#7c5cff"/>' +
      '<ellipse cx="7" cy="1" rx="8" ry="4" fill="#e0a83a"/><ellipse cx="7" cy="-1" rx="8" ry="4" fill="#ffc857"/>' +
      '<ellipse cx="1" cy="-9" rx="7" ry="3.5" fill="#17a582"/><ellipse cx="1" cy="-11" rx="7" ry="3.5" fill="#22d3a6"/>',
    bitki: box(-0.22, 0.22, -0.22, 0.22, 0, 11, '#ff8f6b', '#e0704f', '#c25a3d') +
      path('M0,-11 Q-12,-18 -7,-30 Q-1,-22 0,-11 Z', '#3fbf8f') + path('M0,-11 Q12,-16 9,-28 Q2,-22 0,-11 Z', '#2fa57a') +
      path('M0,-11 Q-3,-26 2,-36 Q5,-24 0,-11 Z', '#58d6a3')
  };
  var CAT = '<ellipse cx="0" cy="-5" rx="6.5" ry="5" fill="#ffa94d"/>' +
    path('M-8.6,-13 L-8,-19 L-5,-15 Z M-2.6,-14 L-1,-19.5 L0.6,-13.4 Z', '#ffa94d') + circ(-4.2, -11.5, 4.6, '#ffa94d') +
    path('M-1,-9 Q2,-6 1,-3 M3,-9.5 Q5,-6 4.4,-2.6', 'none', ' stroke="#e07f2a" stroke-width="1.2"') +
    circ(-6.2, -12, 0.8, OL, NS) + circ(-3, -12.2, 0.8, OL, NS);
  var TAIL = 'M5,-3 Q12,-3 10.5,-12';

  // ---------------------------------------------------------------- duvar süsleri (duvar çerçevesi: u sağa, v aşağı; v = -z)
  function windowSvg(u0, w, top, bot, kind) {
    var l = u0 + 2.5, r = u0 + w - 2.5, t = top + 2.5, b = bot - 2.5, iw = r - l, s = '';
    var sky = { home: '#9fd8ff', small: '#8fcaff', plaza: '#ffc7a1', campus: '#aee6ff', space: '#0d1230', mars: '#e0704f' }[kind];
    s += rect(u0, top, w, bot - top, kind === 'space' || kind === 'mars' ? '#8a93c9' : (kind === 'campus' ? '#e6faff' : '#ffffff'), ' rx="2"');
    s += rect(l, t, iw, b - t, sky, NS);
    if (kind === 'home') s += circ(r1(l + iw * 0.72), r1(t + 6), 3.6, '#ffc857', NS) + '<ellipse cx="' + r1(l + iw * 0.32) + '" cy="' + r1(t + 11) + '" rx="6" ry="2.4" fill="#ffffff"' + NS + '/>';
    if (kind === 'small') s += path('M' + l + ',' + b + ' Q' + r1(l + iw * 0.3) + ',' + r1(b - 12) + ' ' + r1(l + iw * 0.55) + ',' + r1(b - 5) + ' T' + r + ',' + r1(b - 7) + ' V' + b + ' Z', '#58c79b', NS) +
      '<ellipse cx="' + r1(l + iw * 0.6) + '" cy="' + r1(t + 6) + '" rx="5.5" ry="2.2" fill="#ffffff"' + NS + '/>';
    if (kind === 'plaza') {
      var hs = [10, 16, 8, 19, 12, 15, 9], bw = iw / hs.length, d = 'M' + l + ',' + b;
      for (var i = 0; i < hs.length; i++) d += ' V' + r1(b - hs[i]) + ' H' + r1(l + bw * (i + 1));
      s += path(d + ' V' + b + ' Z', '#6a5fb0', NS) + circ(r1(l + iw * 0.2), r1(t + 5), 3, '#ffe08a', NS) +
        rect(l + bw * 1.3, b - 12, 1.6, 2, '#ffe08a', NS) + rect(l + bw * 3.3, b - 15, 1.6, 2, '#ffe08a', NS) + rect(l + bw * 5.3, b - 10, 1.6, 2, '#ffe08a', NS);
    }
    if (kind === 'campus') s += rect(l, b - 5, iw, 5, '#7ed9a8', NS) + circ(r1(l + iw * 0.2), b - 8, 5, '#3fbf8f', NS) +
      circ(r1(l + iw * 0.5), b - 10, 7, '#2fa57a', NS) + circ(r1(l + iw * 0.8), b - 7, 5, '#3fbf8f', NS);
    if (kind === 'space' || kind === 'mars') {
      var st = [[0.15, 0.2], [0.4, 0.55], [0.62, 0.18], [0.85, 0.45], [0.3, 0.8], [0.75, 0.75]];
      for (var j = 0; j < st.length; j++) s += circ(r1(l + iw * st[j][0]), r1(t + (b - t) * (kind === 'mars' ? st[j][1] * 0.5 : st[j][1])), 0.8, '#ffffff', NS);
      if (kind === 'space') s += circ(r1(l + iw * 0.7), r1(t + (b - t) * 0.62), 4, '#7c5cff', NS) + circ(r1(l + iw * 0.66), r1(t + (b - t) * 0.58), 1.4, '#a48bff', NS);
      else s += path('M' + l + ',' + b + ' L' + l + ',' + r1(b - 6) + ' Q' + r1(l + iw * 0.35) + ',' + r1(b - 13) + ' ' + r1(l + iw * 0.6) + ',' + r1(b - 6) + ' T' + r + ',' + r1(b - 9) + ' V' + b + ' Z', '#9c3b2a', NS) +
        circ(r1(l + iw * 0.78), r1(t + 5), 2.6, '#ffd27a', NS);
    }
    s += path('M' + r1(u0 + w / 2) + ',' + top + ' V' + bot, 'none', ' stroke-width="1.2"');
    return s;
  }
  function whiteboard(u0) {
    return rect(u0, -47, 54, 26, '#ffffff', ' rx="2"') +
      path('M' + (u0 + 6) + ',-29 L' + (u0 + 14) + ',-34 L' + (u0 + 21) + ',-31 L' + (u0 + 30) + ',-40', 'none', ' stroke="#22d3a6" stroke-width="1.6" stroke-linecap="round"') +
      path('M' + (u0 + 6) + ',-41 H' + (u0 + 20) + ' M' + (u0 + 6) + ',-37 H' + (u0 + 15), 'none', ' stroke="#7c5cff" stroke-width="1.4" stroke-linecap="round"') +
      rect(u0 + 36, -43, 7, 7, '#ffc857', NS) + rect(u0 + 44, -39, 7, 7, '#ff8fa3', NS) + rect(u0 + 38, -33, 7, 7, '#9ff0d8', NS);
  }
  function poster(u0) {
    return rect(u0, -48, 26, 30, '#7c5cff', ' rx="2"') +
      path('M' + (u0 + 9) + ',-37 L' + (u0 + 5) + ',-33 L' + (u0 + 9) + ',-29 M' + (u0 + 17) + ',-37 L' + (u0 + 21) + ',-33 L' + (u0 + 17) + ',-29 M' + (u0 + 14.5) + ',-39 L' + (u0 + 11.5) + ',-27', 'none', ' stroke="#ffc857" stroke-width="2" stroke-linecap="round"');
  }
  function worldMap(u0) {
    var s = rect(u0, -48, 52, 24, '#bfe0ff', ' rx="2"') +
      path('M' + (u0 + 5) + ',-42 q6,-3 11,0 q2,4 -3,6 q-1,5 -4,6 q-4,-6 -4,-12 Z M' + (u0 + 22) + ',-43 q8,-2 14,1 q4,2 0,5 q-3,1 -6,0 q-1,6 -4,8 q-3,-5 -4,-14 Z M' + (u0 + 40) + ',-35 q5,-1 7,2 q-2,4 -6,2 Z', '#22d3a6', NS);
    for (var i = 0; i < 3; i++) {
      var cx = u0 + 8 + i * 18;
      s += circ(cx, -15, 5, '#ffffff') + path('M' + cx + ',-15 V-18.5 M' + cx + ',-15 L' + (cx + 1 + i) + ',-13', 'none', ' stroke-width="1"');
    }
    return s;
  }

  // ---------------------------------------------------------------- tanımlar (her kurulumda aynı; desen katmana göre)
  var DEFS_STATIC = (function () {
    var s = '';
    for (var i = 0; i < TYPES.length; i++) s += sym('ks-c-' + TYPES[i], CHAR[TYPES[i]]);
    s += sym('ks-chair', chair(false)) + sym('ks-chair2', chair(true)) + sym('ks-desk', desk(false)) + sym('ks-desk-w', desk(true)) +
      sym('ks-mon', MON) + sym('ks-mon2', MON2) + sym('ks-kb', KB) + sym('ks-kb2', KB2) + sym('ks-hands', HANDS) + sym('ks-mug', MUG) +
      sym('ks-code', CODE) + sym('ks-cat', CAT);
    for (var k in DECO) s += sym('ks-d-' + k, DECO[k]);
    return s;
  })();
  var HANDS_FILL = { stajyer: '#ffd9b8', junior: '#f2c29c', senior: '#e9b48c', tasarimci: '#c98f68', pm: '#ffd2ae', ai: '#9aa6d6', yzlab: '#f0c09a', mars: '#f7f8ff' };

  // ---------------------------------------------------------------- durum → görünüm modeli
  function tierOf(stage) { return stage <= 1 ? 0 : stage <= 3 ? 1 : stage <= 6 ? 2 : stage <= 9 ? 3 : 4; }
  function readModel() {
    var S = K.state;
    if (!S || typeof S !== 'object') return null;
    var stage = Math.max(0, Math.min(11, Math.floor(+S.stage || 0)));
    var gens = S.gens && typeof S.gens === 'object' ? S.gens : {};
    var ups = Array.isArray(S.upgrades) ? S.upgrades : [];
    var tier = tierOf(stage), slots = SLOTS[tier];
    var want = [], vis = [], i, total = 0;
    for (i = 0; i < TYPES.length; i++) {
      var n = +gens[TYPES[i]] || 0;
      want.push(n > 0 ? Math.min(4, Math.ceil(Math.log(n + 1) / Math.LN2)) : 0);
      vis.push(0);
    }
    // yuva sınırı: önce her türden 1, sonra sırayla birer birer (her tür görünsün)
    var added = true;
    while (added && total < slots) {
      added = false;
      for (i = 0; i < TYPES.length && total < slots; i++) {
        if (vis[i] < want[i]) { vis[i]++; total++; added = true; }
      }
    }
    var facs = {}, up = {};
    for (i = 0; i < FACS.length; i++) facs[FACS[i]] = (+gens[FACS[i]] || 0) > 0;
    for (i = 0; i < UPS.length; i++) up[UPS[i]] = ups.indexOf(UPS[i]) !== -1;
    var sig = tier + (stage >= 11 ? 'm' : '') + '|' + vis.join(',') + '|' +
      FACS.map(function (f) { return facs[f] ? 1 : 0; }).join('') + '|' + UPS.map(function (u) { return up[u] ? 1 : 0; }).join('');
    return { tier: tier, mars: stage >= 11, vis: vis, facs: facs, up: up, sig: sig };
  }
  // Masa ataması: aynı katmanda önceki atama korunur (yeni gelen boş masaya oturur, kimse yer değiştirmez); katman değişince
  // ya da ilk kurulumda türler sırayla dağıtılır.
  function assignSeats(m, prevSeats) {
    var slots = SLOTS[m.tier], seats = [], i, t, cnt = {};
    if (prevSeats && prevSeats.length === slots) {
      seats = prevSeats.slice();
      for (i = 0; i < slots; i++) if (seats[i]) cnt[seats[i]] = (cnt[seats[i]] || 0) + 1;
      for (t = 0; t < TYPES.length; t++) {
        var id = TYPES[t];
        for (i = slots - 1; i >= 0 && (cnt[id] || 0) > m.vis[t]; i--) if (seats[i] === id) { seats[i] = null; cnt[id]--; }
      }
      for (t = 0; t < TYPES.length; t++) {
        for (i = 0; i < slots && (cnt[TYPES[t]] || 0) < m.vis[t]; i++) if (!seats[i]) { seats[i] = TYPES[t]; cnt[TYPES[t]] = (cnt[TYPES[t]] || 0) + 1; }
      }
      return seats;
    }
    var left = m.vis.slice(), more = true;
    while (more) {
      more = false;
      for (t = 0; t < TYPES.length; t++) if (left[t] > 0) { seats.push(TYPES[t]); left[t]--; more = true; }
    }
    while (seats.length < slots) seats.push(null);
    return seats;
  }
  function decoList(m) {
    var d = [];
    ['sunucu', 'veri', 'arge', 'cip', 'yzlab', 'mars'].forEach(function (f) { if (m.facs[f]) d.push(f); });
    if (m.up.all_4) d.push('toplanti');
    if (m.up.standup) d.push('minder');
    return d;
  }

  // ---------------------------------------------------------------- sahne kurulumu
  function useEl(id, x, y, ex) {
    return '<use href="#' + id + '"' + (x || y ? ' x="' + r1(x) + '" y="' + r1(y) + '"' : '') + (ex || '') + '/>';
  }
  function delay(sec) { return ' style="animation-delay:-' + (Math.round(sec * 100) / 100) + 's"'; }
  var layerNo = 0;
  function wait(sec) { return ' style="animation-delay:' + (Math.round(sec * 100) / 100) + 's"'; }

  // o: { mobile, enter: {koltuk: gecikme}, pop: {dekor: 1}, poof: {koltuk: 1} }
  function build(m, seats, o) {
    CLIP = null;
    var tier = m.tier, pal = ROOM[m.mars ? 5 : tier], cols = GRID[tier][0], rows = GRID[tier][1];
    var DXs = 2.0, DYs = 2.0, GX0 = 2.75, GY0 = 2.45;
    var A = GX0 + (cols - 1) * DXs + 0.42 + 1.0, B = GY0 + (rows - 1) * DYs + 0.82 + 0.9;
    // kamera: oda kutusu; telefonda masa kümesine yakınlaşır (oda kenarları kırpılır)
    var room = [-(B + 0.25) * 20 - 4, -WALL - 9, (A + 0.25) * 20 + 4, (A + B) * 10 + SLAB + 6];
    var FW = 400, FH = o.mobile ? 285 : 252, asp = FW / FH;
    // odak: masa kümesi (+ duvarın üst kısmı); telefonda kenar payı dar, masaüstünde duvar tamamen görünür
    var cx0 = GX0 - 1.3, cx1 = GX0 + (cols - 1) * DXs + 0.5, cy0 = GY0 - 0.9, cy1 = GY0 + (rows - 1) * DYs + 0.9;
    var pts = [XY(cx0, cy1, 0), XY(cx1, cy0, 0), XY(cx1, cy1, 0), XY(cx0, cy0, 74)], mg = o.mobile ? 6 : 12;
    var fx0 = Math.min(pts[0][0], pts[1][0]) - mg, fx1 = Math.max(pts[0][0], pts[1][0]) + mg;
    if (m.up.cay_ocagi || m.up.all_1 || m.up.stajyer_2 || m.up.all_2) fx1 = Math.max(fx1, XY(A, 0.2, 0)[0] - 2);
    var fy0 = Math.min(pts[3][1], o.mobile ? -WALL * 0.55 : -WALL - 3), fy1 = pts[2][1] + (o.mobile ? 6 : 12);
    var fw = fx1 - fx0, fh = fy1 - fy0, mx = (fx0 + fx1) / 2, my = (fy0 + fy1) / 2;
    if (fw / fh < asp) fw = fh * asp; else fh = fw / asp;
    var rw = room[2] - room[0], rh = room[3] - room[1];
    if (fw > rw && fh > rh) { mx = (room[0] + room[2]) / 2; my = (room[1] + room[3]) / 2; }
    fx0 = mx - fw / 2; fy0 = my - fh / 2;
    if (fw <= rw) fx0 = Math.max(room[0], Math.min(fx0, room[2] - fw));
    if (fh <= rh) fy0 = Math.max(room[1], Math.min(fy0, room[3] - fh));
    var vb = [r1(fx0), r1(fy0), r1(fw), r1(fh)];
    var s = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="' + vb.join(' ') + '" width="' + FW + '" height="' + FH + '" preserveAspectRatio="xMidYMid meet" focusable="false">';
    var tile = 'ks-tile-' + (++layerNo);   // katman başına tekil id (geçişte iki katman aynı anda DOM'da)
    s += '<defs>' +
      '<pattern id="' + tile + '" patternUnits="userSpaceOnUse" width="2" height="2" patternTransform="matrix(20 10 -20 10 0 0)">' +
      '<rect width="2" height="2" fill="' + pal.fa + '"/><rect width="1" height="1" fill="' + pal.fb + '"/><rect x="1" y="1" width="1" height="1" fill="' + pal.fb + '"/></pattern></defs>';
    s += '<rect x="' + vb[0] + '" y="' + vb[1] + '" width="' + vb[2] + '" height="' + vb[3] + '" fill="#171c33"/>';
    s += '<ellipse cx="' + r1((A - B) * 10) + '" cy="' + r1((A + B) * 10 + SLAB) + '" rx="' + r1((A + B) * 20 * 0.42) + '" ry="14" fill="#0c0f22" opacity=".55"/>';
    s += '<g stroke="' + OL + '" stroke-width="1.2" stroke-linejoin="round">';

    // zemin dilimi + zemin (kadraja kırpılı; kırpma kenarındaki çizgi kadrajın 3 birim dışında kalır)
    CLIP = [fx0 - 3, fy0 - 3, fx0 + fw + 3, fy0 + fh + 3];
    s += poly([P(-0.25, B, 0), P(A, B, 0), P(A, B, -SLAB), P(-0.25, B, -SLAB)], pal.sl);
    s += poly([P(A, -0.25, 0), P(A, B, 0), P(A, B, -SLAB), P(A, -0.25, -SLAB)], pal.sr);
    s += poly([P(0, 0, 0), P(A, 0, 0), P(A, B, 0), P(0, B, 0)], 'url(#' + tile + ')');
    // duvarlar (iç yüzler) + kalınlık kapakları + uç yüzler + süpürgelik
    s += poly([P(0, 0, 0), P(A, 0, 0), P(A, 0, WALL), P(0, 0, WALL)], pal.wr);
    s += poly([P(0, 0, 0), P(0, B, 0), P(0, B, WALL), P(0, 0, WALL)], pal.wl);
    s += poly([P(0, 0, 0), P(A, 0, 0), P(A, 0, 4), P(0, 0, 4)], pal.base, NS) + poly([P(0, 0, 0), P(0, B, 0), P(0, B, 4), P(0, 0, 4)], pal.base, NS);
    s += poly([P(-0.25, -0.25, WALL), P(A, -0.25, WALL), P(A, 0, WALL), P(0, 0, WALL), P(0, B, WALL), P(-0.25, B, WALL)], pal.cap);
    s += poly([P(A, -0.25, -SLAB), P(A, 0, -SLAB), P(A, 0, WALL), P(A, -0.25, WALL)], pal.sr);
    s += poly([P(-0.25, B, -SLAB), P(0, B, -SLAB), P(0, B, WALL), P(-0.25, B, WALL)], pal.sl);
    CLIP = null;

    // mutfak tezgâhı sağ duvarın ön ucunda (sıraların arkasında değil, görünür yerde): çay ocağı, kahve makinesi, simit
    var kitchen = [];
    if (m.up.cay_ocagi) kitchen.push('cay');
    if (m.up.all_1) kitchen.push('kahve');
    if (m.up.stajyer_2) kitchen.push('simit');
    var kEnd = A - 0.62;
    // sağ duvar: pencereler (tezgâhın üstü boş kalır)
    var kind = m.mars ? 'mars' : ['home', 'small', 'plaza', 'campus', 'space'][tier];
    var nWin = [1, 2, 2, 3, 3][tier], wW = [44, 46, 54, 52, 50][tier], LR = A * 20, LL = B * 20, wins = '';
    var wEnd = kitchen.length ? (kEnd - kitchen.length + 0.4) * 20 : LR;
    nWin = Math.max(1, Math.min(nWin, Math.floor((wEnd - 8) / (wW + 6))));
    for (var i = 0; i < nWin; i++) {
      var uc = 8 + (wEnd - 16) * (i + 0.5) / nWin;
      wins += tier === 3 ? windowSvg(uc - wW / 2, wW, -51, -12, kind) : windowSvg(uc - wW / 2, wW, -47, -19, kind);
    }
    s += '<g transform="matrix(1 .5 0 1 0 0)">' + wins + '</g>';
    // sol duvar: pano / harita+saatler
    var lw = m.facs.ofis ? worldMap(LL * 0.55 - 26) : (tier === 0 ? poster(LL * 0.55 - 13) : whiteboard(LL * 0.55 - 27));
    if (tier >= 3 && !m.facs.ofis) lw += windowSvg(LL * 0.2 - 18, 36, -47, -19, kind);
    var xy = XY(0, B, 0);
    s += '<g transform="matrix(1 -.5 0 1 ' + xy[0] + ' ' + xy[1] + ')">' + lw + '</g>';

    // derinlik sıralı zemin öğeleri
    var items = [];
    function add(gx, gy, svg) { items.push({ d: gx + gy, svg: svg }); }
    function popWrap(key, svg) { return o.pop[key] ? '<g class="sc-pop">' + svg + '</g>' : svg; }

    kitchen.forEach(function (k, j) {
      var p = [kEnd - j, 0.72], c = XY(p[0], p[1], 0), out = useEl('ks-d-' + k, c[0], c[1]);
      if (k === 'cay') out += '<g class="sc-steam"' + delay(0.7) + '>' + path('M' + r1(c[0] + 11) + ',' + r1(c[1] - 34) + ' q-2,-3 0,-6 q2,-3 0,-6', 'none', ' stroke="#ffffff" stroke-width="1.4" stroke-linecap="round" opacity=".85"') + '</g>';
      if (k === 'kahve') out += '<g class="sc-steam"' + delay(1.9) + '>' + path('M' + r1(c[0] + 6.5) + ',' + r1(c[1] - 25) + ' q-1.6,-2.4 0,-4.8 q1.6,-2.4 0,-4.8', 'none', ' stroke="#ffffff" stroke-width="1.2" stroke-linecap="round" opacity=".85"') + '</g>';
      add(p[0], p[1], popWrap(k, out));
    });

    // duvar boyu yuvaları: sağ duvar (gy≈0.75), sol duvar (gx≈0.75); mutfak dolu yuvaları atlanır
    var right = [], left = [], g;
    for (g = 1.3; g + 0.6 <= (kitchen.length ? kEnd - kitchen.length + 0.3 : A - 0.2); g += 1.35) right.push([g, 0.75]);
    for (g = 1.1; g + 0.6 <= B - 0.2; g += 1.35) left.push([0.75, g]);
    var ledNo = 0;
    decoList(m).forEach(function (k) {
      var p = left.shift() || right.shift();
      if (!p) return;
      var c = XY(p[0], p[1], 0), out = useEl('ks-d-' + k, c[0], c[1]);
      if (k === 'sunucu') {
        for (var L = 0; L < 3; L++) {
          var q = XY(p[0] + 0.45, p[1] - 0.2 + L * 0.2, 35 - L * 10);
          out += circ(q[0], q[1], 1.5, L === 1 ? '#ffc857' : '#22d3a6', NS + ' class="sc-led"' + delay(ledNo++ * 0.53));
        }
      }
      add(p[0], p[1], popWrap(k, out));
    });
    var nPlants = [1, 1, 2, 3, 2][tier];
    for (i = 0; i < nPlants; i++) {
      var pp = (i % 2 ? left : right).pop() || left.pop() || right.pop();
      if (pp) { var pc = XY(pp[0], pp[1], 0); add(pp[0], pp[1], useEl('ks-d-bitki', pc[0], pc[1])); }
    }

    // iş istasyonları
    var wood = tier === 0;
    for (var sIdx = 0; sIdx < SLOTS[tier]; sIdx++) {
      var col = sIdx % cols, row = Math.floor(sIdx / cols);
      var gx = GX0 + col * DXs, gy = GY0 + row * DYs, w = XY(gx, gy, 0), t = seats[sIdx];
      var ws = '<g transform="translate(' + w[0] + ',' + w[1] + ')">' + useEl(m.up.click_2 ? 'ks-chair2' : 'ks-chair');
      if (t) {
        var who = '<g class="sc-bob"' + delay(sIdx * 0.71 % 2.6) + '><use href="#ks-c-' + t + '" transform="translate(' + r1(SEAT[0] + 1) + ',' + r1(SEAT[1] + 1) + ') scale(-' + CSC + ',' + CSC + ')"/></g>';
        ws += o.enter[sIdx] !== undefined ? '<g class="sc-enter"' + wait(o.enter[sIdx]) + '>' + who + '</g>' : who;
      }
      ws += useEl(wood ? 'ks-desk-w' : 'ks-desk') + useEl(m.up.click_1 ? 'ks-kb2' : 'ks-kb');
      if (t) ws += '<g class="sc-hands"' + delay(sIdx * 0.23 % 0.5) + '>' + useEl('ks-hands', 0, 0, ' fill="' + HANDS_FILL[t] + '"') + '</g>';
      ws += useEl((m.up.click_4 || (t === 'junior' && m.up.junior_6)) ? 'ks-mon2' : 'ks-mon');
      if (t && sIdx % 3 === 1) ws += '<g class="sc-sip"' + delay(sIdx * 1.3 % 7) + '>' + useEl('ks-mug', XY(-0.12, 0.6, 12)[0], XY(-0.12, 0.6, 12)[1]) + '</g>';
      if (t && sIdx % 3 === 0) ws += '<g class="sc-code"' + delay(sIdx * 1.7 % 6) + '>' + useEl('ks-code', SEAT[0] + 12, SEAT[1] - 64) + '</g>';
      if (o.poof[sIdx]) ws += '<circle class="sc-poof" cx="' + r1(SEAT[0]) + '" cy="' + r1(SEAT[1] - 26) + '" r="16" fill="none" stroke="#ffc857" stroke-width="2.4"' + wait(o.enter[sIdx] || 0) + '/>';
      add(gx, gy, ws + '</g>');
    }

    // ofis kedisi (kuyruk gerçek öğe: döner)
    if (m.up.all_2) {
      var kx = A - 0.55, ky = Math.min(B - 0.6, GY0 + 0.2), cxy = XY(kx, ky, 0);
      add(kx, ky, popWrap('kedi', '<g transform="translate(' + cxy[0] + ',' + cxy[1] + ')"><g class="sc-tail">' +
        path(TAIL, 'none', ' stroke-width="4.4" stroke-linecap="round"') + path(TAIL, 'none', ' stroke="#ffa94d" stroke-width="2.4" stroke-linecap="round"') +
        '</g>' + useEl('ks-cat') + '</g>'));
    }

    items.sort(function (a, b) { return a.d - b.d; });
    for (i = 0; i < items.length; i++) s += items[i].svg;
    return s + '</g></svg>';
  }

  // ---------------------------------------------------------------- kurulum, güncelleme, duraklatma, geçişler
  var panel = document.getElementById('panelEkip');
  if (!panel) return;
  var head = panel.querySelector('.panel-head'), list = document.getElementById('genList');
  var el = document.createElement('div');
  el.id = 'officeScene';
  el.className = 'office-scene';
  el.setAttribute('aria-hidden', 'true');
  try {
    if (head && head.parentNode === panel) panel.insertBefore(el, head.nextSibling);
    else if (list && list.parentNode === panel) panel.insertBefore(el, list);
    else panel.insertBefore(el, panel.firstChild);
    // ortak semboller tek kopya: katmanlar yalnız <use> ile başvurur
    el.innerHTML = '<svg class="sc-defs" width="0" height="0" focusable="false"><defs>' + DEFS_STATIC + '</defs></svg>';
  } catch (e) { return; }

  var mqMobile = window.matchMedia ? window.matchMedia('(max-width: 767px)') : null;
  var mqStill = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null;
  function isMobile() { return !!(mqMobile && mqMobile.matches); }
  function still() { return !!(mqStill && mqStill.matches); }
  var bootAt = Date.now();                   // açılışta kayıt yüklenirken oluşan ilk değişim animasyonsuz çizilir
  var last = null, inView = true;            // last: { sig, tier, mars, seats, deco, up, mobile }
  var BLOCKERS = ['modal', 'accountPanel', 'stageUp'];
  function blocked() {
    for (var i = 0; i < BLOCKERS.length; i++) {
      var b = document.getElementById(BLOCKERS[i]);
      if (b && !b.classList.contains('hidden')) return true;
    }
    return false;
  }
  function updatePaused() {
    try { el.classList.toggle('paused', !!(document.hidden || !inView || blocked())); } catch (e) { /* sessiz */ }
  }
  function render(m) {
    // telefon/masaüstü eşiği geçilince yalnız kamera değişir: koltuklar korunur, animasyon oynamaz
    var mobile = isMobile(), sameRoom = !!last && last.tier === m.tier && last.mars === m.mars;
    var seats = assignSeats(m, sameRoom ? last.seats : null);
    var deco = decoList(m), o = { mobile: mobile, enter: {}, pop: {}, poof: {} }, i, anim = !!last && !still() && last.mobile === mobile && Date.now() - bootAt > 2500;
    var roomChange = anim && !sameRoom;
    if (anim && sameRoom) {
      // yeni işe alınan: önceki atamada boş olan ya da başka türün oturduğu masa
      var n = 0;
      for (i = 0; i < seats.length; i++) if (seats[i] && seats[i] !== last.seats[i]) { o.enter[i] = n * 0.12; o.poof[i] = 1; n++; }
      deco.forEach(function (k) { if (last.deco.indexOf(k) === -1) o.pop[k] = 1; });
      ['cay_ocagi:cay', 'all_1:kahve', 'stajyer_2:simit', 'all_2:kedi'].forEach(function (pair) {
        var a = pair.split(':'); if (m.up[a[0]] && !last.up[a[0]]) o.pop[a[1]] = 1;
      });
    } else if (roomChange) {
      // aşama geçişi: eski ofis büyüyüp söner, yeni ofis belirir, çalışanlar sırayla masalarına oturur
      for (i = 0; i < seats.length; i++) if (seats[i]) o.enter[i] = 0.45 + i * 0.06;
    }
    var html = '<div class="sc-layer' + (roomChange ? ' sc-in' : '') + '">' + build(m, seats, o) + '</div>';
    var olds = el.querySelectorAll('.sc-layer');
    if (roomChange && olds.length) {
      for (i = 0; i < olds.length - 1; i++) olds[i].parentNode.removeChild(olds[i]);
      var old = olds[olds.length - 1];
      old.classList.remove('sc-in'); old.classList.add('sc-out');
      // animasyon biter ya da iptal olursa (reduced-motion açıldı, sahne gizlendi) eski katman kaldırılır
      var drop = function (e) { if (e.target === old && e.animationName === 'scOut' && old.parentNode) old.parentNode.removeChild(old); };
      old.addEventListener('animationend', drop);
      old.addEventListener('animationcancel', drop);
      el.insertAdjacentHTML('beforeend', html);
    } else {
      for (i = 0; i < olds.length; i++) olds[i].parentNode.removeChild(olds[i]);
      el.insertAdjacentHTML('beforeend', html);
    }
    last = { sig: m.sig, tier: m.tier, mars: m.mars, seats: seats, deco: deco, up: m.up, mobile: mobile };
  }
  function dropOld() {
    var outs = el.querySelectorAll('.sc-layer.sc-out');
    for (var i = 0; i < outs.length; i++) outs[i].parentNode.removeChild(outs[i]);
  }
  function tick() {
    try {
      updatePaused();
      if (document.hidden) return;
      var m = readModel();
      if (!m || (last && m.sig === last.sig && last.mobile === isMobile())) return;
      render(m);
    } catch (e) { /* sahne yalnız süs; oyunu asla bozmaz */ }
  }

  try {
    document.addEventListener('visibilitychange', tick);
    if (mqMobile && mqMobile.addEventListener) mqMobile.addEventListener('change', tick);
    if (mqStill && mqStill.addEventListener) mqStill.addEventListener('change', function () { if (still()) dropOld(); });
    if (typeof IntersectionObserver === 'function') {
      new IntersectionObserver(function (en) {
        if (en.length) inView = en[en.length - 1].isIntersecting;
        updatePaused();
      }).observe(el);
    }
    if (typeof MutationObserver === 'function') {
      var mo = new MutationObserver(updatePaused);
      BLOCKERS.forEach(function (id) {
        var b = document.getElementById(id);
        if (b) mo.observe(b, { attributes: true, attributeFilter: ['class'] });
      });
    }
  } catch (e) { /* sessiz */ }
  tick();
  setInterval(tick, 1000);
})();
