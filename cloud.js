/* Kodhane bulut kaydı (Supabase, isteğe bağlı giriş)
 *
 * - Misafirler hiçbir şey indirmez; kayıt yalnızca bu cihazda (localStorage) tutulur.
 * - supabase-js yalnızca gerektiğinde (kayıtlı oturum, e-postadaki giriş bağlantısından dönüş
 *   veya Hesap penceresi açıldığında) sabitlenmiş jsDelivr adresinden, SRI doğrulamasıyla yüklenir.
 * - CDN ya da Supabase erişilemezse oyun misafir gibi çalışmaya devam eder.
 * - Çakışma kuralı: toplam (ömür boyu) kazancı büyük olan kayıt kazanır; eşitse daha yeni olan.
 *   v4.2: buluttaki satırın revision'ı bu cihazın son gördüğünden büyükse bulut kazanır (toplam kazanca bakılmaz).
 *   Kaybeden kayıt 'kodhane_ajans_save_backup' anahtarına yedeklenir.
 *
 * Buradaki anahtar Supabase'in herkese açık (publishable/anon) anahtarıdır; istemcide bulunması
 * tasarım gereğidir. Veri erişimi veritabanındaki RLS kurallarıyla (auth.uid() = user_id) korunur.
 *
 * ---------------------------------------------------------------------------------------------------
 * v4.2 SUNUCU SÖZLEŞMESİ (Backend v2.2: acik-ofis-v2.2-backend 682f68d,
 *   docs/v2.2-backend-client-notes.md + supabase/migrations/20260928160000_v2_2_kodhane_save_safety.sql)
 * BU İSTEMCİ O MIGRATION İLE BİRLİKTE YAYINLANMALI: migration'dan önce 'revision' sütunu ve RPC'ler yok (yazma/sıfırlama
 * hata verir); migration'dan sonra eski istemcinin DELETE'i 403 alır ve sıfırlama fiilen geri alınır.
 *
 *  Tablo kodhane_saves: revision bigint, best_score / best_stage (yalnız artar; sıralama; sıfırlamada kalır),
 *  strict_revision (sunucu). İstemci best_score/best_stage/strict_revision yazamaz; DELETE yasak (42501).
 *  Yazma (upsert): Prefer return=representation + select=revision; gövdede revision = L + 1.
 *  Başarıda L = sunucunun DÖNDÜRDÜĞÜ revision (gönderilen değil): lenient satırda pull→push arasına eski istemci
 *  yazarsa eşit revision kabul edilir (eski+1), satır lenient kalır; döneni almazsak bir geride takılırız.
 *    revision < sunucu                       -> HTTP 409 {code:'PT409', message:'stale_revision', details, hint}
 *    revision = sunucu (strict satır/mod)    -> HTTP 409 {code:'PT409', message:'stale_revision'}
 *    revision = sunucu (lenient, eski istemci) ve totalEarned düşüyor -> HTTP 409 {code:'PT409', message:'stale_write'}
 *    409 alınca: kaydı bir kez yükle, hold (gerçek oyuncu girdisine kadar push yok); ping-pong yok.
 *  Tek yazan sekme (TabGate): yalnız görünür/odaklı/son etkileşimli sekme yazar (yerel + bulut).
 *  RPC adları tek yerde: aşağıdaki RPC sabiti (kodhane_reset_save / kodhane_restore_save / kodhane_list_save_backups).
 *  Kodhane'ye özel yedek tablosu: kodhane_save_backups; ayarlar: kodhane_game_config. Yanıtlarda 'game' alanı YOK.
 *  rpc kodhane_reset_save()                 -> {revision, backup_id, best_score, best_stage}
 *    Satır silinmez: mevcut satır yedeklenir (reason 'reset'), data sıfırlanmış yükle değişir (resetAt dahil),
 *    revision + 1. Satır yoksa {revision:0, backup_id:null}. Revision parametresi/bayatlık kontrolü yok.
 *  rpc kodhane_restore_save({p_backup_id})  -> {revision, backup_id, restored_from, best_score, best_stage}
 *    Önce mevcut durum yedeklenir (reason 'restore'), yedek yükü yazılır, revision + 1. Veri DÖNMEZ: ardından satır çekilir.
 *    Kendi yedeğin değilse / süresi geçtiyse HTTP 404 {code:'PT404', message:'backup_not_found'}.
 *  rpc kodhane_list_save_backups()          -> [{id, revision, reason, score, best_score, stage, best_stage, created_at, expires_at}]
 *    (yeniden eskiye)
 *  best_score / best_stage istemci tarafından yazılamaz (42501); sıralama bunlardan okunur (sıralama istemcisi değişmedi).
 *  Yedek saklama süresi: kodhane_game_config.backup_retention_days (varsayılan 30 gün) = game.js CFG.reset.backupDays (v4.4: oyuncu metinlerinde gösterilmez).
 *  Diğer hatalar: 42501 not_authenticated.
 *
 *  CFG.transport: 'supabase' (varsayılan, gerçek sunucu) | 'mock' (yalnızca test/geliştirme: aynı kuralları ve aynı
 *  hata kodlarını/biçimlerini localStorage üzerinde taklit eder; aynı tarayıcıdaki sekmeler BroadcastChannel ile haberleşir).
 * ---------------------------------------------------------------------------------------------------
 */
(function (root) {
  'use strict';

  // Kayıt RPC adları: TEK YER. Çağrı noktaları adları buradan (CFG.rpc) okur; sahte sunucu da aynı adları kullanır.
  // Kodhane ve Açık Ofis ayrı Supabase'lere taşındığı için oyuna özel fonksiyonlar (p_game parametresi yok).
  var RPC = {
    reset: 'kodhane_reset_save',              // () -> {revision, backup_id, best_score, best_stage}
    restore: 'kodhane_restore_save',          // ({p_backup_id}) -> {revision, backup_id, restored_from, best_score, best_stage}
    listBackups: 'kodhane_list_save_backups'  // () -> [{id, revision, reason, score, best_score, stage, best_stage, created_at, expires_at}]
  };

  // ================================================================ SAHTE SUNUCU (test/geliştirme taşıyıcısı)
  // v2.2 migration'ındaki save_before_write tetikleyicisini ve reset_save / restore_save / list_save_backups
  // fonksiyonlarını taklit eder. Dönüş biçimi supabase-js ile aynıdır: {data, error, status};
  // error = {code, message, details, hint} (PostgREST hata gövdesi).
  function createSaveMock(opts) {
    opts = opts || {};
    var storage = opts.storage || (typeof localStorage !== 'undefined' ? localStorage : null);
    var KEY = opts.key || 'kodhane_save_mock_v1';
    var now = opts.now || function () { return Date.now(); };
    var DAY = 86400000;
    var chan = null;
    try { if (opts.channel !== false && typeof BroadcastChannel !== 'undefined') chan = new BroadcastChannel(KEY); } catch (e) { chan = null; }
    var TABLES = { kodhane: 'kodhane_saves' };
    var NAMES = opts.rpc || RPC;
    function cfg() {
      var d = load().config || {};
      return { retentionDays: d.retentionDays || opts.retentionDays || 30, maxBackups: d.maxBackups || opts.maxBackups || 50,
        mode: d.mode || opts.mode || 'lenient' };
    }
    function load() { try { return JSON.parse(storage.getItem(KEY) || 'null') || { rows: {}, backups: [] }; } catch (e) { return { rows: {}, backups: [] }; } }
    function store(db) { storage.setItem(KEY, JSON.stringify(db)); }
    function res(data, status) { return later({ data: data === undefined ? null : data, error: null, status: status || 200 }); }
    function fail(status, code, message, details, hint) {
      return later({ data: null, error: { code: code, message: message, details: details || null, hint: hint || null }, status: status });
    }
    function later(v) { return new Promise(function (r) { setTimeout(function () { r(v); }, opts.latencyMs || 0); }); }
    function uuid() {
      return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
        var r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 3 | 8)).toString(16);
      });
    }
    function score(d) { var t = d && d.totalEarned; return typeof t === 'number' && isFinite(t) && t >= 0 ? t : 0; }
    function stage(d) { var st = d && d.stage; return typeof st === 'number' && isFinite(st) ? Math.min(99, Math.max(0, Math.floor(st))) : 0; }
    // kodhane_save_stage_checked: aşama, kazanç o aşamanın eşiğine hiç ulaşmadıysa 0 (makullük kontrolü taklit edilmez)
    var STAGE_AT = [0, 1e3, 5e4, 1e6, 5e7, 2.5e9, 1e15, 1e19, 1e23];
    function stageChecked(d) { var st = stage(d), sc = score(d); return st === 0 || sc <= 0 || st > 8 || sc < STAGE_AT[st] ? 0 : st; }
    function rowKey(game, uid) { return game + ':' + uid; }
    function iso(ms) { return new Date(ms).toISOString(); }
    function alive(b) { return Date.parse(b.created_at) > now() - cfg().retentionDays * DAY; }
    function resetPayload(game, old, ms) {
      old = old || {};
      if (game === 'kodhane') {
        return { version: typeof old.version === 'number' ? old.version : 4, startedAt: ms, lastSaved: ms, resetAt: ms,
          money: 0, runEarned: 0, totalEarned: 0, cycleEarned: 0, clicks: 0, clickEarned: 0, playTime: 0, eventsClicked: 0, offlineEarned: 0,
          gens: {}, upgrades: [], achievements: [], shares: 0, prestigeCount: 0, cycleRounds: 0,
          ipoShares: 0, ipoSharesEarned: 0, ipoCount: 0, tree: [], stage: 0, stageBest: 0, cycleStage: 0,
          reputation: 0, boostLeft: 0, buffs: [], critClicks: 0, eventsResolved: 0, logoAccepted: 0, revisions: 0, meetings: 0, serverCrashes: 0,
          noMeetingSec: 0, daily: { date: null, tasks: [], streak: 0, best: 0, lastComplete: null, allDone: false, daysCompleted: 0 },
          newsSeen: Array.isArray(old.newsSeen) ? old.newsSeen : [], newsPending: [], sectorCool: {}, followUps: { kafe: 0, emlak: 0 }, pendingPay: [] };
      }
      return { resetAt: ms, totalEarned: 0 };
    }
    function trim(db, uid, game) {
      var c = cfg();
      var mine = db.backups.filter(function (b) { return b.user_id === uid && b.game === game && alive(b); })
        .sort(function (a, b) { return Date.parse(b.created_at) - Date.parse(a.created_at); }).slice(0, c.maxBackups);
      var keep = {}; mine.forEach(function (b) { keep[b.id] = 1; });
      db.backups = db.backups.filter(function (b) { return !(b.user_id === uid && b.game === game) || keep[b.id]; });
    }
    function backup(db, uid, game, row, reason) {
      var b = { id: uuid(), user_id: uid, game: game, revision: row.revision, payload: row.data, best_score: row.best_score,
        best_stage: row.best_stage || 0, reason: reason,
        created_at: iso(now() + db.backups.length * 0.001) };
      db.backups.push(b);
      return b;
    }
    function stale(sent, cur, message) {
      return fail(409, 'PT409', message || 'stale_revision', 'sent revision ' + sent + ', server revision ' + cur,
        message === 'stale_write' ? 'Use kodhane_reset_save() to start over; pull the save before writing.' : 'Pull the save again and send revision = server revision + 1.');
    }
    function notify(msg) { if (chan) { try { chan.postMessage(msg); } catch (e) {} } }
    var api = {
      KEY: KEY,
      // GET /rest/v1/kodhane_saves?select=data,save_version,updated_at,revision,best_score,best_stage&user_id=eq.<uid>
      select: function (uid, game) {
        var r = load().rows[rowKey(game || 'kodhane', uid)];
        return res(r ? { data: r.data, save_version: r.save_version, updated_at: r.updated_at, revision: r.revision, best_score: r.best_score, best_stage: r.best_stage || 0 } : null);
      },
      // POST /rest/v1/kodhane_saves (upsert, on_conflict=user_id) -> save_before_write
      upsert: function (uid, row, game) {
        game = game || 'kodhane';
        if (!uid) return fail(401, '42501', 'permission denied for table ' + TABLES[game]);
        if (!row || row.user_id !== uid) return fail(403, '42501', 'new row violates row-level security policy for table "' + TABLES[game] + '"');
        if ('best_score' in row || 'best_stage' in row || 'strict_revision' in row) return fail(403, '42501', 'permission denied for table ' + TABLES[game]);
        var db = load(), k = rowKey(game, uid), old = db.rows[k];
        var sent = typeof row.revision === 'number' ? row.revision : null;
        if (!old) {
          var rev0 = Math.max(sent || 0, 0);
          var prev = 0, prevSt = 0;
          db.backups.forEach(function (b) { if (b.user_id === uid && b.game === game) { prev = Math.max(prev, b.best_score || 0); prevSt = Math.max(prevSt, b.best_stage || 0); } });
          db.rows[k] = { data: row.data, save_version: row.save_version, updated_at: row.updated_at || iso(now()), revision: rev0,
            strict_revision: rev0 > 0, best_score: Math.max(score(row.data), prev), best_stage: Math.max(stageChecked(row.data), prevSt) };
          store(db);
          return res({ revision: rev0 }, 201);
        }
        var rev = sent === null ? old.revision : sent, strict;
        if (rev < old.revision) return stale(rev, old.revision);
        if (rev === old.revision) {
          if (old.strict_revision || cfg().mode === 'strict') return stale(rev, old.revision);
          if (score(row.data) < score(old.data)) return stale(rev, old.revision, 'stale_write');
          rev = old.revision + 1; strict = false;
        } else strict = true;
        db.rows[k] = { data: row.data, save_version: row.save_version, updated_at: row.updated_at || iso(now()), revision: rev,
          strict_revision: strict, best_score: Math.max(old.best_score || 0, score(row.data)),
          best_stage: Math.max(old.best_stage || 0, stageChecked(row.data)) };
        store(db);
        return res({ revision: rev }, 201);
      },
      // DELETE /rest/v1/kodhane_saves: v2.2'de istemciye kapalı
      remove: function (uid, game) { return fail(403, '42501', 'permission denied for table ' + TABLES[game || 'kodhane']); },
      // POST /rest/v1/rpc/<name>
      rpc: function (uid, name, args) {
        args = args || {};
        if (!uid) return fail(401, '42501', 'permission denied for function ' + name);
        var db = load(), g, k, row, b;
        if (name === NAMES.reset) {
          g = 'kodhane';
          k = rowKey(g, uid); row = db.rows[k];
          if (!row) return res({ revision: 0, backup_id: null, best_score: 0, best_stage: 0 });
          b = backup(db, uid, g, row, 'reset');
          row.data = resetPayload(g, row.data, Math.floor(now()));
          row.revision += 1; row.strict_revision = true; row.updated_at = iso(now());
          trim(db, uid, g); store(db);
          notify({ type: 'reset', uid: uid, game: g, revision: row.revision });
          return res({ revision: row.revision, backup_id: b.id, best_score: row.best_score, best_stage: row.best_stage || 0 });
        }
        if (name === NAMES.restore) {
          var src = null;
          db.backups.forEach(function (x) { if (x.id === args.p_backup_id && x.user_id === uid && alive(x)) src = x; });
          if (!src) return fail(404, 'PT404', 'backup_not_found');
          g = src.game; k = rowKey(g, uid); row = db.rows[k];
          var bid = null, rev;
          if (row) {
            bid = backup(db, uid, g, row, 'restore').id;
            rev = row.revision + 1;
            row.data = src.payload; row.revision = rev; row.strict_revision = true; row.updated_at = iso(now());
            row.save_version = src.payload && typeof src.payload.version === 'number' ? src.payload.version : 2;
          } else {
            rev = src.revision + 1;
            var pb = 0, ps = 0;
            db.backups.forEach(function (x) { if (x.user_id === uid && x.game === g) { pb = Math.max(pb, x.best_score || 0); ps = Math.max(ps, x.best_stage || 0); } });
            db.rows[k] = row = { data: src.payload, save_version: src.payload && typeof src.payload.version === 'number' ? src.payload.version : 2,
              updated_at: iso(now()), revision: rev, strict_revision: true, best_score: pb, best_stage: ps };
          }
          row.best_score = Math.max(row.best_score || 0, score(src.payload));
          row.best_stage = Math.max(row.best_stage || 0, stageChecked(src.payload));
          trim(db, uid, g); store(db);
          notify({ type: 'restore', uid: uid, game: g, revision: rev });
          return res({ revision: rev, backup_id: bid, restored_from: src.id, best_score: row.best_score, best_stage: row.best_stage });
        }
        if (name === NAMES.listBackups) {
          g = 'kodhane';
          var ret = cfg().retentionDays * DAY;
          var list = db.backups.filter(function (x) { return x.user_id === uid && alive(x) && (!g || x.game === g); })
            .sort(function (a, c) { return Date.parse(c.created_at) - Date.parse(a.created_at) || (a.id < c.id ? 1 : -1); })
            .map(function (x) {
              return { id: x.id, revision: x.revision, reason: x.reason, score: score(x.payload), best_score: x.best_score || 0,
                stage: stage(x.payload), best_stage: x.best_stage || 0, created_at: x.created_at, expires_at: iso(Date.parse(x.created_at) + ret) };
            });
          return res(list);
        }
        return fail(404, 'PGRST202', 'Could not find the function public.' + name);
      },
      onMessage: function (fn) { if (chan) chan.onmessage = function (e) { fn(e.data); }; },
      _db: load, _store: store
    };
    return api;
  }

  // v4.2: yalnız BİR sekme yazar (yerel + bulut). Son gösterilen/odaklanan/dokunulan sekme WRITER_KEY'i tutar;
  // diğerleri duraklar. Yazıcı olunca önceki yazıcının bıraktığı kaydı alır (onClaim).
  var WRITER_KEY = 'kodhane_tab_writer_v1';
  function rid() { return Math.random().toString(36).slice(2) + Date.now().toString(36); }
  function TabGate(opts) {
    opts = opts || {};
    this.storage = opts.storage || (typeof localStorage !== 'undefined' ? localStorage : null);
    this.doc = opts.doc !== undefined ? opts.doc : (typeof document !== 'undefined' ? document : null);
    this.win = opts.win !== undefined ? opts.win : (typeof window !== 'undefined' ? window : null);
    this.id = opts.id || rid();
    this.now = opts.now || function () { return Date.now(); };
    this.claimListeners = [];
    var self = this;
    if (this.win && this.win.addEventListener) {
      var shown = function () { if (self.visible()) self.claim(); };
      this.win.addEventListener('focus', function () { self.claim(); });
      this.win.addEventListener('pageshow', shown);
      if (this.doc && this.doc.addEventListener) this.doc.addEventListener('visibilitychange', shown);
      ['pointerdown', 'keydown'].forEach(function (ev) {
        self.win.addEventListener(ev, function (e) { if (!e || e.isTrusted !== false) self.claim(); }, { capture: true, passive: true });
      });
    }
    if (this.visible()) this.claim();
  }
  TabGate.prototype.onClaim = function (fn) {
    this.claimListeners.push(fn);
    var self = this;
    return function () { self.claimListeners = self.claimListeners.filter(function (f) { return f !== fn; }); };
  };
  TabGate.prototype.visible = function () { return !this.doc || !this.doc.hidden; };
  TabGate.prototype.read = function () {
    if (!this.storage) return undefined;
    try { var v = JSON.parse(this.storage.getItem(WRITER_KEY) || 'null'); return v && typeof v === 'object' ? v : null; } catch (e) { return undefined; }
  };
  TabGate.prototype.claim = function () {
    var cur = this.read();
    if (cur === undefined) return false;
    if (cur && cur.id === this.id) return false;
    try { this.storage.setItem(WRITER_KEY, JSON.stringify({ id: this.id, at: this.now() })); } catch (e) { return false; }
    for (var i = 0; i < this.claimListeners.length; i++) { try { this.claimListeners[i](); } catch (e) {} }
    return true;
  };
  TabGate.prototype.isWriter = function () {
    var cur = this.read();
    if (cur === undefined) return true;
    if (!cur || !cur.id) { if (this.visible()) { this.claim(); return true; } return false; }
    return cur.id === this.id;
  };
  TabGate.prototype.canPush = function (final) { return this.isWriter() && (final || this.visible()); };
  TabGate.prototype.release = function () {
    var cur = this.read();
    if (cur && cur.id === this.id) { try { this.storage.removeItem(WRITER_KEY); } catch (e) {} }
  };
  // 409 sonrası: yüklenen kayıt sıfırlama mı, yoksa eşzamanlı oyun mu? (startedAt daha yeni / boş = reset)
  function staleKind(mine, data) {
    if (!data || typeof data !== 'object' || !Object.keys(data).length) return 'reset';
    var a = +data.startedAt || 0, b = +(mine && mine.startedAt) || 0;
    return a > b + 1000 ? 'reset' : 'sync';
  }
  root.KodhaneSaveMock = createSaveMock;
  root.KodhaneTabGate = TabGate;
  if (typeof module !== 'undefined' && module.exports && typeof document === 'undefined') {
    module.exports = { createSaveMock: createSaveMock, RPC: RPC, TabGate: TabGate, WRITER_KEY: WRITER_KEY, staleKind: staleKind };
    return;
  }

  var K = root.Kodhane;
  if (!K || typeof document === 'undefined') return;

  var CFG = {
    url: 'https://kodhane-api.teserix.com',
    key: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpYXQiOjE3OTA1NjI1NzAsImV4cCI6MTg5MzQ1NjAwMCwicm9sZSI6ImFub24iLCJpc3MiOiJzdXBhYmFzZSJ9._ugMmDZoHw2uolYZUT5xeQbM3xiZnoCu9WZUv5-iNjk',
    sdk: 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.2/dist/umd/supabase.js',
    sri: 'sha384-Rj26LVGvoeRVR6+mwQmFfcR3QOBEwT+ZmuCWpuiqeTzJpCs0ER4ITAWGb4Hiy3Ok',
    storageKey: 'kodhane_auth_v1',
    table: 'kodhane_saves',
    pushDelayMs: 45000,
    sdkTimeoutMs: 15000
  };
  // Testler için geçersiz kılma (ör. sahte Supabase adresi)
  if (root.KODHANE_CLOUD_CONFIG && typeof root.KODHANE_CLOUD_CONFIG === 'object') {
    for (var ck in root.KODHANE_CLOUD_CONFIG) CFG[ck] = root.KODHANE_CLOUD_CONFIG[ck];
  }
  var BACKUP_KEY = 'kodhane_ajans_save_backup';
  // Kod bekleme adımı (ör. iPhone ana ekran uygulaması e-postaya geçerken kapanırsa) kısa süre hatırlanır.
  var PENDING_KEY = 'kodhane_auth_pending';
  var PENDING_TTL_MS = 60 * 60 * 1000;
  // Supabase Cloud (*.supabase.co/in) ya da Teserix'te Kodhane'nin kendi Supabase'i (kodhane-api.teserix.com; eski adı supabase.teserix.com da geçerli)
  var configured = /^https:\/\/([a-z0-9-]+\.supabase\.(co|in)|(kodhane-api|supabase)\.teserix\.com)$/.test(CFG.url) && CFG.key.indexOf('__') !== 0 ||
    !!(root.KODHANE_CLOUD_CONFIG && root.KODHANE_CLOUD_CONFIG.url);

  var C = {
    client: null, user: null, sdkPromise: null, clientPromise: null,
    reconciled: false, reconciling: false, pushTimer: null, pushing: null,
    lastPushAt: 0, lastPushSig: '', status: 'guest', message: '', keepalive: false, cooldownUntil: 0,
    pendingEmail: '', verifying: false, tick: null
  };
  var el = {};
  var startAuthError = authErrorFromUrl();

  // ---------------------------------------------------------------- v4.2 kayıt güvenliği ayarları
  // (Sunucu adresi/anahtarı yukarıdaki mevcut CFG'den okunur; burada adres yok.)
  CFG.rpc = Object.assign({}, RPC, CFG.rpc || {});        // RPC adları (tek yer: dosya başındaki RPC); test geçersiz kılabilir
  if (CFG.transport !== 'mock') CFG.transport = 'supabase'; // 'supabase' (varsayılan) | 'mock' (yalnızca test/geliştirme)
  var REV_KEY = 'kodhane_cloud_rev_v1';  // {uid, rev}: bu cihazın bu hesap için son gördüğü sunucu revision'ı
  C.rev = 0; C.revUid = null; C.staleAt = []; C.mock = null; C.held = false;
  var gate = new TabGate();
  K.tabGate = gate;
  function hold() { C.held = true; clearPushTimer(); }
  function releaseHold() { if (!C.held) return; C.held = false; schedulePush(); }
  if (typeof window !== 'undefined') {
    ['pointerdown', 'keydown', 'touchstart'].forEach(function (ev) {
      window.addEventListener(ev, function (e) { if (e && e.isTrusted) releaseHold(); }, { capture: true, passive: true });
    });
  }
  gate.onClaim(function () {
    // Yazıcı olunca önceki yazıcının bıraktığı yerel kaydı al; bulut imzasını sıfırla ki bir sonraki push güncel olsun.
    try {
      var raw = lsGet((K.SAVE_KEY) || 'kodhane_ajans_save_v2');
      if (raw && raw !== K.lastWritten && K.applySave) {   // bu sekmenin kendi yazdığıysa devralınacak bir şey yok
        var d = JSON.parse(raw); if (d && typeof d === 'object') { K.applySave(d); C.lastPushSig = ''; }
      }
    } catch (e) {}
  });

  // ---------------------------------------------------------------- yardımcılar
  function num(x) { return typeof x === 'number' && isFinite(x) ? x : 0; }
  // v4.3.1 ileri sürüm koruması (game.js writesBlocked): bu istemciden daha yeni biçimde bir kayıt okunduysa hiçbir bulut
  // yazması (upsert, sıfırlama/geri yükleme RPC'si) ve kayıt yedeği yapılmaz.
  function blocked() { return !!(K.writesBlocked && K.writesBlocked()); }
  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function hhmm(t) { var d = new Date(t); return pad(d.getHours()) + ':' + pad(d.getMinutes()); }
  function sig(s) {
    var c = {};
    for (var k in s) if (k !== 'lastSaved') c[k] = s[k];
    try { return JSON.stringify(c); } catch (e) { return String(Math.random()); }
  }
  function track(name) { if (K && typeof K.track === 'function') K.track(name); }
  function lsGet(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
  function lsSet(k, v) { try { localStorage.setItem(k, v); return true; } catch (e) { return false; } }
  function toast(msg, ms) { if (K.toast) { try { K.toast(msg, ms); } catch (e) {} } }
  function online() { return !('onLine' in navigator) || navigator.onLine !== false; }
  function urlHasAuth() {
    return /(^|[#&])(access_token|refresh_token|error|error_code|error_description)=/.test(location.hash) ||
      /[?&](code|error|error_code|error_description)=/.test(location.search);
  }
  function hasStoredSession() { return !!lsGet(CFG.storageKey); }
  function setPending(email) {
    C.pendingEmail = email || '';
    try {
      if (email) localStorage.setItem(PENDING_KEY, JSON.stringify({ email: email, at: Date.now() }));
      else localStorage.removeItem(PENDING_KEY);
    } catch (e) {}
  }
  function loadPending() {
    try {
      var p = JSON.parse(lsGet(PENDING_KEY) || 'null');
      if (p && typeof p.email === 'string' && Date.now() - num(p.at) < PENDING_TTL_MS) return p.email;
      if (p) localStorage.removeItem(PENDING_KEY);
    } catch (e) {}
    return '';
  }
  function redirectUrl() { return location.origin + location.pathname.replace(/index\.html$/, ''); }
  function cleanUrl() {
    // supabase-js hash'i boşaltır ama adres çubuğunda '#' kalır; ikisini de temizle.
    if (!urlHasAuth() && location.href.indexOf('#') === -1) return;
    try { history.replaceState(null, document.title, location.pathname); } catch (e) {}
  }
  function authErrorFromUrl() {
    var src = location.hash.replace(/^#/, '') + '&' + location.search.replace(/^\?/, '');
    var m = /(?:^|&)error_code=([^&]*)/.exec(src) || /(?:^|&)error=([^&]*)/.exec(src);
    return m ? decodeURIComponent(m[1].replace(/\+/g, ' ')) : '';
  }

  // ---------------------------------------------------------------- SDK ve istemci
  function loadSdk() {
    if (root.supabase && typeof root.supabase.createClient === 'function') return Promise.resolve(root.supabase);
    if (C.sdkPromise) return C.sdkPromise;
    if (!online()) return Promise.reject(new Error('offline'));
    C.sdkPromise = new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      var timer = setTimeout(function () { reject(new Error('sdk-timeout')); }, CFG.sdkTimeoutMs);
      s.src = CFG.sdk;
      if (CFG.sri) { s.integrity = CFG.sri; s.crossOrigin = 'anonymous'; }
      s.async = true;
      s.onload = function () {
        clearTimeout(timer);
        if (root.supabase && typeof root.supabase.createClient === 'function') resolve(root.supabase);
        else reject(new Error('sdk-missing'));
      };
      s.onerror = function () { clearTimeout(timer); reject(new Error('sdk-load')); };
      document.head.appendChild(s);
    });
    C.sdkPromise.catch(function () { C.sdkPromise = null; });
    return C.sdkPromise;
  }
  function keepaliveFetch(input, init) {
    init = init || {};
    if (C.keepalive) { var o = {}; for (var k in init) o[k] = init[k]; o.keepalive = true; init = o; }
    return fetch(input, init);
  }
  function getClient() {
    if (C.client) return Promise.resolve(C.client);
    if (!configured) return Promise.reject(new Error('not-configured'));
    if (C.clientPromise) return C.clientPromise;
    C.clientPromise = loadSdk().then(function (sb) {
      if (C.client) return C.client;
      C.client = sb.createClient(CFG.url, CFG.key, {
        auth: {
          storageKey: CFG.storageKey, persistSession: true, autoRefreshToken: true,
          detectSessionInUrl: true, flowType: 'implicit'
        },
        global: { fetch: keepaliveFetch }
      });
      C.client.auth.onAuthStateChange(function (event, session) {
        // Supabase önerisi: geri çağrının içinde başka Supabase çağrısı bekleme; sıraya al.
        setTimeout(function () { onAuth(event, session); }, 0);
      });
      return C.client;
    });
    C.clientPromise.catch(function () { C.clientPromise = null; });
    return C.clientPromise;
  }

  // ---------------------------------------------------------------- oturum
  function onAuth(event, session) {
    var user = session && session.user ? session.user : null;
    if (event === 'INITIAL_SESSION' || event === 'SIGNED_IN') {
      var err = startAuthError || authErrorFromUrl();
      startAuthError = '';
      cleanUrl();
      if (!user && err) {
        setStatus('guest', /expired|otp_expired/i.test(err)
          ? 'Giriş bağlantısının süresi dolmuş. Yeni bir bağlantı iste.'
          : 'Giriş tamamlanamadı. Yeni bir bağlantı iste.');
        toast('⚠️ Giriş bağlantısı geçersiz veya süresi dolmuş.', 4500);
      }
    }
    if (user) {
      var changed = !C.user || C.user.id !== user.id;
      C.user = user;
      // Umami: yalnızca bu cihazda istenen bir giriş (bağlantı/kod) tamamlandığında; kayıtlı oturumun açılışta
      // geri gelmesi giriş sayılmaz. Olayla birlikte hiçbir kullanıcı bilgisi gönderilmez.
      if (changed && (C.pendingEmail || lsGet(PENDING_KEY))) track('login_success');
      if (C.pendingEmail || lsGet(PENDING_KEY)) setPending('');
      if (changed) {
        C.reconciled = false; C.lastPushSig = ''; C.revUid = null;
        reconcile();
      } else render();
    } else if (event === 'SIGNED_OUT' || event === 'INITIAL_SESSION') {
      var was = !!C.user;
      C.user = null; C.reconciled = false; clearPushTimer();
      if (C.status !== 'guest' || was) setStatus('guest', was ? 'Çıkış yapıldı. Oyun bu cihazda kaydedilmeye devam ediyor.' : C.message);
      else render();
    } else render();
  }

  // ---------------------------------------------------------------- taşıyıcı (gerçek Supabase ya da sahte sunucu)
  function useMock() { return CFG.transport === 'mock'; }
  function mock() {
    if (!C.mock) {
      C.mock = createSaveMock(Object.assign({ rpc: CFG.rpc }, CFG.mockOptions || {}));
      // Aynı tarayıcıdaki başka sekmede sıfırlama/geri yükleme: yazmayı dene; bayatsa sunucu 409 ile reddeder -> reconcile
      // Başka sekme sıfırladı/geri yükledi: sunucu revision'ı bu sekmeninkinden ilerideyse doğrudan çek ve uzlaş
      // (bilerek bayat yazıp 409 beklemek yerine; 409 sayacını da tüketmez). Bu sekme o an uzlaşıyorsa ya da
      // sıfırlıyorsa mesaj düşmesin diye kısa aralıklarla yeniden denenir.
      C.mock.onMessage(function onMsg(m, tries) {
        if (!m || !C.user || m.uid !== C.user.id) return;
        if (!C.reconciling && !(K.isResetting && K.isResetting())) {
          var k = knownRev(C.user.id);
          if (k === null || num(m.revision) > k) { clearPushTimer(); C.reconciled = false; reconcile(); }
          return;
        }
        tries = tries || 0;
        if (tries < 20) setTimeout(function () { onMsg(m, tries + 1); }, 250);
      });
    }
    return C.mock;
  }
  var T = {
    select: function () {
      if (useMock()) return mock().select(C.user.id);
      return C.client.from(CFG.table).select('data, save_version, updated_at, revision, best_score, best_stage').eq('user_id', C.user.id).maybeSingle();
    },
    upsert: function (row) {
      // return=representation + select=revision: L = sunucunun sakladığı revision (lenient eşit yazmada eski+1 olabilir)
      if (useMock()) return mock().upsert(C.user.id, row);
      return C.client.from(CFG.table).upsert(row, { onConflict: 'user_id' }).select('revision').maybeSingle();
    },
    rpc: function (name, args) {
      if (useMock()) return mock().rpc(C.user.id, name, args);
      return C.client.rpc(name, args);
    }
  };
  function rpcError(r) {
    var e = r.error || {};
    var o = new Error(e.message || 'rpc_error');
    o.code = e.code; o.details = e.details; o.hint = e.hint; o.status = r.status;
    return o;
  }
  // Bayat yazma: HTTP 409, PT409 (stale_revision ya da eski istemci yolu stale_write)
  function isStale(e) { return !!(e && (e.code === 'PT409' || e.status === 409 || /^(stale_revision|stale_write)$/.test(e.message || ''))); }
  // v4.4 (Backend paket B, sürüm koruması): gönderilen data.saveVersion saklı olandan küçük -> SQLSTATE PT426, HTTP 426,
  // message save_version_too_old. Tekrar denenmez; oyun "Sayfayı yenile" bandını gösterir, yerel kayda dokunulmaz.
  function isTooOld(e) { return !!(e && (e.code === 'PT426' || e.status === 426 || e.message === 'save_version_too_old')); }
  function remoteRow() {
    return T.select().then(function (r) { if (r.error) throw rpcError(r); return r.data; });
  }
  function knownRev(uid) {
    if (C.revUid === uid) return C.rev;
    try {
      var o = JSON.parse(lsGet(REV_KEY) || 'null');
      if (o && o.uid === uid && typeof o.rev === 'number') { C.rev = o.rev; C.revUid = uid; return o.rev; }
    } catch (e) {}
    return null;
  }
  function setRev(uid, rev) {
    C.rev = Math.max(0, num(rev)); C.revUid = uid;
    lsSet(REV_KEY, JSON.stringify({ uid: uid, rev: C.rev }));
  }
  function saveData() { return K.saveData ? K.saveData() : K.state; }
  function backup(data) {
    if (!data || blocked()) return;
    lsSet(BACKUP_KEY, typeof data === 'string' ? data : JSON.stringify(data));
  }
  // Kaybeden kayıt, kazananın aynı oyunun daha eski bir kopyasıysa (aynı başlangıç, daha az kazanç,
  // daha eski zaman) yedeklemeye gerek yoktur; aksi halde yedeklenir. Boş (0 kazançlı) kayıt yedeklenmez.
  function needsBackup(loser, loserTime, winner, winnerTime) {
    if (!loser || num(loser.totalEarned) <= 0) return false;
    var sameGame = num(loser.startedAt) && num(loser.startedAt) === num(winner.startedAt);
    return !(sameGame && num(loser.totalEarned) <= num(winner.totalEarned) && loserTime <= winnerTime);
  }

  function mergeSeen(a, b) {
    var out = [];
    [a, b].forEach(function (arr) {
      (Array.isArray(arr) ? arr : []).forEach(function (id) { if (typeof id === 'string' && out.indexOf(id) === -1) out.push(id); });
    });
    return out;
  }

  function reconcile() {
    if (!C.user || C.reconciling || blocked()) return Promise.resolve();
    C.reconciling = true;
    setStatus('syncing', 'Bulut kaydı kontrol ediliyor…');
    var uid = C.user.id;
    return remoteRow().then(function (row) {
      if (!C.user || C.user.id !== uid) return;
      if (K.isResetting && K.isResetting()) return;
      // v4.3.1: buluttaki kayıt bu istemciden yeni (kodhane_saves.save_version ya da kayıttaki sürüm alanı): uygulanmaz,
      // üstüne yazılmaz; oyun "yenile" bandını gösterir (game.js guardFuture).
      if (row && K.guardFuture && K.guardFuture(row.data, 'cloud', row.save_version)) { clearPushTimer(); C.reconciled = false; return; }
      if (blocked()) return;
      K.save();
      var local = JSON.parse(JSON.stringify(saveData()));
      var localTime = num(local.lastSaved);
      var known = knownRev(uid);
      var rRev = row ? num(row.revision) : 0;
      if (!row || !row.data || typeof row.data !== 'object') {
        setRev(uid, Math.max(rRev, known || 0));
        C.reconciled = true;
        return push(true).then(function (ok) {
          if (ok) toast('☁️ Kaydın buluta yüklendi. Artık başka cihazlarda da devam edebilirsin.', 4500);
        });
      }
      var cloud = row.data;
      var cloudTime = Date.parse(row.updated_at) || num(cloud.lastSaved);
      // Görülen haberler iki kayıttan birleşir: bir cihazda kapatılan haber diğerinde tekrar çıkmaz.
      var seen = mergeSeen(local.newsSeen, cloud.newsSeen);
      var backedUp, res;
      // v4.2 revision kuralı: sunucu bu cihazın son gördüğünden ilerideyse (başka cihazda sıfırlama, geri yükleme ya da
      // yazma) bulut kazanır; bu cihazdaki eski kayıt buluta yazılamaz (sunucu da 409 ile reddeder).
      if (known !== null && rRev > known) {
        setRev(uid, rRev);
        cloud = Object.assign({}, cloud, { newsSeen: seen });
        backedUp = needsBackup(local, localTime, cloud, cloudTime);
        if (backedUp) backup(local);
        C.lastPushSig = '';
        C.reconciled = true;
        // sıfırlama mı yoksa eşzamanlı oyun mu? (staleKind: startedAt / boş kayıt)
        var kind = staleKind(local, cloud);
        C.lastRevWin = kind;
        if (typeof K.adoptSave === 'function') {
          K.adoptSave(cloud, kind);
          C.lastPushSig = sig(saveData());   // yüklenen = bulut kopyası: aynısını geri yazma
          return;
        }
        res = K.applySave(cloud);
        toast('☁️ Buluttaki kaydın yüklendi' + (backedUp ? ' (bu cihazdaki kayıt yedeklendi).' : '.'), 4500);
        return;
      }
      setRev(uid, Math.max(rRev, known || 0));
      var cE = num(cloud.totalEarned), lE = num(local.totalEarned);
      var cloudWins = cE > lE || (cE === lE && cloudTime > localTime);
      if (cloudWins) {
        cloud = Object.assign({}, cloud, { newsSeen: seen });
        backedUp = needsBackup(local, localTime, cloud, cloudTime);
        if (backedUp) backup(local);
        res = K.applySave(cloud);
        C.lastPushSig = '';
        C.reconciled = true;
        toast('☁️ Buluttaki kaydın yüklendi' + (backedUp ? ' (bu cihazdaki kayıt yedeklendi).' : '.') +
          (res && res.gain > 0 ? ' Çevrimdışı kazanç: +' + K.tl(res.gain) : ''), 5000);
        return push(true);
      }
      if (K.state && Array.isArray(K.state.newsSeen)) {
        seen.forEach(function (id) { if (K.markNewsSeen && K.state.newsSeen.indexOf(id) === -1) K.markNewsSeen(id); });
      }
      if (needsBackup(cloud, cloudTime, local, localTime)) {
        backup(cloud);
        toast('☁️ Bu cihazdaki kayıt daha ileride; buluttaki eski kayıt yedeklendi.', 4500);
      }
      C.reconciled = true;
      return push(true);
    }).catch(function (e) {
      setStatus('error', friendlyError(e, 'Bulut kaydına ulaşılamadı; oyun bu cihazda kaydedilmeye devam ediyor.'));
      setTimeout(function () { if (C.user && !C.reconciled) reconcile(); }, 60000);
    }).then(function () {
      C.reconciling = false; render();
      if (typeof K.refreshRestoreBox === 'function') { try { K.refreshRestoreBox(); } catch (e) {} }
    });
  }

  function clearPushTimer() { if (C.pushTimer) { clearTimeout(C.pushTimer); C.pushTimer = null; } }
  function schedulePush() {
    if (!C.user || !C.reconciled || C.pushTimer || C.held || blocked()) return;
    C.pushTimer = setTimeout(function () { C.pushTimer = null; push(false); }, CFG.pushDelayMs);
  }
  // Buluta yaz (upsert). force=false iken değişiklik yoksa atlanır. v4.2: her yazma revision = son görülen + 1 taşır;
  // sunucu 409 (bayat) derse körlemesine tekrar denenmez: reconcile (çek -> revision kuralı) çalışır.
  // o.duringReset: sıfırlamadan hemen önceki son yazma (yedeğe en güncel ilerleme girsin); o.quiet: 409'da reconcile yok.
  function push(force, o) {
    o = o || {};
    if (blocked()) return Promise.resolve(false);
    if (!C.client || !C.user || !C.reconciled) return Promise.resolve(false);
    if (C.held && !o.duringReset) return Promise.resolve(false);
    if (!o.duringReset && !(C.keepalive && C.finalWriter) && !gate.canPush(false)) return Promise.resolve(false);
    if (!o.duringReset && K.isResetting && K.isResetting()) return Promise.resolve(false);
    if (C.pushing) return C.pushing.then(function () { return push(force, o); });
    var state = saveData();
    var s = sig(state);
    if (!force && s === C.lastPushSig) return Promise.resolve(true);
    var now = new Date();
    var uid = C.user.id;
    var rev = num(knownRev(uid)) + 1;
    var row = { user_id: uid, data: state, save_version: num(state.saveVersion) || num(state.version) || 2, updated_at: now.toISOString(), revision: rev };
    var staleErr = null, tooOld = null;
    setStatus('syncing', 'Buluta kaydediliyor…');
    C.pushing = T.upsert(row).then(function (r) {
      if (r.error) throw rpcError(r);
      // L = sunucunun döndürdüğü revision (gönderilen değil; lenient eşit yazmada sunucu eski+1 yazar)
      var got = (r.data && typeof r.data.revision === 'number') ? r.data.revision : rev;
      if (C.user && C.user.id === uid) setRev(uid, got);
      C.lastPushSig = s; C.lastPushAt = now.getTime();
      // Umami: otomatik yazma ~45 sn'de bir olduğundan olay oturum başına bir kez (ilk başarılı bulut kaydı) gider.
      if (!C.cloudSaveTracked) { C.cloudSaveTracked = true; track('cloud_save'); }
      setStatus('saved', '');
      return true;
    }).catch(function (e) {
      if (isTooOld(e)) { tooOld = e; return false; }
      if (isStale(e)) { staleErr = e; return false; }
      setStatus('error', friendlyError(e, 'Buluta kaydedilemedi; tekrar denenecek. Oyun bu cihazda kayıtlı.'));
      return false;
    }).then(function (ok) {
      C.pushing = null;
      if (tooOld) {
        // Genel hata yok, tekrar deneme yok: yazma kapanır (game.js writesBlocked), zamanlayıcı durur, bant gösterilir.
        C.lastTooOld = { code: tooOld.code, message: tooOld.message, status: tooOld.status, details: tooOld.details || null };
        clearPushTimer();
        if (K.markOlderTab) K.markOlderTab({ detail: tooOld.details });
        setStatus('error', (K.uiText && K.uiText('update.olderTab.text')) || '');
        return ok;
      }
      if (staleErr) { C.lastStale = { code: staleErr.code, message: staleErr.message, status: staleErr.status }; if (!o.quiet) handleStale(staleErr); }
      return ok;
    });
    return C.pushing;
  }
  // 409: bu cihaz eski revision'da. Güncel kaydı çek; revision kuralı bulutu seçer (başka cihazda sıfırlandıysa
  // otherDevice metni gösterilir). Döngüye girmemek için 30 sn'de 3'ten fazla 409 olursa durulur.
  function handleStale() {
    // 409: güncel kaydı bir kez yükle; gerçek oyuncu girdisine kadar (hold) yeniden yazma — iki cihaz/sekme ping-pong yapmasın.
    hold();
    var t = Date.now();
    C.staleAt = C.staleAt.filter(function (x) { return t - x < 30000; });
    C.staleAt.push(t);
    clearPushTimer();
    C.reconciled = false;
    if (C.staleAt.length > 3) { setStatus('error', 'Buluta kaydedilemedi; tekrar denenecek. Oyun bu cihazda kayıtlı.'); setTimeout(function () { if (C.user && !C.reconciled) reconcile(); }, 60000); return; }
    reconcile();
  }
  function flush() {
    if (!C.user || !C.reconciled || blocked()) return;
    clearPushTimer();
    C.finalWriter = gate.isWriter();   // son yazma: sekme kapanırken yazıcı bırakılsa da bu push geçer
    C.keepalive = true;
    push(false).then(function () { C.keepalive = false; }, function () { C.keepalive = false; });
  }

  // Giriş e-postası gönderim hataları (Yazı r1, "Kod gönderim hataları"). Resend kotası üç oyunda ortak.
  var CLOUD_TEXT = {
    'cloud.rateLimit': 'Çok fazla deneme oldu, birkaç dakika sonra tekrar dene.',
    'cloud.quotaFull': 'Şu an giriş e-postası gönderemiyoruz. Giriş yapmadan oynamaya devam et, oyun bu cihazda kaydediliyor. Sonra tekrar dene.',
    'cloud.sendError': 'Giriş e-postası şu an gönderilemedi. Biraz sonra tekrar dene.',
    'cloud.sendFail': 'Bağlantı gönderilemedi. Adresi kontrol edip tekrar dene.'
  };
  var NET_TEXT = 'Bulut hizmetine şu an ulaşılamıyor. Oyun bu cihazda kaydedilmeye devam ediyor.';
  // supabase-js AuthApiError: message (GoTrue msg/message), status (HTTP), code (GoTrue error_code ya da yeni API'de code)
  function errParts(e) {
    var msg = (e && (e.message || e.error_description || e.msg)) || '';
    var status = e && typeof e.status === 'number' ? e.status : (e && typeof e.code === 'number' ? e.code : 0);
    var code = e && typeof e.code === 'string' ? e.code : (e && typeof e.error_code === 'string' ? e.error_code : '');
    return { msg: String(msg), status: status, code: code };
  }
  function isNetErr(e) { return !online() || /Failed to fetch|NetworkError|offline|sdk-/i.test(errParts(e).msg); }
  // Hız sınırı: HTTP 429, GoTrue over_email_send_rate_limit / over_request_rate_limit, "For security purposes..." mesajı
  function isRateLimit(e) {
    var x = errParts(e);
    return x.status === 429 || x.code === 'over_email_send_rate_limit' || x.code === 'over_request_rate_limit'
      || /rate limit|too many|security purposes/i.test(x.msg);
  }
  // Gönderim hatası anahtarı: 'network' | 'rateLimit' | 'quotaFull' | 'sendFail' | 'sendError'
  //  quotaFull: SMTP/Resend gönderimi başarısız (kota dahil). GoTrue bunu HTTP 500 + unexpected_failure,
  //             "Error sending magic link email" / "Error sending confirmation email" ile döner. supabase-js 2.117.2 her 5xx'i
  //             AuthRetryableFetchError yapar (status kalır, error_code düşer), bu yüzden asıl eşleşme mesaj metnidir;
  //             status 500 + code unexpected_failure kuralı yalnızca kodu taşıyan (ileriki) SDK sürümleri için.
  //  sendFail:  yalnızca adres hatası: validation_failed / email_address_invalid ya da "invalid format" / "... is invalid".
  //  sendError: diğer her şey (502/503/504, beklenmeyen gövde, otp_disabled, email_address_not_authorized ...).
  function sendErrorKey(e) {
    if (isNetErr(e)) return 'network';
    if (isRateLimit(e)) return 'rateLimit';
    var x = errParts(e);
    if (/error sending .*(e-?mail|mail|link|otp)|smtp|gomail/i.test(x.msg) || (x.status === 500 && x.code === 'unexpected_failure')) return 'quotaFull';
    if (x.code === 'email_address_invalid' || (x.code === 'validation_failed' && /e-?mail/i.test(x.msg))
      || /unable to validate email|invalid format|email address .*is invalid/i.test(x.msg)) return 'sendFail';
    return 'sendError';
  }
  function sendErrorText(e, resend) {
    var k = sendErrorKey(e);
    if (k === 'network') return NET_TEXT;
    // tekrar gönderimde "diğer hata" metni eskisi gibi (Yazı: "aynı işi görüyor, kalabilir")
    if (k === 'sendError' && resend) return 'Kod tekrar gönderilemedi. Biraz sonra yeniden dene.';
    return CLOUD_TEXT['cloud.' + k];
  }
  function friendlyError(e, fallback) {
    if (isNetErr(e)) return NET_TEXT;
    if (isRateLimit(e)) return CLOUD_TEXT['cloud.rateLimit'];
    return fallback;
  }

  // ---------------------------------------------------------------- arayüz
  function setStatus(status, message) { C.status = status; C.message = message || ''; render(); }
  function render() {
    // Sıralama sekmesi (leaderboard.js) oturum değişimlerini buradan izler.
    if (typeof K.onCloudRender === 'function') { try { K.onCloudRender(); } catch (e) {} }
    if (typeof K.onResetCloudRender === 'function') { try { K.onResetCloudRender(); } catch (e) {} }
    if (!el.btn) return;
    var signed = !!C.user;
    el.btn.classList.toggle('signed', signed);
    el.btn.classList.toggle('err', C.status === 'error');
    el.btn.setAttribute('aria-label', signed ? 'Hesap: ' + (C.user.email || 'giriş yapıldı') : 'Hesap: misafir');
    el.guest.classList.toggle('hidden', signed);
    el.user.classList.toggle('hidden', !signed);
    if (signed) {
      el.email.textContent = C.user.email || '';
      var t;
      if (C.status === 'syncing') t = '🔄 ' + (C.message || 'Eşitleniyor…');
      else if (C.status === 'error') t = '⚠️ ' + C.message;
      else if (C.lastPushAt) t = '☁️ Buluta kaydedildi · ' + hhmm(C.lastPushAt);
      else t = '☁️ Bulut kaydı hazır';
      el.sync.textContent = t;
      el.sync.className = 'acc-sync' + (C.status === 'error' ? ' err' : C.status === 'saved' ? ' ok' : '');
      el.msg.textContent = '';
    } else {
      el.msg.textContent = C.message || '';
      el.msg.className = 'acc-msg' + (C.status === 'error' ? ' err' : '');
    }
    var left = Math.max(0, Math.ceil((C.cooldownUntil - Date.now()) / 1000));
    var cooling = left > 0;
    var busy = C.status === 'sending' || C.verifying;
    el.send.disabled = busy || cooling;
    el.send.textContent = C.status === 'sending' ? 'Gönderiliyor…' : cooling ? 'Bağlantı gönderildi' : 'Giriş bağlantısı gönder';
    // Kod adımı: bağlantı/kod gönderildikten sonra
    var codeStep = !signed && !!C.pendingEmail;
    if (el.form) el.form.classList.toggle('hidden', codeStep);
    if (el.codeForm) {
      el.codeForm.classList.toggle('hidden', !codeStep);
      if (codeStep) {
        el.codeInfo.textContent = '';
        el.codeInfo.appendChild(document.createTextNode('Kodu '));
        var b = document.createElement('b'); b.textContent = C.pendingEmail; el.codeInfo.appendChild(b);
        el.codeInfo.appendChild(document.createTextNode(' adresine gönderdik. E-postadaki bağlantıya dokunabilir ya da kodu buraya yazabilirsin.'));
      }
      el.verify.disabled = busy;
      el.verify.textContent = C.verifying ? 'Kontrol ediliyor…' : 'Giriş yap';
      el.code.disabled = C.verifying;
      el.resend.disabled = busy || cooling;
      el.resend.textContent = C.status === 'sending' ? 'Gönderiliyor…' : cooling ? 'Kodu tekrar gönder (' + left + ' sn)' : 'Kodu tekrar gönder';
      el.change.disabled = C.verifying;
    }
    if (cooling && !C.tick) {
      C.tick = setInterval(function () {
        if (Date.now() >= C.cooldownUntil) { clearInterval(C.tick); C.tick = null; }
        render();
      }, 1000);
    }
  }
  function openPanel() {
    el.panel.classList.remove('hidden');
    render();
    if (!configured) { setStatus('error', 'Bulut kaydı bu sürümde yapılandırılmamış. Oyun bu cihazda kaydediliyor.'); return; }
    if (!C.user) {
      if (!C.pendingEmail) { var pe = loadPending(); if (pe) { C.pendingEmail = pe; render(); } }
      getClient().catch(function (e) { if (!C.user) setStatus('error', friendlyError(e, 'Bulut hizmetine şu an ulaşılamıyor.')); });
      setTimeout(function () { try { (C.pendingEmail ? el.code : el.input).focus(); } catch (e) {} }, 50);
    }
  }
  function closePanel() { el.panel.classList.add('hidden'); }

  function sendLink(ev) {
    if (ev) ev.preventDefault();
    var email = (el.input.value || '').trim();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) { setStatus('error', 'Geçerli bir e-posta adresi yaz.'); el.input.focus(); return; }
    requestOtp(email, false);
  }
  // Giriş e-postası (bağlantı + 6 haneli kod) iste; resend=true iken "tekrar gönder".
  function requestOtp(email, resend) {
    if (Date.now() < C.cooldownUntil || C.status === 'sending') return;
    if (!online()) { setStatus('error', 'İnternet bağlantısı yok. Çevrimiçi olunca tekrar dene.'); return; }
    setStatus('sending', '');
    getClient().then(function (client) {
      return client.auth.signInWithOtp({ email: email, options: { emailRedirectTo: redirectUrl(), shouldCreateUser: true } });
    }).then(function (r) {
      if (r && r.error) throw r.error;
      C.cooldownUntil = Date.now() + 60000;
      setPending(email);
      setStatus('guest', resend
        ? '📧 Yeni bir kod ve giriş bağlantısı gönderildi. En son gelen e-postadaki kodu kullan.'
        : '📧 Giriş e-postası gönderildi. (Gelmezse gereksiz klasörüne bak.)');
      setTimeout(function () { try { el.code.value = ''; el.code.focus(); } catch (e) {} }, 50);
    }).catch(function (e) {
      setStatus('error', sendErrorText(e, resend));
    });
  }
  function verifyCode(ev) {
    if (ev) ev.preventDefault();
    if (C.verifying) return;
    var token = (el.code.value || '').replace(/\s+/g, '');
    var email = C.pendingEmail;
    if (!email) return;
    if (!/^\d{6}$/.test(token)) { setStatus('error', 'Kod 6 haneli olmalı; yalnızca rakam yaz.'); el.code.focus(); return; }
    if (!online()) { setStatus('error', 'İnternet bağlantısı yok. Çevrimiçi olunca tekrar dene.'); return; }
    C.verifying = true;
    setStatus('guest', '');
    getClient().then(function (client) {
      return client.auth.verifyOtp({ email: email, token: token, type: 'email' });
    }).then(function (r) {
      if (r && r.error) throw r.error;
      C.verifying = false;
      setPending('');
      el.code.value = '';
      // Oturum SIGNED_IN olayıyla gelir; bağlantıyla girişteki akışın aynısı (onAuth -> reconcile) çalışır.
      // (setPending('') yukarıda çağrıldığı için onAuth ikinci kez login_success saymaz)
      track('login_success');
      if (r && r.data && r.data.session && r.data.session.user && !C.user) onAuth('SIGNED_IN', r.data.session);
      toast('✅ Giriş yapıldı.', 3000);
    }).catch(function (e) {
      C.verifying = false;
      var msg = (e && (e.message || e.msg)) || '';
      var code = e && (e.code || e.error_code);
      var status = e && e.status;
      var bad = code === 'otp_expired' || code === 'otp_invalid' || status === 403 || /expired|invalid|token/i.test(msg);
      setStatus('error', bad && status !== 429
        ? 'Kod hatalı ya da süresi dolmuş. En son gelen e-postadaki kodu kontrol et veya yeni kod iste.'
        : friendlyError(e, 'Giriş yapılamadı. Biraz sonra tekrar dene.'));
      setTimeout(function () { try { el.code.select(); } catch (x) {} }, 30);
    });
  }
  function changeEmail() {
    setPending('');
    if (el.code) el.code.value = '';
    setStatus('guest', '');
    setTimeout(function () { try { el.input.focus(); el.input.select(); } catch (e) {} }, 30);
  }
  function signOut() {
    if (!C.client) { C.user = null; render(); return Promise.resolve(); }
    setStatus('syncing', 'Çıkış yapılıyor…');
    clearPushTimer();
    K.save();
    return push(false).catch(function () {}).then(function () {
      return C.client.auth.signOut({ scope: 'local' });
    }).catch(function () {}).then(function () {
      try { localStorage.removeItem(CFG.storageKey); } catch (e) {}
      if (C.user) onAuth('SIGNED_OUT', null);
      toast('👋 Çıkış yapıldı. Misafir olarak devam ediyorsun; kaydın bu cihazda.', 4000);
    });
  }

  // ---------------------------------------------------------------- oyun kancaları
  K.onSaved = function () { schedulePush(); };
  K.cloudSignedIn = function () { return !!C.user; };
  // v4.2 "Kaydı sıfırla": satır SİLİNMEZ (v2.2'de istemci DELETE'i 403). Sıfırlama RPC'si (CFG.rpc.reset) sunucuda yedek alır, ilerlemeyi
  // temizler ve revision'ı artırır; best_score (sıralama), takma ad ve hesap kalır. Dönen revision saklanır.
  // Önce bekleyen yazma bitirilir ve en güncel ilerleme yazılır ki yedeğe girsin. Hata olursa Promise reddedilir
  // (game.js sıfırlamayı yapmaz). Girişli değilse null.
  K.beforeReset = function () {
    if (blocked()) return Promise.reject(new Error('newer-save'));
    if (!C.client || !C.user) return null;
    clearPushTimer();
    var uid = C.user.id;
    return (C.pushing || Promise.resolve()).catch(function () {}).then(function () {
      return C.reconciled ? push(false, { duringReset: true, quiet: true }) : null;
    }).catch(function () {}).then(function () {
      if (!C.user || C.user.id !== uid) throw new Error('not-signed-in');
      return T.rpc(CFG.rpc.reset, {});
    }).then(function (r) {
      if (r.error) throw rpcError(r);
      var d = r.data || {};
      if (C.user && C.user.id === uid) setRev(uid, num(d.revision));
      C.reconciled = false; C.lastPushSig = '';
      return { revision: num(d.revision), backupId: d.backup_id || null, bestScore: num(d.best_score), bestStage: num(d.best_stage) };
    });
  };
  function whenReady(ms) {
    return new Promise(function (resolve, reject) {
      var t0 = Date.now();
      (function poll() {
        if (C.user && C.client && !C.reconciling) return resolve(C.user.id);
        if (Date.now() - t0 > ms) return reject(new Error('not-signed-in'));
        setTimeout(poll, 100);
      })();
    });
  }
  // Geri al / yedekten geri yükle: geri yükleme RPC'si (CFG.rpc.restore) veri döndürmez; ardından satır çekilir.
  function restoreSave(p) {
    var id = p && (p.backupId || p.resetId);
    if (blocked()) return Promise.reject(new Error('newer-save'));
    if (!id) return Promise.reject(new Error('no-backup'));
    return whenReady(8000).then(function (uid) {
      return T.rpc(CFG.rpc.restore, { p_backup_id: id }).then(function (r) {
        if (r.error) throw rpcError(r);
        var d = r.data || {};
        if (d.game && d.game !== 'kodhane') throw new Error('wrong-game');
        return remoteRow().then(function (row) {
          if (!row || !row.data || typeof row.data !== 'object') throw new Error('empty');
          if (C.user && C.user.id === uid) setRev(uid, Math.max(num(row.revision), num(d.revision)));
          C.lastPushSig = ''; C.reconciled = true;
          return { data: row.data, revision: num(row.revision), backupId: d.backup_id || null, restoredFrom: d.restored_from || id };
        });
      });
    });
  }
  // İstatistik sekmesindeki "Yedekten geri yükle" için: en son geri yüklemeden sonra alınmış, boş olmayan en yeni
  // sıfırlama (ya da yönetici silme) yedeği. En son işlem geri yüklemeyse (ör. Geri al) gösterilecek yedek yok.
  function latestBackup() {
    if (!C.client || !C.user) return Promise.resolve(null);
    return T.rpc(CFG.rpc.listBackups, {}).then(function (r) {
      if (r.error) throw rpcError(r);
      var rows = Array.isArray(r.data) ? r.data : [];
      for (var i = 0; i < rows.length; i++) {
        var b = rows[i];
        if (b.reason === 'restore') return null;
        if ((b.reason === 'reset' || b.reason === 'delete') && num(Number(b.score)) > 0) {
          return { backupId: b.id, createdAt: b.created_at, expiresAt: b.expires_at, score: Number(b.score) };
        }
      }
      return null;
    });
  }
  K.cloud = {
    state: C, config: CFG, push: push, flush: flush, reconcile: reconcile, signOut: signOut, open: openPanel, close: closePanel,
    getClient: getClient, online: online,
    resetSave: function () { return K.beforeReset() || Promise.reject(new Error('not-signed-in')); },
    restoreSave: restoreSave, latestBackup: latestBackup, handleStale: handleStale, mock: function () { return useMock() ? mock() : null; },
    hold: hold, release: releaseHold, gate: gate, staleKind: staleKind,
    TEXT: CLOUD_TEXT, sendErrorKey: sendErrorKey,
    BACKUP_KEY: BACKUP_KEY, REV_KEY: REV_KEY, WRITER_KEY: WRITER_KEY, isConfigured: function () { return configured; }
  };

  function start() {
    ['accountBtn', 'accountPanel', 'accClose', 'accGuest', 'accUser', 'accForm', 'accEmail', 'accSend', 'accEmailShown', 'accSync', 'accSyncNow', 'accSignOut', 'accMsg',
      'accCodeForm', 'accCodeInfo', 'accCode', 'accVerify', 'accResend', 'accChange']
      .forEach(function (id) { el[id] = document.getElementById(id); });
    el.btn = el.accountBtn; el.panel = el.accountPanel; el.guest = el.accGuest; el.user = el.accUser;
    el.input = el.accEmail; el.send = el.accSend; el.email = el.accEmailShown; el.sync = el.accSync; el.msg = el.accMsg;
    el.form = el.accForm; el.codeForm = el.accCodeForm; el.codeInfo = el.accCodeInfo; el.code = el.accCode;
    el.verify = el.accVerify; el.resend = el.accResend; el.change = el.accChange;
    if (!el.btn || !el.panel) return;
    el.btn.addEventListener('click', openPanel);
    el.accClose.addEventListener('click', closePanel);
    el.panel.addEventListener('click', function (e) { if (e.target === el.panel) closePanel(); });
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape' && !el.panel.classList.contains('hidden')) closePanel(); });
    el.accForm.addEventListener('submit', sendLink);
    if (el.codeForm) {
      el.codeForm.addEventListener('submit', verifyCode);
      el.code.addEventListener('input', function () {
        var v = el.code.value.replace(/\D+/g, '').slice(0, 6);
        if (v !== el.code.value) el.code.value = v;
        if (v.length === 6 && !C.verifying) verifyCode();  // otomatik doldurma / yapıştırma
      });
      el.resend.addEventListener('click', function () { if (C.pendingEmail) requestOtp(C.pendingEmail, true); });
      el.change.addEventListener('click', changeEmail);
    }
    C.pendingEmail = loadPending();
    el.accSyncNow.addEventListener('click', function () {
      K.save();
      if (!C.reconciled) reconcile(); else push(true);
    });
    el.accSignOut.addEventListener('click', function () { signOut(); });
    document.addEventListener('visibilitychange', function () { if (document.hidden) { K.save(); flush(); } });
    root.addEventListener('pagehide', function () { K.save(); flush(); try { gate.release(); } catch (e) {} });  // son yazmadan SONRA bırak
    root.addEventListener('online', function () {
      if (C.user && !C.reconciled) reconcile();
      else if (!C.client && configured && (hasStoredSession() || urlHasAuth())) boot();
    });
    render();
    boot();
  }
  function boot() {
    if (!configured) { cleanUrl(); return; }
    if (!(hasStoredSession() || urlHasAuth())) return; // misafir: SDK indirilmez
    if (!online()) return;
    getClient().catch(function (e) {
      if (hasStoredSession()) setStatus('error', friendlyError(e, 'Bulut hizmetine şu an ulaşılamıyor.'));
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})(typeof window !== 'undefined' ? window : this);
