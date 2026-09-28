/* Kodhane: Ajans Tycoon — v3
 * Vanilla JS, derleme adımı yok. Tüm oyun metinleri Türkçe.
 * v1 kayıtları ('kodhane_ajans_save_v1') ilk açılışta otomatik olarak v2 biçimine taşınır.
 * Bulut kaydı (isteğe bağlı giriş) cloud.js içindedir; oyun onsuz da tam çalışır.
 */
(function (root) {
  'use strict';

  // ------------------------------------------------------------------
  // Tanımlar (denge değerleri)
  // ------------------------------------------------------------------
  var VERSION = '3.0.0';
  var SAVE_KEY = 'kodhane_ajans_save_v2';
  var LEGACY_KEYS = ['kodhane_ajans_save_v1'];
  var SETTINGS_KEY = 'kodhane_ayarlar_v1';
  var COST_GROWTH = 1.15;
  var OFFLINE_CAP_SEC = 8 * 3600;
  var AUTOSAVE_MS = 10000;
  var BASE_CLICK = 1;
  var CRIT_CHANCE = 0.05;
  var CRIT_MULT = 10;
  var ACH_BONUS = 0.01;        // her başarım kalıcı +%1 üretim
  var REP_MAX = 100;
  var REP_OFFER_BONUS = 0.01;  // her itibar puanı müşteri projesi ödemelerine +%1

  var GENERATORS = [
    { id: 'stajyer',  name: 'Stajyer',               icon: '🧑‍🎓', base: 15,        tps: 0.2,   desc: 'Kahve getirir, bazen de kod yazar.' },
    { id: 'junior',   name: 'Junior Geliştirici',    icon: '👩‍💻', base: 100,       tps: 1,     desc: 'Soru-cevap sitelerinin en sadık ziyaretçisi.' },
    { id: 'senior',   name: 'Senior Geliştirici',    icon: '🧔',   base: 1100,      tps: 8,     desc: '“Bende çalışıyordu” der, haklıdır.' },
    { id: 'tasarimci',name: 'Tasarımcı',             icon: '🎨',   base: 12000,     tps: 47,    desc: 'Logoyu biraz daha büyütür.' },
    { id: 'pm',       name: 'Proje Yöneticisi',      icon: '📋',   base: 130000,    tps: 260,   desc: 'Toplantıları toplantıyla planlar.' },
    { id: 'ai',       name: 'Yapay Zekâ Kod Ajanı',  icon: '🤖',   base: 1400000,   tps: 1400,  desc: 'Gece gündüz yorulmadan commit atar.' },
    { id: 'sunucu',   name: 'Sunucu Odası',          icon: '🖥️',   base: 20000000,  tps: 7800,  desc: 'Uğultusu para sesi gibidir.' },
    { id: 'ofis',     name: 'Yurt Dışı Ofis',        icon: '🌍',   base: 330000000, tps: 44000, desc: 'Güneş hiç batmayan ajans.' }
  ];
  var DEV_IDS = ['stajyer', 'junior', 'senior', 'ai'];

  // Her çalışan için 5 kademe geliştirme: [eşik, maliyet çarpanı]
  var GEN_TIERS = [[1, 10], [10, 75], [25, 750], [50, 7500], [100, 75000]];
  var GEN_UPG_NAMES = {
    stajyer:  [['Staj Sertifikası', '📜'], ['Bedava Simit', '🥯'], ['Mentorluk Programı', '🧭'], ['Kadro Sözü', '🤝'], ['Staj Efsanesi', '🌟']],
    junior:   [['Mekanik Klavye Paketi', '⌨️'], ['Code Review Kültürü', '🔍'], ['Eğitim Bütçesi', '📚'], ['Hackathon Haftası', '🏆'], ['Kendi Framework’ü', '🧪']],
    senior:   [['Sessiz Oda', '🎧'], ['Mimari Toplantısı', '🏛️'], ['Teknik Borç Günü', '🧹'], ['Kıdemli Maaş Paketi', '💼'], ['Emekliliği Unuttu', '🦉']],
    tasarimci:[['Çizim Tableti', '🖊️'], ['Tasarım Sistemi', '🧩'], ['Renk Paleti Kütüphanesi', '🌈'], ['Ödüllü Portfolyo', '🥇'], ['Piksel Mükemmeliyeti', '🔬']],
    pm:       [['Kanban Panosu', '🗂️'], ['Çevik Sertifika', '🏃'], ['Toplantısız Cuma', '🚫'], ['Yol Haritası Ustası', '🗺️'], ['Gantt Şeması Sanatı', '📐']],
    ai:       [['Daha Büyük Bağlam Penceresi', '🧠'], ['İnce Ayarlı Model', '🎛️'], ['Ajan Sürüsü', '🐝'], ['Kendini Test Eden Kod', '✅'], ['Tekillik Toplantısı', '🌀']],
    sunucu:   [['Sıvı Soğutma', '💧'], ['Otomatik Ölçekleme', '📈'], ['Yeşil Enerji', '🌱'], ['Kendi Veri Merkezin', '🏗️'], ['Kuantum Rafı', '⚛️']],
    ofis:     [['Berlin Şubesi', '🥨'], ['Dubai Şubesi', '🏙️'], ['Tokyo Şubesi', '🗼'], ['New York Genel Merkezi', '🗽'], ['Ay Üssü Şubesi', '🌙']]
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
    { id: 'cay_ocagi', name: 'Çay Ocağı Sözleşmesi', icon: '🫖', cost: 5000, req: { total: 8 }, all: 1.05, desc: 'Tüm üretim +%5. Demlik hiç soğumaz.' },
    { id: 'all_1', name: 'Türk Kahvesi Makinesi', icon: '☕', cost: 25000, req: { total: 15 }, all: 1.1, desc: 'Tüm üretim +%10' },
    { id: 'all_2', name: 'Ofis Kedisi', icon: '🐈', cost: 5000000, req: { total: 75 }, all: 1.15, desc: 'Tüm üretim +%15. Moral tavan.' },
    { id: 'all_3', name: 'Hibrit Çalışma Modeli', icon: '🏡', cost: 500000000, req: { total: 150 }, all: 1.25, desc: 'Tüm üretim +%25' },
    { id: 'all_4', name: 'Halka Arz Hazırlığı', icon: '📊', cost: 100000000000, req: { total: 250 }, all: 1.5, desc: 'Tüm üretim +%50' }
  ].forEach(function (u) { u.type = 'all'; UPGRADES.push(u); });
  // Olay kartlarını etkileyen geliştirmeler
  [
    { id: 'kahve_fali', name: 'Kahve Falı Yol Haritası', icon: '🔮', cost: 30000, req: { total: 20 }, desc: 'Bir sonraki olay kartını önceden gösterir' },
    { id: 'push_dua', name: 'Push ve Dua', icon: '🙏', cost: 60000, req: { total: 25 }, desc: 'Cuma akşamı deploy olayında başarı ihtimali +%10' },
    { id: 'standup', name: 'Oturarak Stand-up', icon: '🧘', cost: 150000, req: { total: 30 }, desc: 'Toplantı kaynaklı verim cezaları %20 daha hafif' },
    { id: 'deploy_yasak', name: 'Cuma Deploy Yasağı', icon: '📵', cost: 400000, req: { total: 40 }, desc: 'Cuma akşamı deploy olayı artık çıkmaz' },
    { id: 'tercuman', name: 'Müşteri Tercümanı', icon: '🗣️', cost: 750000, req: { total: 45 }, desc: 'Revize ve olumsuz olayların süresi -%25' }
  ].forEach(function (u) { u.type = 'perk'; UPGRADES.push(u); });
  UPGRADES.push({ id: 'sprint', name: 'Sprint Planlaması', icon: '📆', cost: 650000, req: { gen: 'pm', count: 5 }, type: 'devs', mult: 1.1,
    desc: 'Proje Yöneticileri koordine eder: tüm geliştiriciler (Stajyer, Junior, Senior, Yapay Zekâ) +%10' });
  var UPG_BY_ID = {};
  UPGRADES.forEach(function (u) { UPG_BY_ID[u.id] = u; });

  var STAGES = [
    { name: 'Freelancer',     icon: '🏠', at: 0,          desc: 'Evde bir laptop ve bolca çay.', msg: '' },
    { name: 'Ev Ofisi',       icon: '🛋️', at: 1000,       desc: 'Salonun köşesi artık resmen ofis.', msg: 'Tebrikler! Pijamayla toplantıya girmek artık resmen şirket kültürü.' },
    { name: 'Butik Stüdyo',   icon: '🏢', at: 50000,      desc: 'Küçük ama tatlı bir ekip, ilk kurumsal müşteriler.', msg: 'Kapıda adınız yazıyor. Müşteri artık ‘ekibiniz kaç kişi?’ diye sormaya çekinmiyor.' },
    { name: 'Ajans',          icon: '🚀', at: 1000000,    desc: 'Kendi binan, kendi tabelan.', msg: 'Artık ‘biz’ diyorsunuz ve bunu gerçekten ciddi söylüyorsunuz.' },
    { name: 'Dev Ajans',      icon: '🏙️', at: 50000000,   desc: 'Plaza katları, yüzlerce proje.', msg: 'Toplantı odalarına gezegen adı koyma zamanı geldi.' },
    { name: 'Global Holding', icon: '🌐', at: 2500000000, desc: 'Kıtalar arası bir teknoloji devi.', msg: 'Tebrikler! Artık logoyu büyütmeyi siz istiyorsunuz.' }
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
  function fmtSec(s) { return Math.round(s) + ' sn'; }
  function pct(x) { return Math.round(x * 100); }

  // ------------------------------------------------------------------
  // Durum
  // ------------------------------------------------------------------
  function newDaily() {
    return { date: null, tasks: [], streak: 0, best: 0, lastComplete: null, allDone: false, daysCompleted: 0 };
  }
  function newState() {
    var gens = {};
    GENERATORS.forEach(function (g) { gens[g.id] = 0; });
    var now = Date.now();
    return {
      version: 2, money: 0, runEarned: 0, totalEarned: 0, clicks: 0, clickEarned: 0,
      playTime: 0, startedAt: now, lastSaved: now, gens: gens, upgrades: [],
      shares: 0, prestigeCount: 0, boostLeft: 0, eventsClicked: 0, offlineEarned: 0, stage: 0,
      buffs: [], achievements: [], critClicks: 0, eventsResolved: 0, logoAccepted: 0, revisions: 0,
      meetings: 0, serverCrashes: 0, reputation: 0, noMeetingSec: 0, daily: newDaily()
    };
  }
  var S = newState();
  var queue = []; // arayüze giden bildirimler (başarım, görev, seri)
  function notify(type, data) { queue.push({ type: type, data: data }); if (queue.length > 50) queue.shift(); }
  function rnd() { return Core.rng(); }
  function chance(p) { return rnd() < p; }

  function has(id) { return S.upgrades.indexOf(id) !== -1; }
  function totalOwned() { var t = 0; for (var k in S.gens) t += S.gens[k]; return t; }
  function stageIndex(earned) {
    var i = 0;
    for (var j = 0; j < STAGES.length; j++) if (earned >= STAGES[j].at) i = j;
    return i;
  }
  function achMult() { return 1 + ACH_BONUS * S.achievements.length; }
  function globalMult() {
    var m = 1 + STAGE_BONUS * stageIndex(S.runEarned);
    m *= 1 + SHARE_BONUS * S.shares;
    m *= achMult();
    S.upgrades.forEach(function (id) { var u = UPG_BY_ID[id]; if (u && u.type === 'all') m *= u.all; });
    return m;
  }
  function boostMult() { return S.boostLeft > 0 ? 2 : 1; }
  function buffMult(kind) {
    var m = 1;
    S.buffs.forEach(function (b) { if (b.kind === kind) m *= b.mult; });
    return m;
  }
  function genMult(id) {
    var m = 1;
    S.upgrades.forEach(function (uid) {
      var u = UPG_BY_ID[uid];
      if (!u) return;
      if (u.type === 'gen' && u.target === id) m *= u.mult;
      if (u.type === 'devs' && DEV_IDS.indexOf(id) !== -1) m *= u.mult;
    });
    return m;
  }
  function genTps(g) { return g.tps * genMult(g.id) * globalMult(); }
  function baseTps() { // takviyesiz, olay etkisiz
    var t = 0;
    GENERATORS.forEach(function (g) { t += S.gens[g.id] * genTps(g); });
    return t;
  }
  function tps() { return baseTps() * boostMult() * buffMult('prod'); }
  function clickBase() {
    var mult = 1, p = 0;
    S.upgrades.forEach(function (id) {
      var u = UPG_BY_ID[id];
      if (u && u.type === 'click') { if (u.click) mult *= u.click; if (u.clickPct) p += u.clickPct; }
    });
    var stageShare = (1 + STAGE_BONUS * stageIndex(S.runEarned)) * (1 + SHARE_BONUS * S.shares);
    return BASE_CLICK * mult * stageShare + p * baseTps();
  }
  function clickValue() { return clickBase() * boostMult() * buffMult('click'); }
  // Olay/görev ödülleri: mevcut üretimin belirli saniyesi kadar (erken oyunda tıklamaya göre taban)
  function pay(sec) { return Math.max(baseTps() * sec, clickBase() * sec * 0.5, 25); }
  function negSec(sec) { return has('tercuman') ? sec * 0.75 : sec; }
  function meetPct(p) { return has('standup') ? p * 0.8 : p; }
  function addRep(n) { S.reputation = Math.max(0, Math.min(REP_MAX, S.reputation + n)); }
  function repMult() { return 1 + REP_OFFER_BONUS * S.reputation; }
  function addBuff(id, kind, mult, sec, label) {
    S.buffs = S.buffs.filter(function (b) { return b.id !== id; });
    S.buffs.push({ id: id, kind: kind, mult: mult, left: sec, total: sec, label: label });
  }
  function meeting() { S.meetings++; S.noMeetingSec = 0; }
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
  function earn(x, src) {
    S.money += x; S.runEarned += x; S.totalEarned += x;
    if (src !== 'offline' && src !== 'task') taskProgress('earn', x);
  }

  // Eylemler
  function doClick(forceCrit) {
    var crit = forceCrit === true || (forceCrit !== false && rnd() < CRIT_CHANCE);
    var v = clickValue() * (crit ? CRIT_MULT : 1);
    earn(v); S.clicks++; S.clickEarned += v;
    if (crit) { S.critClicks++; taskProgress('crit', 1); }
    taskProgress('click', 1);
    Core.lastCrit = crit;
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
    taskProgress('hire', n, id);
    return true;
  }
  function buyUpgrade(id) {
    var u = UPG_BY_ID[id];
    if (!u || has(id) || !upgradeUnlocked(u) || S.money < u.cost) return false;
    S.money -= u.cost; S.upgrades.push(id);
    taskProgress('upgrade', 1);
    return true;
  }
  function sharesGain() { return Math.floor(Math.sqrt(S.runEarned / PRESTIGE_UNIT)); }
  function nextShareAt() { var n = sharesGain() + 1; return n * n * PRESTIGE_UNIT; }
  var KEEP_ON_PRESTIGE = ['totalEarned', 'clicks', 'clickEarned', 'playTime', 'startedAt', 'eventsClicked', 'offlineEarned',
    'achievements', 'critClicks', 'eventsResolved', 'logoAccepted', 'revisions', 'meetings', 'serverCrashes',
    'reputation', 'noMeetingSec', 'daily'];
  function doPrestige() {
    var gain = sharesGain();
    if (gain < 1) return 0;
    var keep = { shares: S.shares + gain, prestigeCount: S.prestigeCount + 1 };
    KEEP_ON_PRESTIGE.forEach(function (k) { keep[k] = S[k]; });
    S = newState();
    for (var k in keep) S[k] = keep[k];
    return gain;
  }
  // Simülasyon/ilerleme
  function tick(dt) {
    if (dt <= 0) return;
    var boostPart = Math.min(dt, S.boostLeft);
    var b = baseTps() * buffMult('prod');
    earn(b * dt + b * boostPart, 'prod'); // takviye süresi boyunca x2
    S.boostLeft = Math.max(0, S.boostLeft - dt);
    if (S.buffs.length) {
      S.buffs.forEach(function (x) { x.left -= dt; });
      S.buffs = S.buffs.filter(function (x) { return x.left > 0; });
    }
    S.playTime += dt;
    S.noMeetingSec += dt;
  }

  // ------------------------------------------------------------------
  // Ajans olay kartları (iki seçenekli)
  // ------------------------------------------------------------------
  function fridayChance() { return 0.5 + (has('push_dua') ? 0.1 : 0); }
  function crashMult() { return S.gens.sunucu > 0 ? 0.5 : 0; }
  function crashLabel() { return S.gens.sunucu > 0 ? 'verim -%50' : 'üretim durur'; }
  function crashFix() { return Math.min(S.money, pay(15)); }
  function cash(sec, msg) { var x = pay(sec); earn(x, 'event'); return msg + ' +' + tl(x); }
  var EVENTS = [
    { id: 'logo', icon: '🔍', title: '“Logoyu biraz daha büyütebilir miyiz?”', text: 'Müşteri aynı ricayla üçüncü kez arıyor. Logo zaten sayfanın yarısı.',
      choices: [
        { label: 'Büyütelim', hint: function () { return '+' + tl(pay(45)) + ' · ' + fmtSec(negSec(30)) + ' verim -%10'; },
          run: function () { S.logoAccepted++; S.revisions++; addBuff('revize', 'prod', 0.9, negSec(30), 'Revize yorgunluğu'); return cash(45, 'Logo büyüdü, fatura da:'); } },
        { label: 'Tasarımı savun', hint: '+2 itibar', run: function () { addRep(2); return 'Tasarım bütünlüğünü korudun. İtibar +2'; } }
      ] },
    { id: 'yarin', icon: '⏰', title: '“Yarına yetişir mi?”', text: 'Acil iş: ödeme normalin iki katı, ama ekip gece yarısına kadar çalışacak.',
      choices: [
        { label: 'Yetişir!', hint: function () { return '+' + tl(pay(120)) + ' · ' + fmtSec(negSec(60)) + ' verim -%20'; },
          run: function () { addBuff('gece', 'prod', 0.8, negSec(60), 'Gece mesaisi'); return cash(120, 'Teslim edildi, ekip uykusuz:'); } },
        { label: 'Makul bir süre iste', hint: function () { return '+' + tl(pay(30)) + ' · +1 itibar'; },
          run: function () { addRep(1); return cash(30, 'Müşteri ikna oldu, itibar +1:'); } }
      ] },
    { id: 'cuma', icon: '🎲', title: '“Cuma akşamı deploy”', text: 'Testler yeşil… çoğunlukla. Saat 17.45.',
      choices: [
        { label: 'Yazı tura, deploy!', hint: function () { var p = fridayChance(); return '%' + pct(p) + ': +' + tl(pay(90)) + ' · %' + pct(1 - p) + ': ' + fmtSec(negSec(45)) + ' verim -%40'; },
          run: function () {
            if (chance(fridayChance())) return cash(90, 'Sorunsuz çıktı, müşteri bayıldı:');
            addBuff('haftasonu', 'prod', 0.6, negSec(45), 'Hafta sonu mesaisi');
            return 'Canlıda hata! Hafta sonu mesaisi başladı.';
          } },
        { label: 'Pazartesiye bırak', hint: function () { return '+' + tl(pay(20)); }, run: function () { return cash(20, 'Temkinli davrandın:'); } }
      ] },
    { id: 'begenmedik', icon: '🤷', title: '“Beğenmedik ama ne istediğimizi de tam bilmiyoruz.”', text: 'Geri bildirimin tamamı: “Daha bir şey olsun.”',
      choices: [
        { label: 'Baştan tasarla', hint: function () { return '+' + tl(pay(40)) + ' · ' + fmtSec(negSec(40)) + ' verim -%15'; },
          run: function () { S.revisions++; addBuff('revize', 'prod', 0.85, negSec(40), 'Revize turu'); return cash(40, 'Yeni taslak gönderildi:'); } },
        { label: 'Brif toplantısı iste', hint: function () { return fmtSec(negSec(30)) + ' verim -%' + pct(meetPct(0.10)) + ' · +2 itibar'; },
          run: function () { meeting(); addRep(2); addBuff('toplanti', 'prod', 1 - meetPct(0.10), negSec(30), 'Brif toplantısı'); return 'Sonunda ne istediklerini öğrendin. İtibar +2'; } }
      ] },
    { id: 'portfolyo', icon: '🖼️', title: '“Bütçemiz yok ama portfolyona çok iyi gider.”', text: 'Ücretsiz ama herkesin göreceği bir iş.',
      choices: [
        { label: 'Portfolyo için yap', hint: function () { return '+5 itibar · ' + fmtSec(negSec(30)) + ' verim -%20'; },
          run: function () { addRep(5); addBuff('bedava', 'prod', 0.8, negSec(30), 'Ücretsiz iş'); return 'Portfolyon parladı. İtibar +5'; } },
        { label: 'Nazikçe reddet', hint: 'Etkisi yok', run: function () { return 'Kibarca reddettin, ekip işine döndü.'; } }
      ] },
    { id: 'yegen', icon: '🧒', title: '“Yeğenim de biraz web’den anlıyor.”', text: 'Müşteri fiyat için pazarlık etmek istiyor.',
      choices: [
        { label: 'Fiyatta dur', hint: function () { return '%60: +' + tl(pay(60)) + ' · %40: -2 itibar'; },
          run: function () {
            if (chance(0.6)) return cash(60, 'Değerini bildiler:');
            addRep(-2); return 'Yeğenle devam ettiler. İtibar -2';
          } },
        { label: 'Biraz indirim yap', hint: function () { return '+' + tl(pay(30)) + ' · +1 itibar'; },
          run: function () { addRep(1); return cash(30, 'Orta yolda buluştunuz, itibar +1:'); } }
      ] },
    { id: 'final', icon: '📄', title: '“Final_v7_son_bu_kesin.pdf geldi.”', text: 'Ekte bir de “son_final_revize2.docx” var.',
      choices: [
        { label: 'Revizeleri işle', hint: function () { return '+' + tl(pay(50)) + ' · ' + fmtSec(negSec(45)) + ' verim -%20'; },
          run: function () { S.revisions++; addBuff('revize', 'prod', 0.8, negSec(45), 'Revize turu'); return cash(50, 'v8 de gönderildi:'); } },
        { label: 'v6’yı geri öner', hint: function () { return '+' + tl(pay(15)) + ' · +1 itibar'; },
          run: function () { addRep(1); return cash(15, 'Meğer v6 daha iyiymiş, itibar +1:'); } }
      ] },
    { id: 'toplanti', icon: '📅', title: '“Toplantı olmasın, kısa bir görüşme yapalım.”', text: 'Takvimde “kısa” diye bir buçuk saat ayrılmış.',
      choices: [
        { label: 'Katıl', hint: function () { return fmtSec(negSec(40)) + ' verim -%' + pct(meetPct(0.15)) + ' · +2 itibar'; },
          run: function () { meeting(); addRep(2); addBuff('toplanti', 'prod', 1 - meetPct(0.15), negSec(40), 'Kısa görüşme'); return 'Görüşme uzadı ama müşteri memnun. İtibar +2'; } },
        { label: 'E-postayla yanıtla', hint: '-1 itibar', run: function () { addRep(-1); return 'Müşteri biraz bozuldu. İtibar -1'; } }
      ] },
    { id: 'rakip', icon: '🪞', title: '“Rakip sitenin aynısı olsun ama bizim olsun.”', text: 'Referans olarak tek bir bağlantı gönderdiler.',
      choices: [
        { label: 'Aynısını yap', hint: function () { return '+' + tl(pay(60)) + ' · -3 itibar'; },
          run: function () { addRep(-3); return cash(60, 'Hızlı iş, sektörde dedikodu. İtibar -3,'); } },
        { label: 'Özgün öneri sun', hint: function () { return '+' + tl(pay(25)) + ' · +2 itibar'; },
          run: function () { addRep(2); return cash(25, 'Müşteri fikri sevdi, itibar +2:'); } }
      ] },
    { id: 'kedi', icon: '🐈', title: '“Ofis Kedisi klavyeye yattı, commit gitti.”', text: 'Commit mesajı: “ffffffjjjjjjj”.',
      choices: [
        { label: 'Commit’i geri al', hint: function () { return fmtSec(negSec(20)) + ' verim -%10'; },
          run: function () { addBuff('revert', 'prod', 0.9, negSec(20), 'Geri alma'); return 'Commit geri alındı, kedi ofisten uzaklaştırıldı.'; } },
        { label: 'Canlıya çıksın', hint: function () { return '%70: ' + fmtSec(negSec(30)) + ' verim -%25 · %30: +' + tl(pay(90)); },
          run: function () {
            if (chance(0.3)) return cash(90, '“Yeni özellik” diye satıldı:');
            addBuff('bug', 'prod', 0.75, negSec(30), 'Kedi hatası'); return 'Küçük bir hata çıktı, ekip düzeltiyor.';
          } }
      ] },
    { id: 'sunucu', icon: '🔥', title: '“Sunucu çöktü!”', defaultChoice: 1,
      text: function () { return S.gens.sunucu > 0 ? 'Sunucu Odası’ndaki yedekler devrede ama her şey yavaşladı.' : 'Tüm projeler durdu. Herkes aynı anda “bende açılıyor” diyor.'; },
      choices: [
        { label: 'Hemen müdahale et', hint: function () { return '-' + tl(crashFix()) + ' · ' + fmtSec(negSec(15)) + ' ' + crashLabel(); },
          run: function () { var c = crashFix(); S.money -= c; S.serverCrashes++; addBuff('cokme', 'prod', crashMult(), negSec(15), 'Sunucu çöktü'); return 'Acil ekip devrede, kısa sürede toparlanacak. -' + tl(c); } },
        { label: 'Kendiliğinden düzelsin', hint: function () { return fmtSec(negSec(30)) + ' ' + crashLabel(); },
          run: function () { S.serverCrashes++; addBuff('cokme', 'prod', crashMult(), negSec(30), 'Sunucu çöktü'); return 'Sunucu yeniden başlatılıyor…'; } }
      ] },
    { id: 'viral', icon: '📣', title: '“Viral iş ağı paylaşımı”', text: 'Ekibinin paylaşımı bir gecede herkesin akışına düştü.',
      choices: [
        { label: 'Klavye başına!', hint: '60 sn tık kazancı x2', run: function () { addBuff('viral', 'click', 2, 60, 'Viral etki'); return 'Herkes kod yazıyor: 60 sn tık kazancı x2!'; } },
        { label: 'Müşterilere yönlendir', hint: '+3 itibar', run: function () { addRep(3); return 'Gelen kutusu doldu. İtibar +3'; } }
      ] }
  ];
  var EVENT_BY_ID = {};
  EVENTS.forEach(function (e) { EVENT_BY_ID[e.id] = e; });
  function eventPool() {
    return EVENTS.filter(function (e) {
      if (e.id === 'cuma' && has('deploy_yasak')) return false;
      if (e.id === 'sunucu' && totalOwned() < 5) return false;
      return true;
    });
  }
  function pickEvent(exclude) {
    var p = eventPool().filter(function (e) { return e.id !== exclude; });
    if (!p.length) p = eventPool();
    return p[Math.floor(rnd() * p.length)].id;
  }
  function resolveEvent(id, idx) {
    var e = EVENT_BY_ID[id];
    if (!e || !e.choices[idx]) return '';
    var msg = e.choices[idx].run();
    S.eventsResolved++;
    taskProgress('event', 1);
    return msg;
  }

  // ------------------------------------------------------------------
  // Başarımlar (her biri kalıcı +%1 üretim, Yatırım Turu’nda korunur)
  // ------------------------------------------------------------------
  var ACHIEVEMENTS = [
    { id: 'tik_1', icon: '👋', name: 'Merhaba Dünya', desc: 'İlk satır kodunu yaz', test: function () { return S.clicks >= 1; } },
    { id: 'tik_100', icon: '⌨️', name: 'Klavye Isındı', desc: '100 kez kod yaz', test: function () { return S.clicks >= 100; } },
    { id: 'tik_1000', icon: '💪', name: 'Parmak Kası', desc: '1.000 kez kod yaz', test: function () { return S.clicks >= 1000; } },
    { id: 'tik_10000', icon: '🦾', name: 'Mekanik Klavye Tutkunu', desc: '10.000 kez kod yaz', test: function () { return S.clicks >= 10000; } },
    { id: 'kritik_1', icon: '💥', name: 'Kritik Satır', desc: 'İlk kritik tıkını yap', test: function () { return S.critClicks >= 1; } },
    { id: 'kritik_50', icon: '🎯', name: 'Tesadüf Değil', desc: '50 kritik tık yap', test: function () { return S.critClicks >= 50; } },
    { id: 'kazanc_1k', icon: '🧾', name: 'İlk Fatura', desc: 'Toplam 1 Bin TL kazan', test: function () { return S.totalEarned >= 1e3; } },
    { id: 'kazanc_1m', icon: '💰', name: 'Milyonluk Proje', desc: 'Toplam 1 Mn TL kazan', test: function () { return S.totalEarned >= 1e6; } },
    { id: 'kazanc_1b', icon: '🏦', name: 'Milyar Değerleme', desc: 'Toplam 1 Mr TL kazan', test: function () { return S.totalEarned >= 1e9; } },
    { id: 'kazanc_1t', icon: '👑', name: 'Trilyon Kulübü', desc: 'Toplam 1 Tn TL kazan', test: function () { return S.totalEarned >= 1e12; } },
    { id: 'ekip_10', icon: '👥', name: 'Küçük Ekip', desc: 'Aynı anda 10 çalışanın olsun', test: function () { return totalOwned() >= 10; } },
    { id: 'ekip_50', icon: '🏢', name: 'Açık Ofis', desc: 'Aynı anda 50 çalışanın olsun', test: function () { return totalOwned() >= 50; } },
    { id: 'ekip_150', icon: '🧍', name: 'Kalabalık Stand-up', desc: 'Aynı anda 150 çalışanın olsun', test: function () { return totalOwned() >= 150; } },
    { id: 'ekip_300', icon: '🗃️', name: 'İK Departmanı Şart', desc: 'Aynı anda 300 çalışanın olsun', test: function () { return totalOwned() >= 300; } },
    { id: 'robot', icon: '🤖', name: 'Robot Meslektaş', desc: 'İlk Yapay Zekâ Kod Ajanını işe al', test: function () { return S.gens.ai >= 1; } },
    { id: 'asama_2', icon: '🏢', name: 'Butik Hayaller', desc: 'Butik Stüdyo aşamasına ulaş', test: function () { return S.stage >= 2; } },
    { id: 'asama_3', icon: '🚀', name: 'Tabela Asıldı', desc: 'Ajans aşamasına ulaş', test: function () { return S.stage >= 3; } },
    { id: 'asama_5', icon: '🌐', name: 'Kıtalar Arası', desc: 'Global Holding aşamasına ulaş', test: function () { return S.stage >= 5; } },
    { id: 'localhost', icon: '💻', name: 'Localhost’ta Çalışıyordu', desc: 'Bir sunucu çökmesini atlat', test: function () { return S.serverCrashes >= 1; } },
    { id: 'revize_7', icon: '📑', name: 'Son Revize 7. Kez', desc: '7 revize talebini kabul et', test: function () { return S.revisions >= 7; } },
    { id: 'toplantisiz', icon: '🤫', name: 'Toplantısız Gün', desc: '10 dakika boyunca hiçbir toplantıya katılmadan oyna', test: function () { return S.noMeetingSec >= 600; } },
    { id: 'logo_5', icon: '🔎', name: 'Logo Artık Ekrana Sığmıyor', desc: '“Logoyu büyütelim” isteğini 5 kez kabul et', test: function () { return S.logoAccepted >= 5; } },
    { id: 'olay_10', icon: '🧯', name: 'Kriz Yöneticisi', desc: '10 olay kartı çöz', test: function () { return S.eventsResolved >= 10; } },
    { id: 'olay_50', icon: '🧠', name: 'Her Şeyi Gördüm', desc: '50 olay kartı çöz', test: function () { return S.eventsResolved >= 50; } },
    { id: 'teklif_10', icon: '📨', name: 'Müşteri Mıknatısı', desc: '10 müşteri projesi teslim et', test: function () { return S.eventsClicked >= 10; } },
    { id: 'itibar_25', icon: '⭐', name: 'Sektörde Tanınıyorsun', desc: '25 itibar puanına ulaş', test: function () { return S.reputation >= 25; } },
    { id: 'gorev_1', icon: '✅', name: 'Günü Kurtardın', desc: 'Bir günün tüm görevlerini tamamla', test: function () { return S.daily.daysCompleted >= 1; } },
    { id: 'seri_3', icon: '🔥', name: 'Üç Gün Üst Üste', desc: '3 günlük seri yap', test: function () { return S.daily.best >= 3; } },
    { id: 'seri_7', icon: '📆', name: 'Haftalık Rutin', desc: '7 günlük seri yap', test: function () { return S.daily.best >= 7; } },
    { id: 'yatirim_1', icon: '💼', name: 'İlk Yatırım', desc: 'İlk Yatırım Turunu tamamla', test: function () { return S.prestigeCount >= 1; } }
  ];
  var ACH_BY_ID = {};
  ACHIEVEMENTS.forEach(function (a) { ACH_BY_ID[a.id] = a; });
  function checkAchievements() {
    var got = [];
    ACHIEVEMENTS.forEach(function (a) {
      if (S.achievements.indexOf(a.id) === -1 && a.test()) { S.achievements.push(a.id); got.push(a); notify('ach', a); }
    });
    return got;
  }

  // ------------------------------------------------------------------
  // Günlük görevler ve seri
  // ------------------------------------------------------------------
  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function dateStr(d) { return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); }
  function today() { return Core.fakeToday || dateStr(new Date()); }
  function shiftDay(s, n) {
    var p = s.split('-');
    var d = new Date(Date.UTC(+p[0], +p[1] - 1, +p[2] + n));
    return d.getUTCFullYear() + '-' + pad(d.getUTCMonth() + 1) + '-' + pad(d.getUTCDate());
  }
  function seeded(str) {
    var h = 2166136261;
    for (var i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = Math.imul(h, 16777619); }
    return function () {
      h = (h + 0x6D2B79F5) | 0;
      var t = Math.imul(h ^ (h >>> 15), h | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  function niceRound(x) {
    if (x < 100) return Math.ceil(x);
    var p = Math.pow(10, Math.floor(Math.log10(x)) - 1);
    return Math.ceil(x / p) * p;
  }
  var TASK_POOL = ['click', 'offer', 'event', 'hire', 'earn', 'crit', 'upgrade'];
  function makeTasks(date) {
    var r = seeded('kodhane:' + date);
    var pool = TASK_POOL.slice();
    for (var i = pool.length - 1; i > 0; i--) { var j = Math.floor(r() * (i + 1)); var tmp = pool[i]; pool[i] = pool[j]; pool[j] = tmp; }
    var si = stageIndex(S.runEarned);
    var tasks = [];
    for (var k = 0; k < pool.length && tasks.length < 3; k++) {
      var type = pool[k];
      var t = { type: type, target: 1, progress: 0, done: false, reward: 0 };
      if (type === 'click') t.target = [150, 250, 350, 500, 500, 600][si];
      else if (type === 'offer') t.target = [2, 2, 3, 3, 3, 3][si];
      else if (type === 'event') t.target = [1, 1, 2, 2, 2, 3][si];
      else if (type === 'crit') t.target = [3, 4, 5, 6, 8, 10][si];
      else if (type === 'earn') t.target = niceRound(Math.max(500, baseTps() * 900));
      else if (type === 'upgrade') { if (totalOwned() < 1) continue; t.target = si >= 2 ? 2 : 1; }
      else if (type === 'hire') {
        var idx = 0;
        GENERATORS.forEach(function (g, gi) { if (S.gens[g.id] > 0) idx = gi; });
        t.gen = GENERATORS[idx].id;
        t.target = [5, 3, 2, 1, 1, 1, 1, 1][idx];
      }
      tasks.push(t);
    }
    return tasks;
  }
  function taskLabel(t) {
    switch (t.type) {
      case 'click': return fmt(t.target) + ' kez kod yaz';
      case 'offer': return t.target + ' müşteri projesi teslim et';
      case 'event': return t.target + ' olay kartı çöz';
      case 'crit': return t.target + ' kritik tık yap';
      case 'earn': return tl(t.target) + ' kazan';
      case 'upgrade': return t.target + ' geliştirme satın al';
      case 'hire': var g = GENERATORS.filter(function (x) { return x.id === t.gen; })[0]; return t.target + ' ' + (g ? g.name : 'çalışan') + ' işe al';
    }
    return '';
  }
  function taskReward() { return pay(120); }
  function streakBonus(n) { return pay(300) * Math.min(Math.max(n, 1), 7); }
  function checkDaily() {
    var d = today();
    var prev = S.daily;
    if (prev.date === d) return false;
    var streak = prev.streak || 0;
    var reset = false;
    if (prev.lastComplete !== shiftDay(d, -1) && prev.lastComplete !== d) { reset = streak > 0; streak = 0; }
    var nd = newDaily();
    nd.date = d; nd.tasks = makeTasks(d); nd.streak = streak; nd.best = prev.best || 0;
    nd.lastComplete = prev.lastComplete || null; nd.daysCompleted = prev.daysCompleted || 0;
    S.daily = nd;
    if (prev.date) notify('newday', { reset: reset });
    return true;
  }
  function taskProgress(type, amount, meta) {
    var D = S.daily;
    if (!D || !D.tasks || !D.tasks.length) return;
    var finished = false;
    D.tasks.forEach(function (t) {
      if (t.done || t.type !== type) return;
      if (type === 'hire' && t.gen !== meta) return;
      t.progress = Math.min(t.target, t.progress + amount);
      if (t.progress >= t.target) {
        t.done = true; finished = true;
        t.reward = taskReward(); earn(t.reward, 'task');
        notify('task', t);
      }
    });
    if (finished && !D.allDone && D.tasks.every(function (t) { return t.done; })) {
      D.allDone = true;
      D.streak = (D.streak || 0) + 1;
      D.best = Math.max(D.best || 0, D.streak);
      D.lastComplete = D.date;
      D.daysCompleted = (D.daysCompleted || 0) + 1;
      var bonus = streakBonus(D.streak);
      earn(bonus, 'task');
      notify('streak', { streak: D.streak, bonus: bonus });
    }
  }

  // ------------------------------------------------------------------
  // Kayıt (v1 -> v2 taşıma dahil)
  // ------------------------------------------------------------------
  function serialize() { S.lastSaved = Date.now(); return JSON.stringify(S); }
  function isNum(x) { return typeof x === 'number' && isFinite(x); }
  function deserialize(str) {
    var d = JSON.parse(str);
    if (!d || typeof d !== 'object') throw new Error('Geçersiz kayıt');
    var base = newState();
    Core.loadedVersion = d.version || 1;
    for (var k in base) {
      if (d[k] === undefined || d[k] === null) continue;
      if (typeof base[k] === 'number') { if (isNum(d[k])) base[k] = d[k]; }
      else if (Array.isArray(base[k])) { if (Array.isArray(d[k])) base[k] = d[k]; }
    }
    GENERATORS.forEach(function (g) {
      var n = d.gens && d.gens[g.id];
      base.gens[g.id] = isNum(n) ? Math.max(0, Math.floor(n)) : 0;
    });
    var seen = {};
    base.upgrades = base.upgrades.filter(function (id) { var ok = UPG_BY_ID[id] && !seen[id]; seen[id] = 1; return ok; });
    seen = {};
    base.achievements = base.achievements.filter(function (id) { var ok = ACH_BY_ID[id] && !seen[id]; seen[id] = 1; return ok; });
    base.buffs = base.buffs.filter(function (b) {
      return b && isNum(b.mult) && isNum(b.left) && b.left > 0 && (b.kind === 'prod' || b.kind === 'click');
    });
    if (d.daily && typeof d.daily === 'object' && Array.isArray(d.daily.tasks)) {
      var nd = newDaily();
      for (var j in nd) if (d.daily[j] !== undefined) nd[j] = d.daily[j];
      base.daily = nd;
    }
    base.reputation = Math.max(0, Math.min(REP_MAX, base.reputation));
    base.version = 2;
    S = base;
    return S;
  }
  function applyOffline(now) {
    var elapsed = Math.max(0, ((now || Date.now()) - S.lastSaved) / 1000);
    var sec = Math.min(elapsed, OFFLINE_CAP_SEC);
    var gain = baseTps() * sec;
    if (gain > 0) { earn(gain, 'offline'); S.offlineEarned += gain; }
    return { elapsed: elapsed, sec: sec, gain: gain, capped: elapsed > OFFLINE_CAP_SEC };
  }

  var Core = {
    VERSION: VERSION, GENERATORS: GENERATORS, UPGRADES: UPGRADES, STAGES: STAGES, EVENTS: EVENTS, ACHIEVEMENTS: ACHIEVEMENTS,
    fmt: fmt, tl: tl, fmtTime: fmtTime,
    get state() { return S; }, set state(v) { S = v; }, newState: newState,
    tps: tps, baseTps: baseTps, clickValue: clickValue, clickBase: clickBase, genCost: genCost, genTps: genTps, maxAffordable: maxAffordable,
    availableUpgrades: availableUpgrades, buyGen: buyGen, buyUpgrade: buyUpgrade, doClick: doClick, tick: tick,
    stageIndex: stageIndex, totalOwned: totalOwned, sharesGain: sharesGain, doPrestige: doPrestige,
    serialize: serialize, deserialize: deserialize, applyOffline: applyOffline, earn: earn, has: has,
    pay: pay, addBuff: addBuff, buffMult: buffMult, achMult: achMult, repMult: repMult, addRep: addRep,
    eventPool: eventPool, pickEvent: pickEvent, resolveEvent: resolveEvent, checkAchievements: checkAchievements,
    checkDaily: checkDaily, makeTasks: makeTasks, taskProgress: taskProgress, taskLabel: taskLabel, today: today, shiftDay: shiftDay,
    streakBonus: streakBonus, setToday: function (s) { Core.fakeToday = s || null; },
    rng: Math.random, lastCrit: false, fakeToday: null, loadedVersion: null,
    CRIT_CHANCE: CRIT_CHANCE, CRIT_MULT: CRIT_MULT
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
  var achSig = '';
  var lastStageShown = 0;
  var activeTab = 'upgrades';
  var view = 'kod';
  var updateRequested = false;
  var reduceMotion = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
  function isMobile() { return !!(window.matchMedia && window.matchMedia('(max-width: 767px)').matches); }

  // Ayarlar (ses varsayılan olarak kapalı)
  function loadSettings() {
    var s = { sound: false, vibrate: true };
    try {
      var d = JSON.parse(localStorage.getItem(SETTINGS_KEY) || '{}');
      if (typeof d.sound === 'boolean') s.sound = d.sound;
      if (typeof d.vibrate === 'boolean') s.vibrate = d.vibrate;
    } catch (e) {}
    return s;
  }
  var settings = loadSettings();
  function saveSettings() { try { localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings)); } catch (e) {} }

  // Web Audio ile üretilen sesler (dosya yok)
  var actx = null;
  function audio() {
    if (!settings.sound) return null;
    if (!actx) {
      var AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) return null;
      try { actx = new AC(); } catch (e) { return null; }
    }
    if (actx.state === 'suspended') actx.resume();
    return actx;
  }
  function tone(freq, dur, type, vol, delay, slideTo) {
    var a = audio();
    if (!a) return;
    var t = a.currentTime + (delay || 0);
    var o = a.createOscillator(), g = a.createGain();
    o.type = type || 'sine';
    o.frequency.setValueAtTime(freq, t);
    if (slideTo) o.frequency.exponentialRampToValueAtTime(slideTo, t + dur);
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(vol || 0.06, t + 0.01);
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    o.connect(g); g.connect(a.destination);
    o.start(t); o.stop(t + dur + 0.02);
  }
  var SFX = {
    click: function () { tone(520 + Math.random() * 90, 0.05, 'square', 0.025); },
    crit: function () { tone(660, 0.08, 'triangle', 0.07); tone(990, 0.14, 'triangle', 0.07, 0.06); },
    buy: function () { tone(440, 0.07, 'triangle', 0.05); tone(660, 0.09, 'triangle', 0.05, 0.05); },
    stage: function () { [523, 659, 784, 1047].forEach(function (f, i) { tone(f, 0.2, 'triangle', 0.06, i * 0.1); }); },
    offer: function () { tone(880, 0.1, 'sine', 0.05); tone(1175, 0.12, 'sine', 0.05, 0.1); },
    ach: function () { [784, 988, 1319].forEach(function (f, i) { tone(f, 0.18, 'sine', 0.06, i * 0.08); }); }
  };
  function sfx(name) { if (settings.sound && SFX[name]) { try { SFX[name](); } catch (e) {} } }
  function vibrate(p) { if (settings.vibrate && navigator.vibrate) { try { navigator.vibrate(p); } catch (e) {} } }

  function toast(msg, ms) {
    var t = document.createElement('div');
    t.className = 'toast-item';
    t.textContent = msg;
    el.toast.appendChild(t);
    while (el.toast.children.length > 3) el.toast.removeChild(el.toast.firstChild);
    setTimeout(function () { t.classList.add('out'); setTimeout(function () { if (t.parentNode) t.parentNode.removeChild(t); }, 300); }, ms || 2600);
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
    if (typeof Core.onSaved === 'function') { try { Core.onSaved(); } catch (e) { /* bulut kancası oyunu durdurmamalı */ } }
  }
  // Buluttan (veya başka bir kaynaktan) gelen kaydı uygula: yerel kaydı değiştirir ve arayüzü yeniler.
  function applySave(data) {
    deserialize(typeof data === 'string' ? data : JSON.stringify(data));
    var res = applyOffline(Date.now());
    lastStageShown = stageIndex(S.runEarned);
    S.stage = Math.max(S.stage, lastStageShown);
    checkDaily();
    checkAchievements();
    queue = queue.filter(function (n) { return n.type !== 'ach' && n.type !== 'newday'; });
    upgSig = ''; achSig = '';
    setCounter('money', S.money, true);
    setCounter('rate', tps(), true);
    save();
    renderAll();
    return res;
  }
  function load() {
    var raw = null, migrated = false;
    try {
      raw = localStorage.getItem(SAVE_KEY);
      for (var i = 0; !raw && i < LEGACY_KEYS.length; i++) {
        raw = localStorage.getItem(LEGACY_KEYS[i]);
        if (raw) migrated = true;
      }
    } catch (e) {}
    if (!raw) return null;
    try { deserialize(raw); } catch (e) { S = newState(); return null; }
    var res = applyOffline(Date.now());
    res.migrated = migrated;
    return res;
  }

  // Sayaç animasyonu (~250 ms rAF geçişi)
  var TWEEN_MS = 250;
  var counters = {
    money: { shown: 0, from: 0, to: 0, t0: 0, fmt: function (v) { return tl(v); } },
    rate: { shown: 0, from: 0, to: 0, t0: 0, fmt: function (v) { return tl(v) + '/sn'; } }
  };
  var rafId = 0;
  function paintCounter(key) { el[key].textContent = counters[key].fmt(counters[key].shown); }
  function setCounter(key, value, instant) {
    var c = counters[key];
    if (value === c.to && !instant) return;
    if (key === 'money' && value < c.to - 1e-9) flashSpend();
    if (instant || reduceMotion || Math.abs(value - c.shown) < 1e-9) {
      c.shown = c.from = c.to = value; paintCounter(key); return;
    }
    c.from = c.shown; c.to = value; c.t0 = performance.now();
    if (!rafId) rafId = requestAnimationFrame(counterFrame);
  }
  function counterFrame(now) {
    var active = false;
    for (var key in counters) {
      var c = counters[key];
      if (c.shown === c.to) continue;
      var p = Math.min(1, Math.max(0, (now - c.t0) / TWEEN_MS));
      var e = 1 - Math.pow(1 - p, 3);
      c.shown = p >= 1 ? c.to : c.from + (c.to - c.from) * e;
      paintCounter(key);
      if (p < 1) active = true;
    }
    rafId = active ? requestAnimationFrame(counterFrame) : 0;
  }
  var spendTimer = 0;
  function flashSpend() {
    el.money.classList.add('spend');
    clearTimeout(spendTimer);
    spendTimer = setTimeout(function () { el.money.classList.remove('spend'); }, 450);
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
        if (buyGen(g.id, buyQty)) { sfx('buy'); vibrate(8); renderAll(); }
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
        r.btn.classList.remove('hidden', 'affordable');
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
          if (buyUpgrade(u.id)) {
            if (u.id === 'deploy_yasak' && evs.nextId === 'cuma') evs.nextId = pickEvent('cuma');
            toast(u.icon + ' ' + u.name + ' alındı!'); sfx('buy'); vibrate(8); renderAll();
          }
        });
        el.upgList.appendChild(b);
      });
      if (S.upgrades.length) {
        var d = document.createElement('div');
        d.className = 'owned-upgs';
        d.textContent = 'Sahip olunan geliştirmeler (' + S.upgrades.length + '): ';
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
    [el.upgBadge, el.navUpgBadge].forEach(function (x) {
      x.textContent = affordableCount;
      x.classList.toggle('hidden', affordableCount === 0);
    });
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
        toast('🎉 ' + st.icon + ' ' + st.name + ' — ' + st.msg + ' (+%' + Math.round(i * STAGE_BONUS * 100) + ' üretim)', 6000);
        sfx('stage'); vibrate([15, 40, 15]);
      }
    }
    el.repChip.textContent = '⭐ İtibar ' + S.reputation + ' · müşteri ödemeleri +%' + Math.round(S.reputation * REP_OFFER_BONUS * 100);
    el.achChip.textContent = '🏅 Başarım ' + S.achievements.length + '/' + ACHIEVEMENTS.length + ' · +%' + S.achievements.length + ' üretim';
    el.streakChip.textContent = '🔥 Seri ' + (S.daily.streak || 0) + ' gün';
  }
  function renderStats() {
    var rows = [
      ['Mevcut para', tl(S.money)],
      ['Saniyelik üretim', tl(tps()) + '/sn'],
      ['Tık başına', tl(clickValue())],
      ['Bu turdaki kazanç', tl(S.runEarned)],
      ['Toplam kazanç (tüm zamanlar)', tl(S.totalEarned)],
      ['Toplam tıklama', fmt(S.clicks)],
      ['Kritik tık', fmt(S.critClicks)],
      ['Tıklamayla kazanılan', tl(S.clickEarned)],
      ['Toplam çalışan', fmt(totalOwned())],
      ['Alınan geliştirme', S.upgrades.length + ' / ' + UPGRADES.length],
      ['Tamamlanan müşteri projesi', fmt(S.eventsClicked)],
      ['Çözülen olay kartı', fmt(S.eventsResolved)],
      ['İtibar', S.reputation + ' / ' + REP_MAX],
      ['Başarım bonusu', '+%' + S.achievements.length + ' üretim'],
      ['Günlük seri (en iyi)', (S.daily.streak || 0) + ' gün (' + (S.daily.best || 0) + ')'],
      ['Çevrimdışı kazanç', tl(S.offlineEarned)],
      ['Oynama süresi', fmtTime(S.playTime)],
      ['Yatırım turu sayısı', fmt(S.prestigeCount)],
      ['Sürüm', 'v' + VERSION]
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
  function renderDaily() {
    var D = S.daily;
    var head = '🔥 Seri: <b>' + (D.streak || 0) + ' gün</b> · En iyi: ' + (D.best || 0) + ' gün<br>' +
      (D.allDone ? '✅ Bugünün görevleri tamam! Yarın seriyi sürdürmeyi unutma.'
        : 'Üç görevi de bitirirsen seri bonusu: <b>' + tl(streakBonus((D.streak || 0) + 1)) + '</b>');
    var html = D.tasks.map(function (t) {
      var p = Math.min(100, t.progress / t.target * 100);
      var prog = t.type === 'earn' ? tl(t.progress) + ' / ' + tl(t.target) : fmt(Math.floor(t.progress)) + ' / ' + fmt(t.target);
      return '<div class="task' + (t.done ? ' done' : '') + '"><div class="task-top"><span>' + (t.done ? '✅ ' : '🎯 ') + taskLabel(t) + '</span><b>' + prog + '</b></div>' +
        '<div class="progress"><div class="progress-fill" style="width:' + p.toFixed(1) + '%"></div></div>' +
        '<small>' + (t.done ? 'Ödül alındı: +' + tl(t.reward) : 'Ödül: yaklaşık ' + tl(taskReward())) + '</small></div>';
    }).join('');
    if (el.streakBox._html !== head) { el.streakBox.innerHTML = head; el.streakBox._html = head; }
    if (el.taskList._html !== html) { el.taskList.innerHTML = html; el.taskList._html = html; }
  }
  function renderAchievements() {
    var sig = S.achievements.join(',');
    if (sig === achSig) return;
    achSig = sig;
    el.achHead.textContent = S.achievements.length + ' / ' + ACHIEVEMENTS.length + ' başarım · kalıcı +%' + S.achievements.length + ' üretim (Yatırım Turu’nda korunur)';
    el.achGrid.innerHTML = '';
    ACHIEVEMENTS.forEach(function (a) {
      var ok = S.achievements.indexOf(a.id) !== -1;
      var c = document.createElement('div');
      c.className = 'ach ' + (ok ? 'unlocked' : 'locked');
      c.title = a.desc;
      c.innerHTML = '<div class="ach-icon"></div><div class="ach-name"></div><div class="ach-desc"></div>';
      c.querySelector('.ach-icon').textContent = ok ? a.icon : '🔒';
      c.querySelector('.ach-name').textContent = a.name;
      c.querySelector('.ach-desc').textContent = a.desc;
      el.achGrid.appendChild(c);
    });
  }
  function renderBuffs() {
    var parts = [];
    if (S.boostLeft > 0) parts.push('<span class="buff good">🔥 Acil teslim modu: tüm kazanç x2 — ' + Math.ceil(S.boostLeft) + ' sn</span>');
    S.buffs.forEach(function (b) {
      var good = b.mult >= 1;
      var eff = b.kind === 'click' ? 'tık x' + fmt(b.mult) : (b.mult === 0 ? 'üretim durdu' : 'verim ' + (good ? '+' : '-') + '%' + Math.round(Math.abs(1 - b.mult) * 100));
      parts.push('<span class="buff ' + (good ? 'good' : 'bad') + '">' + (good ? '🚀 ' : '🐢 ') + b.label + ': ' + eff + ' — ' + Math.ceil(b.left) + ' sn</span>');
    });
    var html = parts.join('');
    if (html !== el.boostBar._html) { el.boostBar.innerHTML = html; el.boostBar._html = html; }
    el.boostBar.classList.toggle('hidden', !parts.length);
  }
  function renderFal() {
    var show = has('kahve_fali') && !evs.visible && !!evs.nextId && totalOwned() >= 1;
    if (show) {
      var e = EVENT_BY_ID[evs.nextId];
      var sec = Math.max(0, Math.ceil((evs.nextAt - Date.now()) / 1000));
      var txt = '🔮 Kahve falı: sıradaki olay ' + e.icon + ' ' + e.title + ' — yaklaşık ' + fmtTime(sec) + ' sonra';
      if (el.falBar.textContent !== txt) el.falBar.textContent = txt;
    }
    el.falBar.classList.toggle('hidden', !show);
  }
  function renderSettings() {
    el.soundBtn.textContent = settings.sound ? '🔊 Ses: Açık' : '🔇 Ses: Kapalı';
    el.soundBtn.setAttribute('aria-pressed', String(settings.sound));
    el.vibBtn.textContent = settings.vibrate ? '📳 Titreşim: Açık' : '📴 Titreşim: Kapalı';
    el.vibBtn.setAttribute('aria-pressed', String(settings.vibrate));
  }
  function renderTop() {
    setCounter('money', S.money);
    setCounter('rate', tps());
    el.clickValue.textContent = '+' + tl(clickValue());
    renderBuffs();
  }
  function renderAll() {
    renderTop(); renderStage(); renderGens(); renderUpgrades(); renderFal();
    if (activeTab === 'stats') renderStats();
    if (activeTab === 'prestige') renderPrestige();
    if (activeTab === 'daily') renderDaily();
    if (activeTab === 'achievements') renderAchievements();
  }

  function floater(text, x, y, cls) {
    var f = document.createElement('div');
    f.className = 'floater' + (cls ? ' ' + cls : ''); f.textContent = text;
    f.style.left = x + 'px'; f.style.top = y + 'px';
    el.floaters.appendChild(f);
    setTimeout(function () { f.remove(); }, cls === 'crit' ? 1200 : 900);
  }
  function burst(x, y, gold) {
    if (reduceMotion) return;
    var n = gold ? 14 : 7;
    for (var i = 0; i < n; i++) {
      var p = document.createElement('div');
      p.className = 'particle' + (gold ? ' gold' : '');
      var a = Math.random() * Math.PI * 2, d = 28 + Math.random() * (gold ? 80 : 45);
      p.style.left = x + 'px'; p.style.top = y + 'px';
      p.style.setProperty('--dx', (Math.cos(a) * d).toFixed(1) + 'px');
      p.style.setProperty('--dy', (Math.sin(a) * d).toFixed(1) + 'px');
      el.floaters.appendChild(p);
      setTimeout(p.remove.bind(p), 700);
    }
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
      offer.amount = Math.max(clickValue() * 40, baseTps() * (60 + Math.random() * 60), 50) * repMult();
      el.coText.textContent = t + ' — ' + tl(offer.amount) + ' ödeme!';
    } else {
      el.coText.textContent = t + ' — 30 sn boyunca tüm kazanç x2!';
    }
    var w = window.innerWidth, h = window.innerHeight;
    var bw = Math.min(290, w - 24);
    el.clientOffer.style.left = Math.round(12 + Math.random() * Math.max(0, w - bw - 24)) + 'px';
    el.clientOffer.style.top = Math.round(80 + Math.random() * Math.max(0, h - (isMobile() ? 300 : 200))) + 'px';
    el.clientOffer.classList.remove('hidden');
    sfx('offer');
  }
  function hideOffer() { offer.visible = false; el.clientOffer.classList.add('hidden'); scheduleOffer(false); }
  function claimOffer() {
    if (!offer.visible) return;
    S.eventsClicked++;
    if (offer.kind === 'cash') { earn(offer.amount); toast('📨 Proje teslim edildi! +' + tl(offer.amount)); }
    else { S.boostLeft = 30; toast('🔥 Acil teslim modu! 30 sn boyunca tüm kazanç x2'); }
    taskProgress('offer', 1);
    sfx('buy'); vibrate(12);
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

  // Olay kartı arayüzü
  var EVENT_SHOW_MS = 25000;
  var evs = { visible: false, id: null, until: 0, nextAt: 0, nextId: null };
  function scheduleEvent(first) {
    var min = first ? 90 : 150, max = first ? 150 : 270;
    evs.nextAt = Date.now() + (min + Math.random() * (max - min)) * 1000;
    evs.nextId = pickEvent(evs.id);
  }
  function spawnEvent(id) {
    var pool = eventPool();
    if (!id || !EVENT_BY_ID[id]) {
      id = evs.nextId;
      if (!id || !pool.some(function (e) { return e.id === id; })) id = pickEvent(evs.id);
    }
    var e = EVENT_BY_ID[id];
    evs.visible = true; evs.id = id; evs.until = Date.now() + EVENT_SHOW_MS;
    el.evIcon.textContent = e.icon;
    el.evTitle.textContent = e.title;
    el.evText.textContent = typeof e.text === 'function' ? e.text() : e.text;
    el.evChoices.innerHTML = '';
    e.choices.forEach(function (c, i) {
      var b = document.createElement('button');
      b.className = 'ev-choice'; b.dataset.choice = i;
      var lb = document.createElement('b'); lb.textContent = c.label;
      var sm = document.createElement('small'); sm.textContent = typeof c.hint === 'function' ? c.hint() : c.hint;
      b.appendChild(lb); b.appendChild(sm);
      b.addEventListener('click', function () { chooseEvent(i); });
      el.evChoices.appendChild(b);
    });
    el.evLater.textContent = e.defaultChoice != null ? 'Bekle' : 'Sonra';
    el.eventCard.classList.remove('hidden');
    sfx('offer'); vibrate(15);
    return id;
  }
  function hideEvent() { evs.visible = false; el.eventCard.classList.add('hidden'); scheduleEvent(false); }
  function chooseEvent(i) {
    if (!evs.visible) return '';
    var e = EVENT_BY_ID[evs.id];
    var msg = resolveEvent(evs.id, i);
    hideEvent();
    toast(e.icon + ' ' + msg, 3800);
    renderAll();
    return msg;
  }
  function laterEvent() {
    if (!evs.visible) return;
    var e = EVENT_BY_ID[evs.id];
    if (e.defaultChoice != null) chooseEvent(e.defaultChoice);
    else hideEvent();
  }
  function updateEvent() {
    var now = Date.now();
    if (evs.visible) {
      var left = evs.until - now;
      el.evTimerFill.style.width = Math.max(0, left / EVENT_SHOW_MS * 100) + '%';
      if (left <= 0) laterEvent();
    } else if (now >= evs.nextAt && totalOwned() >= 1 && el.modal.classList.contains('hidden')) {
      spawnEvent();
    }
  }

  function drainQueue() {
    while (queue.length) {
      var n = queue.shift();
      if (n.type === 'ach') { toast('🏅 Başarım açıldı: ' + n.data.name + ' — kalıcı +%1 üretim', 3800); sfx('ach'); vibrate([10, 30, 10]); }
      else if (n.type === 'task') { toast('✅ Görev tamam: ' + taskLabel(n.data) + ' (+' + tl(n.data.reward) + ')', 3800); sfx('buy'); }
      else if (n.type === 'streak') { toast('🔥 Günlük seri ' + n.data.streak + ' gün! Seri bonusu +' + tl(n.data.bonus), 4500); sfx('stage'); }
      else if (n.type === 'newday') { toast('📅 Yeni günün görevleri hazır!' + (n.data.reset ? ' Dün görevler bitmediği için seri sıfırlandı.' : ''), 4200); }
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

  // Sekmeler ve mobil alt çubuk
  var TAB_GROUP = { upgrades: 'upgrades', daily: 'daily', achievements: 'daily', stats: 'prestige', prestige: 'prestige' };
  function selectTab(name, fromNav) {
    activeTab = name;
    document.querySelectorAll('.tabs button').forEach(function (x) { x.classList.toggle('active', x.dataset.tab === name); });
    document.querySelectorAll('.tab').forEach(function (t) { t.classList.toggle('hidden', t.id !== 'tab-' + name); });
    if (!fromNav && view !== 'kod' && view !== 'ekip') { view = TAB_GROUP[name] || view; navActive(); }
    renderAll();
  }
  function navActive() {
    document.querySelectorAll('#bottomNav button').forEach(function (b) { b.classList.toggle('active', b.dataset.view === view); });
  }
  function setView(v) {
    view = v;
    document.body.dataset.view = v;
    var side = v !== 'kod' && v !== 'ekip';
    el.panelKod.classList.toggle('mhide', v !== 'kod');
    el.stageCard.classList.toggle('mhide', v !== 'kod');
    el.panelEkip.classList.toggle('mhide', v !== 'ekip');
    el.panelSide.classList.toggle('mhide', !side);
    if (side) selectTab(v, true);
    navActive();
    if (isMobile()) window.scrollTo(0, 0);
  }

  // PWA: servis çalışanı ve güncelleme bildirimi
  function showUpdate(worker) {
    el.updateBar.classList.remove('hidden');
    el.updateBtn.onclick = function () {
      updateRequested = true; save();
      worker.postMessage('skipWaiting');
      setTimeout(function () { location.reload(); }, 3000);
    };
  }
  function initServiceWorker() {
    if (!('serviceWorker' in navigator) || !/^https?:$/.test(location.protocol)) return;
    navigator.serviceWorker.addEventListener('controllerchange', function () {
      if (!updateRequested) return;
      updateRequested = false; location.reload();
    });
    navigator.serviceWorker.register('sw.js').then(function (reg) {
      Core.swRegistration = reg;
      function watch(w) {
        w.addEventListener('statechange', function () {
          if (w.state === 'installed' && navigator.serviceWorker.controller) showUpdate(w);
        });
      }
      if (reg.waiting && navigator.serviceWorker.controller) showUpdate(reg.waiting);
      if (reg.installing) watch(reg.installing);
      reg.addEventListener('updatefound', function () { if (reg.installing) watch(reg.installing); });
      setInterval(function () { reg.update().catch(function () {}); }, 30 * 60 * 1000);
    }).catch(function () {});
  }

  function init() {
    ['money', 'rate', 'stageCard', 'stageIcon', 'stageName', 'stageDesc', 'stageBonus', 'stageProgress', 'stageNext',
      'repChip', 'achChip', 'streakChip', 'boostBar', 'falBar', 'clickBtn', 'clickValue', 'floaters', 'genList', 'upgList',
      'upgBadge', 'navUpgBadge', 'statsList', 'saveBtn', 'resetBtn', 'saveNote', 'soundBtn', 'vibBtn', 'prShares', 'prBonus',
      'prGain', 'prNext', 'prestigeBtn', 'streakBox', 'taskList', 'achHead', 'achGrid', 'clientOffer', 'coText', 'coTimerFill',
      'eventCard', 'evIcon', 'evTitle', 'evText', 'evChoices', 'evLater', 'evTimerFill', 'toast', 'updateBar', 'updateBtn',
      'modal', 'modalEmoji', 'modalTitle', 'modalText', 'modalActions', 'panelKod', 'panelEkip', 'panelSide', 'bottomNav'
    ].forEach(function (id) { el[id] = $(id); });

    var offlineRes = load();
    lastStageShown = stageIndex(S.runEarned);
    S.stage = Math.max(S.stage, lastStageShown);
    checkDaily();
    var retro = checkAchievements();
    queue = queue.filter(function (n) { return n.type !== 'ach' && n.type !== 'newday'; });
    buildGenList();
    setCounter('money', S.money, true);
    setCounter('rate', tps(), true);

    el.clickBtn.addEventListener('click', function (e) {
      var v = doClick();
      var crit = Core.lastCrit;
      var rect = el.floaters.getBoundingClientRect();
      var x = (e.clientX || rect.left + rect.width / 2) - rect.left;
      var y = (e.clientY || rect.top + rect.height / 2) - rect.top;
      floater((crit ? 'KRİTİK! +' : '+') + tl(v), x + (Math.random() * 30 - 15), y - 20, crit ? 'crit' : '');
      burst(x, y, crit);
      sfx(crit ? 'crit' : 'click');
      vibrate(crit ? 25 : 10);
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
      b.addEventListener('click', function () { selectTab(b.dataset.tab); });
    });
    document.querySelectorAll('#bottomNav button').forEach(function (b) {
      b.addEventListener('click', function () { setView(b.dataset.view); });
    });
    el.clientOffer.addEventListener('click', claimOffer);
    el.evLater.addEventListener('click', laterEvent);
    el.saveBtn.addEventListener('click', function () { save(); toast('💾 Oyun kaydedildi'); });
    el.soundBtn.addEventListener('click', function () {
      settings.sound = !settings.sound; saveSettings(); renderSettings();
      if (settings.sound) sfx('buy');
    });
    el.vibBtn.addEventListener('click', function () {
      settings.vibrate = !settings.vibrate; saveSettings(); renderSettings();
      if (settings.vibrate) vibrate(15);
    });
    el.resetBtn.addEventListener('click', function () {
      modal({
        emoji: '⚠️', title: 'Kaydı sıfırla?',
        html: 'Tüm ilerlemen, çalışanların, geliştirmelerin, başarımların ve yatırımcı hisselerin <b>kalıcı olarak silinecek</b>. Bu işlem geri alınamaz.' +
          (Core.cloudSignedIn && Core.cloudSignedIn() ? '<br><small>Giriş yaptığın için buluttaki kaydın da silinecek.</small>' : ''),
        buttons: [
          { label: 'Vazgeç', cls: 'ghost' },
          { label: 'Evet, sıfırla', cls: 'danger', onClick: function () {
            resetting = true;
            try { localStorage.removeItem(SAVE_KEY); LEGACY_KEYS.forEach(function (k) { localStorage.removeItem(k); }); } catch (e) {}
            var done = false;
            var go = function () { if (!done) { done = true; location.reload(); } };
            // Girişliyse buluttaki kayıt da silinir (en fazla 4 sn beklenir)
            var p = null;
            try { p = typeof Core.beforeReset === 'function' ? Core.beforeReset() : null; } catch (e) { p = null; }
            if (p && typeof p.then === 'function') { p.then(go, go); setTimeout(go, 4000); } else go();
          } }
        ]
      });
    });
    el.prestigeBtn.addEventListener('click', function () {
      var g = sharesGain();
      if (g < 1) return;
      modal({
        emoji: '💰', title: 'Yatırım turuna çık?',
        html: 'Yatırımcılar şirketine <b>' + fmt(g) + ' hisse</b> karşılığında yatırım yapacak. Paran, çalışanların ve geliştirmelerin sıfırlanır; karşılığında tüm kazançlara kalıcı <b>+%' + fmt(g * SHARE_BONUS * 100) + '</b> bonus alırsın. Başarımların, itibarın ve günlük serin korunur.',
        buttons: [
          { label: 'Vazgeç', cls: 'ghost' },
          { label: 'Anlaştık!', cls: 'primary', onClick: function () {
            doPrestige(); lastStageShown = 0; upgSig = ''; save(); renderAll();
            toast('🚀 Yatırım turu tamamlandı! Yeni bir başlangıç.'); sfx('stage');
          } }
        ]
      });
    });

    window.addEventListener('beforeunload', save);
    window.addEventListener('pagehide', save);
    document.addEventListener('visibilitychange', function () { if (document.hidden) save(); });

    var last = Date.now(), slow = 0;
    setInterval(function () {
      var now = Date.now();
      var dt = Math.min((now - last) / 1000, OFFLINE_CAP_SEC);
      last = now;
      tick(dt);
      updateOffer();
      updateEvent();
      if (++slow >= 10) { slow = 0; checkDaily(); }
      checkAchievements();
      drainQueue();
      renderAll();
    }, 100);
    setInterval(save, AUTOSAVE_MS);

    scheduleOffer(true);
    scheduleEvent(true);
    setView('kod');
    selectTab('upgrades', true);
    renderSettings();
    renderAll();
    showWelcomeBack(offlineRes);
    if (offlineRes && offlineRes.migrated) toast('📦 Kaydın yeni sürüme taşındı. Hoş geldin, Kodhane v2!', 4500);
    if (retro.length) toast('🏅 ' + retro.length + ' başarım açıldı! Her biri kalıcı +%1 üretim.', 4500);
    save();
    initServiceWorker();
  }

  // Test ve hata ayıklama için
  root.Kodhane = Core;
  Core.save = save; Core.load = load; Core.renderAll = renderAll; Core.spawnOffer = spawnOffer; Core.claimOffer = claimOffer;
  Core.spawnEvent = spawnEvent; Core.chooseEvent = chooseEvent; Core.laterEvent = laterEvent; Core.setView = setView; Core.selectTab = selectTab;
  Core.eventState = evs; Core.getSettings = function () { return settings; };
  Core.SAVE_KEY = SAVE_KEY; Core.LEGACY_KEYS = LEGACY_KEYS; Core.SETTINGS_KEY = SETTINGS_KEY;
  Core.applySave = applySave; Core.toast = toast; Core.isResetting = function () { return resetting; };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})(typeof window !== 'undefined' ? window : this);
