/* Kodhane: Ajans Tycoon — v1
 * Vanilla JS, derleme adımı yok. Tüm oyun metinleri Türkçe.
 */
(function (root) {
  'use strict';

  // ------------------------------------------------------------------
  // Tanımlar (denge değerleri)
  // ------------------------------------------------------------------
  var SAVE_KEY = 'kodhane_ajans_save_v1';
  var COST_GROWTH = 1.15;
  var OFFLINE_CAP_SEC = 8 * 3600;
  var AUTOSAVE_MS = 10000;
  var BASE_CLICK = 1;

  var GENERATORS = [
    { id: 'stajyer',  name: 'Stajyer',               icon: '🧑‍🎓', base: 15,        tps: 0.2,   desc: 'Kahve getirir, bazen de kod yazar.' },
    { id: 'junior',   name: 'Junior Geliştirici',    icon: '👩‍💻', base: 100,       tps: 1,     desc: 'Stack Overflow’un en sadık ziyaretçisi.' },
    { id: 'senior',   name: 'Senior Geliştirici',    icon: '🧔',   base: 1100,      tps: 8,     desc: '“Bende çalışıyordu” der, haklıdır.' },
    { id: 'tasarimci',name: 'Tasarımcı',             icon: '🎨',   base: 12000,     tps: 47,    desc: 'Logoyu biraz daha büyütür.' },
    { id: 'pm',       name: 'Proje Yöneticisi',      icon: '📋',   base: 130000,    tps: 260,   desc: 'Toplantıları toplantıyla planlar.' },
    { id: 'ai',       name: 'Yapay Zekâ Kod Ajanı',  icon: '🤖',   base: 1400000,   tps: 1400,  desc: 'Gece gündüz yorulmadan commit atar.' },
    { id: 'sunucu',   name: 'Sunucu Odası',          icon: '🖥️',   base: 20000000,  tps: 7800,  desc: 'Uğultusu para sesi gibidir.' },
    { id: 'ofis',     name: 'Yurt Dışı Ofis',        icon: '🌍',   base: 330000000, tps: 44000, desc: 'Güneş hiç batmayan ajans.' }
  ];

  // Her çalışan için 4 kademe geliştirme: [eşik, maliyet çarpanı]
  var GEN_TIERS = [[1, 10], [10, 75], [25, 750], [50, 7500]];
  var GEN_UPG_NAMES = {
    stajyer:  [['Staj Sertifikası', '📜'], ['Bedava Simit', '🥯'], ['Mentorluk Programı', '🧭'], ['Kadro Sözü', '🤝']],
    junior:   [['Mekanik Klavye Paketi', '⌨️'], ['Code Review Kültürü', '🔍'], ['Eğitim Bütçesi', '📚'], ['Hackathon Haftası', '🏆']],
    senior:   [['Sessiz Oda', '🎧'], ['Mimari Toplantısı', '🏛️'], ['Teknik Borç Günü', '🧹'], ['Kıdemli Maaş Paketi', '💼']],
    tasarimci:[['Çizim Tableti', '🖊️'], ['Tasarım Sistemi', '🧩'], ['Renk Paleti Kütüphanesi', '🌈'], ['Ödüllü Portfolyo', '🥇']],
    pm:       [['Kanban Panosu', '🗂️'], ['Çevik Sertifika', '🏃'], ['Toplantısız Cuma', '🚫'], ['Yol Haritası Ustası', '🗺️']],
    ai:       [['Daha Büyük Bağlam Penceresi', '🧠'], ['İnce Ayarlı Model', '🎛️'], ['Ajan Sürüsü', '🐝'], ['Kendini Test Eden Kod', '✅']],
    sunucu:   [['Sıvı Soğutma', '💧'], ['Otomatik Ölçekleme', '📈'], ['Yeşil Enerji', '🌱'], ['Kendi Veri Merkezin', '🏗️']],
    ofis:     [['Berlin Şubesi', '🥨'], ['Dubai Şubesi', '🏙️'], ['Tokyo Şubesi', '🗼'], ['New York Genel Merkezi', '🗽']]
  };

  var UPGRADES = [];
  GENERATORS.forEach(function (g) {
    GEN_TIERS.forEach(function (t, i) {
      var nm = GEN_UPG_NAMES[g.id][i];
      UPGRADES.push({
        id: g.id + '_' + (i + 1), name: nm[0], icon: nm[1], cost: g.base * t[1],
        type: 'gen', target: g.id, mult: 2, req: { gen: g.id, count: t[0] },
        desc: g.name + ' üretimi x2'
      });
    });
  });
  // Tıklama geliştirmeleri (toplam çalışan sayısına göre açılır)
  [
    { id: 'click_1', name: 'Mekanik Klavye', icon: '⌨️', cost: 100, req: { total: 1 }, click: 2, desc: 'Tık başına kazanç x2' },
    { id: 'click_2', name: 'Ergonomik Sandalye', icon: '🪑', cost: 1000, req: { total: 10 }, click: 2, desc: 'Tık başına kazanç x2' },
    { id: 'click_3', name: 'Klavye Kısayolu Ustası', icon: '⚡', cost: 20000, req: { total: 25 }, clickPct: 0.01, desc: 'Her tık, saniyelik üretimin %1’ini de kazandırır' },
    { id: 'click_4', name: 'Çift Monitör', icon: '🖥️', cost: 500000, req: { total: 50 }, click: 3, desc: 'Tık başına kazanç x3' },
    { id: 'click_5', name: 'Otomatik Tamamlama', icon: '✨', cost: 50000000, req: { total: 100 }, clickPct: 0.02, desc: 'Her tık, saniyelik üretimin %2’sini daha kazandırır' },
    { id: 'click_6', name: 'On Kat Mühendis', icon: '🦸', cost: 5000000000, req: { total: 200 }, clickPct: 0.03, desc: 'Her tık, saniyelik üretimin %3’ünü daha kazandırır' }
  ].forEach(function (u) { u.type = 'click'; UPGRADES.push(u); });
  // Genel üretim geliştirmeleri
  [
    { id: 'all_1', name: 'Türk Kahvesi Makinesi', icon: '☕', cost: 25000, req: { total: 15 }, all: 1.1, desc: 'Tüm üretim +%10' },
    { id: 'all_2', name: 'Ofis Kedisi', icon: '🐈', cost: 5000000, req: { total: 75 }, all: 1.15, desc: 'Tüm üretim +%15. Moral tavan.' },
    { id: 'all_3', name: 'Hibrit Çalışma Modeli', icon: '🏡', cost: 500000000, req: { total: 150 }, all: 1.25, desc: 'Tüm üretim +%25' },
    { id: 'all_4', name: 'Halka Arz Hazırlığı', icon: '📊', cost: 100000000000, req: { total: 250 }, all: 1.5, desc: 'Tüm üretim +%50' }
  ].forEach(function (u) { u.type = 'all'; UPGRADES.push(u); });
  var UPG_BY_ID = {};
  UPGRADES.forEach(function (u) { UPG_BY_ID[u.id] = u; });

  var STAGES = [
    { name: 'Freelancer',     icon: '🏠', at: 0,           desc: 'Evde bir laptop ve bolca çay.' },
    { name: 'Ev Ofisi',       icon: '🛋️', at: 1000,        desc: 'Salonun köşesi artık resmen ofis.' },
    { name: 'Butik Stüdyo',   icon: '🏢', at: 50000,       desc: 'Küçük ama tatlı bir ekip, ilk kurumsal müşteriler.' },
    { name: 'Ajans',          icon: '🚀', at: 1000000,     desc: 'Kendi binan, kendi tabelan.' },
    { name: 'Dev Ajans',      icon: '🏙️', at: 50000000,    desc: 'Plaza katları, yüzlerce proje.' },
    { name: 'Global Holding', icon: '🌐', at: 2500000000,  desc: 'Kıtalar arası bir teknoloji devi.' }
  ];
  var STAGE_BONUS = 0.10; // her aşama +%10 üretim ve tıklama
  var PRESTIGE_UNIT = 1e8; // hisse = floor(sqrt(turKazancı / 1e8))
  var SHARE_BONUS = 0.10;

  // ------------------------------------------------------------------
  // Sayı biçimlendirme (Türkçe)
  // ------------------------------------------------------------------
  var SUFFIXES = ['', 'Bin', 'Mn', 'Mr', 'Tn', 'Kat', 'Kent', 'Sek', 'Sep', 'Okt', 'Non', 'Des'];
  function groupTR(intStr) { return intStr.replace(/\B(?=(\d{3})+(?!\d))/g, '.'); }
  function fixedTR(n, d) {
    var s = n.toFixed(d);
    var parts = s.split('.');
    var out = groupTR(parts[0]);
    if (parts[1] && /[1-9]/.test(parts[1])) out += ',' + parts[1].replace(/0+$/, '');
    return out;
  }
  function fmt(n) {
    if (!isFinite(n)) return '∞';
    if (n < 0) return '-' + fmt(-n);
    if (n < 1000) return fixedTR(n, n < 10 ? 1 : 0);
    var k = Math.floor(Math.log10(n) / 3);
    if (k >= SUFFIXES.length) return n.toExponential(2).replace('.', ',');
    var v = n / Math.pow(1000, k);
    if (v >= 999.995) { k++; v = v / 1000; if (k >= SUFFIXES.length) return n.toExponential(2).replace('.', ','); }
    return fixedTR(v, 2) + ' ' + SUFFIXES[k];
  }
  function tl(n) { return fmt(n) + ' TL'; }
  function fmtTime(sec) {
    sec = Math.floor(sec);
    var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
    var out = [];
    if (h) out.push(h + ' sa');
    if (m || h) out.push(m + ' dk');
    out.push(s + ' sn');
    return out.join(' ');
  }

  // ------------------------------------------------------------------
  // Durum
  // ------------------------------------------------------------------
  function newState() {
    var gens = {};
    GENERATORS.forEach(function (g) { gens[g.id] = 0; });
    var now = Date.now();
    return {
      version: 1, money: 0, runEarned: 0, totalEarned: 0, clicks: 0, clickEarned: 0,
      playTime: 0, startedAt: now, lastSaved: now, gens: gens, upgrades: [],
      shares: 0, prestigeCount: 0, boostLeft: 0, eventsClicked: 0, offlineEarned: 0, stage: 0
    };
  }
  var S = newState();

  function has(id) { return S.upgrades.indexOf(id) !== -1; }
  function totalOwned() { var t = 0; for (var k in S.gens) t += S.gens[k]; return t; }
  function stageIndex(earned) {
    var i = 0;
    for (var j = 0; j < STAGES.length; j++) if (earned >= STAGES[j].at) i = j;
    return i;
  }
  function globalMult() {
    var m = 1 + STAGE_BONUS * stageIndex(S.runEarned);
    m *= 1 + SHARE_BONUS * S.shares;
    S.upgrades.forEach(function (id) { var u = UPG_BY_ID[id]; if (u && u.type === 'all') m *= u.all; });
    return m;
  }
  function boostMult() { return S.boostLeft > 0 ? 2 : 1; }
  function genMult(id) {
    var m = 1;
    S.upgrades.forEach(function (uid) { var u = UPG_BY_ID[uid]; if (u && u.type === 'gen' && u.target === id) m *= u.mult; });
    return m;
  }
  function genTps(g) { return g.tps * genMult(g.id) * globalMult(); }
  function baseTps() { // takviyesiz
    var t = 0;
    GENERATORS.forEach(function (g) { t += S.gens[g.id] * genTps(g); });
    return t;
  }
  function tps() { return baseTps() * boostMult(); }
  function clickValue() {
    var mult = 1, pct = 0;
    S.upgrades.forEach(function (id) {
      var u = UPG_BY_ID[id];
      if (u && u.type === 'click') { if (u.click) mult *= u.click; if (u.clickPct) pct += u.clickPct; }
    });
    var stageShare = (1 + STAGE_BONUS * stageIndex(S.runEarned)) * (1 + SHARE_BONUS * S.shares);
    return (BASE_CLICK * mult * stageShare + pct * baseTps()) * boostMult();
  }
  function genCost(g, n) {
    n = n || 1;
    var first = g.base * Math.pow(COST_GROWTH, S.gens[g.id]);
    return first * (Math.pow(COST_GROWTH, n) - 1) / (COST_GROWTH - 1);
  }
  function maxAffordable(g) {
    var first = g.base * Math.pow(COST_GROWTH, S.gens[g.id]);
    if (S.money < first) return 0;
    return Math.floor(Math.log(S.money * (COST_GROWTH - 1) / first + 1) / Math.log(COST_GROWTH));
  }
  function upgradeUnlocked(u) {
    if (u.req.gen) return S.gens[u.req.gen] >= u.req.count;
    if (u.req.total) return totalOwned() >= u.req.total;
    return true;
  }
  function availableUpgrades() {
    return UPGRADES.filter(function (u) { return !has(u.id) && upgradeUnlocked(u); })
      .sort(function (a, b) { return a.cost - b.cost; });
  }
  function earn(x) { S.money += x; S.runEarned += x; S.totalEarned += x; }

  // Eylemler
  function doClick() {
    var v = clickValue();
    earn(v); S.clicks++; S.clickEarned += v;
    return v;
  }
  function buyGen(id, n) {
    var g = GENERATORS.filter(function (x) { return x.id === id; })[0];
    if (!g) return false;
    if (n === 'max') n = maxAffordable(g);
    n = n || 1;
    if (n < 1) return false;
    var c = genCost(g, n);
    if (S.money + 1e-9 < c) return false;
    S.money -= c; S.gens[id] += n;
    return true;
  }
  function buyUpgrade(id) {
    var u = UPG_BY_ID[id];
    if (!u || has(id) || !upgradeUnlocked(u) || S.money < u.cost) return false;
    S.money -= u.cost; S.upgrades.push(id);
    return true;
  }
  function sharesGain() { return Math.floor(Math.sqrt(S.runEarned / PRESTIGE_UNIT)); }
  function nextShareAt() { var n = sharesGain() + 1; return n * n * PRESTIGE_UNIT; }
  function doPrestige() {
    var gain = sharesGain();
    if (gain < 1) return 0;
    var keep = { shares: S.shares + gain, prestigeCount: S.prestigeCount + 1, totalEarned: S.totalEarned,
      clicks: S.clicks, clickEarned: S.clickEarned, playTime: S.playTime, startedAt: S.startedAt,
      eventsClicked: S.eventsClicked, offlineEarned: S.offlineEarned };
    S = newState();
    for (var k in keep) S[k] = keep[k];
    return gain;
  }
  // Simülasyon/ilerleme
  function tick(dt) {
    if (dt <= 0) return;
    var boostPart = Math.min(dt, S.boostLeft);
    var b = baseTps();
    earn(b * dt + b * boostPart); // takviye süresi boyunca x2
    S.boostLeft = Math.max(0, S.boostLeft - dt);
    S.playTime += dt;
  }

  // Kayıt
  function serialize() { S.lastSaved = Date.now(); return JSON.stringify(S); }
  function deserialize(str) {
    var d = JSON.parse(str);
    var base = newState();
    for (var k in base) if (d[k] !== undefined) base[k] = d[k];
    GENERATORS.forEach(function (g) { base.gens[g.id] = (d.gens && d.gens[g.id]) || 0; });
    base.upgrades = (d.upgrades || []).filter(function (id) { return UPG_BY_ID[id]; });
    ['money', 'runEarned', 'totalEarned', 'playTime'].forEach(function (k) { if (!isFinite(base[k])) base[k] = 0; });
    S = base;
    return S;
  }
  function applyOffline(now) {
    var elapsed = Math.max(0, ((now || Date.now()) - S.lastSaved) / 1000);
    var sec = Math.min(elapsed, OFFLINE_CAP_SEC);
    var gain = baseTps() * sec;
    if (gain > 0) { earn(gain); S.offlineEarned += gain; }
    return { elapsed: elapsed, sec: sec, gain: gain, capped: elapsed > OFFLINE_CAP_SEC };
  }

  var Core = {
    GENERATORS: GENERATORS, UPGRADES: UPGRADES, STAGES: STAGES, fmt: fmt, tl: tl, fmtTime: fmtTime,
    get state() { return S; }, set state(v) { S = v; }, newState: newState,
    tps: tps, baseTps: baseTps, clickValue: clickValue, genCost: genCost, genTps: genTps, maxAffordable: maxAffordable,
    availableUpgrades: availableUpgrades, buyGen: buyGen, buyUpgrade: buyUpgrade, doClick: doClick, tick: tick,
    stageIndex: stageIndex, totalOwned: totalOwned, sharesGain: sharesGain, doPrestige: doPrestige,
    serialize: serialize, deserialize: deserialize, applyOffline: applyOffline, earn: earn, has: has
  };

  if (typeof module !== 'undefined' && module.exports) { module.exports = Core; }
  if (typeof document === 'undefined') return;

  // ------------------------------------------------------------------
  // Arayüz
  // ------------------------------------------------------------------
  var $ = function (id) { return document.getElementById(id); };
  var el = {};
  var buyQty = 1;
  var resetting = false;
  var genRows = {};
  var upgSig = '';
  var lastStageShown = 0;

  function toast(msg, ms) {
    var t = el.toast;
    t.textContent = msg; t.classList.remove('hidden');
    clearTimeout(toast._t);
    toast._t = setTimeout(function () { t.classList.add('hidden'); }, ms || 2600);
  }
  function modal(opts) {
    el.modalEmoji.textContent = opts.emoji || '💬';
    el.modalTitle.textContent = opts.title;
    el.modalText.innerHTML = opts.html;
    el.modalActions.innerHTML = '';
    (opts.buttons || [{ label: 'Tamam', cls: 'primary' }]).forEach(function (b) {
      var btn = document.createElement('button');
      btn.className = 'btn ' + (b.cls || '');
      btn.textContent = b.label;
      btn.addEventListener('click', function () { closeModal(); if (b.onClick) b.onClick(); });
      el.modalActions.appendChild(btn);
    });
    el.modal.classList.remove('hidden');
  }
  function closeModal() { el.modal.classList.add('hidden'); }

  function save() {
    if (resetting) return;
    try { localStorage.setItem(SAVE_KEY, serialize()); } catch (e) { /* kota vb. */ }
  }
  function load() {
    var raw = null;
    try { raw = localStorage.getItem(SAVE_KEY); } catch (e) {}
    if (!raw) return null;
    try { deserialize(raw); } catch (e) { S = newState(); return null; }
    return applyOffline(Date.now());
  }

  function buildGenList() {
    el.genList.innerHTML = '';
    GENERATORS.forEach(function (g) {
      var b = document.createElement('button');
      b.className = 'gen';
      b.dataset.gen = g.id;
      b.innerHTML = '<div class="gen-icon">' + g.icon + '</div>' +
        '<div><div class="gen-name"></div><div class="gen-sub"></div></div>' +
        '<div class="gen-right"><div class="gen-owned">0</div><div class="gen-cost"></div></div>';
      b.addEventListener('click', function () {
        if (buyGen(g.id, buyQty)) { renderAll(); }
      });
      el.genList.appendChild(b);
      genRows[g.id] = { btn: b, name: b.querySelector('.gen-name'), sub: b.querySelector('.gen-sub'),
        owned: b.querySelector('.gen-owned'), cost: b.querySelector('.gen-cost') };
    });
  }
  function renderGens() {
    var revealedNext = false;
    GENERATORS.forEach(function (g, i) {
      var r = genRows[g.id];
      var owned = S.gens[g.id];
      var revealed = owned > 0 || i === 0 || S.gens[GENERATORS[i - 1].id] > 0 || S.runEarned >= g.base;
      if (!revealed) {
        if (revealedNext) { r.btn.classList.add('hidden'); return; }
        revealedNext = true;
        r.btn.classList.remove('hidden');
        r.btn.classList.add('locked'); r.btn.disabled = true;
        r.name.textContent = '???';
        r.sub.textContent = 'Bir önceki pozisyona birini işe al';
        r.owned.textContent = '';
        r.cost.textContent = tl(g.base);
        return;
      }
      r.btn.classList.remove('hidden', 'locked');
      var n = buyQty === 'max' ? Math.max(1, maxAffordable(g)) : buyQty;
      var cost = genCost(g, n);
      var afford = S.money >= cost;
      r.btn.disabled = !afford;
      r.btn.classList.toggle('affordable', afford);
      r.name.textContent = g.name + (n > 1 ? '  ×' + n : '');
      var each = genTps(g);
      r.sub.textContent = '+' + fmt(each) + ' TL/sn her biri' + (owned ? ' · toplam ' + fmt(each * owned) + ' TL/sn' : ' · ' + g.desc);
      r.owned.textContent = owned;
      r.cost.textContent = tl(cost);
    });
  }
  function renderUpgrades() {
    var list = availableUpgrades();
    var sig = list.map(function (u) { return u.id; }).join(',') + '|' + S.upgrades.length;
    if (sig !== upgSig) {
      upgSig = sig;
      el.upgList.innerHTML = '';
      if (!list.length) {
        el.upgList.innerHTML = '<div class="empty">Şu an alınabilecek geliştirme yok. Daha fazla çalışan işe aldıkça yenileri açılır.</div>';
      }
      list.forEach(function (u) {
        var b = document.createElement('button');
        b.className = 'upg'; b.dataset.upg = u.id;
        b.innerHTML = '<div class="upg-icon">' + u.icon + '</div><div><div class="upg-name"></div><div class="upg-desc"></div></div><div class="upg-cost"></div>';
        b.querySelector('.upg-name').textContent = u.name;
        b.querySelector('.upg-desc').textContent = u.desc;
        b.querySelector('.upg-cost').textContent = tl(u.cost);
        b.addEventListener('click', function () {
          if (buyUpgrade(u.id)) { toast(u.icon + ' ' + u.name + ' alındı!'); renderAll(); }
        });
        el.upgList.appendChild(b);
      });
      if (S.upgrades.length) {
        var d = document.createElement('div');
        d.className = 'owned-upgs';
        d.innerHTML = 'Sahip olunan geliştirmeler (' + S.upgrades.length + '): ';
        S.upgrades.forEach(function (id) {
          var s = document.createElement('span'); s.textContent = UPG_BY_ID[id].icon; s.title = UPG_BY_ID[id].name; d.appendChild(s);
        });
        el.upgList.appendChild(d);
      }
    }
    var affordableCount = 0;
    Array.prototype.forEach.call(el.upgList.querySelectorAll('.upg'), function (b) {
      var u = UPG_BY_ID[b.dataset.upg];
      var ok = S.money >= u.cost;
      if (ok) affordableCount++;
      b.disabled = !ok; b.classList.toggle('affordable', ok);
    });
    el.upgBadge.textContent = affordableCount;
    el.upgBadge.classList.toggle('hidden', affordableCount === 0);
  }
  function renderStage() {
    var i = stageIndex(S.runEarned);
    var st = STAGES[i];
    el.stageIcon.textContent = st.icon;
    el.stageName.textContent = st.name;
    el.stageDesc.textContent = st.desc;
    el.stageBonus.textContent = '+%' + Math.round(i * STAGE_BONUS * 100) + ' üretim';
    var nx = STAGES[i + 1];
    if (nx) {
      var p = (S.runEarned - st.at) / (nx.at - st.at);
      el.stageProgress.style.width = Math.min(100, Math.max(0, p * 100)).toFixed(1) + '%';
      el.stageNext.textContent = 'Sonraki aşama: ' + nx.icon + ' ' + nx.name + ' — ' + tl(S.runEarned) + ' / ' + tl(nx.at) + ' toplam kazanç';
    } else {
      el.stageProgress.style.width = '100%';
      el.stageNext.textContent = 'Zirvedesin! Yatırım Turu ile daha da büyüyebilirsin.';
    }
    if (i > lastStageShown) {
      lastStageShown = i;
      if (i > S.stage) {
        S.stage = i;
        el.stageCard.classList.remove('levelup'); void el.stageCard.offsetWidth; el.stageCard.classList.add('levelup');
        toast('🎉 Tebrikler! Şirketin büyüdü: ' + st.icon + ' ' + st.name + ' (+%' + Math.round(i * STAGE_BONUS * 100) + ' üretim)', 4000);
      }
    }
  }
  function renderStats() {
    var rows = [
      ['Mevcut para', tl(S.money)],
      ['Saniyelik üretim', tl(tps()) + '/sn'],
      ['Tık başına', tl(clickValue())],
      ['Bu turdaki kazanç', tl(S.runEarned)],
      ['Toplam kazanç (tüm zamanlar)', tl(S.totalEarned)],
      ['Toplam tıklama', fmt(S.clicks)],
      ['Tıklamayla kazanılan', tl(S.clickEarned)],
      ['Toplam çalışan', fmt(totalOwned())],
      ['Alınan geliştirme', S.upgrades.length + ' / ' + UPGRADES.length],
      ['Tamamlanan müşteri projesi', fmt(S.eventsClicked)],
      ['Çevrimdışı kazanç', tl(S.offlineEarned)],
      ['Oynama süresi', fmtTime(S.playTime)],
      ['Yatırım turu sayısı', fmt(S.prestigeCount)]
    ];
    var html = rows.map(function (r) { return '<div><dt>' + r[0] + '</dt><dd>' + r[1] + '</dd></div>'; }).join('');
    if (el.statsList._html !== html) { el.statsList.innerHTML = html; el.statsList._html = html; }
  }
  function renderPrestige() {
    el.prShares.textContent = fmt(S.shares);
    el.prBonus.textContent = '+%' + fmt(S.shares * SHARE_BONUS * 100);
    var g = sharesGain();
    el.prGain.textContent = fmt(g) + ' hisse';
    el.prNext.textContent = tl(nextShareAt()) + ' tur kazancı';
    el.prestigeBtn.disabled = g < 1;
  }
  function renderTop() {
    el.money.textContent = tl(S.money);
    el.rate.textContent = tl(tps()) + '/sn';
    el.clickValue.textContent = '+' + tl(clickValue());
    if (S.boostLeft > 0) {
      el.boostBar.classList.remove('hidden');
      el.boostBar.textContent = '🔥 Acil teslim modu: tüm kazanç x2 — ' + Math.ceil(S.boostLeft) + ' sn';
    } else el.boostBar.classList.add('hidden');
  }
  var activeTab = 'upgrades';
  function renderAll() {
    renderTop(); renderStage(); renderGens(); renderUpgrades();
    if (activeTab === 'stats') renderStats();
    if (activeTab === 'prestige') renderPrestige();
  }

  function floater(text, x, y) {
    var f = document.createElement('div');
    f.className = 'floater'; f.textContent = text;
    f.style.left = x + 'px'; f.style.top = y + 'px';
    el.floaters.appendChild(f);
    setTimeout(function () { f.remove(); }, 900);
  }

  // Müşteri projesi etkinliği
  var offer = { visible: false, until: 0, nextAt: 0, kind: null, amount: 0 };
  function scheduleOffer(first) {
    var min = first ? 45 : 60, max = first ? 90 : 180;
    offer.nextAt = Date.now() + (min + Math.random() * (max - min)) * 1000;
  }
  var OFFER_TEXTS = [
    'Bir e-ticaret sitesi acil yenileme istiyor',
    'Yerel bir kafe mobil uygulama istiyor',
    'Bir belediye web portalı ihalesi',
    'Bir girişim MVP’sini 1 haftada istiyor',
    'Bir otel zinciri rezervasyon sistemi istiyor',
    'Bir lojistik firması takip paneli istiyor'
  ];
  function spawnOffer(kind) {
    offer.visible = true;
    offer.until = Date.now() + 10000;
    offer.kind = kind || (Math.random() < 0.65 ? 'cash' : 'boost');
    var t = OFFER_TEXTS[Math.floor(Math.random() * OFFER_TEXTS.length)];
    if (offer.kind === 'cash') {
      offer.amount = Math.max(clickValue() * 40, baseTps() * (60 + Math.random() * 60), 50);
      el.coText.textContent = t + ' — ' + tl(offer.amount) + ' ödeme!';
    } else {
      el.coText.textContent = t + ' — 30 sn boyunca tüm kazanç x2!';
    }
    var w = window.innerWidth, h = window.innerHeight;
    var bw = Math.min(290, w - 24);
    el.clientOffer.style.left = Math.round(12 + Math.random() * Math.max(0, w - bw - 24)) + 'px';
    el.clientOffer.style.top = Math.round(80 + Math.random() * Math.max(0, h - 200)) + 'px';
    el.clientOffer.classList.remove('hidden');
  }
  function hideOffer() { offer.visible = false; el.clientOffer.classList.add('hidden'); scheduleOffer(false); }
  function claimOffer() {
    if (!offer.visible) return;
    S.eventsClicked++;
    if (offer.kind === 'cash') { earn(offer.amount); toast('📨 Proje teslim edildi! +' + tl(offer.amount)); }
    else { S.boostLeft = 30; toast('🔥 Acil teslim modu! 30 sn boyunca tüm kazanç x2'); }
    hideOffer(); renderAll();
  }
  function updateOffer() {
    var now = Date.now();
    if (offer.visible) {
      var left = offer.until - now;
      el.coTimerFill.style.width = Math.max(0, left / 100) + '%';
      if (left <= 0) hideOffer();
    } else if (now >= offer.nextAt && el.modal.classList.contains('hidden')) {
      spawnOffer();
    }
  }

  function showWelcomeBack(res) {
    if (!res || res.elapsed < 60 || res.gain <= 0) return;
    modal({
      emoji: '👋', title: 'Tekrar hoş geldin!',
      html: 'Sen yokken ekibin <b>' + fmtTime(res.sec) + '</b> boyunca çalıştı ve <b>' + tl(res.gain) + '</b> kazandı.' +
        (res.capped ? '<br><small>Çevrimdışı kazanç en fazla 8 saat için hesaplanır.</small>' : ''),
      buttons: [{ label: 'Harika, devam!', cls: 'primary' }]
    });
  }

  function init() {
    ['money', 'rate', 'stageCard', 'stageIcon', 'stageName', 'stageDesc', 'stageBonus', 'stageProgress', 'stageNext',
      'boostBar', 'clickBtn', 'clickValue', 'floaters', 'genList', 'upgList', 'upgBadge', 'statsList', 'saveBtn',
      'resetBtn', 'saveNote', 'prShares', 'prBonus', 'prGain', 'prNext', 'prestigeBtn', 'clientOffer', 'coText',
      'coTimerFill', 'toast', 'modal', 'modalEmoji', 'modalTitle', 'modalText', 'modalActions'
    ].forEach(function (id) { el[id] = $(id); });

    var offlineRes = load();
    lastStageShown = stageIndex(S.runEarned);
    S.stage = Math.max(S.stage, lastStageShown);
    buildGenList();

    el.clickBtn.addEventListener('click', function (e) {
      var v = doClick();
      var rect = el.floaters.getBoundingClientRect();
      var x = (e.clientX || rect.left + rect.width / 2) - rect.left + (Math.random() * 30 - 15);
      var y = (e.clientY || rect.top + rect.height / 2) - rect.top - 20;
      floater('+' + tl(v), x, y);
      renderTop(); renderStage();
    });
    document.querySelectorAll('.qty button').forEach(function (b) {
      b.addEventListener('click', function () {
        document.querySelectorAll('.qty button').forEach(function (x) { x.classList.remove('active'); });
        b.classList.add('active');
        buyQty = b.dataset.qty === 'max' ? 'max' : parseInt(b.dataset.qty, 10);
        renderGens();
      });
    });
    document.querySelectorAll('.tabs button').forEach(function (b) {
      b.addEventListener('click', function () {
        document.querySelectorAll('.tabs button').forEach(function (x) { x.classList.remove('active'); });
        b.classList.add('active');
        activeTab = b.dataset.tab;
        document.querySelectorAll('.tab').forEach(function (t) { t.classList.add('hidden'); });
        $('tab-' + activeTab).classList.remove('hidden');
        renderAll();
      });
    });
    el.clientOffer.addEventListener('click', claimOffer);
    el.saveBtn.addEventListener('click', function () { save(); toast('💾 Oyun kaydedildi'); });
    el.resetBtn.addEventListener('click', function () {
      modal({
        emoji: '⚠️', title: 'Kaydı sıfırla?',
        html: 'Tüm ilerlemen, çalışanların, geliştirmelerin ve yatırımcı hisselerin <b>kalıcı olarak silinecek</b>. Bu işlem geri alınamaz.',
        buttons: [
          { label: 'Vazgeç', cls: 'ghost' },
          { label: 'Evet, sıfırla', cls: 'danger', onClick: function () {
            resetting = true;
            try { localStorage.removeItem(SAVE_KEY); } catch (e) {}
            location.reload();
          } }
        ]
      });
    });
    el.prestigeBtn.addEventListener('click', function () {
      var g = sharesGain();
      if (g < 1) return;
      modal({
        emoji: '💰', title: 'Yatırım turuna çık?',
        html: 'Yatırımcılar şirketine <b>' + fmt(g) + ' hisse</b> karşılığında yatırım yapacak. Paran, çalışanların ve geliştirmelerin sıfırlanır; karşılığında tüm kazançlara kalıcı <b>+%' + fmt(g * SHARE_BONUS * 100) + '</b> bonus alırsın.',
        buttons: [
          { label: 'Vazgeç', cls: 'ghost' },
          { label: 'Anlaştık!', cls: 'primary', onClick: function () {
            doPrestige(); lastStageShown = 0; upgSig = ''; save(); renderAll();
            toast('🚀 Yatırım turu tamamlandı! Yeni bir başlangıç.');
          } }
        ]
      });
    });

    window.addEventListener('beforeunload', save);
    window.addEventListener('pagehide', save);
    document.addEventListener('visibilitychange', function () { if (document.hidden) save(); });

    var last = Date.now();
    setInterval(function () {
      var now = Date.now();
      var dt = Math.min((now - last) / 1000, OFFLINE_CAP_SEC);
      last = now;
      tick(dt);
      updateOffer();
      renderAll();
    }, 100);
    setInterval(save, AUTOSAVE_MS);

    scheduleOffer(true);
    renderAll();
    showWelcomeBack(offlineRes);
    save();
  }

  // Test ve hata ayıklama için
  root.Kodhane = Core;
  Core.save = save; Core.load = load; Core.renderAll = renderAll; Core.spawnOffer = spawnOffer; Core.claimOffer = claimOffer;
  Core.SAVE_KEY = SAVE_KEY;

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})(typeof window !== 'undefined' ? window : this);
