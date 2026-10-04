/* Kodhane v4.5 (P7) "Kayıp bildir" istemcisi.
 * Sunucu sözleşmesi: kodhane-v44-backend dalı v4.5-kayip-bildir, docs/kodhane-v4.5-kayip-bildir-istemci-notu.md (f00cbf1 + 547010c):
 *   kodhane_loss_report_create({p_lost_items, p_lost_since, p_description, p_client_version}) -> {id, status:'in_review', created_at}
 *   kodhane_loss_report_status({p_limit}) -> yalnız oyuncunun kendi bildirimleri, yeniden eskiye
 *   Hatalar (HTTP / message / details): 401 (oturum yok) · 403 not_authenticated · 400 loss_report_invalid (lost_items | lost_since |
 *   description) · 404 no_cloud_save · 409 loss_report_open · 429 loss_report_daily_limit | loss_report_monthly_limit, details =
 *   tekrar deneme zamanı UTC ISO (Retry-After YOK). Kayıt yazımındaki 409 stale_revision: kayıt yeniden çekilir, yazma tekrarlanmaz.
 * Metinler: Yazı kodhane-p7-kayip-bildir-yazi-r3.json (LOSS_TEXT) birebir. Eksik iki hata metni (LOSS_TEXT_PENDING) Yazı kodhane-v4.5-metinler-yazi-r1.json'dan.
 * Arayüz Hesap penceresindeki "Kayıp bildir" bölümüdür (#lossSection); metinler yalnız textContent ile basılır.
 */
(function (root) {
  'use strict';
  var K = root && root.Kodhane;

  // Yazı r3 (kodhane-p7-kayip-bildir-yazi-r3.json, LOSS_TEXT), birebir.
  var LOSS_TEXT = {
    "lossReport.open": "Kayıp bildir",
    "lossReport.title": "Kayıp bildir",
    "lossReport.intro": "Oyunda bir ilerlemen kaybolduysa bize yaz. Bildirimini inceleriz, uygunsa kaybını telafi ederiz.",
    "lossReport.items.label": "Ne kayboldu?",
    "lossReport.items.hint": "Birden fazlasını seçebilirsin.",
    "lossReport.items.yatirim_turu": "Yatırım Turu",
    "lossReport.items.halka_arz": "Halka Arz",
    "lossReport.items.borsa_payi": "Borsa Payı",
    "lossReport.items.agac": "Borsa Payı Ağacı",
    "lossReport.items.diger": "Diğer",
    "lossReport.since.label": "Oyun en son ne zaman doğruydu?",
    "lossReport.since.optional": "İsteğe bağlı",
    "lossReport.since.bugun": "Bugün",
    "lossReport.since.dun": "Dün",
    "lossReport.since.son_7_gun": "Son 7 gün",
    "lossReport.since.son_30_gun": "Son 30 gün",
    "lossReport.since.bilmiyorum": "Daha eski ya da bilmiyorum",
    "lossReport.description.label": "Ne oldu?",
    "lossReport.description.optional": "İsteğe bağlı",
    "lossReport.description.placeholder": "Örneğin: Halka Arz yaptım, sayfayı yenileyince Borsa Paylarım gitti.",
    "lossReport.description.counter": "{n} / 280",
    "lossReport.description.privacy": "Ad, telefon, e-posta gibi kişisel bilgi yazma.",
    "lossReport.submit": "Gönder",
    "lossReport.cancel": "Vazgeç",
    "lossReport.sent": "Bildirimin bize ulaştı, teşekkürler. Sonucu Hesap penceresindeki “Kayıp bildir” bölümünde görebilirsin.",
    "lossReport.error.itemsRequired": "Ne kaybolduğunu seç, en az biri gerekli.",
    "lossReport.error.description": "Açıklamaya e-posta adresi ya da @ işareti yazma.",
    "lossReport.error.generic": "Bildirim gönderilemedi. Biraz sonra tekrar dene.",
    "lossReport.status.in_review.label": "İnceleniyor",
    "lossReport.status.in_review.text": "Bildirimini inceliyoruz. Sonuç belli olunca burada göreceksin.",
    "lossReport.status.in_review.save_changed": "Kaydın değişti, bildirimin yeniden inceleniyor.",
    "lossReport.status.approved.label": "Kabul edildi",
    "lossReport.status.approved.text": "Bildirimini inceledik ve kabul ettik. Telafin kaydına yüklenince burada göreceksin.",
    "lossReport.status.applied.label": "Yüklendi",
    "lossReport.status.applied.text": "Telafin kaydına yüklendi. Görmek için sayfayı yenile.",
    "lossReport.status.rejected.label": "Reddedildi",
    "lossReport.status.rejected.text": "Bildirimini inceledik ama bu kez telafi edemiyoruz.",
    "lossReport.applied.toast": "Telafin yüklendi, sayfayı yenile.",
    "lossReport.applied.staleTab": "Telafin kaydına yüklendi. Güncel kaydın bu sekmede de açıldı.",
    "lossReport.limit.daily": "24 saatte 1 bildirim gönderebilirsin. Yeni bildirim için kalan süre: {sure}",
    "lossReport.limit.monthly": "30 günde en çok 5 bildirim gönderebilirsin. Yeni bildirim için kalan süre: {sure}",
    "lossReport.limit.tooMany": "Kısa sürede çok fazla bildirim gönderildi. Yeni bildirim için kalan süre: {sure}",
    "lossReport.limit.open": "Sonuçlanmamış bir bildirimin var. O sonuçlanınca yenisini gönderebilirsin.",
    "lossReport.needLogin": "Kayıp bildirmek için giriş yapman gerekiyor. Giriş yapınca ilerlemen buluta kaydedilir, bildirimini de bulut kaydına bakarak inceleriz.",
    "lossReport.needLogin.button": "Giriş yap",
    "lossReport.noCloudSave": "Bu hesapta bulut kaydı bulamadık. Bildirim için önce bulut kaydı gerekiyor. Hesap penceresinde “Şimdi eşitle” düğmesine bas, sonra tekrar dene.",
    "lossReport.reject.kayip_bulunamadi": "Kayıtlarına baktık ama bir kayıp bulamadık. Hâlâ eksik bir şey görüyorsan ne olduğunu biraz daha anlatarak yeni bir bildirim gönderebilirsin.",
    "lossReport.reject.zaten_telafi_edildi": "Bu kaybı daha önce telafi etmiştik. Telafini göremiyorsan sayfayı yenile.",
    "lossReport.reject.kural_disi": "Bu bildirim telafi kapsamına girmiyor. Başka bir kaybın olursa yeni bir bildirim gönderebilirsin.",
    "lossReport.reject.diger": "Bildirimini inceledik ama bu kez telafi edemiyoruz. Bir yanlışlık olduğunu düşünüyorsan yeni bir bildirim gönderebilirsin.",
    "lossReport.reject.generic": "Kayıtlarına baktık ama bu bildirim için telafi yapamıyoruz. Bir yanlışlık olduğunu düşünüyorsan yeni bir bildirim gönderebilirsin."
  };
  // Yazı r3'te olmayan metinler: yer tutucu ([anahtar]); kesin metin gelince yalnız burası değişir.
  var LOSS_TEXT_PENDING = {
    "lossReport.error.lostSince": "Oyunun en son ne zaman doğru olduğunu yeniden seç.", // Yazı kodhane-v4.5-metinler-yazi-r1
    "lossReport.error.descriptionLength": "Açıklama en çok 280 karakter olabilir." // Yazı kodhane-v4.5-metinler-yazi-r1
  };

  var CFG = {
    enabled: true,                 // false: elle kapatma; bölüm hiç görünmez, sunucu yoklanmaz
    availKey: 'kodhane_loss_avail_v1', // sessionStorage: sunucu kurulu mu ('yes' | 'no'), oturum boyunca önbellek (karar 7)
    rpcCreate: 'kodhane_loss_report_create',
    rpcStatus: 'kodhane_loss_report_status',
    statusLimit: 10,
    maxDescription: 280,
    defaultRetrySec: 86400,        // 429 'details' gelmez ya da okunamazsa güvenli varsayılan: şimdi + 24 saat
    maxRetrySec: 31 * 86400,       // sunucudan gelen tekrar deneme zamanı en fazla 31 gün ileri sayılır
    pollMs: 15 * 60 * 1000,        // girişliyken durum yoklaması (telafi bu sekme açıkken yüklenirse bildirim için)
    retryKey: 'kodhane_loss_retry_v1',
    seenKey: 'kodhane_loss_applied_seen_v1'
  };
  var ITEMS = ['yatirim_turu', 'halka_arz', 'borsa_payi', 'agac', 'diger'];
  var SINCE = ['bugun', 'dun', 'son_7_gun', 'son_30_gun', 'bilmiyorum'];
  var REJECT_CODES = ['kayip_bulunamadi', 'zaten_telafi_edildi', 'kural_disi', 'diger'];
  var DAY = 86400000;

  function has(o, k) { return !!o && Object.prototype.hasOwnProperty.call(o, k); }
  function text(key, vars) {
    var t = has(LOSS_TEXT, key) ? LOSS_TEXT[key] : has(LOSS_TEXT_PENDING, key) ? LOSS_TEXT_PENDING[key] : '';
    return t.replace(/\{([a-z]+)\}/g, function (m, k) { return vars && vars[k] !== undefined ? String(vars[k]) : m; });
  }
  function fmtDur(sec) { return K && typeof K.fmtDur === 'function' ? K.fmtDur(sec) : Math.round(sec) + ' saniye'; }

  // ---------------------------------------------------------------- saf işlevler (tests/test_v45_loss.js)
  // "Bugün" / "Dün": oyuncunun yerel gün başlangıcı (UTC ISO); "Son 7 / 30 gün": şimdi - N gün; "Bilmiyorum" ya da seçim yok: null.
  function lostSinceISO(choice, now) {
    now = typeof now === 'number' ? now : Date.now();
    if (choice === 'bugun' || choice === 'dun') {
      var d = new Date(now);
      d.setHours(0, 0, 0, 0);
      if (choice === 'dun') d.setDate(d.getDate() - 1);
      return d.toISOString();
    }
    if (choice === 'son_7_gun') return new Date(now - 7 * DAY).toISOString();
    if (choice === 'son_30_gun') return new Date(now - 30 * DAY).toISOString();
    return null;
  }
  // Açıklama: satır sonu / sekme boşluk olur, kalan kontrol karakterleri atılır (sunucu reddeder), baş/son boşluk kırpılır; boş -> null.
  function cleanDescription(s) {
    if (typeof s !== 'string') return null;
    s = s.replace(/[\r\n\t]+/g, ' ').replace(/[\u0000-\u001f\u007f-\u009f]/g, '').trim();
    return s ? s : null;
  }
  function charCount(s) { return Array.from ? Array.from(s || '').length : (s || '').length; }
  // Form doğrulama: { ok, field, key }. Seçimler 1–5 bilinen kayıp; açıklama en çok 280 karakter, @ ve e-posta yok.
  function validate(form) {
    var items = (form && Array.isArray(form.items) ? form.items : []).filter(function (x, i, a) { return ITEMS.indexOf(x) !== -1 && a.indexOf(x) === i; });
    if (items.length < 1 || items.length > 5) return { ok: false, field: 'items', key: 'lossReport.error.itemsRequired' };
    if (form.since != null && form.since !== '' && SINCE.indexOf(form.since) === -1) return { ok: false, field: 'since', key: 'lossReport.error.lostSince' };
    var desc = cleanDescription(form.description);
    if (desc && /[@\uFF20\uFE6B]|[^\s]+\s*\(?\s*(at|et)\s*\)?\s*[^\s]+\.(com|net|org|tr)\b/i.test(desc)) return { ok: false, field: 'description', key: 'lossReport.error.description' };
    if (desc && charCount(desc) > CFG.maxDescription) return { ok: false, field: 'description', key: 'lossReport.error.descriptionLength' };
    return { ok: true, items: items, description: desc };
  }
  function buildArgs(form, now) {
    var v = validate(form);
    if (!v.ok) return null;
    return {
      p_lost_items: v.items,
      p_lost_since: lostSinceISO(form.since, now),
      p_description: v.description,
      p_client_version: (K && K.CLIENT_VERSION) || null
    };
  }
  // 429 tekrar deneme zamanı: details = UTC ISO 'YYYY-MM-DDTHH:MM:SSZ' (mutlak zaman). Okunamazsa şimdi + 24 sa (defaulted).
  var ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$/;
  function parseRetry(details, now) {
    now = typeof now === 'number' ? now : Date.now();
    var t = typeof details === 'string' && ISO_RE.test(details.trim()) ? Date.parse(details.trim()) : NaN;
    if (!isFinite(t)) return { at: now + CFG.defaultRetrySec * 1000, defaulted: true };
    return { at: Math.min(t, now + CFG.maxRetrySec * 1000), defaulted: false };
  }
  // {sure}: kalan süre tam dakikaya yukarı yuvarlanır (metin her saniye değişmez); süre bittiyse '' (metin kalkar, düğme açılır).
  function sureText(at, now) {
    now = typeof now === 'number' ? now : Date.now();
    var ms = at - now;
    if (!(ms > 0)) return '';
    return fmtDur(Math.ceil(ms / 60000) * 60);
  }
  function errOf(resp) { return (resp && resp.error) || null; }
  // 429 message -> metin anahtarı (Yazılım Yöneticisi, 4 Ekim: iki sınır da lossReport.limit.tooMany). Sunucu: code PT429,
  // message loss_report_daily_limit (24 saatte 1) | loss_report_monthly_limit (30 günde 5), details = tekrar deneme zamanı UTC ISO.
  // Not: Yazı r3 ve Backend istemci notu günlük/aylık için ayrı metin (lossReport.limit.daily / .monthly) öngörüyordu; metinler
  // TEXT'te duruyor, geri dönmek bu tabloyu değiştirmekten ibaret. Tabloda olmayan message da tooMany'ye düşer.
  var LIMIT_KEYS = { loss_report_daily_limit: 'lossReport.limit.tooMany', loss_report_monthly_limit: 'lossReport.limit.tooMany' };
  // RPC yanıtı -> { kind, key, field?, retryAt?, defaulted? }. kind: ok | needLogin | invalid | noCloudSave | open | stale | limit | generic
  function classify(resp, now) {
    if (!resp) return { kind: 'generic', key: 'lossReport.error.generic' };
    var e = errOf(resp), st = resp.status, msg = e && typeof e.message === 'string' ? e.message : '', det = e ? e.details : null;
    if (!e && (st === undefined || (st >= 200 && st < 300))) return { kind: 'ok' };
    if (st === 401) return { kind: 'needLogin', key: 'lossReport.needLogin' };
    if (st === 403) return msg === 'not_authenticated' ? { kind: 'needLogin', key: 'lossReport.needLogin' } : { kind: 'generic', key: 'lossReport.error.generic' };
    if (st === 400) {
      if (msg === 'loss_report_invalid' && det === 'lost_items') return { kind: 'invalid', field: 'items', key: 'lossReport.error.itemsRequired' };
      if (msg === 'loss_report_invalid' && det === 'description') return { kind: 'invalid', field: 'description', key: 'lossReport.error.description' };
      if (msg === 'loss_report_invalid' && det === 'lost_since') return { kind: 'invalid', field: 'since', key: 'lossReport.error.lostSince' };
      return { kind: 'generic', key: 'lossReport.error.generic' };
    }
    if (st === 404) return msg === 'no_cloud_save' ? { kind: 'noCloudSave', key: 'lossReport.noCloudSave' } : { kind: 'generic', key: 'lossReport.error.generic', missing: e && e.code === 'PGRST202' };
    if (st === 409) {
      if (msg === 'loss_report_open') return { kind: 'open', key: 'lossReport.limit.open' };
      if (msg === 'stale_revision' || msg === 'stale_write') return { kind: 'stale' };
      return { kind: 'generic', key: 'lossReport.error.generic' };
    }
    if (st === 429) {
      var r = parseRetry(det, now);
      var key = LIMIT_KEYS.hasOwnProperty(msg) ? LIMIT_KEYS[msg] : 'lossReport.limit.tooMany';   // bilinmeyen / boş message da tooMany
      return { kind: 'limit', key: key, retryAt: r.at, defaulted: r.defaulted };
    }
    return { kind: 'generic', key: 'lossReport.error.generic' };
  }
  // Durum satırı -> { status, label, text, open }. Gösterim kuralı Yazı r3 bölüm 2.
  function statusView(row) {
    if (!row || typeof row !== 'object') return null;
    var s = row.status;
    if (s === 'rejected') {
      var code = typeof row.reason === 'string' && REJECT_CODES.indexOf(row.reason) !== -1 ? row.reason : 'generic';
      return { status: s, label: text('lossReport.status.rejected.label'), text: text('lossReport.reject.' + code), open: false };
    }
    if (s === 'approved') return { status: s, label: text('lossReport.status.approved.label'), text: text('lossReport.status.approved.text'), open: true };
    if (s === 'applied') return { status: s, label: text('lossReport.status.applied.label'), text: text('lossReport.status.applied.text'), open: false };
    // in_review (ve tanınmayan durum: güvenli tarafta "inceleniyor")
    return { status: 'in_review', label: text('lossReport.status.in_review.label'),
      text: row.review_reason === 'save_changed' ? text('lossReport.status.in_review.save_changed') : text('lossReport.status.in_review.text'), open: true };
  }
  // Karar 7: durum RPC'si yanıtından "P7 sunucusu kurulu mu" -> 'yes' | 'no' | null (bilinmiyor, karar değişmez).
  // PostgREST önce fonksiyonu şema önbelleğinde arar: yoksa 404 PGRST202 (eski sürümde 42883). Varsa yetki kapısı gelir:
  // anon anahtarla 401 42501 (EXECUTE yalnız authenticated'da; istemci notu bölüm 3), bozuk JWT 403. Durum RPC'sinin
  // başka bir 404'ü yok (no_cloud_save yalnız create'te), bu yüzden durum RPC'sinde her 404 "kurulu değil" sayılır.
  // Ağ hatası (status 0) ve 5xx geçicidir: null, bölüm kalıcı olarak gizlenmez.
  function availability(resp) {
    if (!resp) return null;
    var e = errOf(resp), st = resp.status, code = e && e.code;
    if (!e && st >= 200 && st < 300) return 'yes';
    if (st === 404 || code === 'PGRST202' || code === '42883') return 'no';
    if (st === 401 || st === 403) return 'yes';
    return null;
  }
  function latest(rows) {
    if (!Array.isArray(rows) || !rows.length) return null;
    return rows.slice().sort(function (a, b) { return (Date.parse(b && b.created_at) || 0) - (Date.parse(a && a.created_at) || 0); })[0] || null;
  }

  // Eski sekme ayrımı (karar 6). Kesin alan: durum RPC'sinin applied_revision kolonu (Backend 1cd221d, istemci notu §2). Alan
  // yalnız status = applied iken dolu: geri yüklemenin yazdığı kayıt revision'ı; diğer durumlarda null.
  // 409 stale_revision'da sekmenin gönderdiği revision N, applied satırlarındaki en büyük applied_revision A ile karşılaştırılır:
  //   N <= A -> lossReport.applied.staleTab (sekme geri yüklemeden önceki kayıtla açıktı)
  //   N >  A ya da applied satırı yok -> '' (game.js reset.otherDeviceSync gösterir: 409 başka bir yazıdan)
  // Alan null / eksikse (eski sunucu), satırlar okunamadıysa ya da N bilinmiyorsa eski sezgiye düşülür:
  // applied_at > sekme açılışı ve 409'dan önceki durum yenilemesinde yakalanmış olması (S.pendingApplied).
  function staleVerdict(rows, sent) {
    if (!Array.isArray(rows) || typeof sent !== 'number' || !isFinite(sent)) return null;
    var max = null, missing = false;
    rows.forEach(function (row) {
      if (!row || row.status !== 'applied') return;            // applied dışı satırın değeri (gelse bile) sayılmaz
      var a = row.applied_revision;
      if (typeof a === 'string' && /^\d+$/.test(a)) a = Number(a);   // bigint metin olarak gelirse
      if (typeof a === 'number' && isFinite(a)) { if (max === null || a > max) max = a; } else missing = true;
    });
    if (max !== null && sent <= max) return 'staleTab';
    if (missing) return null;                                  // alan null/eksik: sezgiye düş
    return 'sync';
  }

  var LR = {
    TEXT: LOSS_TEXT, TEXT_PENDING: LOSS_TEXT_PENDING, CFG: CFG, ITEMS: ITEMS, SINCE: SINCE, REJECT_CODES: REJECT_CODES,
    text: text, lostSinceISO: lostSinceISO, cleanDescription: cleanDescription, validate: validate, buildArgs: buildArgs,
    parseRetry: parseRetry, sureText: sureText, classify: classify, statusView: statusView, latest: latest, availability: availability, staleVerdict: staleVerdict
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = LR;
  if (!K) return;
  K.lossReport = LR;
  if (typeof document === 'undefined') return;

  // ---------------------------------------------------------------- tarayıcı
  // avail: 'unknown' (yoklanmadı / geçici hata) | 'yes' | 'no'. Bölüm yalnız 'yes' iken görünür (kanıtlanana kadar gizli).
  var S = { rows: null, avail: 'unknown', probing: null, notice: null, form: false, sending: false, retry: null, pendingApplied: null, staleVerdict: null, rowsSeq: 0, loadedAt: Date.now(), fetching: null };
  var el = {};
  function lsGet(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
  function lsSet(k, v) { try { if (v == null) localStorage.removeItem(k); else localStorage.setItem(k, v); } catch (e) {} }
  function signed() { return !!(K.cloud && K.cloud.state && K.cloud.state.user); }
  function toast(m, ms) { if (K.toast) { try { K.toast(m, ms); } catch (e) {} } }
  // RPC taşıyıcısı (testler değiştirir): { data, error: {message, code, details, hint} | null, status }
  LR.transport = function (name, args) {
    if (!K.cloud || typeof K.cloud.rpc !== 'function') return Promise.reject(new Error('no-cloud'));
    return K.cloud.rpc(name, args);
  };
  // Misafir yoklaması (testler değiştirir): oturumsuz, herkese açık anahtarla doğrudan durum RPC'si; SDK indirilmez.
  // Kuruluysa 401 42501, kurulu değilse 404 PGRST202 döner. Yanıt { data, error, status }.
  LR.anonTransport = function (name, args) {
    if (!K.cloud || typeof K.cloud.anonRpc !== 'function') return Promise.reject(new Error('no-cloud'));
    return K.cloud.anonRpc(name, args);
  };
  function ssGet(k) { try { return sessionStorage.getItem(k); } catch (e) { return null; } }
  function ssSet(k, v) { try { sessionStorage.setItem(k, v); } catch (e) {} }
  // Kesin sonuç ('yes' | 'no') oturum boyunca saklanır; null (geçici hata) mevcut kararı değiştirmez.
  function setAvail(a) {
    if (a !== 'yes' && a !== 'no') return;
    S.avail = a; ssSet(CFG.availKey, a);
  }
  function call(name, args, anon) {
    var p;
    try { p = Promise.resolve((anon ? LR.anonTransport : LR.transport)(name, args)); } catch (e) { p = Promise.reject(e); }
    return p.then(function (r) { return r || { data: null, error: { message: 'empty' }, status: 0 }; },
      function (e) { return { data: null, error: { message: String(e && e.message || e) }, status: 0 }; });
  }
  function loadRetry() {
    try { var o = JSON.parse(lsGet(CFG.retryKey) || 'null'); if (o && isFinite(o.at) && typeof o.key === 'string' && o.at > Date.now()) return o; } catch (e) {}
    lsSet(CFG.retryKey, null); return null;
  }
  function seenIds() { try { var a = JSON.parse(lsGet(CFG.seenKey) || '[]'); return Array.isArray(a) ? a : []; } catch (e) { return []; } }
  function markSeen(id) { var a = seenIds(); if (a.indexOf(id) === -1) { a.push(id); lsSet(CFG.seenKey, JSON.stringify(a.slice(-20))); } }

  function node(tag, cls, txt) { var n = document.createElement(tag); if (cls) n.className = cls; if (txt != null) n.textContent = txt; return n; }
  function build() {
    var sec = el.section;
    sec.textContent = '';
    sec.appendChild(node('h4', 'loss-title', text('lossReport.title'))).id = 'lossTitle';
    el.status = sec.appendChild(node('div', 'loss-status hidden')); el.status.id = 'lossStatus';
    el.statusLabel = el.status.appendChild(node('b', 'loss-status-label')); el.statusText = el.status.appendChild(node('p', 'loss-status-text'));
    el.notice = sec.appendChild(node('p', 'loss-notice')); el.notice.id = 'lossNotice'; el.notice.setAttribute('aria-live', 'polite');
    var acts = sec.appendChild(node('div', 'loss-actions'));
    el.open = acts.appendChild(node('button', 'btn ghost', text('lossReport.open'))); el.open.type = 'button'; el.open.id = 'lossOpen';
    el.login = acts.appendChild(node('button', 'btn primary hidden', text('lossReport.needLogin.button'))); el.login.type = 'button'; el.login.id = 'lossLogin';
    var f = el.form = sec.appendChild(node('form', 'loss-form hidden')); f.id = 'lossForm'; f.noValidate = true;
    f.appendChild(node('p', 'loss-intro', text('lossReport.intro')));
    var fs1 = f.appendChild(node('fieldset', 'loss-items')); fs1.id = 'lossItems';
    fs1.appendChild(node('legend', '', text('lossReport.items.label')));
    fs1.appendChild(node('small', 'loss-hint', text('lossReport.items.hint')));
    ITEMS.forEach(function (id) {
      var lab = fs1.appendChild(node('label', 'loss-check'));
      var c = lab.appendChild(node('input')); c.type = 'checkbox'; c.name = 'lossItem'; c.value = id;
      lab.appendChild(node('span', '', text('lossReport.items.' + id)));
    });
    var fs2 = f.appendChild(node('fieldset', 'loss-since')); fs2.id = 'lossSince';
    var lg = fs2.appendChild(node('legend', '', text('lossReport.since.label') + ' '));
    lg.appendChild(node('small', 'loss-opt', '(' + text('lossReport.since.optional') + ')'));
    SINCE.forEach(function (id) {
      var lab = fs2.appendChild(node('label', 'loss-radio'));
      var r = lab.appendChild(node('input')); r.type = 'radio'; r.name = 'lossSince'; r.value = id;
      lab.appendChild(node('span', '', text('lossReport.since.' + id)));
    });
    var dl = f.appendChild(node('label', 'loss-desc-label', text('lossReport.description.label') + ' ')); dl.htmlFor = 'lossDesc';
    dl.appendChild(node('small', 'loss-opt', '(' + text('lossReport.description.optional') + ')'));
    el.desc = f.appendChild(node('textarea', 'loss-desc')); el.desc.id = 'lossDesc'; el.desc.rows = 3; el.desc.maxLength = CFG.maxDescription;
    el.desc.placeholder = text('lossReport.description.placeholder');
    var foot = f.appendChild(node('div', 'loss-desc-foot'));
    foot.appendChild(node('small', 'loss-privacy', text('lossReport.description.privacy')));
    el.counter = foot.appendChild(node('small', 'loss-counter')); el.counter.id = 'lossCounter';
    el.error = f.appendChild(node('p', 'loss-error')); el.error.id = 'lossError'; el.error.setAttribute('role', 'alert');
    var fa = f.appendChild(node('div', 'modal-actions'));
    el.submit = fa.appendChild(node('button', 'btn primary', text('lossReport.submit'))); el.submit.type = 'submit'; el.submit.id = 'lossSubmit';
    el.cancel = fa.appendChild(node('button', 'btn ghost', text('lossReport.cancel'))); el.cancel.type = 'button'; el.cancel.id = 'lossCancel';
    el.open.addEventListener('click', openForm);
    el.login.addEventListener('click', goLogin);
    el.cancel.addEventListener('click', function () { S.form = false; setError(''); render(); });
    el.desc.addEventListener('input', counter);
    f.addEventListener('submit', submit);
    counter();
  }
  function counter() { el.counter.textContent = text('lossReport.description.counter', { n: charCount(el.desc.value) }); }
  function setError(key, field) {
    el.error.textContent = key ? text(key) : '';
    el.form.dataset.errorField = field || '';
  }
  function formValue() {
    var items = Array.prototype.map.call(el.form.querySelectorAll('input[name=lossItem]:checked'), function (c) { return c.value; });
    var s = el.form.querySelector('input[name=lossSince]:checked');
    return { items: items, since: s ? s.value : null, description: el.desc.value };
  }
  function goLogin() {
    var done = function () { if (K.cloud && K.cloud.open) K.cloud.open(); setTimeout(function () { var i = document.getElementById('accEmail'); if (i) { try { i.focus(); i.scrollIntoView({ block: 'center' }); } catch (e) {} } }, 60); };
    S.notice = null; render();
    if (signed() && K.cloud.signOut) K.cloud.signOut().then(done, done); else done();
  }
  function openForm() {
    if (!signed()) { S.notice = { key: 'lossReport.needLogin', login: true }; render(); return; }
    if (S.retry && S.retry.at > Date.now()) { render(); return; }
    var lt = latest(S.rows), v = statusView(lt);
    if (v && v.open) { S.notice = { key: 'lossReport.limit.open' }; render(); return; }
    S.form = true; S.notice = null; setError(''); render();
    try { el.form.querySelector('input[name=lossItem]').focus(); } catch (e) {}
  }
  function submit(ev) {
    if (ev) ev.preventDefault();
    if (S.sending) return;
    var fv = formValue(), v = validate(fv);
    if (!v.ok) { setError(v.key, v.field); return; }
    var args = buildArgs(fv);
    S.sending = true; setError(''); render();
    call(CFG.rpcCreate, args).then(function (r) {
      S.sending = false;
      handleResult(classify(r), r);
    });
  }
  function handleResult(c) {
    switch (c.kind) {
      case 'ok':
        S.form = false; el.form.reset(); counter();
        S.notice = { key: 'lossReport.sent' };
        refresh(); break;
      case 'invalid': setError(c.key, c.field); break;
      case 'needLogin': S.form = false; S.notice = { key: c.key, login: true }; break;
      case 'noCloudSave': S.notice = { key: c.key }; S.form = false; break;
      case 'open': S.form = false; S.notice = { key: c.key }; refresh(); break;
      case 'stale':
        // Kayıt sunucuda değişmiş: kaydı yeniden çek (cloud.reconcile), güncel durumu göster; aynı yazma TEKRAR DENENMEZ.
        S.form = false; S.notice = null;
        try { if (K.cloud && K.cloud.reconcile) K.cloud.reconcile(); } catch (e) {}
        refresh(); break;
      case 'limit':
        S.form = false; S.retry = { at: c.retryAt, key: c.key }; lsSet(CFG.retryKey, JSON.stringify(S.retry)); S.notice = null; break;
      default: setError(c.key || 'lossReport.error.generic'); if (!S.form) S.notice = { key: c.key || 'lossReport.error.generic' };
    }
    render();
  }
  // Durum RPC'si: yalnız oyuncunun kendi bildirimleri. Fonksiyon sunucuda yoksa (404 PGRST202) bölüm gizlenir.
  // Karar 7: kurulu değilse ('no', oturum önbelleği) bir daha istek atılmaz.
  function refresh() {
    if (!CFG.enabled || S.avail === 'no') return Promise.resolve(null);
    if (!signed()) return probe();
    if (S.fetching) return S.fetching;
    S.fetching = call(CFG.rpcStatus, { p_limit: CFG.statusLimit }).then(function (r) {
      S.fetching = null;
      setAvail(availability(r));
      if (classify(r).kind === 'ok') {
        S.rows = Array.isArray(r.data) ? r.data : [];
        S.rowsSeq++;                                           // beforeStale: bu yenileme başarılı mı
        noticeApplied();
      }
      render();
      return S.rows;
    });
    return S.fetching;
  }
  // Misafir: sunucu kurulu mu? Karar biliniyorsa (oturum önbelleği) istek atılmaz; geçici hatada yalnız bir sonraki
  // Hesap penceresi açılışında (düğme) yeniden denenir. Misafirin satırı yoktur; yalnız görünürlük belirlenir.
  function probe() {
    if (!CFG.enabled || S.avail !== 'unknown') return Promise.resolve(null);
    if (S.probing) return S.probing;
    // Aynı tıklamada iki tetik (Hesap düğmesi + bulut render'ı) tek istek sayılır.
    if (S.probeAt && Date.now() - S.probeAt < 500) return Promise.resolve(null);
    S.probeTried = true; S.probeAt = Date.now();
    S.probing = call(CFG.rpcStatus, { p_limit: 1 }, true).then(function (r) {
      S.probing = null;
      setAvail(availability(r));
      render();
      return null;
    });
    return S.probing;
  }
  // Telafi yüklendi: bu sekme yükleme anında açıksa (applied_at > sayfa açılışı) applied.toast; eski sekmenin 409'unda staleTab.
  function noticeApplied() {
    var seen = seenIds();
    (S.rows || []).forEach(function (row) {
      if (!row || row.status !== 'applied' || !row.id || seen.indexOf(row.id) !== -1) return;
      markSeen(row.id);
      var at = Date.parse(row.applied_at);
      if (isFinite(at) && at > S.loadedAt) { S.pendingApplied = row.id; toast(text('lossReport.applied.toast'), 7000); }
    });
  }
  // game.js adoptSave (409 stale_revision -> güncel kayıt yüklendi) bunu sorar: telafiden geldiyse staleTab metni, değilse ''.
  LR.consumeAppliedForStale = function () {
    var v = S.staleVerdict; S.staleVerdict = null;
    if (v === 'staleTab') { S.pendingApplied = null; return text('lossReport.applied.staleTab'); }
    if (v === 'sync') { S.pendingApplied = null; return ''; }
    if (!S.pendingApplied) return '';                          // eski sezgi (applied_revision yokken)
    S.pendingApplied = null;
    return text('lossReport.applied.staleTab');
  };
  // cloud.js handleStale bunu reconcile'dan önce çağırır (en fazla 2,5 sn bekler). info.sent: 409'u alan yazmanın revision'ı.
  // Durum yenilenince staleVerdict hesaplanır; adoptSave consumeAppliedForStale ile sonucu alır.
  LR.beforeStale = function (info) {
    S.staleVerdict = null;
    if (!signed() || S.avail === 'no' || !CFG.enabled) return Promise.resolve();
    var sent = info && typeof info.sent === 'number' ? info.sent : null, seq = S.rowsSeq;
    // Karar yalnız bu yenileme başarılıysa (satırlar taze) verilir; hata / zaman aşımında eski sezgi.
    return Promise.race([refresh(), new Promise(function (r) { setTimeout(r, 2500); })]).then(function () {}, function () {})
      .then(function () { S.staleVerdict = S.rowsSeq > seq ? staleVerdict(S.rows, sent) : null; });
  };
  function render() {
    if (!el.section) return;
    var show = CFG.enabled && S.avail === 'yes';   // karar 7: kurulu olduğu kanıtlanana kadar gizli
    el.section.classList.toggle('hidden', !show);
    if (!show) return;
    var now = Date.now();
    if (S.retry && !(S.retry.at > now)) { S.retry = null; lsSet(CFG.retryKey, null); }
    var v = signed() ? statusView(latest(S.rows)) : null;
    el.status.classList.toggle('hidden', !v);
    el.status.dataset.status = v ? v.status : '';
    if (v) { el.statusLabel.textContent = v.label; el.statusText.textContent = v.text; }
    var nt = '', login = false;
    if (S.retry && signed()) nt = text(S.retry.key, { sure: sureText(S.retry.at, now) });
    else if (S.notice) { nt = text(S.notice.key); login = !!S.notice.login; }
    el.notice.textContent = nt;
    el.notice.classList.toggle('hidden', !nt);
    el.login.classList.toggle('hidden', !login);
    el.open.classList.toggle('hidden', S.form || login);
    el.open.disabled = !!(S.retry && signed()) || S.sending;
    el.form.classList.toggle('hidden', !S.form);
    el.submit.disabled = S.sending;
  }
  LR.render = render; LR.refresh = refresh; LR.probe = probe; LR.state = S; LR.el = el; LR.handleResult = handleResult;
  LR.setRetry = function (o) { S.retry = o; lsSet(CFG.retryKey, o ? JSON.stringify(o) : null); render(); };

  function start() {
    el.section = document.getElementById('lossSection');
    if (!el.section) return;
    S.retry = loadRetry();
    var cached = ssGet(CFG.availKey);
    if (cached === 'yes' || cached === 'no') S.avail = cached;
    build(); render();
    // Hesap penceresi açılınca ve oturum değişince durumu yenile; kalan süre metni 30 sn'de bir güncellenir.
    var btn = document.getElementById('accountBtn');
    if (btn) btn.addEventListener('click', function () { S.notice = null; render(); refresh(); });
    var prev = K.onCloudRender;
    var wasSigned = false;
    K.onCloudRender = function () {
      if (typeof prev === 'function') { try { prev(); } catch (e) {} }
      var s = signed();
      if (s !== wasSigned) { wasSigned = s; if (!s) { S.rows = null; S.form = false; } else { S.notice = null; setTimeout(refresh, 0); } }
      // Hesap penceresi başka yoldan açıldıysa da (giriş akışı) misafir yoklaması yapılır; karar biliniyorsa istek yok.
      // Yalnız ilk kez: geçici hatadan sonra her render'da yeniden istek atılmaz (sonraki deneme Hesap düğmesine basınca).
      if (!s && S.avail === 'unknown' && !S.probeTried) { var pn = document.getElementById('accountPanel'); if (pn && !pn.classList.contains('hidden')) probe(); }
      render();
    };
    setInterval(function () { if (S.retry) render(); }, 30000);
    setInterval(function () { if (signed() && !document.hidden) refresh(); }, CFG.pollMs);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})(typeof window !== 'undefined' ? window : this);
