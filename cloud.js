/* Kodhane bulut kaydı (Supabase, isteğe bağlı giriş)
 *
 * - Misafirler hiçbir şey indirmez; kayıt yalnızca bu cihazda (localStorage) tutulur.
 * - supabase-js yalnızca gerektiğinde (kayıtlı oturum, e-postadaki giriş bağlantısından dönüş
 *   veya Hesap penceresi açıldığında) sabitlenmiş jsDelivr adresinden, SRI doğrulamasıyla yüklenir.
 * - CDN ya da Supabase erişilemezse oyun misafir gibi çalışmaya devam eder.
 * - Çakışma kuralı: toplam (ömür boyu) kazancı büyük olan kayıt kazanır; eşitse daha yeni olan.
 *   Kaybeden kayıt 'kodhane_ajans_save_backup' anahtarına yedeklenir.
 *
 * Buradaki anahtar Supabase'in herkese açık (publishable/anon) anahtarıdır; istemcide bulunması
 * tasarım gereğidir. Veri erişimi veritabanındaki RLS kurallarıyla (auth.uid() = user_id) korunur.
 */
(function (root) {
  'use strict';
  var K = root.Kodhane;
  if (!K || typeof document === 'undefined') return;

  var CFG = {
    url: 'https://supabase.teserix.com',
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
  // Supabase Cloud (*.supabase.co/in) ya da Teserix'in kendi Supabase'i (supabase.teserix.com)
  var configured = /^https:\/\/([a-z0-9-]+\.supabase\.(co|in)|supabase\.teserix\.com)$/.test(CFG.url) && CFG.key.indexOf('__') !== 0 ||
    !!(root.KODHANE_CLOUD_CONFIG && root.KODHANE_CLOUD_CONFIG.url);

  var C = {
    client: null, user: null, sdkPromise: null, clientPromise: null,
    reconciled: false, reconciling: false, pushTimer: null, pushing: null,
    lastPushAt: 0, lastPushSig: '', status: 'guest', message: '', keepalive: false, cooldownUntil: 0,
    pendingEmail: '', verifying: false, tick: null
  };
  var el = {};
  var startAuthError = authErrorFromUrl();

  // ---------------------------------------------------------------- yardımcılar
  function num(x) { return typeof x === 'number' && isFinite(x) ? x : 0; }
  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function hhmm(t) { var d = new Date(t); return pad(d.getHours()) + ':' + pad(d.getMinutes()); }
  function sig(s) {
    var c = {};
    for (var k in s) if (k !== 'lastSaved') c[k] = s[k];
    try { return JSON.stringify(c); } catch (e) { return String(Math.random()); }
  }
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
      if (C.pendingEmail || lsGet(PENDING_KEY)) setPending('');
      if (changed) {
        C.reconciled = false; C.lastPushSig = '';
        reconcile();
      } else render();
    } else if (event === 'SIGNED_OUT' || event === 'INITIAL_SESSION') {
      var was = !!C.user;
      C.user = null; C.reconciled = false; clearPushTimer();
      if (C.status !== 'guest' || was) setStatus('guest', was ? 'Çıkış yapıldı. Oyun bu cihazda kaydedilmeye devam ediyor.' : C.message);
      else render();
    } else render();
  }

  function remoteRow() {
    return C.client.from(CFG.table).select('data, save_version, updated_at').eq('user_id', C.user.id).maybeSingle()
      .then(function (r) { if (r.error) throw r.error; return r.data; });
  }
  function backup(data) {
    if (!data) return;
    lsSet(BACKUP_KEY, typeof data === 'string' ? data : JSON.stringify(data));
  }
  // Kaybeden kayıt, kazananın aynı oyunun daha eski bir kopyasıysa (aynı başlangıç, daha az kazanç,
  // daha eski zaman) yedeklemeye gerek yoktur; aksi halde yedeklenir. Boş (0 kazançlı) kayıt yedeklenmez.
  function needsBackup(loser, loserTime, winner, winnerTime) {
    if (!loser || num(loser.totalEarned) <= 0) return false;
    var sameGame = num(loser.startedAt) && num(loser.startedAt) === num(winner.startedAt);
    return !(sameGame && num(loser.totalEarned) <= num(winner.totalEarned) && loserTime <= winnerTime);
  }

  function reconcile() {
    if (!C.user || C.reconciling) return Promise.resolve();
    C.reconciling = true;
    setStatus('syncing', 'Bulut kaydı kontrol ediliyor…');
    var uid = C.user.id;
    return remoteRow().then(function (row) {
      if (!C.user || C.user.id !== uid) return;
      if (K.isResetting && K.isResetting()) return;
      K.save();
      var local = JSON.parse(JSON.stringify(K.state));
      var localTime = num(local.lastSaved);
      if (!row || !row.data || typeof row.data !== 'object') {
        C.reconciled = true;
        return push(true).then(function (ok) {
          if (ok) toast('☁️ Kaydın buluta yüklendi. Artık başka cihazlarda da devam edebilirsin.', 4500);
        });
      }
      var cloud = row.data;
      var cloudTime = Date.parse(row.updated_at) || num(cloud.lastSaved);
      var cE = num(cloud.totalEarned), lE = num(local.totalEarned);
      var cloudWins = cE > lE || (cE === lE && cloudTime > localTime);
      if (cloudWins) {
        var backedUp = needsBackup(local, localTime, cloud, cloudTime);
        if (backedUp) backup(local);
        var res = K.applySave(cloud);
        C.lastPushSig = '';
        C.reconciled = true;
        toast('☁️ Buluttaki kaydın yüklendi' + (backedUp ? ' (bu cihazdaki kayıt yedeklendi).' : '.') +
          (res && res.gain > 0 ? ' Çevrimdışı kazanç: +' + K.tl(res.gain) : ''), 5000);
        return push(true);
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
    }).then(function () { C.reconciling = false; render(); });
  }

  function clearPushTimer() { if (C.pushTimer) { clearTimeout(C.pushTimer); C.pushTimer = null; } }
  function schedulePush() {
    if (!C.user || !C.reconciled || C.pushTimer) return;
    C.pushTimer = setTimeout(function () { C.pushTimer = null; push(false); }, CFG.pushDelayMs);
  }
  // Buluta yaz (upsert). force=false iken değişiklik yoksa atlanır.
  function push(force) {
    if (!C.client || !C.user || !C.reconciled) return Promise.resolve(false);
    if (K.isResetting && K.isResetting()) return Promise.resolve(false);
    if (C.pushing) return C.pushing.then(function () { return push(force); });
    var state = K.state;
    var s = sig(state);
    if (!force && s === C.lastPushSig) return Promise.resolve(true);
    var now = new Date();
    var row = { user_id: C.user.id, data: state, save_version: num(state.version) || 2, updated_at: now.toISOString() };
    setStatus('syncing', 'Buluta kaydediliyor…');
    C.pushing = C.client.from(CFG.table).upsert(row, { onConflict: 'user_id' }).then(function (r) {
      if (r.error) throw r.error;
      C.lastPushSig = s; C.lastPushAt = now.getTime();
      setStatus('saved', '');
      return true;
    }).catch(function (e) {
      setStatus('error', friendlyError(e, 'Buluta kaydedilemedi; tekrar denenecek. Oyun bu cihazda kayıtlı.'));
      return false;
    }).then(function (ok) { C.pushing = null; return ok; });
    return C.pushing;
  }
  function flush() {
    if (!C.user || !C.reconciled) return;
    clearPushTimer();
    C.keepalive = true;
    push(false).then(function () { C.keepalive = false; }, function () { C.keepalive = false; });
  }

  function friendlyError(e, fallback) {
    var msg = (e && (e.message || e.error_description || e.msg)) || '';
    var status = e && (e.status || e.code);
    if (!online() || /Failed to fetch|NetworkError|offline|sdk-/i.test(msg)) return 'Bulut hizmetine şu an ulaşılamıyor. Oyun bu cihazda kaydedilmeye devam ediyor.';
    if (status === 429 || /rate limit|too many|security purposes/i.test(msg)) return 'Çok fazla deneme yapıldı. Lütfen birkaç dakika sonra tekrar dene.';
    return fallback;
  }

  // ---------------------------------------------------------------- arayüz
  function setStatus(status, message) { C.status = status; C.message = message || ''; render(); }
  function render() {
    // Sıralama sekmesi (leaderboard.js) oturum değişimlerini buradan izler.
    if (typeof K.onCloudRender === 'function') { try { K.onCloudRender(); } catch (e) {} }
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
      setStatus('error', friendlyError(e, resend ? 'Kod tekrar gönderilemedi. Biraz sonra yeniden dene.' : 'Bağlantı gönderilemedi. Adresi kontrol edip tekrar dene.'));
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
  K.beforeReset = function () {
    if (!C.client || !C.user) return null;
    clearPushTimer(); C.reconciled = false;
    return C.client.from(CFG.table).delete().eq('user_id', C.user.id).then(function () {}, function () {});
  };
  K.cloud = {
    state: C, config: CFG, push: push, flush: flush, reconcile: reconcile, signOut: signOut, open: openPanel, close: closePanel,
    getClient: getClient, online: online,
    BACKUP_KEY: BACKUP_KEY, isConfigured: function () { return configured; }
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
    root.addEventListener('pagehide', function () { K.save(); flush(); });
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
