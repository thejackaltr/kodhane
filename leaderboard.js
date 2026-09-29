/* Kodhane sıralaması ("Sıralama")
 *
 * - Puan: bulut kaydındaki ömür boyu toplam kazanç (totalEarned). Yatırım Turu'nda sıfırlanmaz.
 * - Liste herkese açıktır: misafirler SDK indirmeden, yalnızca herkese açık anahtarla
 *   kodhane_leaderboard fonksiyonunu çağırır. Fonksiyon kullanıcı kimliği veya e-posta döndürmez.
 * - Listeye yalnızca takma ad seçen (katılan) girişli oyuncular girer. Takma ad kuralları
 *   veritabanında da aynen uygulanır; buradaki kontrol yalnızca hızlı ve anlaşılır geri bildirim içindir.
 * - Oyun tarayıcıda çalıştığı için puanlar oyuncunun cihazından gelir (istemciye güvenilir). Sunucu makul
 *   görünmeyen puanları listeden çıkarır (oyuncuya yalnızca kendi satırında "kontrol ediliyor" gösterilir) ve
 *   yöneticinin gizlediği takma adları göstermez. Takma adlar yalnızca textContent ile yazılır (HTML asla).
 * - Sonuçlar ~60 sn önbellekte tutulur; "Yenile" her zaman yeniden çeker.
 */
(function (root) {
  'use strict';
  var K = root.Kodhane;
  if (!K) return;

  var LIMIT = 50;
  var STALE_MS = 60000;
  var GAME = 'kodhane'; // Açık Ofis gibi başka oyunların listeleri karışmasın
  var TABLE = 'kodhane_profiles';
  var RPC = 'kodhane_leaderboard';

  // ---------------------------------------------------------------- saf mantık (testlerde de kullanılır)
  var NICK_RE = /^[A-Za-z0-9çğıöşüÇĞİÖŞÜ _-]+$/;
  var HAS_ALNUM = /[A-Za-z0-9çğıöşüÇĞİÖŞÜ]/;
  var RESERVED = ['admin', 'administrator', 'moderator', 'mod', 'kodhane', 'teserix', 'sistem', 'system', 'support', 'destek', 'root', 'null', 'undefined'];
  var BLOCK_EXACT = ['amk', 'aq', 'mk', 'oc', 'pic', 'got', 'sik', 'am', 'amq', 'sg', 'siq', 'ass', 'fag', 'cum', 'tits', 'nazi'];
  var BLOCK_SUB = ['orospu', 'siktir', 'sikis', 'sikik', 'sikim', 'sikey', 'yarrak', 'yarak', 'amcik', 'aminak', 'aminako',
    'gavat', 'pezevenk', 'kahpe', 'yavsak', 'ibne', 'pust', 'kaltak', 'surtuk', 'serefsiz', 'godos', 'dalyarak', 'tassak', 'amcuk',
    'fuck', 'shit', 'bitch', 'cunt', 'nigger', 'nigga', 'whore', 'slut', 'dick', 'pussy', 'asshole', 'faggot', 'hitler', 'porn'];
  function tr(s, from, to) {
    var out = '';
    for (var i = 0; i < s.length; i++) { var j = from.indexOf(s[i]); out += j === -1 ? s[i] : to[j]; }
    return out;
  }
  // Büyük/küçük harf duyarsız anahtar (veritabanındaki kodhane_nick_key ile aynı): I/İ/ı/i hepsi 'i'.
  function nickKey(n) { return tr(String(n), 'ÇĞİIÖŞÜı', 'çğiiöşüi').toLowerCase(); }
  // Baştaki/sondaki boşluklar atılır, art arda boşluklar teke indirilir (veritabanıyla aynı).
  function normalizeNickname(raw) { return String(raw == null ? '' : raw).trim().replace(/ {2,}/g, ' '); }
  function validateNickname(raw) {
    var v = normalizeNickname(raw);
    var len = Array.from ? Array.from(v).length : v.length;
    if (len < 3) return { ok: false, value: v, error: 'too_short' };
    if (len > 16) return { ok: false, value: v, error: 'too_long' };
    if (!NICK_RE.test(v) || !HAS_ALNUM.test(v)) return { ok: false, value: v, error: 'invalid_chars' };
    var flat = tr(nickKey(v).replace(/[ _-]/g, ''), 'çğöşü013457', 'cgosuoieast');
    if (RESERVED.indexOf(flat) !== -1 || BLOCK_EXACT.indexOf(flat) !== -1) return { ok: false, value: v, error: 'blocked' };
    for (var i = 0; i < BLOCK_SUB.length; i++) if (flat.indexOf(BLOCK_SUB[i]) !== -1) return { ok: false, value: v, error: 'blocked' };
    return { ok: true, value: v, error: null };
  }
  var MESSAGES = {
    too_short: 'Takma ad 3-16 karakter olmalı.',
    too_long: 'Takma ad 3-16 karakter olmalı.',
    invalid_chars: 'Harf, rakam, boşluk, - ve _ kullanabilirsin.',
    blocked: 'Bu ad listeye uygun değil. Başka bir ad dene.',
    taken: 'Bu ad kapılmış. Başka bir tane dene.',
    offline: 'İnternet bağlantısı yok. Çevrimiçi olunca tekrar dene.',
    failed: 'Takma ad kaydedilemedi. Biraz sonra tekrar dene.'
  };
  function serverNickError(err) {
    var code = err && err.code, msg = (err && err.message) || '';
    if (code === '23505' || /duplicate|unique/i.test(msg)) return 'taken';
    if (code === '23514') {
      if (/too_short/.test(msg)) return 'too_short';
      if (/too_long/.test(msg)) return 'too_long';
      if (/invalid_chars/.test(msg)) return 'invalid_chars';
      if (/blocked/.test(msg)) return 'blocked';
    }
    if (/Failed to fetch|NetworkError|offline/i.test(msg)) return 'offline';
    return 'failed';
  }
  var STATUS_TEXT = {
    pending: 'Puanın kontrol ediliyor. Kısa süre içinde listede görünürsün.',
    hidden: 'Takma adın listeden kaldırıldı. Yeni bir ad seçebilirsin.'
  };
  function validRow(r) {
    return r && typeof r.nickname === 'string' && (r.status == null || r.status === 'ok') &&
      typeof r.score === 'number' && isFinite(r.score) && r.score >= 0 && typeof r.rank === 'number';
  }
  // Sunucu en iyi N'i sırayla, çağıranın satırı listede değilse sona ekleyerek döndürür. Kendi puanı kontrol
  // ediliyorsa ya da takma adı gizlendiyse yalnızca çağırana status 'pending' / 'hidden' satırı gelir (sırasız).
  function buildView(rows, limit) {
    limit = limit || LIMIT;
    var all = Array.isArray(rows) ? rows : [];
    var meStatus = null;
    all.forEach(function (r) { if (r && r.is_me && (r.status === 'pending' || r.status === 'hidden')) meStatus = r.status; });
    rows = all.filter(validRow);
    var top = rows.slice(0, limit);
    var me = null, pinned = null;
    rows.forEach(function (r) { if (r.is_me) me = r; });
    if (me && top.indexOf(me) === -1) pinned = me;
    return { top: top, me: me, pinned: pinned, empty: top.length === 0, meStatus: me ? null : meStatus };
  }
  // best_stage sunucuda eski (v4.3) aşama sırasıyla tutulur (0..8); v4.4'te araya aşama girdiği için sıra -> aşama ID'si -> aşama.
  function stageLabel(i) {
    if (typeof i !== 'number' || !isFinite(i) || i < 0) return '';
    var id = K.LEGACY_STAGE_IDS ? K.LEGACY_STAGE_IDS[Math.floor(i)] : null;
    var st = id && K.STAGE_BY_ID ? K.STAGE_BY_ID[id] : (K.LEGACY_STAGE_IDS ? null : (K.STAGES ? K.STAGES[i] : null));
    return st ? st.icon + ' ' + st.name : 'Aşama ' + (Math.floor(i) + 1); // yeni aşamalar eski sürümde de görünsün
  }
  function ownRankText(rank) { return 'Sen: #' + rank; }
  function rankBadge(rank) { return rank === 1 ? '🥇' : rank === 2 ? '🥈' : rank === 3 ? '🥉' : '#' + rank; }
  function gameLink() {
    try { return location.origin + location.pathname.replace(/index\.html$/, ''); } catch (e) { return 'https://thejackaltr.github.io/kodhane/'; }
  }
  function shareText(rank, link) { return 'Kodhane sıralamasında #' + rank + '. sıradayım! Sen de ajansını kur: ' + (link || gameLink()); }

  // ---------------------------------------------------------------- durum
  var L = {
    rows: null, view: null, loading: false, error: '', fetchedAt: 0, seq: 0,
    uid: null, profileUid: null, nickname: null, hidden: false, profileLoading: false, profileError: false,
    editing: false, saving: false, nickMsg: '', nickDraft: ''
  };
  var el = {};

  function cloud() { return K.cloud || null; }
  function cstate() { var c = cloud(); return c ? c.state : null; }
  function configured() { var c = cloud(); return !!(c && c.isConfigured && c.isConfigured()); }
  function isOnline() { return !('onLine' in navigator) || navigator.onLine !== false; }
  function signedUser() { var s = cstate(); return s && s.user ? s.user : null; }
  function visible() { return typeof K.activeTab === 'function' && K.activeTab() === 'siralama'; }
  function toast(m, ms) { if (K.toast) { try { K.toast(m, ms); } catch (e) {} } }

  function fetchRows() {
    var c = cloud(), s = cstate(), cfg = c.config;
    if (s && s.client && s.user) {
      return s.client.rpc(RPC, { p_limit: LIMIT, p_game: GAME }).then(function (r) { if (r.error) throw r.error; return r.data; });
    }
    // Misafir: SDK indirmeden, herkese açık anahtarla doğrudan çağrı
    return fetch(cfg.url + '/rest/v1/rpc/' + RPC, {
      method: 'POST',
      headers: { apikey: cfg.key, Authorization: 'Bearer ' + cfg.key, 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ p_limit: LIMIT, p_game: GAME })
    }).then(function (res) {
      if (!res.ok) throw new Error('HTTP ' + res.status);
      return res.json();
    });
  }
  function refresh() {
    if (!configured()) { render(); return Promise.resolve(); }
    if (!isOnline()) { L.error = 'offline'; L.loading = false; render(); return Promise.resolve(); }
    var my = ++L.seq;
    L.loading = true; L.error = '';
    render();
    var c = cloud(), s = cstate();
    // Girişliyse önce güncel kaydı buluta yaz: kendi puanın listede güncel görünsün.
    var pre = Promise.resolve();
    if (s && s.user && s.reconciled) {
      try { K.save(); } catch (e) {}
      pre = Promise.race([c.push(false).catch(function () {}), new Promise(function (r) { setTimeout(r, 5000); })]);
    }
    return pre.then(fetchRows).then(function (rows) {
      if (my !== L.seq) return;
      L.rows = rows; L.view = buildView(rows, LIMIT); L.fetchedAt = Date.now(); L.error = '';
      if (L.view.meStatus === 'hidden') L.hidden = true;
      else if (L.view.me || L.view.meStatus === 'pending') L.hidden = false;
    }).catch(function () {
      if (my !== L.seq) return;
      L.error = isOnline() ? 'failed' : 'offline';
    }).then(function () {
      if (my !== L.seq) return;
      L.loading = false; render();
    });
  }
  function loadProfile(force) {
    var u = signedUser(), s = cstate();
    if (!u || !s.client || L.profileLoading) return Promise.resolve();
    if (!force && L.profileUid === u.id && !L.profileError) return Promise.resolve();
    L.profileLoading = true; L.profileError = false;
    renderJoin();
    return s.client.from(TABLE).select('nickname,hidden').eq('user_id', u.id).maybeSingle().then(function (r) {
      if (r.error) throw r.error;
      L.profileUid = u.id; L.nickname = r.data && r.data.nickname ? r.data.nickname : null;
      L.hidden = !!(r.data && r.data.hidden);
    }).catch(function () { L.profileError = true; }).then(function () { L.profileLoading = false; renderJoin(); });
  }
  function onCloudRender() {
    var u = signedUser(), uid = u ? u.id : null;
    if (uid !== L.uid) {
      L.uid = uid; L.nickname = null; L.hidden = false; L.profileUid = null; L.profileError = false; L.editing = false; L.nickMsg = '';
      if (el.list && visible()) { loadProfile(); refresh(); }
      else L.fetchedAt = 0;
    }
    if (el.join && visible()) renderJoin();
  }
  function onShown() {
    if (!el.list) return;
    if (signedUser()) loadProfile();
    if (!L.loading && (Date.now() - L.fetchedAt > STALE_MS || L.error)) refresh();
    else render();
  }

  // ---------------------------------------------------------------- takma ad
  function submitNick(ev) {
    if (ev) ev.preventDefault();
    if (L.saving) return;
    var input = el.join.querySelector('#lbNick');
    var v = validateNickname(input ? input.value : '');
    L.nickDraft = input ? input.value : '';
    if (!v.ok) { L.nickMsg = MESSAGES[v.error]; renderJoin(true); return; }
    if (!isOnline()) { L.nickMsg = MESSAGES.offline; renderJoin(true); return; }
    var u = signedUser();
    if (!u) return;
    L.saving = true; L.nickMsg = ''; renderJoin();
    cloud().getClient().then(function (client) {
      return client.from(TABLE).upsert({ user_id: u.id, nickname: v.value }, { onConflict: 'user_id' });
    }).then(function (r) {
      if (r && r.error) throw r.error;
      var first = !L.nickname;
      // Aynı adı (büyük/küçük harf farkıyla) yeniden seçmek gizlemeyi kaldırmaz; yeni ad kaldırır (sunucuyla aynı kural).
      L.hidden = L.hidden && !!L.nickname && nickKey(L.nickname) === nickKey(v.value);
      L.nickname = v.value; L.profileUid = u.id; L.editing = false; L.saving = false; L.nickDraft = '';
      toast(first ? '🏆 Sıralamaya katıldın! Takma adın: ' + v.value : '✏️ Takma adın güncellendi: ' + v.value, 3500);
      renderJoin();
      loadProfile(true);
      return refresh();
    }).catch(function (e) {
      L.saving = false;
      L.nickMsg = MESSAGES[serverNickError(e)];
      renderJoin(true);
    });
  }
  function share() {
    var me = L.view && L.view.me;
    if (!me) return;
    if (!me || typeof me.rank !== 'number') return;
    var text = shareText(me.rank);
    if (K.track) K.track('share_click');
    if (navigator.share) {
      navigator.share({ text: text }).catch(function () {});
    } else if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () { toast('📋 Paylaşım metni kopyalandı.', 3000); },
        function () { toast(text, 6000); });
    } else toast(text, 6000);
  }

  // ---------------------------------------------------------------- arayüz
  function node(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }
  function rowNode(r) {
    var li = node('li', 'lb-row' + (r.is_me ? ' me' : '') + (r.rank <= 3 ? ' top' + r.rank : ''));
    li.appendChild(node('span', 'lb-rank', rankBadge(r.rank)));
    var who = node('div', 'lb-who');
    var nm = node('div', 'lb-name', r.nickname);
    if (r.is_me) nm.appendChild(node('span', 'lb-you', 'sen'));
    who.appendChild(nm);
    var st = stageLabel(r.stage);
    if (st) who.appendChild(node('div', 'lb-stage', st));
    li.appendChild(who);
    li.appendChild(node('span', 'lb-score', K.tl(r.score)));
    return li;
  }
  function renderList() {
    var v = L.view;
    el.list.innerHTML = '';
    el.me.innerHTML = '';
    el.me.classList.add('hidden');
    if (v && !v.empty) {
      v.top.forEach(function (r) { el.list.appendChild(rowNode(r)); });
      if (v.pinned) {
        el.me.appendChild(node('div', 'lb-gap', '⋯'));
        var ol = node('ol', 'lb-list');
        ol.appendChild(rowNode(v.pinned));
        el.me.appendChild(ol);
        el.me.classList.remove('hidden');
      }
    }
    el.list.classList.toggle('hidden', !(v && !v.empty));
  }
  function renderStatus() {
    var t = '', cls = 'lb-status';
    if (!configured()) t = 'Sıralama bu sürümde kullanılamıyor.';
    else if (L.error === 'offline') { t = '📡 Sıralama için internet bağlantısı gerekli'; cls += ' warn'; }
    else if (L.error) { t = 'Sıralama yüklenemedi. Bağlantını kontrol edip yenile.'; cls += ' warn'; }
    else if (L.loading && !L.view) t = 'Sıralama derleniyor…';
    else if (L.view && L.view.empty) t = 'Liste henüz boş. Birinciliği kapmak için tek proje yeter.';
    el.status.textContent = t;
    el.status.className = cls + (t ? '' : ' hidden');
    if (L.error === 'failed' && configured()) {
      var rb = node('button', 'btn ghost lb-retry', 'Yenile'); rb.type = 'button'; rb.id = 'lbRetry';
      rb.disabled = L.loading;
      rb.addEventListener('click', manualRefresh);
      el.status.appendChild(node('br')); el.status.appendChild(rb);
    }
    el.refresh.disabled = L.loading || !configured();
    el.refresh.textContent = '↻ Yenile';
  }
  function renderJoin(focus) {
    if (!el.join) return;
    var box = el.join;
    box.innerHTML = '';
    if (!configured()) { box.classList.add('hidden'); return; }
    var u = signedUser();
    box.classList.remove('hidden');
    box.className = 'lb-join';
    if (!u) {
      box.appendChild(node('p', null, 'Listeye girmek için giriş yap. İlerlemen de buluta kaydolur.'));
      var b = node('button', 'btn primary', 'Giriş yap');
      b.type = 'button'; b.id = 'lbSignIn';
      b.addEventListener('click', function () { var c = cloud(); if (c) c.open(); });
      box.appendChild(b);
      return;
    }
    if (L.profileLoading && L.profileUid !== u.id) { box.classList.add('hidden'); return; }
    if (L.profileError && L.profileUid !== u.id) {
      box.appendChild(node('p', null, 'Takma adın şu an kontrol edilemedi.'));
      var rb = node('button', 'acc-link', 'Tekrar dene'); rb.type = 'button';
      rb.addEventListener('click', function () { loadProfile(); });
      box.appendChild(rb);
      return;
    }
    if (!L.nickname || L.editing || L.hidden) {
      box.classList.add('form');
      if (L.hidden) box.appendChild(node('p', 'lb-flag', STATUS_TEXT.hidden));
      var f = node('form', 'lb-form'); f.id = 'lbNickForm'; f.noValidate = true;
      var lab = node('label', 'lb-label', 'Listede hangi adla görünmek istersin?');
      lab.htmlFor = 'lbNick';
      var row = node('div', 'lb-form-row');
      var inp = node('input'); inp.id = 'lbNick'; inp.type = 'text'; inp.maxLength = 16; inp.autocomplete = 'off';
      inp.setAttribute('autocapitalize', 'off'); inp.spellcheck = false; inp.placeholder = 'Takma ad';
      inp.value = L.nickDraft || (L.editing && !L.hidden ? L.nickname : '') || '';
      inp.setAttribute('aria-describedby', 'lbNickHint lbNickMsg');
      var sb = node('button', 'btn primary', L.saving ? 'Kaydediliyor…' : 'Listeye gir');
      sb.type = 'submit'; sb.id = 'lbNickSave'; sb.disabled = L.saving;
      row.appendChild(inp); row.appendChild(sb);
      f.appendChild(lab); f.appendChild(row);
      var hint = node('p', 'lb-hint', '3-16 karakter. E-postan hiçbir yerde görünmez.');
      hint.id = 'lbNickHint';
      f.appendChild(hint);
      var msg = node('p', 'lb-msg', L.nickMsg); msg.id = 'lbNickMsg'; msg.setAttribute('aria-live', 'polite');
      if (!L.nickMsg) msg.classList.add('hidden');
      f.appendChild(msg);
      if (L.editing && !L.hidden) {
        var cb = node('button', 'acc-link', 'Vazgeç'); cb.type = 'button';
        cb.addEventListener('click', function () { L.editing = false; L.nickMsg = ''; L.nickDraft = ''; renderJoin(); });
        f.appendChild(cb);
      }
      f.addEventListener('submit', submitNick);
      inp.addEventListener('input', function () { L.nickDraft = inp.value; if (L.nickMsg) { L.nickMsg = ''; msg.textContent = ''; msg.classList.add('hidden'); } });
      box.appendChild(f);
      if (focus) setTimeout(function () { try { inp.focus(); } catch (e) {} }, 0);
      return;
    }
    var me = L.view && L.view.me;
    if (me) {
      box.appendChild(node('p', 'lb-joined', ownRankText(me.rank)));
      if (me.rank === 1) box.appendChild(node('p', 'lb-top', 'Zirvedesin. Logoyu büyütmenin tam zamanı.'));
    } else if (L.view && L.view.meStatus === 'pending') {
      box.appendChild(node('p', 'lb-flag', STATUS_TEXT.pending));
    } else if (L.view) {
      box.appendChild(node('p', 'lb-hint', 'Kaydın buluta yüklenince burada görüneceksin.'));
    }
    var acts = node('div', 'lb-actions');
    if (me) {
      var sh = node('button', 'btn ghost', '📣 Sıramı paylaş'); sh.type = 'button'; sh.id = 'lbShare';
      sh.addEventListener('click', share);
      acts.appendChild(sh);
    }
    var ed = node('button', 'acc-link', 'Takma adı değiştir'); ed.type = 'button'; ed.id = 'lbEdit';
    ed.addEventListener('click', function () { L.editing = true; L.nickMsg = ''; L.nickDraft = ''; renderJoin(true); });
    acts.appendChild(ed);
    box.appendChild(acts);
  }
  function render() {
    if (!el.list) return;
    renderStatus(); renderList(); renderJoin();
  }

  function manualRefresh() { if (signedUser()) { L.profileError = false; loadProfile(true); } refresh(); }
  function start() {
    ['lbList', 'lbMe', 'lbStatus', 'lbJoin', 'lbRefresh'].forEach(function (id) { el[id] = document.getElementById(id); });
    el.list = el.lbList; el.me = el.lbMe; el.status = el.lbStatus; el.join = el.lbJoin; el.refresh = el.lbRefresh;
    if (!el.list) return;
    el.refresh.addEventListener('click', manualRefresh);
    root.addEventListener('online', function () { if (visible()) refresh(); });
    root.addEventListener('offline', function () { if (visible()) { L.error = 'offline'; render(); } });
    var s = cstate();
    L.uid = s && s.user ? s.user.id : null;
    render();
    if (visible()) onShown();
  }

  // Anonim sayaç (haber gösterimi/tıklaması): yalnızca olay adı gider; kullanıcı kimliği, IP vb. saklanmaz.
  var COUNT_RPC = 'kodhane_count_event';
  // v4.3: izin (game.js GATE_SUPABASE_COUNTER + isimsiz sayaç izni) yoksa istek hiç yapılmaz. Yalnızca bu sayaç;
  // giriş, bulut kaydı ve sıralama izinden bağımsız çalışır.
  function countEvent(name) {
    if (typeof K.counterAllowed !== 'function' || !K.counterAllowed()) return;
    if (!configured() || !isOnline()) return;
    var cfg = cloud().config;
    try {
      fetch(cfg.url + '/rest/v1/rpc/' + COUNT_RPC, {
        method: 'POST', keepalive: true, credentials: 'omit',
        headers: { apikey: cfg.key, Authorization: 'Bearer ' + cfg.key, 'Content-Type': 'application/json' },
        body: JSON.stringify({ p_event: String(name) })
      }).catch(function () {});
    } catch (e) {}
  }
  K.countEvent = countEvent;
  K.newsNeedsLeaderboard = configured; // Sıralama haberi yalnızca sıralama kullanılabilirse gösterilir

  K.onLeaderboardShown = onShown;
  K.onCloudRender = onCloudRender;
  K.leaderboard = {
    state: L, refresh: refresh, validateNickname: validateNickname, normalizeNickname: normalizeNickname, nickKey: nickKey, buildView: buildView,
    serverNickError: serverNickError, messages: MESSAGES, statusText: STATUS_TEXT, ownRankText: ownRankText, shareText: shareText,
    stageLabel: stageLabel, rankBadge: rankBadge, LIMIT: LIMIT, STALE_MS: STALE_MS, GAME: GAME
  };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})(typeof window !== 'undefined' ? window : this);
