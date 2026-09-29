/* Kodhane: Ajans Tycoon — v4.4.0 (Halka Arz hisseleri korur + hızlandırıcı + 12 sa bekleme + Unicorn / Şirketler Grubu aşamaları + aşama ID'leri, isimsiz sayaç izni + gizlilik ayarı + güvenli kayıt sıfırlama + yeni aşamalar + Halka Arz + Borsa Payı Ağacı + müşteri sektörleri)
 * Vanilla JS, derleme adımı yok. Tüm oyun metinleri Türkçe.
 * v1 kayıtları ('kodhane_ajans_save_v1') ilk açılışta otomatik olarak taşınır; v2/v3/v4 kayıtları kayıpsız yeni alanları alır.
 * Denge sayıları CFG (ayarlar) ve tablolarda durur; açıklama metinleri sayıları bu ayarlardan okur.
 * Bulut kaydı (isteğe bağlı giriş) cloud.js içindedir; oyun onsuz da tam çalışır.
 */
(function (root) {
  'use strict';

  // ------------------------------------------------------------------
  // Tanımlar (denge değerleri)
  // ------------------------------------------------------------------
  var VERSION = '4.4.0';
  // kayıt biçimi (3 = oyun v4, 4 = v4.1, 5 = v4.4: aşamalar ID ile). Kayda 'version' ve (v4.3.1'den beri) 'saveVersion' olarak yazılır.
  var SAVE_VERSION = 5;
  var SAVE_KEY = 'kodhane_ajans_save_v2';
  var LEGACY_KEYS = ['kodhane_ajans_save_v1'];
  var SETTINGS_KEY = 'kodhane_ayarlar_v1';
  var COST_GROWTH = 1.15;
  var AUTOSAVE_MS = 10000;
  var BASE_CLICK = 1;
  var CRIT_CHANCE = 0.05;
  var CRIT_MULT = 10;
  var ACH_BONUS = 0.01;        // her başarım kalıcı +%1 üretim
  var REP_MAX = 100;
  var REP_OFFER_BONUS = 0.01;  // her itibar puanı müşteri projesi ödemelerine +%1

  // v4 ayarları: sabit sayı yok, metinler de buradan okur
  var CFG = {
    offlineCapHours: 8,          // çevrimdışı kazanç sınırı (Uzaktan Çalışma / Gece Vardiyası ile artar)
    offerSec: 10,                // müşteri projesi teklifinin ekranda kalma süresi
    offerFirst: [45, 90],        // ilk teklif aralığı (sn)
    offerEvery: [60, 180],       // sonraki teklifler (sn)
    stageModalSec: 7,            // aşama tebrik penceresi kendiliğinden kapanma süresi
    newsDelaySec: 4,             // oturum açıldıktan sonra haberin gösterilmesi için bekleme
    newsPerSession: 1,           // oturum başına en fazla haber
    halkaArz: {
      rounds: 3,                 // Halka Arz, bu döngüde bu kadar Yatırım Turu'ndan sonra açılır
      // Borsa Payı = max(ilk ? firstMin : 0, bu döngüde ulaşılan en yüksek aşamanın payı (stagePays[aşama ID'si]))
      mode: 'stage',             // 'stage' (seçilen) | 'root': floor(k * (döngü kazancı / threshold)^(1/root)) (karşılaştırma için)
      // v4.4 (E100cd12): aşama ID'si -> Borsa Payı (listede olmayan aşama 0 pay). Simülasyon: tests/balance_v44.js PAYS44.
      stagePays: { global_holding: 2, unicorn: 3, sirketler_grubu: 4, teknoloji_devi: 5, yapay_zeka_lab: 8, mars_ofisi: 12 },
      repeatMinStage: 'teknoloji_devi', // 2. halka arzdan itibaren pay için en az bu aşama (hızlı tekrar = pay çiftliği olmasın)
      k: 1, threshold: 1e14, root: 6,
      firstMin: 1,
      unspentBonus: 0.01,        // harcanmamış her Borsa Payı kalıcı +%1 üretim...
      unspentCap: 50,            // ...en fazla bu kadar pay sayılır (+%50; hızlı halka arz çiftliği katlanarak büyümesin)
      // v4.4 (E100cd12): Halka Arz hisseleri silmez. Yatırımcı hisselerinin keepShares oranı kalır (1 = hepsi; keepMode
      // 'floor' = tam sayıya aşağı yuvarlanır); bankPending: bu turda biriken (henüz Yatırım Turu yapılmamış) hisse de önce eklenir.
      keepShares: 1.0, keepMode: 'floor', bankPending: true,
      // Borsa hızlandırıcısı: kazanılmış her Borsa Payı (ipoSharesEarned, harcansa da sayılır) Yatırım Turu hissesini
      // +shareGainPerEarned artırır; en fazla accelCap pay sayılır (0,10 x 40 = +%400, yani en fazla 5 kat).
      shareGainPerEarned: 0.10, accelCap: 40,
      // İki Halka Arz arasında en az bu kadar saniye (12 sa). Son Halka Arz anı kayıtta (ipoAt, ms). Eski kayıtta alan yoksa ilk
      // Halka Arz hemen açıktır; ileri tarihli ipoAt yüklemede ve her kontrolde şimdiye çekilir (bekleme en fazla cooldownSec).
      // NOT: 12 saatin altına inerse arka arkaya Halka Arz yeniden mümkün olur (pay çiftliği; kodhane-v4.4-sim-sonuclari.md bölüm 6).
      cooldownSec: 43200
    },
    tree: {
      costs: [1, 3, 6],          // her dalda 1., 2., 3. düğüm (Borsa Payı)
      clickMult: 2,              // Parmak Hızı
      flowChance: 0.05, flowMult: 10, // Akış Hâli
      clickPct: 0.01,            // Kas Hafızası
      genMult: 1.5,              // İyi Referans
      startGens: [['stajyer', 5], ['junior', 2]], // Hazır Kadro
      costGrowth: 1.14,          // İK Anlaşması
      offerMore: 0.25,           // Sadık Müşteri: teklifler %25 daha sık (aralık / 1,25)
      offerSec: 15,              // Esnek Teslim
      offerPayMult: 2,           // Referans Zinciri
      offlineHours1: 12,         // Uzaktan Çalışma
      shareBoost: 0.25,          // Yatırımcı Güveni
      offlineHours2: 24          // Gece Vardiyası (üst sınır)
    },
    utm: { stage: 'asama_paylasim', ipo: 'halka_arz' }, // paylaşım bağlantısı kampanya etiketleri
    // Müşteri sektörleri (olay kartları). Ödemeler "saniyelik üretim x saniye" (pay()), süreler saniye.
    sectors: {
      share: 0.5,                // açık sektör varken olay kartlarının bu kadarı sektör kartı
      rejectSec: 600,            // reddedilen sektörden kartlar bu süre boyunca azalır...
      rejectWeight: 0.25,        // ...bu ağırlıkla (itibar etkilenmez)
      unlock: { esnaf: 'freelancer', eticaret: 'butik_studyo', oyun: 'ajans', kamu: 'dev_ajans' }, // açıldığı aşama ID'si (en iyi aşama; Yatırım Turu'nda kapanmaz)
      eticaret_sunucu: { cost: 20, pay: 120 },
      eticaret_buton: { pay: 25, sec: 20, mult: 0.9 },
      oyun_yama: { pay: 150, sec: 60, mult: 0.7 },
      oyun_karakter: { pay: 40, sec: 40, mult: 0.85 },
      kamu_ihale: { pay: 240, delay: 300 },
      kamu_imza: { pay: 60, delay: 60 },
      esnaf_kafe: { pay: 20, revisions: 3, revPay: 10, revSec: 15, revMult: 0.95 },
      esnaf_emlak: { pay: 15, returnChance: 0.35, supportPay: 5, supportSec: 10, supportMult: 0.95 }
    },
    // v4.2: Kaydı sıfırla. Metinlerdeki {s} = undoSeconds, {d} = backupDays (metinlere sayı yazılmaz).
    reset: {
      undoSeconds: 10,           // sıfırladıktan sonra "Geri al" düğmesinin kalma süresi (sn)
      backupDays: 30             // YER TUTUCU (onay bekliyor): silinen bulut kaydının yedekte kalma süresi (gün); Backend'in saklama süresiyle aynı olmalı
    },
    // v4.4: kayıt içi olay listesi (S.eventLog). Son max olay (FIFO): Halka Arz, Yatırım Turu, Kaydı sıfırla. Her girdi YALNIZCA
    // { type, at (ms), sharesBefore, sharesAfter, paysBefore, paysAfter }. Hiçbir yere gönderilmez (Umami / sayaç yok); yalnızca
    // kaydın parçası olarak (bulut kaydı dahil) durur. Gizlilik metni (telemetry.details) "son 20" der: max değişirse metin de değişmeli.
    eventLog: { max: 20 }
  };
  // Testler için geçersiz kılma (ör. { reset: { undoSeconds: 2 } })
  if (root && root.KODHANE_CFG_OVERRIDE && typeof root.KODHANE_CFG_OVERRIDE === 'object') {
    var CO = root.KODHANE_CFG_OVERRIDE;
    if (CO.reset && typeof CO.reset === 'object') for (var cok in CO.reset) CFG.reset[cok] = CO.reset[cok];
  }

  // v4.2: "Kaydı sıfırla" metinlerinin tamamı (anahtarlar ve yazım, metin yazarının kodhane-reset-copy.json dosyasından birebir).
  // {s} ve {d} yer tutucuları resetText() ile CFG.reset'ten doldurulur.
  var RESET_TEXT = {
    "reset.title": "Kaydın sıfırlansın mı?",
    "reset.body": "Oyuna en baştan başlarsın. Kalacaklar dışında her şey silinir, silinecekleri seçemezsin.",
    "reset.deleteTitle": "Silinecekler",
    "reset.deleteList": ["Para ve kazanç", "Çalışanlar", "Geliştirmeler", "Başarımlar", "Yatırım turu hisseleri ve yatırım turu sayısı", "Halka Arz, Borsa Payları ve ağaç", "Aşama ilerlemesi", "Haberler", "İtibar ve günlük seri"],
    "reset.keepTitle": "Kalacaklar",
    "reset.keepList": ["Tüm Zamanlar puanın ve sıradaki yerin", "Takma adın", "Kodhane hesabın", "Son olayların listesi", "Ses, titreşim ve gizlilik ayarların"],
    "reset.prestigeHint": "Başarımlarını, itibarını ve günlük serini korumak istiyorsan sıfırlamak yerine yatırım turuna çık. Yatırım turunda bunlar korunur, üstüne bir üretim bonusu kazanırsın. Bu bonus Halka Arz'da da silinmez.",
    "reset.prestigeBtn": "Yatırım turuna git",
    "reset.backup": "Silinen kayıt {d} gün boyunca yedekte kalır. Bu süre içinde geri yükleyebilirsin.",
    "reset.hold": "Sıfırlamak için basılı tut",
    "reset.holding": "Sıfırlanıyor… Vazgeçmek için bırak.",
    "reset.cancel": "Vazgeç",
    "reset.done": "Kaydın sıfırlandı. Oyun baştan başlıyor.",
    "reset.undo": "Geri al ({s})",
    "reset.undoDone": "Sıfırlama geri alındı. Kaldığın yerden devam ediyorsun.",
    "reset.restoreTitle": "Yedekten geri yükle",
    "reset.restoreBody": "Yedekteki kayıt, şu anki ilerlemenin yerine geçer.",
    "reset.restoreBtn": "Geri yükle",
    "reset.restoreDone": "Kaydın geri yüklendi.",
    "reset.otherDevice": "Kaydın başka bir cihazda sıfırlandı. Bu cihazda da oyun baştan başlıyor. Yanlışlıkla olduysa yedeği geri yükleyebilirsin.",
    // girişli oyuncuda kodhane_reset_save RPC'si başarısız (sıfırlama yapılmaz) / yedekten geri yükleme başarısız /
    // eşzamanlı oyun 409'u (sıfırlama değil)
    "reset.cloudFailed": "Kaydın şu an sıfırlanamadı. Bağlantını kontrol edip tekrar dene.",
    "reset.restoreFailed": "Yedek şu an geri yüklenemedi. Bağlantını kontrol edip tekrar dene.",
    "reset.otherDeviceSync": "Oyuna başka bir cihazda ya da sekmede devam ettin. Güncel kaydın yüklendi."
  };
  // Yalnızca girişli oyunculara gösterilen metinler (misafir asla görmez)
  var RESET_SIGNED_ONLY = ['reset.backup', 'reset.restoreTitle', 'reset.restoreBody', 'reset.restoreBtn', 'reset.restoreDone', 'reset.restoreFailed', 'reset.cloudFailed'];
  function resetText(key, vars) {
    var t = RESET_TEXT[key];
    if (Array.isArray(t)) return t.slice();
    if (typeof t !== 'string') return '';
    var v = { s: CFG.reset.undoSeconds, d: CFG.reset.backupDays };
    if (vars) for (var vk in vars) v[vk] = vars[vk];
    return t.replace(/\{(s|d)\}/g, function (m, k) { return String(v[k]); });
  }

  // Yatırım Turu / Halka Arz / bekleme metinleri ve yeni sürüm (daha yeni kayıt) bandı. Onaylı kesin metin (v4.4: Yazı r3,
  // kodhane-v4.4-metinler-yazi-r3.md). Metinlerde sayı yok; yer tutucular uiText() ile CFG'den ve oyundan doldurulur:
  //  {g} kazanılacak hisse (hızlandırıcı dahil), {b} bu turun hisselerinin bonusu, {p} Halka Arz'da eklenecek bu turun
  //  hissesi, {n} kazanılacak Borsa Payı, {y} Halka Arz sonrası yatırımcı bonusu, {z} hızlandırıcı yüzdesi (bu Halka Arz'ın
  //  payları dahil), {u} harcanmamış pay başına üretim, {h} iki Halka Arz arası en kısa süre ("12 saat"), {s} kalan süre
  //  (fmtSec), {k} pay başına hızlandırma, {max} en fazla kat, {x} Halka Arz sonrası Borsa Payı toplamı.
  var UI_TEXT = {
    "prestige.confirm": "Yatırımcılar şirketine <b>{g} hisse</b> karşılığında yatırım yapacak. Paran, çalışanların ve geliştirmelerin sıfırlanır; karşılığında tüm kazançlara <b>+%{b}</b> bonus alırsın. Bu bonus Halka Arz'da da silinmez. Başarımların, itibarın ve günlük serin korunur.",
    // p >= 1 iken tam metin; p < 1 iken ilk cümle ipo.confirm.noPending olur, hızlandırıcı tavandaysa ikinci satırın sonu
    // ipo.confirm.accelMax olur; isteğe bağlı bonus satırı (ipo.confirm.bonus) p >= 1 iken "Kazanacağın"dan önce gelir.
    "ipo.confirm": "Kasa, çalışanlar ve geliştirmeler sıfırlanacak. Yatırımcı hisselerin korunur, bu turda biriken <b>{p} hisse</b> de eklenir. Borsa Payı Ağacı, başarımların ve sıralamadaki puanın da kalır.<br>Kazanacağın: <b>{n} Borsa Payı</b>. Sonraki Yatırım Turlarında hisselerin %{z} fazla gelir.<br><small>Harcamadığın her Borsa Payı +%{u} üretim verir. Sonraki Halka Arz için en az {h} beklemen gerekir.</small>",
    "ipo.confirm.noPending": "Kasa, çalışanlar ve geliştirmeler sıfırlanacak. Yatırımcı hisselerin korunur. Borsa Payı Ağacı, başarımların ve sıralamadaki puanın da kalır.",
    "ipo.confirm.accel": "Sonraki Yatırım Turlarında hisselerin %{z} fazla gelir.",
    "ipo.confirm.accelMax": "Sonraki Yatırım Turlarında hisselerin %{z} fazla gelir (en fazla).",
    "ipo.confirm.bonus": "Yatırımcı bonusun +%{y} olur.",
    "ipo.done": "Artık halka açık bir şirketsin. Hisselerin yerinde duruyor. Borsa Payların: <b>{x}</b>",
    "ipo.btnWait": "Halka arz et ({s})",
    "ipo.lockWait": "⏳ Sonraki Halka Arz için {s} kaldı.",
    "ipo.lockWaitNote": "İki Halka Arz arasında en az {h} olmalı.",
    "ipo.reopened": "🔔 Halka Arz yeniden açık.",
    "ipo.accelLabel": "Hisse hızlandırıcısı",
    "ipo.accelValue": "+%{z}",
    "ipo.accelValueMax": "+%{z} (en fazla)",
    "ipo.accelNote": "Kazandığın her Borsa Payı yeni hisseleri +%{k} artırır, harcasan da sayılır. En fazla {max} kat.",
    "update.newerSave.text": "✨ Yeni sürüm hazır, ilerlemen korunuyor. Devam etmek için yenile.",
    "update.newerSave.textShort": "✨ Yeni sürüm hazır, ilerlemen korunuyor.",
    "update.newerSave.btn": "Yenile",
    // v4.4: eski sekme uyarısı (Yazı, kodhane-v4.4-eski-sekme-yazi-r1): bulut kaydı yazılırken sunucu 426 / PT426
    // save_version_too_old döndü (hesaptaki kayıt bu istemciden yeni sürümle yazılmış). Aynı bantta newerSave'den önceliklidir.
    "update.olderTab.title": "Oyunun yeni sürümü var",
    "update.olderTab.text": "Hesabına oyunun yeni sürümünden kayıt yapıldı, bu sekmede oynadıkların artık kaydedilmiyor.",
    "update.olderTab.btn": "Sayfayı yenile",
    "update.olderTab.textShort": "Bu sekmede oynadıkların kaydedilmiyor."
  };
  function uiText(key, vars) {
    var t = UI_TEXT[key];
    if (typeof t !== 'string') return '';
    return t.replace(/\{([a-z]+)\}/g, function (m, k) { return vars && vars[k] !== undefined ? String(vars[k]) : m; });
  }

  // v4.3: İsimsiz sayaç (Umami + anonim Supabase sayacı) izin metinleri. Onaylı kesin metin; olduğu gibi kullanılır
  // (tests/fixtures/kodhane-telemetry-copy.json ile birebir karşılaştırılır).
  var TEL_TEXT = {
    "telemetry.title": "İsimsiz sayaç",
    "telemetry.body": "Oyunu geliştirmek için ziyaretleri ve bazı oyun olaylarını isimsiz olarak sayıyoruz. Hesap bilgilerin ve takma adın gönderilmez. İstemezsen kapatabilirsin.",
    "telemetry.ok": "Tamam",
    "telemetry.off": "Kapat",
    "telemetry.detailsLink": "Ayrıntılar",
    "telemetry.detailsTitle": "İsimsiz sayaç hakkında",
    "telemetry.details": [
      "Oyunu geliştirmek için sayfa ziyaretlerini ve bazı oyun olaylarını Teserix'in kendi analiz sunucusunda sayıyoruz. Sayılan olaylar şunlar: oyuna başlama, giriş, oturumdaki ilk bulut kaydı, sıfırlama, Yatırım turu, Halka Arz, Borsa Payı ağacının dolması, paylaşım ve Açık Ofis haberine tıklama. Çoğu olayda bizim gönderdiğimiz yalnızca olayın adı. İki olayda oyundaki ilerlemenden birkaç bilgi de gider: Halka Arz'da ulaştığın aşama, kazandığın Borsa Payı ve kaçıncı Halka Arz olduğu; ağaç dolduğunda oyuna başladığından bu yana geçen süre (tam saat olarak), kaçıncı Halka Arz olduğu ve oyuna v4.4 güncellemesinden önce mi, sonra mı başladığın. Bunların dışında hesabın ya da kaydının içeriği gönderilmez. Analiz aracı her kayda standart olarak şunları da ekler: sayfa adresi (? ve # işaretinden sonrası hariç), sayfa başlığı, geldiğin site, alan adı, ekran boyutu, tarayıcı dili, tarayıcın, işletim sistemin ve cihaz türün. Konum yalnızca ülke düzeyinde tutulur, IP adresi istatistik kayıtlarına yazılmaz. Ziyaret kayıtları 13 ay sonra silinir.",
      "Ayrıca sıralama ve Açık Ofis haberlerinin kaç kez gösterildiğini ve tıklandığını Teserix'in kendi sunucusunda sayıyoruz. Bu sayımda yalnızca olayın adı gider. Sunucu olayları tek tek kaydetmez, yalnızca o günün toplamını bir artırır. Hesap bilgisi, IP adresi ya da cihaz bilgisi bu sayıma yazılmaz.",
      "Site Cloudflare üzerinden sunulduğu için Cloudflare de sayfa açılışlarını kendi aracıyla ayrıca sayar. Cloudflare'in açıklamasına göre bu araç çerez kullanmaz ve ziyaretçileri tanımaya çalışmaz.",
      "Bu iki sayaç da yalnızca bu bildirime “Tamam” dedikten sonra çalışır. “Tamam” demeden hiçbiri bir şey göndermez. İstediğin zaman İstatistik sekmesindeki Gizlilik bölümünden kapatabilirsin. Kapattığın anda ikisi de durur. Cloudflare'in sayımı bunun dışındadır ve sayfa açıldığında çalışır.",
      "Kaydın, son 20 önemli olayı da kendi içinde tutar: Halka Arz, Yatırım turu ve sıfırlama, ayrıca bu olaylardan önceki ve sonraki hisse ve Borsa Payı sayıların. Bu liste yalnızca kaydının içinde durur. Bulut kaydı kullanıyorsan kaydınla birlikte buluta gider, başka hiçbir yere gönderilmez. Bir destek talebinde neyin ne zaman olduğunu görmek için kullanılır. Kaydını sıfırlasan da bu liste kalır. Hesabın silinirse liste sunucudan silinir, bu cihazdaki kaydınla birlikte cihazında kalır.",
      "Bu bilgilerin veri sorumlusu Teserix Bilişim ve Dijital Çözümler. KVKK'nın 11. maddesindeki haklarını kullanmak için info@teserix.com adresine yazabilirsin."
    ],
    "telemetry.detailsClose": "Kapat",
    "telemetry.offToast": "Sayaç kapatıldı. Bizim sayaçlarımız artık hiçbir şey göndermeyecek.",
    "telemetry.onToast": "Sayaç açıldı. Teşekkürler!",
    "settings.privacy": "Gizlilik",
    "settings.telemetryOn": "📊 İsimsiz sayaç: Açık",
    "settings.telemetryOff": "📊 İsimsiz sayaç: Kapalı",
    "settings.telemetryHint": "Ziyaretler ve bazı oyun olayları isimsiz olarak sayılır. Hesabın ya da kaydının içeriği gönderilmez. Cloudflare'in sayımı bu ayardan bağımsızdır."
  };
  function telText(key) { var t = TEL_TEXT[key]; return Array.isArray(t) ? t.slice() : (typeof t === 'string' ? t : ''); }
  // "Başka cihazda sıfırlandı" metni: yedek/geri yükleme cümlesi yalnızca girişli oyuncuya gösterilir.
  function otherDeviceText(signedIn, kind) {
    if (kind === 'sync') return resetText('reset.otherDeviceSync');
    var t = resetText('reset.otherDevice');
    if (signedIn) return t;
    return (t.match(/[^.]+\.?/g) || [t]).filter(function (x) { return !/yede|geri yükle/i.test(x); }).join('').trim();
  }

  var GENERATORS = [
    { id: 'stajyer',  name: 'Stajyer',               icon: '🧑‍🎓', base: 15,        tps: 0.2,   desc: 'Kahve getirir, bazen de kod yazar.' },
    { id: 'junior',   name: 'Junior Geliştirici',    icon: '👩‍💻', base: 100,       tps: 1,     desc: 'Soru-cevap sitelerinin en sadık ziyaretçisi.' },
    { id: 'senior',   name: 'Senior Geliştirici',    icon: '🧔',   base: 1100,      tps: 8,     desc: '“Bende çalışıyordu” der, haklıdır.' },
    { id: 'tasarimci',name: 'Tasarımcı',             icon: '🎨',   base: 12000,     tps: 47,    desc: 'Logoyu biraz daha büyütür.' },
    { id: 'pm',       name: 'Proje Yöneticisi',      icon: '📋',   base: 130000,    tps: 260,   desc: 'Toplantıları toplantıyla planlar.' },
    { id: 'ai',       name: 'Yapay Zekâ Kod Ajanı',  icon: '🤖',   base: 1400000,   tps: 1400,  desc: 'Gece gündüz yorulmadan commit atar.' },
    { id: 'sunucu',   name: 'Sunucu Odası',          icon: '🖥️',   base: 20000000,  tps: 7800,  desc: 'Uğultusu para sesi gibidir.' },
    { id: 'ofis',     name: 'Yurt Dışı Ofis',        icon: '🌍',   base: 330000000, tps: 44000, desc: 'Güneş hiç batmayan ajans.' },
    // v4: her yeni aşama bir çalışan tipi açar (stage = gereken aşamanın ID'si). v4.4: Veri Merkezi (Unicorn) ve Çip Fabrikası
    // (Teknoloji Devi) yeni; Ar-Ge Kampüsü Şirketler Grubu'na taşındı. Maliyet/üretim simülasyondan (balance_v44.js GENS44).
    { id: 'veri',     name: 'Veri Merkezi',          icon: '🗄️',   base: 1.5e9,     tps: 1.2e5, stage: 'unicorn', desc: 'Sunucu Odası\'nın büyüğü. Soğutma faturası da öyle.' },
    { id: 'arge',     name: 'Ar-Ge Kampüsü',         icon: '🏛️',   base: 6.0e9,     tps: 3.0e5, stage: 'sirketler_grubu', desc: 'Her fikrin bir prototipi, her prototipin bir toplantısı var.' },
    { id: 'cip',      name: 'Çip Fabrikası',         icon: '🏭',   base: 2.5e10,    tps: 8.0e5, stage: 'teknoloji_devi', desc: 'Yapay zekânın yediği çipleri artık kendin üretiyorsun.' },
    { id: 'yzlab',    name: 'Yapay Zekâ Araştırmacısı', icon: '🧪', base: 1.2e11,    tps: 2.5e6, stage: 'yapay_zeka_lab', desc: 'Modeli eğitiyor; model de onu.' },
    { id: 'mars',     name: 'Mars Ekibi',            icon: '👩‍🚀', base: 3.0e12,    tps: 2.0e7, stage: 'mars_ofisi', desc: 'Günlük stand-up 20 dakika gecikmeyle başlar.' }
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
    ofis:     [['Berlin Şubesi', '🥨'], ['Dubai Şubesi', '🏙️'], ['Tokyo Şubesi', '🗼'], ['New York Genel Merkezi', '🗽'], ['Ay Üssü Şubesi', '🌙']],
    veri:     [['Sıcak–Soğuk Koridor', '🌡️'], ['Yedeğin Yedeği', '🪆'], ['Denizaltı Kablosu', '🐙'], ['Kutup Soğutması', '🧊'], ['Uzay Soğutması', '🪐']],
    arge:     [['Prototip Atölyesi', '🛠️'], ['Patent Duvarı', '📜'], ['Kuluçka Merkezi', '🐣'], ['Kampüs Servisi', '🚌'], ['Uzay Asansörü Taslağı', '🛗']],
    cip:      [['Temiz Oda Tulumu', '🥼'], ['Silikon Gofret', '🧇'], ['Nanometre Yarışı', '🏁'], ['Çip Kıtlığına Son', '🚚'], ['Kendini Tasarlayan Çip', '♾️']],
    yzlab:    [['GPU Kümesi', '🎮'], ['Temiz Veri Seti', '🧼'], ['Hizalama Ekibi', '📏'], ['Kendini Eğiten Model', '♻️'], ['Genel Zekâ Toplantısı', '🧠']],
    mars:     [['Basınçlı Ofis Kubbesi', '🫧'], ['Kızıl Toz Filtresi', '🌪️'], ['Gecikmeli Toplantı Protokolü', '📡'], ['Yerel Kahve Serası', '🌱'], ['Olympus Genel Merkezi', '🏔️']]
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
    { id: 'all_4', name: 'Yönetim Kurulu Odası', icon: '📊', cost: 100000000000, req: { total: 250 }, all: 1.5, desc: 'Tüm üretim +%50' }
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

  // v4.4: aşamalar ID ile tutulur (kayıt, ayarlar, karşılaştırmalar). Sıra (indeks) yalnız bellekte: aşama bonusu, ilerleme
  // çubuğu ve "en az şu aşama" karşılaştırmaları stageRank(id) ile yapılır. tint: arka plan ve tebrik penceresi rengi.
  var STAGES = [
    { id: 'freelancer',      name: 'Freelancer',     icon: '🏠', at: 0,          tint: '#7c5cff', desc: 'Evde bir laptop ve bolca çay.', msg: '' },
    { id: 'ev_ofisi',        name: 'Ev Ofisi',       icon: '🛋️', at: 1000,       tint: '#8b6cff', desc: 'Salonun köşesi artık resmen ofis.', msg: 'Tebrikler! Pijamayla toplantıya girmek artık resmen şirket kültürü.' },
    { id: 'butik_studyo',    name: 'Butik Stüdyo',   icon: '🏢', at: 50000,      tint: '#5c8dff', desc: 'Küçük ama tatlı bir ekip, ilk kurumsal müşteriler.', msg: 'Kapıda adınız yazıyor. Müşteri artık ‘ekibiniz kaç kişi?’ diye sormaya çekinmiyor.' },
    { id: 'ajans',           name: 'Ajans',          icon: '🚀', at: 1000000,    tint: '#22d3a6', desc: 'Kendi binan, kendi tabelan.', msg: 'Artık ‘biz’ diyorsunuz ve bunu gerçekten ciddi söylüyorsunuz.' },
    { id: 'dev_ajans',       name: 'Dev Ajans',      icon: '🏙️', at: 50000000,   tint: '#ffb347', desc: 'Plaza katları, yüzlerce proje.', msg: 'Toplantı odalarına gezegen adı koyma zamanı geldi.' },
    { id: 'global_holding',  name: 'Global Holding', icon: '🌐', at: 2500000000, tint: '#4fc3f7', desc: 'Üç kıtada ofis, her saat diliminde bir toplantı.', msg: 'Tebrikler! Artık logoyu büyütmeyi siz istiyorsunuz.' },
    { id: 'unicorn',         name: 'Unicorn',        icon: '🦄', at: 1e11,       tint: '#4fc3f7', desc: 'Yatırımcılar kapıda, basın peşinde.', msg: 'Tebrikler! Artık sunumlarda “başarı hikâyesi” diye sizin logonuz gösteriliyor.' },
    { id: 'sirketler_grubu', name: 'Şirketler Grubu', icon: '🏬', at: 1e13,      tint: '#4fc3f7', desc: 'Bir çatı şirket, altında bir sürü şirket. Hepsinin ayrı bir toplantısı var.', msg: 'Tebrikler! Artık şirketlerinizin de şirketleri var. Organizasyon şeması tek sayfaya sığmıyor.' },
    { id: 'teknoloji_devi',  name: 'Teknoloji Devi', icon: '🛰️', at: 1e15,       tint: '#00e5ff', desc: 'Müşteriler sırada, hepsi acil.', msg: 'Tebrikler! Artık müşteri aramıyorsunuz, müşteriler sizi arıyor. Hepsi de \'acil\' diyor.' },
    { id: 'yapay_zeka_lab',  name: 'Yapay Zekâ Laboratuvarı', icon: '🧬', at: 1e19, tint: '#b388ff', desc: 'Kodu model yazıyor, siz yön veriyorsunuz.', msg: 'Tebrikler! Kodu artık yapay zekâ yazıyor, siz de ona \'biraz daha büyüt\' diyorsunuz.' },
    { id: 'mars_ofisi',      name: 'Mars Ofisi',     icon: '🔴', at: 1e23,       tint: '#ff5a3c', desc: 'Kızıl gezegende ilk ajans.', msg: 'Tebrikler! Mars\'tasınız. Mesajlar 20 dakikada geliyor, revize talepleri yine de anında.' }
  ];
  var STAGE_BY_ID = {};
  STAGES.forEach(function (st, i) { st.rank = i; STAGE_BY_ID[st.id] = st; });
  // Aşama ID'sinin sırası (bilinmeyen ID: -1). "En az şu aşama" karşılaştırmaları hep bununla.
  function stageRank(id) { var st = STAGE_BY_ID[id]; return st ? st.rank : -1; }
  function stageAtLeast(rank, id) { var r = stageRank(id); return r >= 0 && rank >= r; }
  // Aşamaya göre hafif tema rengi (arka plan ve tebrik penceresi), sıraya göre
  var STAGE_TINTS = STAGES.map(function (st) { return st.tint; });
  // v4.4 öncesi kayıtların (saveVersion <= 4) ve sunucunun (best_stage, kodhane_save_stage_checked) aşama sırası.
  // Eski kayıttaki sayı bu listeyle ID'ye çevrilir. v4.4 kayıtları da 'stage'/'stageBest'/'cycleStage' alanlarına bu eski
  // sıradaki sayıyı yazar (sunucudaki sıralama aşaması ve eski istemciler için); asıl değer '...Id' alanlarındaki ID'dir.
  var LEGACY_STAGE_IDS = ['freelancer', 'ev_ofisi', 'butik_studyo', 'ajans', 'dev_ajans', 'global_holding', 'teknoloji_devi', 'yapay_zeka_lab', 'mars_ofisi'];
  function legacyStageIndex(rank) { // şimdiki sıra -> eski sıra (Unicorn / Şirketler Grubu eski listede yok: Global Holding sayılır)
    var out = 0;
    LEGACY_STAGE_IDS.forEach(function (id, i) { if (stageRank(id) <= rank) out = i; });
    return out;
  }
  function stageRankFromLegacy(n) { var i = Math.max(0, Math.min(LEGACY_STAGE_IDS.length - 1, Math.floor(n))); return stageRank(LEGACY_STAGE_IDS[i]); }
  // Borsa Payı Ağacı (Halka Arz ile kazanılan Borsa Payı ile alınır; halka arzdan sonra da kalır).
  // Her dalda 3 düğüm sırayla açılır; maliyetler CFG.tree.costs. Açıklamalar sayıları CFG'den okur.
  var T = CFG.tree;
  var TREE = [
    { id: 'kod', name: 'Kod', icon: '⌨️', nodes: [
      { id: 'kod_1', name: 'Parmak Hızı', desc: function () { return 'Klavye alev aldı. \'Kod yaz\' kazancı ×' + num(T.clickMult) + '.'; } },
      { id: 'kod_2', name: 'Akış Hâli', desc: function () { return 'Kulaklık takıldı, dünya sustu. Her tıklamada %' + num(T.flowChance * 100) + ' ihtimalle ×' + num(T.flowMult) + ' kazanç.'; } },
      { id: 'kod_3', name: 'Kas Hafızası', desc: function () { var p = T.clickPct * 100; return 'Parmaklar artık kendi kendine yazıyor. Her tıklama saniyelik gelirinin %' + num(p) + '\'' + sfxAcc3(p) + ' de getirir.'; } }
    ] },
    { id: 'ekip', name: 'Ekip', icon: '👥', nodes: [
      { id: 'ekip_1', name: 'İyi Referans', desc: function () { return 'Eski çalışanların seni her yerde övüyor. Tüm çalışanlar ×' + num(T.genMult) + ' üretir.'; } },
      { id: 'ekip_2', name: 'Hazır Kadro', desc: function () {
        var parts = T.startGens.map(function (x) { var g = GEN_BY_ID[x[0]]; return x[1] + ' ' + (g.short || g.name); });
        return 'Kapıda sıra var. Her sıfırlamadan sonra ' + parts.join(' ve ') + ' ile başlarsın.'; } },
      { id: 'ekip_3', name: 'İK Anlaşması', desc: function () {
        var a = Math.round((COST_GROWTH - 1) * 100), b = Math.round((T.costGrowth - 1) * 100);
        return 'Maaş pazarlığı artık çay eşliğinde. Her yeni çalışanın fiyat artışı %' + a + '\'' + sfxAbl(a) + ' %' + b + '\'' + sfxDat(b) + ' iner.'; } }
    ] },
    { id: 'musteri', name: 'Müşteri', icon: '🤝', nodes: [
      { id: 'musteri_1', name: 'Sadık Müşteri', desc: function () { return 'Aynı müşteri, yine aynı logo. Proje teklifleri %' + num(T.offerMore * 100) + ' daha sık gelir.'; } },
      { id: 'musteri_2', name: 'Esnek Teslim', desc: function () { return '\'Yarına yetişir mi?\' artık \'Öbür güne olur mu?\' oldu. Teklif süresi ' + CFG.offerSec + ' saniyeden ' + T.offerSec + ' saniyeye çıkar.'; } },
      { id: 'musteri_3', name: 'Referans Zinciri', desc: function () { return 'Her müşteri bir müşteri daha getiriyor. Proje ödülleri ×' + num(T.offerPayMult) + '.'; } }
    ] },
    { id: 'yatirim', name: 'Yatırım', icon: '📈', nodes: [
      { id: 'yatirim_1', name: 'Uzaktan Çalışma', desc: function () { return 'Ekip evden de çalışıyor. Çevrimdışı kazanç sınırı ' + CFG.offlineCapHours + ' saatten ' + T.offlineHours1 + ' saate çıkar.'; } },
      { id: 'yatirim_2', name: 'Yatırımcı Güveni', desc: function () { return 'Sunum slaytları artık animasyonlu. Yatırım turu bonusu %' + num(T.shareBoost * 100) + ' güçlenir.'; } },
      { id: 'yatirim_3', name: 'Gece Vardiyası', desc: function () { return 'Ofisin ışığı hiç sönmüyor. Çevrimdışı kazanç sınırı ' + T.offlineHours2 + ' saate çıkar.'; } }
    ] }
  ];
  var NODE_BY_ID = {};
  TREE.forEach(function (br) { br.nodes.forEach(function (n, i) { n.branch = br.id; n.index = i; n.prev = i ? br.nodes[i - 1].id : null; NODE_BY_ID[n.id] = n; }); });
  function nodeCost(n) { return CFG.tree.costs[n.index]; }
  var GEN_BY_ID = {};
  GENERATORS.forEach(function (g) { GEN_BY_ID[g.id] = g; });
  GEN_BY_ID.junior.short = 'Junior';

  var STAGE_BONUS = 0.10; // her aşama +%10 üretim ve tıklama
  var PRESTIGE_UNIT = 1e8; // hisse = floor(sqrt(turKazancı / 1e8))
  var SHARE_BONUS = 0.10;

  // ------------------------------------------------------------------
  // Sayı biçimlendirme (Türkçe)
  // ------------------------------------------------------------------
  // Kısaltmalar Katrilyon (Kat) ve Kentilyon'a (Kent) kadar; ötesi bilimsel gösterim (1,23e21)
  var SUFFIXES = ['', 'Bin', 'Mn', 'Mr', 'Tn', 'Kat', 'Kent'];
  function groupTR(intStr) { return intStr.replace(/\B(?=(\d{3})+(?!\d))/g, '.'); }
  function fixedTR(n, d) {
    var s = n.toFixed(d);
    var parts = s.split('.');
    var out = groupTR(parts[0]);
    if (parts[1] && /[1-9]/.test(parts[1])) out += ',' + parts[1].replace(/0+$/, '');
    return out;
  }
  // En büyük sonekin (Kent = 1e18) ötesi bilimsel gösterim: 1,2e21 (Türkçe ondalık virgülü, '+' yok)
  function sciTR(n) {
    var p = n.toExponential(2).split('e');
    var m = p[0].replace(/\.?0+$/, '').replace('.', ',');
    return m + 'e' + p[1].replace('+', '');
  }
  function fmt(n) {
    if (typeof n !== 'number' || n !== n) return '0';
    if (!isFinite(n)) return '∞';
    if (n < 0) return '-' + fmt(-n);
    if (n < 1000) return fixedTR(n, n < 10 ? 1 : 0);
    var k = Math.floor(Math.log10(n) / 3);
    if (k >= SUFFIXES.length) return sciTR(n);
    var v = n / Math.pow(1000, k);
    if (v >= 999.995) { k++; v = v / 1000; if (k >= SUFFIXES.length) return sciTR(n); }
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
  // Süre/sayaç: 60 sn'ye kadar "45 sn", üstü dk:sn ("9:00"), saat üstü sa:dk:sn
  function fmtSec(s) {
    s = Math.max(0, Math.round(s));
    if (s <= 60) return s + ' sn';
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60;
    return (h ? h + ':' + pad(m) : m) + ':' + pad(r);
  }
  // v4.4: ayar süresini okunur yazar (metinlerdeki {h}): 43200 -> "12 saat", 5400 -> "1 saat 30 dakika", 90 -> "1 dakika 30 saniye".
  // fmtTime'dan ayrı (o "12 sa 0 dk 0 sn" verir ve başka yerlerde kullanılıyor).
  function fmtDur(sec) {
    sec = Math.max(0, Math.round(sec));
    var d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60, out = [];
    if (d) out.push(d + ' gün');
    if (h) out.push(h + ' saat');
    if (m) out.push(m + ' dakika');
    if (s || !out.length) out.push(s + ' saniye');
    return out.join(' ');
  }
  function pct(x) { return Math.round(x * 100); }
  function num(x) { return fixedTR(x, 2); } // ayar sayılarını metne yazar: 1.5 -> "1,5"
  // v4.3.1: bonus oranını yüzde metnine çevirir (0,125 -> "12,5"; büyük değerler kısaltmalı: 1250 -> "1,25 Bin")
  function pctText(frac) { var x = frac * 100; return x < 1000 ? num(x) : fmt(x); }
  // Türkçe ek uyumu (sayılar için): %1'ini, %15'ten, %14'e ...
  function numWord(n) {
    n = Math.abs(Math.round(n));
    var ones = ['sıfır', 'bir', 'iki', 'üç', 'dört', 'beş', 'altı', 'yedi', 'sekiz', 'dokuz'];
    var tens = ['', 'on', 'yirmi', 'otuz', 'kırk', 'elli', 'altmış', 'yetmiş', 'seksen', 'doksan'];
    if (n % 10) return ones[n % 10];
    if (n % 100) return tens[(n % 100) / 10];
    if (n === 0) return 'sıfır';
    return n % 1000 ? 'yüz' : 'bin';
  }
  function lastVowel(w) { var m = w.match(/[aeıioöuü](?=[^aeıioöuü]*$)/); return m ? m[0] : 'e'; }
  function sfx4(v) { return /[aı]/.test(v) ? 'ı' : /[ei]/.test(v) ? 'i' : /[ou]/.test(v) ? 'u' : 'ü'; }
  function sfxAcc3(n) { var w = numWord(n), v = lastVowel(w), i = sfx4(v); return (/[aeıioöuü]$/.test(w) ? 's' + i + 'n' + i : i + 'n' + i); }
  function sfxAbl(n) { var w = numWord(n), front = /[eiöü]/.test(lastVowel(w)); return (/[çfhkpsşt]$/.test(w) ? 't' : 'd') + (front ? 'en' : 'an'); }
  function sfxDat(n) { var w = numWord(n), front = /[eiöü]/.test(lastVowel(w)); return (/[aeıioöuü]$/.test(w) ? 'y' : '') + (front ? 'e' : 'a'); }

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
      version: SAVE_VERSION, money: 0, runEarned: 0, totalEarned: 0, clicks: 0, clickEarned: 0,
      playTime: 0, startedAt: now, lastSaved: now, gens: gens, upgrades: [],
      shares: 0, prestigeCount: 0, boostLeft: 0, eventsClicked: 0, offlineEarned: 0, stage: 0,
      buffs: [], achievements: [], critClicks: 0, eventsResolved: 0, logoAccepted: 0, revisions: 0,
      meetings: 0, serverCrashes: 0, reputation: 0, noMeetingSec: 0, daily: newDaily(),
      // v4
      ipoShares: 0, ipoSharesEarned: 0, ipoCount: 0, cycleEarned: 0, cycleRounds: 0, tree: [], stageBest: 0,
      newsSeen: [], newsPending: [],
      // v4.1
      cycleStage: 0, sectorCool: {}, followUps: { kafe: 0, emlak: 0 }, pendingPay: [],
      // v4.4: son Halka Arz anı (ms; 0 = yok) ve kaydın başladığı oyun sürümü (yeni kayıt ve "Kaydı sıfırla" sonrası
      // bu sürüm; v4.4 öncesi kayıtlarda boş kalır, doldurulmaz)
      ipoAt: 0, startedVersion: VERSION,
      // v4.4: olay listesi (CFG.eventLog); Yatırım Turu / Halka Arz'da korunur, "Kaydı sıfırla"da taşınır ve sıfırlama girdisi eklenir
      eventLog: []
    };
  }
  var S = newState();
  var queue = []; // arayüze giden bildirimler (başarım, görev, seri)
  function notify(type, data) { queue.push({ type: type, data: data }); if (queue.length > 50) queue.shift(); }
  function rnd() { return Core.rng(); }
  function chance(p) { return rnd() < p; }

  function has(id) { return S.upgrades.indexOf(id) !== -1; }
  function hasNode(id) { return S.tree.indexOf(id) !== -1; }
  function costGrowth() { return hasNode('ekip_3') ? CFG.tree.costGrowth : COST_GROWTH; }
  function offlineCapSec() { return 3600 * (hasNode('yatirim_3') ? CFG.tree.offlineHours2 : hasNode('yatirim_1') ? CFG.tree.offlineHours1 : CFG.offlineCapHours); }
  function shareBonus() { return SHARE_BONUS * (1 + (hasNode('yatirim_2') ? CFG.tree.shareBoost : 0)); }
  // v4.3.1: n Yatırımcı Hissesinin tüm kazançlara eklediği bonus (oran; 0,3 = +%30). Üretim (globalMult, tıklama) ve
  // metinler (Yatırım sekmesi, Yatırım Turu / Halka Arz onayları) aynı işlevi kullanır: Yatırımcı Güveni dahil.
  function investorBonus(n) { return shareBonus() * (n === undefined ? S.shares : n); }
  function offerSec() { return hasNode('musteri_2') ? CFG.tree.offerSec : CFG.offerSec; }
  function offerFreq() { return hasNode('musteri_1') ? 1 / (1 + CFG.tree.offerMore) : 1; } // teklif aralığı çarpanı
  function offerPayMult() { return hasNode('musteri_3') ? CFG.tree.offerPayMult : 1; }
  function unspentMult() { return 1 + CFG.halkaArz.unspentBonus * Math.min(S.ipoShares, CFG.halkaArz.unspentCap); } // harcanmamış Borsa Payı bonusu
  function genUnlocked(g) { return !g.stage || stageAtLeast(S.stageBest, g.stage); }
  function totalOwned() { var t = 0; for (var k in S.gens) t += S.gens[k]; return t; }
  function stageIndexOf(earned) {
    var i = 0;
    for (var j = 0; j < STAGES.length; j++) if (earned >= STAGES[j].at) i = j;
    return i;
  }
  function stageIndex(earned) { return stageIndexOf(earned); }
  function achMult() { return 1 + ACH_BONUS * S.achievements.length; }
  function globalMult() {
    var m = 1 + STAGE_BONUS * stageIndex(S.runEarned);
    m *= 1 + investorBonus(S.shares);
    m *= achMult();
    if (hasNode('ekip_1')) m *= CFG.tree.genMult;
    m *= unspentMult();
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
    if (hasNode('kod_1')) mult *= CFG.tree.clickMult;
    if (hasNode('kod_3')) p += CFG.tree.clickPct;
    var stageShare = (1 + STAGE_BONUS * stageIndex(S.runEarned)) * (1 + investorBonus(S.shares));
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
    var cg = costGrowth();
    var first = g.base * Math.pow(cg, S.gens[g.id]);
    return first * (Math.pow(cg, n) - 1) / (cg - 1);
  }
  function maxAffordable(g) {
    var cg = costGrowth();
    var first = g.base * Math.pow(cg, S.gens[g.id]);
    if (!genUnlocked(g) || S.money < first) return 0;
    return Math.floor(Math.log(S.money * (cg - 1) / first + 1) / Math.log(cg));
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
    S.money += x; S.runEarned += x; S.totalEarned += x; S.cycleEarned += x;
    var nx = S.cycleStage + 1; // bu döngüde (son halka arzdan beri) ulaşılan en yüksek aşama
    if (nx < STAGES.length && S.runEarned >= STAGES[nx].at) S.cycleStage = stageIndexOf(S.runEarned);
    if (src !== 'offline' && src !== 'task') taskProgress('earn', x);
  }

  // Eylemler
  function doClick(forceCrit) {
    var crit = forceCrit === true || (forceCrit !== false && rnd() < CRIT_CHANCE);
    var v = clickValue() * (crit ? CRIT_MULT : 1);
    var flow = hasNode('kod_2') && rnd() < CFG.tree.flowChance;
    if (flow) v *= CFG.tree.flowMult;
    Core.lastFlow = flow;
    earn(v); S.clicks++; S.clickEarned += v;
    if (crit) { S.critClicks++; taskProgress('crit', 1); }
    taskProgress('click', 1);
    Core.lastCrit = crit;
    return v;
  }
  function buyGen(id, n) {
    var g = GEN_BY_ID[id];
    if (!g || !genUnlocked(g)) return false;
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
  // v4.4: Borsa hızlandırıcısı dahil. Hisse = floor(sqrt(turKazancı / PRESTIGE_UNIT) x (1 + shareGainPerEarned x min(kazanılan pay, accelCap)))
  function accelEarned(earned) { var H = CFG.halkaArz; return Math.min(earned === undefined ? S.ipoSharesEarned : earned, H.accelCap == null ? Infinity : H.accelCap); }
  function shareAccel(earned) { return 1 + (CFG.halkaArz.shareGainPerEarned || 0) * accelEarned(earned); }
  function sharesGain() { return Math.floor(Math.sqrt(S.runEarned / PRESTIGE_UNIT) * shareAccel()); }
  function nextShareAt() { // bir sonraki hisse için gereken tur kazancı (hızlandırıcıyla)
    var n = sharesGain() + 1, a = shareAccel(), r = Math.pow(n / a, 2) * PRESTIGE_UNIT;
    while (Math.floor(Math.sqrt(r / PRESTIGE_UNIT) * a) < n) r *= 1 + 1e-12;
    return r;
  }
  var KEEP_ON_PRESTIGE = ['totalEarned', 'clicks', 'clickEarned', 'playTime', 'startedAt', 'eventsClicked', 'offlineEarned',
    'achievements', 'critClicks', 'eventsResolved', 'logoAccepted', 'revisions', 'meetings', 'serverCrashes',
    'reputation', 'noMeetingSec', 'daily',
    'ipoShares', 'ipoSharesEarned', 'ipoCount', 'cycleEarned', 'tree', 'stageBest', 'newsSeen', 'newsPending',
    'cycleStage', 'sectorCool', 'followUps', 'pendingPay', 'ipoAt', 'startedVersion', 'eventLog'];
  // Sıfırlama sonrası (Yatırım Turu ve Halka Arz): Hazır Kadro başlangıç çalışanları
  function resetTo(keep) {
    S = newState();
    for (var k in keep) S[k] = keep[k];
    if (hasNode('ekip_2')) CFG.tree.startGens.forEach(function (x) { if (S.gens[x[0]] !== undefined) S.gens[x[0]] += x[1]; });
  }
  // ---- v4.4: kayıt içi olay listesi. Yazma kapalıyken (writesBlocked: daha yeni sürümün kaydı okundu) girdi eklenmez.
  var EVENT_TYPES = ['ipo', 'prestige', 'reset'];
  function logEntry(type, sb, sa, pb, pa, at) {
    return { type: type, at: at || nowMs(), sharesBefore: sb, sharesAfter: sa, paysBefore: pb, paysAfter: pa };
  }
  function pushEvent(list, entry) {
    var max = Math.max(1, (CFG.eventLog && CFG.eventLog.max) | 0 || 20);
    list.push(entry);
    while (list.length > max) list.shift();
    return list;
  }
  function logEvent(type, sb, sa, pb, pa) {
    if (writesBlocked()) return false;
    if (!Array.isArray(S.eventLog)) S.eventLog = [];
    pushEvent(S.eventLog, logEntry(type, sb, sa, pb, pa));
    return true;
  }
  // Kayıttan gelen liste: yalnızca bilinen tür ve alanlar, sayılar negatif olamaz, en fazla max girdi (en yeniler)
  function cleanEventLog(a) {
    if (!Array.isArray(a)) return [];
    var nz = function (x) { return isNum(x) && x > 0 ? x : 0; };
    var out = a.filter(function (e) { return e && typeof e === 'object' && EVENT_TYPES.indexOf(e.type) !== -1 && isNum(e.at) && e.at > 0; })
      .map(function (e) { return logEntry(e.type, nz(e.sharesBefore), nz(e.sharesAfter), nz(e.paysBefore), nz(e.paysAfter), e.at); });
    var max = Math.max(1, (CFG.eventLog && CFG.eventLog.max) | 0 || 20);
    return out.slice(-max);
  }
  // "Kaydı sıfırla": mevcut liste + sıfırlama girdisi (hisse ve Borsa Payı -> 0), tavan (CFG.eventLog.max) aşılmaz (FIFO)
  function resetCarryLog(st) {
    st = st || S;
    return pushEvent(cleanEventLog(st.eventLog), logEntry('reset', isNum(st.shares) && st.shares > 0 ? st.shares : 0, 0,
      isNum(st.ipoShares) && st.ipoShares > 0 ? st.ipoShares : 0, 0));
  }
  function doPrestige() {
    var gain = sharesGain();
    if (gain < 1) return 0;
    var sb = S.shares, pb = S.ipoShares;
    var keep = { shares: S.shares + gain, prestigeCount: S.prestigeCount + 1, cycleRounds: S.cycleRounds + 1 };
    KEEP_ON_PRESTIGE.forEach(function (k) { keep[k] = S[k]; });
    resetTo(keep);
    logEvent('prestige', sb, S.shares, pb, S.ipoShares);
    return gain;
  }
  // ---- Halka Arz (ikinci prestij): kasa, çalışanlar ve geliştirmeler sıfırlanır. v4.4: yatırımcı hisseleri korunur
  // (keepShares) ve bu turda biriken hisse de eklenir (bankPending); Borsa Payı Ağacı, başarımlar ve sıralamadaki toplam
  // kazanç (totalEarned) da kalır. İki Halka Arz arasında en az CFG.halkaArz.cooldownSec.
  function nowMs() { return typeof Core.nowMs === 'function' ? Core.nowMs() : Date.now(); } // testler/simülasyon saati değiştirebilir
  // Son Halka Arz anı gelecekteyse (saat geri alındı / ileri tarihli kayıt) şimdiye çekilir: bekleme en fazla cooldownSec.
  function clampIpoAt(now) { if (!(S.ipoAt > 0)) S.ipoAt = 0; else if (S.ipoAt > now) S.ipoAt = now; return S.ipoAt; }
  function ipoCooldownLeft() { // kalan bekleme (sn); ilk Halka Arz ve alanı olmayan eski kayıt: 0
    var H = CFG.halkaArz, now = nowMs();
    if (!(H.cooldownSec > 0) || !(S.ipoCount > 0)) return 0;
    var at = clampIpoAt(now);
    if (!at) return 0;
    return Math.max(0, H.cooldownSec - (now - at) / 1000);
  }
  function ipoRoundsOk() { return S.cycleRounds >= CFG.halkaArz.rounds; }
  function ipoUnlocked() { return ipoRoundsOk() && !(ipoCooldownLeft() > 0); }
  function stagePay(rank) { var st = STAGES[rank]; return (st && CFG.halkaArz.stagePays[st.id]) || 0; }
  function ipoGain() {
    var H = CFG.halkaArz, g;
    if (H.mode === 'root') g = Math.floor(H.k * Math.pow(Math.max(0, S.cycleEarned) / H.threshold, 1 / H.root) + 1e-9);
    else g = (S.ipoCount > 0 && !stageAtLeast(S.cycleStage, H.repeatMinStage)) ? 0 : stagePay(S.cycleStage);
    return Math.max(S.ipoCount === 0 ? H.firstMin : 0, g);
  }
  // Borsa Payı veren ilk aşamanın sırası (ör. Global Holding): kilit açıkken 0 pay görünürse ipucu için
  function ipoPayStage() {
    var from = S.ipoCount > 0 ? Math.max(0, stageRank(CFG.halkaArz.repeatMinStage)) : 0;
    for (var i = from; i < STAGES.length; i++) if (stagePay(i) >= 1) return i;
    return STAGES.length - 1;
  }
  // Halka Arz'da eklenecek, bu turda biriken hisse ({p}) ve Halka Arz sonrası hisse sayısı
  function ipoPendingShares() { return CFG.halkaArz.bankPending ? sharesGain() : 0; }
  function ipoKeptShares() {
    var H = CFG.halkaArz, ks = (S.shares + ipoPendingShares()) * (H.keepShares || 0);
    return H.keepMode === 'frac' ? ks : Math.floor(ks + 1e-9);
  }
  function doIpo() {
    if (!ipoUnlocked()) return 0;
    var gain = ipoGain();
    if (gain < 1) return 0;
    var keep = { prestigeCount: S.prestigeCount };
    KEEP_ON_PRESTIGE.forEach(function (k) { keep[k] = S[k]; });
    keep.ipoAt = nowMs();
    keep.shares = ipoKeptShares();
    keep.ipoShares = S.ipoShares + gain; keep.ipoSharesEarned = S.ipoSharesEarned + gain; keep.ipoCount = S.ipoCount + 1;
    keep.cycleEarned = 0; keep.cycleStage = 0;
    var sb = S.shares, pb = S.ipoShares;
    resetTo(keep);
    logEvent('ipo', sb, S.shares, pb, S.ipoShares);
    return gain;
  }
  function nodeState(id) {
    var n = NODE_BY_ID[id];
    if (!n) return 'none';
    if (hasNode(id)) return 'owned';
    if (n.prev && !hasNode(n.prev)) return 'locked';
    return S.ipoShares >= nodeCost(n) ? 'ready' : 'poor';
  }
  function buyNode(id) {
    if (nodeState(id) !== 'ready') return false;
    S.ipoShares -= nodeCost(NODE_BY_ID[id]); S.tree.push(id);
    return true;
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
    for (var sc in S.sectorCool) { S.sectorCool[sc] -= dt; if (S.sectorCool[sc] <= 0) delete S.sectorCool[sc]; }
    settlePending(dt);
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

  // ---- v4.1 Müşteri sektörleri: sektör kartları olay kartı olarak çıkar. Reddetmek o sektörden kartları bir süre azaltır.
  var SC = CFG.sectors;
  var SECTORS = [
    { id: 'esnaf', name: 'Mahalle Esnafı', icon: '🏪' },
    { id: 'eticaret', name: 'E-ticaret', icon: '🛒' },
    { id: 'oyun', name: 'Oyun şirketi', icon: '🎮' },
    { id: 'kamu', name: 'Kamu ihalesi', icon: '🏛️' }
  ];
  var SECTOR_BY_ID = {};
  SECTORS.forEach(function (x) { SECTOR_BY_ID[x.id] = x; });
  function sectorOpen(id) { return stageAtLeast(S.stageBest, SC.unlock[id]); }
  function sectorWeight(id) { return (S.sectorCool[id] || 0) > 0 ? SC.rejectWeight : 1; }
  function payLater(sec, delay, label) {
    var x = pay(sec);
    S.pendingPay.push({ amount: x, left: delay, total: delay, label: label });
    return x;
  }
  function settlePending(dt) { // gecikmeli ödemeler (çevrimdışıyken de işler)
    if (!S.pendingPay.length) return;
    var due = [];
    S.pendingPay.forEach(function (p) { p.left -= dt; if (p.left <= 0) due.push(p); });
    if (!due.length) return;
    S.pendingPay = S.pendingPay.filter(function (p) { return p.left > 0; });
    due.forEach(function (p) { earn(p.amount, 'event'); notify('paid', p); });
  }
  function rejectSector(id) {
    S.sectorCool[id] = SC.rejectSec;
    var x = SECTOR_BY_ID[id];
    return 'Teklifi geri çevirdin. ' + x.name + ' teklifleri bir süre seyrek gelecek.';
  }
  function rejectChoice(id) {
    return { label: 'Reddet', hint: function () { return SECTOR_BY_ID[id].name + ' teklifleri ' + fmtSec(SC.rejectSec) + ' seyrek gelir'; },
      run: function () { return rejectSector(id); } };
  }
  function sectorCard(sector, id, title, choice, extra) {
    var sx = SECTOR_BY_ID[sector];
    var e = { id: id, sector: sector, icon: sx.icon, title: title, text: sx.icon + ' ' + sx.name, choices: [choice, extra || rejectChoice(sector)] };
    EVENTS.push(e);
    return e;
  }
  sectorCard('eticaret', 'eticaret_sunucu', '“İndirim gecesi site yavaşladı. Sunucu ekler misin?”',
    { label: 'Kabul et', hint: function () { var c = SC.eticaret_sunucu; return '-' + tl(Math.min(S.money, pay(c.cost))) + ' sunucu · +' + tl(pay(c.pay)); },
      run: function () { var c = SC.eticaret_sunucu, k = Math.min(S.money, pay(c.cost)); S.money -= k; var x = pay(c.pay); earn(x, 'event'); return 'Sunucular eklendi, site uçtu. Gider -' + tl(k) + ', gelir +' + tl(x); } });
  sectorCard('eticaret', 'eticaret_buton', '“Sepete ekle butonu biraz daha kırmızı olabilir mi?”',
    { label: 'Kabul et', hint: function () { var c = SC.eticaret_buton; return '+' + tl(pay(c.pay)) + ' · ' + fmtSec(negSec(c.sec)) + ' verim -%' + pct(1 - c.mult); },
      run: function () { var c = SC.eticaret_buton; S.revisions++; addBuff('buton', 'prod', c.mult, negSec(c.sec), 'Buton revizesi'); return cash(c.pay, 'Buton biraz daha kırmızı:'); } });
  sectorCard('oyun', 'oyun_yama', '“Oyun çıktı ama ilk gün yaması lazım.”',
    { label: 'Kabul et', hint: function () { var c = SC.oyun_yama; return '+' + tl(pay(c.pay)) + ' · ' + fmtSec(negSec(c.sec)) + ' verim -%' + pct(1 - c.mult); },
      run: function () { var c = SC.oyun_yama; addBuff('yama', 'prod', c.mult, negSec(c.sec), 'İlk gün yaması'); return cash(c.pay, 'Yama yetişti, ekip bitkin:'); } });
  sectorCard('oyun', 'oyun_karakter', '“Karakter bir tık daha havalı olsun. Nasıl yani, biz de bilmiyoruz.”',
    { label: 'Kabul et', hint: function () { var c = SC.oyun_karakter; return '+' + tl(pay(c.pay)) + ' · ' + fmtSec(negSec(c.sec)) + ' verim -%' + pct(1 - c.mult); },
      run: function () { var c = SC.oyun_karakter; S.revisions++; addBuff('karakter', 'prod', c.mult, negSec(c.sec), 'Havalı karakter revizesi'); return cash(c.pay, 'Karakter havalandı (sanırım):'); } });
  sectorCard('kamu', 'kamu_ihale', '“İhale kazanıldı. Evrak listesi 14 sayfa.”',
    { label: 'Kabul et', hint: function () { var c = SC.kamu_ihale; return '+' + tl(pay(c.pay)) + ' · ödeme ' + fmtSec(c.delay) + ' sonra'; },
      run: function () { var c = SC.kamu_ihale, x = payLater(c.pay, c.delay, 'İhale ödemesi'); return 'Evraklar teslim edildi. Ödeme ' + fmtSec(c.delay) + ' sonra geliyor: +' + tl(x); } });
  sectorCard('kamu', 'kamu_imza', '“Islak imza lazım, PDF olmaz.”',
    { label: 'Kabul et', hint: function () { var c = SC.kamu_imza; return '+' + tl(pay(c.pay)) + ' · ödeme ' + fmtSec(c.delay) + ' sonra'; },
      run: function () { var c = SC.kamu_imza, x = payLater(c.pay, c.delay, 'Islak imzalı ödeme'); return 'İmza atıldı, kargoya verildi. Ödeme ' + fmtSec(c.delay) + ' sonra geliyor: +' + tl(x); } });
  sectorCard('esnaf', 'esnaf_kafe', '“Kafe: Menüyü siteye koyalım. Fiyatlar her hafta değişiyor ama.”',
    { label: 'Kabul et', hint: function () { var c = SC.esnaf_kafe; return '+' + tl(pay(c.pay)) + ' · sonra fiyat revizeleri'; },
      run: function () { var c = SC.esnaf_kafe; S.followUps.kafe = c.revisions; return cash(c.pay, 'Menü yayında:'); } });
  sectorCard('esnaf', 'esnaf_emlak', '“Emlakçı: İlanları ben girerim, sen sadece şifremi hatırla.”',
    { label: 'Kabul et', hint: function () { var c = SC.esnaf_emlak; return '+' + tl(pay(c.pay)) + ' · arada destek isteği'; },
      run: function () { S.followUps.emlak = 1; return cash(SC.esnaf_emlak.pay, 'Kurulum tamam:'); } });
  // Takip kartları (yalnızca kabul edilen esnaf işlerinden sonra)
  sectorCard('esnaf', 'esnaf_kafe_revize', '“Kafe: Fiyatlar yine değişti.”',
    { label: 'Güncelle', hint: function () { var c = SC.esnaf_kafe; return '+' + tl(pay(c.revPay)) + ' · ' + fmtSec(negSec(c.revSec)) + ' verim -%' + pct(1 - c.revMult); },
      run: function () { var c = SC.esnaf_kafe; S.followUps.kafe = Math.max(0, S.followUps.kafe - 1); S.revisions++; addBuff('menu', 'prod', c.revMult, negSec(c.revSec), 'Menü revizesi'); return cash(c.revPay, 'Fiyatlar güncellendi:'); } },
    { label: 'Artık yapamayız', hint: 'Kafe işi biter', run: function () { S.followUps.kafe = 0; return 'Kafe başka birini buldu.'; } });
  sectorCard('esnaf', 'esnaf_emlak_destek', '“Emlakçı: Şifremi yine unuttum.”',
    { label: 'Yardım et', hint: function () { var c = SC.esnaf_emlak; return '+' + tl(pay(c.supportPay)) + ' · ' + fmtSec(negSec(c.supportSec)) + ' verim -%' + pct(1 - c.supportMult); },
      run: function () { var c = SC.esnaf_emlak; addBuff('sifre', 'prod', c.supportMult, negSec(c.supportSec), 'Şifre desteği'); return cash(c.supportPay, 'Şifre sıfırlandı (yine):'); } },
    { label: 'Artık yapamayız', hint: 'Emlakçı işi biter', run: function () { S.followUps.emlak = 0; return 'Emlakçı yeğenine sordu.'; } });

  var EVENT_BY_ID = {};
  EVENTS.forEach(function (e) { EVENT_BY_ID[e.id] = e; });
  function cardAvailable(e) {
    if (!e) return false;
    if (e.sector) {
      if (!sectorOpen(e.sector)) return false;
      if (e.id === 'esnaf_kafe_revize') return S.followUps.kafe > 0;
      if (e.id === 'esnaf_emlak_destek') return S.followUps.emlak > 0;
      return true;
    }
    if (e.id === 'cuma' && has('deploy_yasak')) return false;
    if (e.id === 'sunucu' && totalOwned() < 5) return false;
    return true;
  }
  function eventPool() { return EVENTS.filter(function (e) { return !e.sector && cardAvailable(e); }); }
  function sectorPool(id) {
    return EVENTS.filter(function (e) {
      if (e.sector !== id || !cardAvailable(e)) return false;
      if (e.id === 'esnaf_emlak_destek') return rnd() < SC.esnaf_emlak.returnChance; // ara sıra geri döner
      return true;
    });
  }
  function pickSector() {
    var open = SECTORS.filter(function (x) { return sectorOpen(x.id); });
    var tot = 0; open.forEach(function (x) { tot += sectorWeight(x.id); });
    var r = rnd() * tot;
    for (var i = 0; i < open.length; i++) { r -= sectorWeight(open[i].id); if (r < 0) return open[i].id; }
    return open.length ? open[open.length - 1].id : null;
  }
  function pickEvent(exclude) {
    if (rnd() < SC.share) {
      var sec = pickSector();
      if (sec) {
        var sp = sectorPool(sec).filter(function (e) { return e.id !== exclude; });
        // kafe revizesi bekliyorsa önce o gelir
        var fu = sp.filter(function (e) { return e.id === 'esnaf_kafe_revize'; });
        if (fu.length && rnd() < 0.5) return fu[0].id;
        if (sp.length) return sp[Math.floor(rnd() * sp.length)].id;
      }
    }
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
    { id: 'ekip_50', icon: '🏢', name: 'Kat Doldu', desc: 'Aynı anda 50 çalışanın olsun', test: function () { return totalOwned() >= 50; } },
    { id: 'ekip_150', icon: '🧍', name: 'Kalabalık Stand-up', desc: 'Aynı anda 150 çalışanın olsun', test: function () { return totalOwned() >= 150; } },
    { id: 'ekip_300', icon: '🗃️', name: 'İK Departmanı Şart', desc: 'Aynı anda 300 çalışanın olsun', test: function () { return totalOwned() >= 300; } },
    { id: 'robot', icon: '🤖', name: 'Robot Meslektaş', desc: 'İlk Yapay Zekâ Kod Ajanını işe al', test: function () { return S.gens.ai >= 1; } },
    // aşama başarımları aşama ID'sine bağlı (v4.4 öncesi kimlikler asama_6/7/8 aynen kalır)
    { id: 'asama_2', icon: '🏢', name: 'Butik Hayaller', desc: 'Butik Stüdyo aşamasına ulaş', test: function () { return stageAtLeast(S.stage, 'butik_studyo'); } },
    { id: 'asama_3', icon: '🚀', name: 'Tabela Asıldı', desc: 'Ajans aşamasına ulaş', test: function () { return stageAtLeast(S.stage, 'ajans'); } },
    { id: 'asama_5', icon: '🌐', name: 'Kıtalar Arası', desc: 'Global Holding aşamasına ulaş', test: function () { return stageAtLeast(S.stage, 'global_holding'); } },
    { id: 'asama_unicorn', icon: '🦄', name: 'Tek Boynuzlu', desc: 'Unicorn aşamasına ulaş', test: function () { return stageAtLeast(S.stageBest, 'unicorn'); } },
    { id: 'asama_grup', icon: '🏬', name: 'Organizasyon Şeması', desc: 'Şirketler Grubu aşamasına ulaş', test: function () { return stageAtLeast(S.stageBest, 'sirketler_grubu'); } },
    { id: 'asama_6', icon: '🛰️', name: 'Acil Kuyruğu', desc: 'Teknoloji Devi aşamasına ulaş', test: function () { return stageAtLeast(S.stageBest, 'teknoloji_devi'); } },
    { id: 'asama_7', icon: '🧬', name: 'Model Eğitildi', desc: 'Yapay Zekâ Laboratuvarı aşamasına ulaş', test: function () { return stageAtLeast(S.stageBest, 'yapay_zeka_lab'); } },
    { id: 'asama_8', icon: '🔴', name: 'Kızıl Tabela', desc: 'Mars Ofisi aşamasına ulaş', test: function () { return stageAtLeast(S.stageBest, 'mars_ofisi'); } },
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
    { id: 'yatirim_1', icon: '💼', name: 'İlk Yatırım', desc: 'İlk Yatırım Turunu tamamla', test: function () { return S.prestigeCount >= 1; } },
    { id: 'borsa_zili', icon: '🔔', name: 'Borsa Zili', desc: 'İlk halka arzını yaptın.', test: function () { return S.ipoCount >= 1; } }
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
      var sj = Math.min(si, 5); // yeni aşamalarda son değerler geçerli
      if (type === 'click') t.target = [150, 250, 350, 500, 500, 600][sj];
      else if (type === 'offer') t.target = [2, 2, 3, 3, 3, 3][sj];
      else if (type === 'event') t.target = [1, 1, 2, 2, 2, 3][sj];
      else if (type === 'crit') t.target = [3, 4, 5, 6, 8, 10][sj];
      else if (type === 'earn') t.target = niceRound(Math.max(500, baseTps() * 900));
      else if (type === 'upgrade') { if (totalOwned() < 1) continue; t.target = si >= 2 ? 2 : 1; }
      else if (type === 'hire') {
        var idx = 0;
        GENERATORS.forEach(function (g, gi) { if (S.gens[g.id] > 0) idx = gi; });
        t.gen = GENERATORS[idx].id;
        t.target = [5, 3, 2][idx] || 1;
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
  // v4.2: kayıt kuşağı bilgisi. Oyun durumunun (S) dışında tutulur: Yatırım Turu / Halka Arz (resetTo) ona hiç
  // dokunmaz; kayda (yerel ve bulut) eklenir.
  //  - epoch: bu kaydın kuşağı (ms). Her sıfırlama ve geri alma/geri yüklemede yenilenir. Aynı tarayıcıdaki sekmeler,
  //    'kodhane_save_epoch' anahtarındaki değerden eski kuşaktaysa yerel kayda yazamaz (bayat sekme koruması).
  //  - resetAt: bu kaydın en son sıfırlandığı an (ms). Sunucunun kodhane_reset_save() yükü de 'resetAt' yazar; bulut
  //    kazanınca başka cihazdaki sıfırlama buradan anlaşılır.
  //  Bulut revizyonu (kodhane_saves.revision) kaydın içinde değil, cloud.js'te tutulur.
  var meta = { epoch: 0, resetAt: 0 };
  // v4.4: aşamalar kayıtta ID ile ('stageId', 'stageBestId', 'cycleStageId'). 'stage' / 'stageBest' / 'cycleStage' sayıları eski
  // sıradadır (LEGACY_STAGE_IDS): sunucu sıralama aşamasını (best_stage) 'stage'den hesaplar, eski istemciler de okur.
  function saveData() {
    var o = {}; for (var k in S) o[k] = S[k];
    ['stage', 'stageBest', 'cycleStage'].forEach(function (k) {
      var r = Math.max(0, Math.min(STAGES.length - 1, S[k] | 0));
      o[k + 'Id'] = STAGES[r].id; o[k] = legacyStageIndex(r);
    });
    o.version = SAVE_VERSION; o.saveVersion = SAVE_VERSION; o.epoch = meta.epoch; o.resetAt = meta.resetAt; return o;
  }

  // v4.3.1: İleri sürüm koruması. Kayıt biçimi sürümü kayıtta 'saveVersion' (v4.3.1'den beri) ve 'version' (eski ad, aynı
  // değer) alanlarında, bulutta ayrıca kodhane_saves.save_version sütunundadır. Alan(lar) yoksa kayıt eski biçimdir ve
  // eskisi gibi yüklenir (deserialize taşır). Okunan bir kayıt (bu cihaz, başka sekme, bulut) bu istemcinin bildiğinden
  // (SAVE_VERSION) YENİYSE futureSave dolar ve bu sayfa oturumunda hiçbir kayıt yazılmaz. Tek bayrak: writesBlocked().
  // Bakan yerler: save() (otomatik/aralıklı, beforeunload/pagehide/visibilitychange, elle, Yatırım Turu/Halka Arz/ağaç
  // sonrası), applySave/adoptSave (bulut, başka sekme, geri yükleme), sıfırlama, Geri al, yedekten geri yükleme ve
  // cloud.js'in tüm bulut yazmaları (push/flush/reconcile/yedek/sıfırlama ve geri yükleme RPC'leri).
  var futureSave = null;
  function saveVersionOf(d, rowVersion) {
    var v = 0, o = d && typeof d === 'object' ? d : {};
    [o.saveVersion, o.version, rowVersion].forEach(function (x) { if (typeof x === 'number' && isFinite(x) && x > v) v = x; });
    return v;
  }
  function guardFuture(d, source, rowVersion) {
    if (typeof d === 'string') { try { d = JSON.parse(d); } catch (e) { d = null; } }
    var v = saveVersionOf(d, rowVersion);
    if (!(v > SAVE_VERSION)) return false;
    if (!futureSave) {
      futureSave = { version: v, source: source || '' };
      if (typeof Core.onFutureSave === 'function') { try { Core.onFutureSave(futureSave); } catch (e) {} }
    }
    return true;
  }
  // v4.4: bulut yazması 426 (PT426 save_version_too_old) aldı: sunucudaki kayıt bu istemciden yeni sürümle yazılmış.
  // Aynı sonuç: bu sayfa oturumunda hiçbir kayıt (yerel dahil) yazılmaz, bulut yazması tekrar denenmez; bant olderTab metni.
  var olderTab = null;
  function markOlderTab(info) {
    if (olderTab) return false;
    olderTab = { at: Date.now(), detail: info && info.detail ? String(info.detail) : '' };
    if (typeof Core.onOlderTab === 'function') { try { Core.onOlderTab(olderTab); } catch (e) {} }
    return true;
  }
  function writesBlocked() { return !!futureSave || !!olderTab; }
  function serialize() { S.lastSaved = Date.now(); return JSON.stringify(saveData()); }
  function isNum(x) { return typeof x === 'number' && isFinite(x); }
  function deserialize(str) {
    var d = JSON.parse(str);
    if (!d || typeof d !== 'object') throw new Error('Geçersiz kayıt');
    var base = newState();
    Core.loadedVersion = saveVersionOf(d) || 1;
    meta.epoch = isNum(d.epoch) && d.epoch > 0 ? d.epoch : 0;
    meta.resetAt = isNum(d.resetAt) && d.resetAt > 0 ? d.resetAt : 0;
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
    // v4 alanları: ağaç sırası korunur (önceki düğüm yoksa sonraki geçersiz), haber bayrakları yalnızca bilinen kimlikler
    seen = {};
    base.tree = base.tree.filter(function (id) { var n = NODE_BY_ID[id]; var ok = n && !seen[id] && (!n.prev || seen[n.prev]); seen[id] = 1; return ok; });
    base.newsSeen = base.newsSeen.filter(function (id, i, a) { return typeof id === 'string' && NEWS_BY_ID[id] && a.indexOf(id) === i; });
    base.newsPending = base.newsPending.filter(function (id, i, a) { return typeof id === 'string' && NEWS_BY_ID[id] && a.indexOf(id) === i; });
    ['ipoShares', 'ipoSharesEarned', 'ipoCount', 'cycleRounds', 'stageBest', 'shares', 'prestigeCount', 'cycleStage'].forEach(function (k) {
      base[k] = Math.max(0, Math.floor(base[k]));
    });
    base.buffs = base.buffs.filter(function (b) {
      return b && isNum(b.mult) && isNum(b.left) && b.left > 0 && (b.kind === 'prod' || b.kind === 'click');
    });
    if (d.daily && typeof d.daily === 'object' && Array.isArray(d.daily.tasks)) {
      var nd = newDaily();
      for (var j in nd) if (d.daily[j] !== undefined) nd[j] = d.daily[j];
      base.daily = nd;
    }
    base.reputation = Math.max(0, Math.min(REP_MAX, base.reputation));
    // v4.1: sektör bekleme süreleri, esnaf takip işleri, gecikmeli ödemeler
    base.sectorCool = {};
    if (d.sectorCool && typeof d.sectorCool === 'object') {
      SECTORS.forEach(function (x) { var v = d.sectorCool[x.id]; if (isNum(v) && v > 0) base.sectorCool[x.id] = Math.min(v, SC.rejectSec); });
    }
    base.followUps = { kafe: 0, emlak: 0 };
    if (d.followUps && typeof d.followUps === 'object') {
      if (isNum(d.followUps.kafe)) base.followUps.kafe = Math.max(0, Math.min(SC.esnaf_kafe.revisions, Math.floor(d.followUps.kafe)));
      base.followUps.emlak = d.followUps.emlak ? 1 : 0;
    }
    base.pendingPay = base.pendingPay.filter(function (p) {
      return p && isNum(p.amount) && p.amount >= 0 && isNum(p.left) && p.left > 0 && typeof p.label === 'string';
    }).slice(0, 20).map(function (p) {
      var maxDelay = Math.max(SC.kamu_ihale.delay, SC.kamu_imza.delay), left = Math.min(p.left, maxDelay);
      return { amount: p.amount, left: left, total: isNum(p.total) ? Math.min(Math.max(p.total, left), maxDelay) : left, label: p.label.slice(0, 40) };
    });
    // v4.4: aşamalar ID'den (kayıt v5). ID yoksa ya da bilinmiyorsa (v4.4 öncesi kayıt, sunucunun sıfırlama yükü) sayı eski
    // sıradadır (LEGACY_STAGE_IDS) ve ID'ye çevrilir: eski 6 = Teknoloji Devi (Unicorn değil), 7 = Yapay Zekâ Lab, 8 = Mars.
    ['stage', 'stageBest', 'cycleStage'].forEach(function (k) {
      var id = d[k + 'Id'];
      if (typeof id === 'string' && STAGE_BY_ID[id]) base[k] = stageRank(id);
      else base[k] = stageRankFromLegacy(isNum(d[k]) ? Math.max(0, d[k]) : 0);
    });
    // v4.4: son Halka Arz anı (yoksa 0: ilk Halka Arz hemen açık; gelecekteyse şimdiye çekilir) ve başlangıç sürümü (eski
    // kayıtta boş kalır). startedAt yoksa / geçersizse 0 (bilinmiyor): ağaç olayında süre alanı gönderilmez.
    base.ipoAt = isNum(d.ipoAt) && d.ipoAt > 0 ? Math.min(d.ipoAt, nowMs()) : 0;
    base.startedVersion = typeof d.startedVersion === 'string' ? d.startedVersion.slice(0, 20) : '';
    if (!(isNum(d.startedAt) && d.startedAt > 0)) base.startedAt = 0;
    base.eventLog = cleanEventLog(d.eventLog);   // v4.4 (kayıt v5): eski kayıtta alan yok -> boş liste
    // v2/v3 (oyun v1-v3) -> kayıt v3 (oyun v4): kayıpsız taşıma
    if (Core.loadedVersion < 3) {
      base.cycleEarned = base.totalEarned;          // henüz halka arz yok: döngü = tüm zamanlar
      base.cycleRounds = base.prestigeCount;        // şimdiye kadarki yatırım turları Halka Arz koşuluna sayılır
      base.stageBest = Math.max(base.stage, stageIndexOf(base.runEarned));
      if (stageAtLeast(base.stageBest, 'global_holding') && base.newsPending.indexOf('yeni_asama') === -1) base.newsPending.push('yeni_asama');
    }
    // kayıt v3 (oyun v4) -> v4 (oyun v4.1): bu döngüde ulaşılan en yüksek aşama (halka arz yoksa tüm geçmiş)
    if (Core.loadedVersion < 4) {
      base.cycleStage = base.ipoCount === 0 ? Math.max(base.stageBest, base.stage, stageIndexOf(base.runEarned)) : Math.max(base.stage, stageIndexOf(base.runEarned));
    }
    base.cycleEarned = Math.min(base.totalEarned, Math.max(base.cycleEarned, base.runEarned));
    base.stageBest = Math.max(base.stageBest, base.stage, stageIndexOf(base.runEarned));
    base.cycleStage = Math.min(STAGES.length - 1, Math.max(0, Math.floor(base.cycleStage), stageIndexOf(base.runEarned)));
    base.version = SAVE_VERSION;
    S = base;
    return S;
  }
  function applyOffline(now) {
    var elapsed = Math.max(0, ((now || Date.now()) - S.lastSaved) / 1000);
    var cap = offlineCapSec();
    var sec = Math.min(elapsed, cap);
    var gain = baseTps() * sec;
    if (gain > 0) { earn(gain, 'offline'); S.offlineEarned += gain; }
    for (var sc in S.sectorCool) { S.sectorCool[sc] -= elapsed; if (S.sectorCool[sc] <= 0) delete S.sectorCool[sc]; }
    settlePending(elapsed);
    return { elapsed: elapsed, sec: sec, gain: gain, capped: elapsed > cap, capHours: cap / 3600 };
  }

  // ------------------------------------------------------------------
  // Oyun içi haberler: sırayla, oturum başına en fazla CFG.newsPerSession; oyuncu başına bir kez (kayıtta newsSeen)
  // ------------------------------------------------------------------
  var NEWS = [
    { id: 'yeni_asama', emoji: '🛰️', title: 'Global Holding son durak değilmiş.',
      text: function () { return 'Yeni aşama açıldı: ' + STAGE_BY_ID.teknoloji_devi.name + '.'; },
      eligible: function () { return S.newsPending.indexOf('yeni_asama') !== -1; } },
    { id: 'siralama', emoji: '🏆', title: 'Yeni: Sıralama!',
      text: function () { return 'Toplam kazancınla listeye gir. Yatırım turu yapsan da yerin korunur.'; },
      action: 'Sıralamaya bak', count: 'news_leaderboard',
      eligible: function () { return !!(Core.newsNeedsLeaderboard && Core.newsNeedsLeaderboard()); } },
    { id: 'acik_ofis', emoji: '🪑', title: 'Kodhane ailesine yeni oyun: Açık Ofis!',
      text: function () { return 'Kendi ofisini kur, masaları yerleştir, ekibini büyüt. E-postana gelen 6 haneli kodla giriş yap, ilerlemen buluta kaydolsun.'; },
      action: 'Açık Ofis\'i dene', count: 'news_acikofis',
      url: 'https://acikofis.teserix.com/?utm_source=kodhane&utm_medium=news&utm_campaign=acikofis_v1',
      eligible: function () { return true; } }
  ];
  var NEWS_BY_ID = {};
  NEWS.forEach(function (n) { NEWS_BY_ID[n.id] = n; });
  function nextNews() {
    for (var i = 0; i < NEWS.length; i++) {
      var n = NEWS[i];
      if (S.newsSeen.indexOf(n.id) === -1 && n.eligible()) return n;
    }
    return null;
  }
  function markNewsSeen(id) {
    if (S.newsSeen.indexOf(id) === -1) S.newsSeen.push(id);
    S.newsPending = S.newsPending.filter(function (x) { return x !== id; });
  }

  // v4.4: Halka Arz onay metni (Yazı r3). {z}: bu Halka Arz'ın payları dahil hızlandırıcı; {y}: Halka Arz sonrası bonus.
  function ipoConfirmHtml() {
    var H = CFG.halkaArz, n = ipoGain(), p = ipoPendingShares(), after = S.ipoSharesEarned + n;
    var capped = H.accelCap != null && after >= H.accelCap;
    var v = { p: fmt(p), n: fmt(n), z: num(accelEarned(after) * H.shareGainPerEarned * 100), u: num(H.unspentBonus * 100),
      h: fmtDur(H.cooldownSec), y: pctText(investorBonus(ipoKeptShares())) };
    var html = uiText('ipo.confirm', v), br = html.indexOf('<br>');
    if (!(p >= 1)) html = uiText('ipo.confirm.noPending') + html.slice(br);
    else html = html.replace('<br>Kazanacağın:', '<br>' + uiText('ipo.confirm.bonus', v) + ' Kazanacağın:');
    if (capped) html = html.replace(uiText('ipo.confirm.accel', v), uiText('ipo.confirm.accelMax', v));
    return html;
  }
  // v4.4: iki Umami olayının alanları (yalnız bunlar; kişisel veri ya da ek kimlik yok). Gönderim track() ile, izin kapısından.
  //  ipo_complete: stage_id (bu döngüde ulaşılan, payı belirleyen aşamanın ID'si), pays (kazanılan Borsa Payı), ipo_number (kaçıncı Halka Arz)
  //  tree_full:    hours_since_start (startedAt'ten bu yana tam saat; startedAt yok/geçersizse alan HİÇ yok), ipo_number,
  //                started_v44 ('yes' = kayıt v4.4 ya da sonrasında başladı / sıfırlandı, startedVersion dolu; 'no' = boş)
  function ipoEventData(stageRankBefore, pays) {
    var st = STAGES[Math.max(0, Math.min(STAGES.length - 1, stageRankBefore | 0))];
    return { stage_id: st.id, pays: pays, ipo_number: S.ipoCount };
  }
  var TREE_NODE_COUNT = TREE.reduce(function (a, br) { return a + br.nodes.length; }, 0);
  function treeFull() { return S.tree.length >= TREE_NODE_COUNT; }
  function treeEventData(now) {
    now = now || nowMs();
    var o = {}, st = S.startedAt;
    if (isNum(st) && st > 0 && st <= now) o.hours_since_start = Math.round((now - st) / 3600000);
    o.ipo_number = S.ipoCount;
    o.started_v44 = S.startedVersion ? 'yes' : 'no';
    return o;
  }

  var Core = {
    VERSION: VERSION, SAVE_VERSION: SAVE_VERSION, CFG: CFG, TREE: TREE, NEWS: NEWS, STAGE_TINTS: STAGE_TINTS,
    STAGE_BY_ID: STAGE_BY_ID, LEGACY_STAGE_IDS: LEGACY_STAGE_IDS, stageRank: stageRank, stageAtLeast: stageAtLeast, legacyStageIndex: legacyStageIndex,
    ipoCooldownLeft: ipoCooldownLeft, ipoRoundsOk: ipoRoundsOk, ipoPendingShares: ipoPendingShares, ipoKeptShares: ipoKeptShares, stagePay: stagePay,
    shareAccel: shareAccel, accelEarned: accelEarned, nextShareAt: nextShareAt, fmtDur: fmtDur, num: num, ipoEventData: ipoEventData, treeEventData: treeEventData, treeFull: treeFull, ipoConfirmHtml: ipoConfirmHtml, cleanEventLog: cleanEventLog, EVENT_TYPES: EVENT_TYPES, resetCarryLog: resetCarryLog,
    hasNode: hasNode, nodeState: nodeState, nodeCost: nodeCost, buyNode: buyNode, ipoUnlocked: ipoUnlocked, ipoGain: ipoGain, doIpo: doIpo,
    costGrowth: costGrowth, offlineCapSec: offlineCapSec, shareBonus: shareBonus, investorBonus: investorBonus, pctText: pctText, offerSec: offerSec, offerFreq: offerFreq, offerPayMult: offerPayMult,
    genUnlocked: genUnlocked, unspentMult: unspentMult, ipoPayStage: ipoPayStage, globalMult: globalMult,
    SECTORS: SECTORS, sectorOpen: sectorOpen, sectorWeight: sectorWeight, sectorPool: sectorPool, pickSector: pickSector, cardAvailable: cardAvailable,
    settlePending: settlePending, EVENT_BY_ID: EVENT_BY_ID, nextNews: nextNews, markNewsSeen: markNewsSeen, sfxAcc3: sfxAcc3, sfxAbl: sfxAbl, sfxDat: sfxDat, GENERATORS: GENERATORS, UPGRADES: UPGRADES, STAGES: STAGES, EVENTS: EVENTS, ACHIEVEMENTS: ACHIEVEMENTS,
    fmt: fmt, tl: tl, fmtTime: fmtTime, fmtSec: fmtSec,
    get state() { return S; }, set state(v) { S = v; }, newState: newState,
    tps: tps, baseTps: baseTps, clickValue: clickValue, clickBase: clickBase, genCost: genCost, genTps: genTps, maxAffordable: maxAffordable,
    availableUpgrades: availableUpgrades, buyGen: buyGen, buyUpgrade: buyUpgrade, doClick: doClick, tick: tick,
    stageIndex: stageIndex, totalOwned: totalOwned, sharesGain: sharesGain, doPrestige: doPrestige,
    serialize: serialize, deserialize: deserialize, applyOffline: applyOffline, earn: earn, has: has,
    pay: pay, addBuff: addBuff, buffMult: buffMult, achMult: achMult, repMult: repMult, addRep: addRep,
    eventPool: eventPool, pickEvent: pickEvent, resolveEvent: resolveEvent, checkAchievements: checkAchievements,
    checkDaily: checkDaily, makeTasks: makeTasks, taskProgress: taskProgress, taskLabel: taskLabel, today: today, shiftDay: shiftDay,
    streakBonus: streakBonus, setToday: function (s) { Core.fakeToday = s || null; },
    UI_TEXT: UI_TEXT, uiText: uiText, guardFuture: guardFuture, writesBlocked: writesBlocked, saveVersionOf: saveVersionOf, get futureSave() { return futureSave; }, markOlderTab: markOlderTab, get olderTab() { return olderTab; }, RESET_TEXT: RESET_TEXT, RESET_SIGNED_ONLY: RESET_SIGNED_ONLY, TEL_TEXT: TEL_TEXT, telText: telText, resetText: resetText, otherDeviceText: otherDeviceText, saveData: saveData,
    meta: meta,
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
    if (el.modalExtra) { el.modalExtra.innerHTML = ''; if (opts.extra) el.modalExtra.appendChild(opts.extra); }
    if (el.modalCard) el.modalCard.className = 'modal-card' + (opts.cardClass ? ' ' + opts.cardClass : '');
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
    if (writesBlocked()) return;       // v4.3.1: daha yeni sürümün kaydı okundu: hiçbir yere yazılmaz
    if (resetting) return;
    // v4.2: yalnız yazıcı sekme yazar (arka plan sekmeleri duraklar; TabGate)
    if (Core.tabGate && !Core.tabGate.isWriter()) return;
    if (staleLocal()) return; // başka sekmede sıfırlandı/geri yüklendi: bu sekmenin eski kaydı yazılmaz
    try {
      // v4.3.1: bu arada başka bir sekme (daha yeni sürüm) kendi kaydını yazdıysa üstüne yazma
      var cur = localStorage.getItem(SAVE_KEY);
      if (cur && cur !== Core.lastWritten && guardFuture(cur, 'local')) return;
      if (meta.epoch > readEpoch()) localStorage.setItem(EPOCH_KEY, String(meta.epoch));
      var str = serialize();
      localStorage.setItem(SAVE_KEY, str);
      Core.lastWritten = str;   // TabGate: yazıcı olunca yalnız BAŞKA sekmenin yazdığı kayıt devralınır
    } catch (e) { /* kota vb. */ }
    if (typeof Core.onSaved === 'function') { try { Core.onSaved(); } catch (e) { /* bulut kancası oyunu durdurmamalı */ } }
  }
  // Buluttan (veya başka bir kaynaktan) gelen kaydı uygula: yerel kaydı değiştirir ve arayüzü yeniler.
  function applySave(data) {
    if (guardFuture(data, 'apply')) return null;   // v4.3.1: daha yeni sürümün kaydı uygulanmaz (ve geri yazılmaz)
    deserialize(typeof data === 'string' ? data : JSON.stringify(data));
    meta.epoch = Math.max(meta.epoch, readEpoch()); // uygulanan kayıt (bulut/geri yükleme) bu tarayıcıda güncel kuşaktır
    var res = applyOffline(Date.now());
    lastStageShown = stageIndex(S.runEarned);
    S.stage = Math.max(S.stage, lastStageShown);
    S.stageBest = Math.max(S.stageBest, S.stage);
    checkDaily();
    checkAchievements();
    treeSig = '';
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
      Core.lastWritten = raw;
      for (var i = 0; !raw && i < LEGACY_KEYS.length; i++) {
        raw = localStorage.getItem(LEGACY_KEYS[i]);
        if (raw) migrated = true;
      }
    } catch (e) {}
    var floor = readEpoch();
    var fresh = function () { S = newState(); meta.epoch = floor; meta.resetAt = floor; if (floor) S.eventLog = takeLogCarry(floor); return null; };
    if (!raw) return fresh();
    // v4.3.1: daha yeni sürümün kaydı: gösterim için okunur (bilinen alanlar), ama bu oturumda hiç yazılmaz
    guardFuture(raw, 'local');
    try { deserialize(raw); } catch (e) { return fresh(); }
    // Sıfırlamadan sonra kalmış eski kuşaktan kayıt (ör. eski sürümlü bir sekme yazdıysa) yüklenmez.
    if (meta.epoch < floor) return fresh();
    var res = applyOffline(Date.now());
    res.migrated = migrated;
    return res;
  }

  // ------------------------------------------------------------------
  // v4.2: Kaydı sıfırla. Basılı tutarak onay, "Geri al", yedekten geri yükleme ve bayat sekme/cihaz koruması.
  // Bulut tarafı (kodhane_reset_save / kodhane_restore_save RPC'leri — adlar yalnızca cloud.js RPC sabitinde —, revision kuralı) cloud.js içindedir.
  // ------------------------------------------------------------------
  var RESET_HOLD_MS = 2000;                  // basılı tutma süresi: bilerek sabit (ayar değil)
  var EPOCH_KEY = 'kodhane_save_epoch';      // localStorage: bu tarayıcıdaki en yeni kayıt kuşağı (tüm sekmeler)
  var UNDO_KEY = 'kodhane_reset_undo';       // sessionStorage: sıfırlamadan hemen önceki kayıt + geri alma bilgisi (yalnızca bu sekme)
  var UNDO_RELOAD_MS = 60000;                // sıfırlama ile sayfanın yeniden açılması arasında izin verilen en uzun süre
  // v4.4: "Kaydı sıfırla" olay listesini silmez: liste + sıfırlama girdisi yeni kuşak numarasıyla burada bekler, yeniden açılışta
  // boş kayda (aynı kuşak) konur. Geri al / yedekten geri yükleme kendi kaydının listesini getirir (sıfırlama girdisi olmadan).
  var LOG_CARRY_KEY = 'kodhane_event_log_carry';
  function takeLogCarry(epoch) {
    try {
      var c = JSON.parse(localStorage.getItem(LOG_CARRY_KEY) || 'null');
      return c && c.epoch === epoch ? cleanEventLog(c.log) : [];
    } catch (e) { return []; }
  }
  var resetBusy = false;
  var undoState = { timer: 0, marker: null };
  function readEpoch() { try { var n = Number(localStorage.getItem(EPOCH_KEY)); return n > 0 && isFinite(n) ? n : 0; } catch (e) { return 0; } }
  function newEpoch() { return Math.max(Date.now(), readEpoch() + 1, meta.epoch + 1); }
  function signedIn() { return !!(Core.cloudSignedIn && Core.cloudSignedIn()); }
  function cloudApi(name) { return Core.cloud && typeof Core.cloud[name] === 'function' ? Core.cloud : null; }
  function esc(t) { return String(t).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function num0(x) { return typeof x === 'number' && isFinite(x) ? x : 0; }

  // Bu sekme eski kuşaktaysa (başka sekmede sıfırlama/geri alma oldu): yerel kayda yazmaz, güncel kaydı yükler.
  var stalePendingSince = 0;
  function staleLocal() {
    var floor = readEpoch();
    if (floor <= meta.epoch) { stalePendingSince = 0; return false; }
    var cur = null;
    try { cur = JSON.parse(localStorage.getItem(SAVE_KEY) || 'null'); } catch (e) { cur = null; }
    if (!cur || typeof cur !== 'object' || !(num0(cur.epoch) >= floor)) {
      // Diğer sekme yeni kuşağı duyurdu ama kaydını henüz yazmadı (depolama olayları sırasız gelebilir):
      // kısa süre bekle (bu sekme yazmaz); ~2 sn içinde gelmezse (ör. sıfırlayan sekme kapandı) boş kayıtla devam et.
      if (!stalePendingSince) stalePendingSince = Date.now();
      if (Date.now() - stalePendingSince < 2000) {
        setTimeout(function () { if (!resetting) staleLocal(); }, 400);
        return true;
      }
      cur = null;
    }
    stalePendingSince = 0;
    var otherReset = !cur || num0(cur.resetAt) > meta.resetAt;
    if (!cur) { cur = saveDataOf(newState()); cur.epoch = floor; cur.resetAt = floor; cur.eventLog = takeLogCarry(floor); }
    adoptSave(cur, otherReset ? 'otherDevice' : 'undoDone');
    return true;
  }
  function saveDataOf(st) { var o = {}; for (var k in st) o[k] = st[k]; return o; }

  // Başka sekmede/cihazda yapılmış değişikliğin sonucunu uygula. kind: 'otherDevice' (orada sıfırlandı),
  // 'undoDone' (orada sıfırlama geri alındı), 'silent' (mesajı çağıran gösterir).
  function adoptSave(data, kind) {
    if (guardFuture(data, 'adopt')) return;
    if (undoState.marker) hideUndo(true); // bu sekmedeki geri alma artık geçersiz
    if (!el.modal.classList.contains('hidden')) closeModal();
    var d = JSON.parse(JSON.stringify(data));
    // kind 'otherDevice' | 'undoDone' | ya da doğrudan 'reset'/'sync' (staleKind)
    var sk = (kind === 'otherDevice' || kind === 'reset' || kind === 'sync')
      ? ((kind === 'reset' || kind === 'sync') ? kind
        : (Core.cloud && Core.cloud.staleKind ? Core.cloud.staleKind(S, d) : 'reset'))
      : null;
    if ((sk === 'reset' || sk === 'sync') && !d.lastSaved) d.lastSaved = Date.now();
    applySave(d);
    Core.lastAdopt = sk ? 'otherDevice' : kind;   // uyumluluk: 409/başka sekme = 'otherDevice'
    Core.lastAdoptKind = sk || null;               // 'reset' | 'sync' (staleKind)
    if (sk === 'reset') toast('🔄 ' + otherDeviceText(signedIn(), sk), 7000);
    else if (sk === 'sync') toast(otherDeviceText(signedIn(), sk), 7000);   // yalnız onaylı metin
    else if (kind === 'undoDone') toast('↩️ ' + resetText('reset.undoDone'), 4500);
    refreshRestoreBox();
  }
  Core.adoptSave = adoptSave;

  // Geri alınan / yedekten gelen kaydı yeni kuşakla uygula (eski sekmeler üstüne yazamasın).
  function applyRestored(data) {
    if (writesBlocked() || guardFuture(data, 'restore')) return;
    var d = JSON.parse(JSON.stringify(data));
    d.epoch = newEpoch();
    d.lastSaved = Date.now(); // yedekte geçen süre için çevrimdışı kazanç verilmez
    applySave(d);
  }

  function goPrestige() { if (isMobile()) setView('prestige'); else selectTab('prestige'); }

  function listBlock(title, items, cls) {
    var box = document.createElement('div'); box.className = 'reset-col ' + cls;
    var h = document.createElement('h4'); h.textContent = title; box.appendChild(h);
    var ul = document.createElement('ul');
    items.forEach(function (t) { var li = document.createElement('li'); li.textContent = t; ul.appendChild(li); });
    box.appendChild(ul);
    return box;
  }

  // Basılı tutma düğmesi: 2 sn dolum (sayı yok), erken bırakmak iptal eder; fare/dokunma ve Space/Enter.
  function makeHoldButton(onDone) {
    var btn = document.createElement('button');
    btn.type = 'button'; btn.id = 'resetHold'; btn.className = 'btn danger hold-btn';
    var fill = document.createElement('span'); fill.className = 'hold-fill'; fill.setAttribute('aria-hidden', 'true');
    var label = document.createElement('span'); label.className = 'hold-label'; label.textContent = resetText('reset.hold');
    btn.appendChild(fill); btn.appendChild(label);
    var t0 = 0, raf = 0, timer = 0, via = null, done = false;
    function paint(p) { fill.style.transform = 'scaleX(' + p + ')'; }
    function frame() {
      if (!t0) return;
      paint(Math.min(1, (performance.now() - t0) / RESET_HOLD_MS));
      raf = requestAnimationFrame(frame);
    }
    function start(src) {
      if (done || t0) return;
      t0 = performance.now(); via = src;
      btn.classList.add('holding'); label.textContent = resetText('reset.holding');
      vibrate(10);
      raf = requestAnimationFrame(frame);
      timer = setTimeout(finish, RESET_HOLD_MS);
    }
    function cancel(src) {
      if (done || !t0 || (src && src !== via)) return;
      t0 = 0; via = null; clearTimeout(timer); cancelAnimationFrame(raf);
      btn.classList.remove('holding'); label.textContent = resetText('reset.hold'); paint(0);
    }
    function finish() {
      if (!t0) return;
      // Pencere bu arada kapandıysa / değiştiyse sıfırlama yapılmaz.
      if (!btn.isConnected || el.modal.classList.contains('hidden')) { cancel(); return; }
      t0 = 0; cancelAnimationFrame(raf);
      done = true; paint(1); btn.classList.remove('holding'); btn.classList.add('done'); btn.disabled = true;
      vibrate([20, 40, 20]);
      onDone();
    }
    btn.addEventListener('pointerdown', function (e) {
      if (e.pointerType === 'mouse' && e.button !== 0) return;
      e.preventDefault();
      try { btn.setPointerCapture(e.pointerId); } catch (x) {}
      start('pointer');
    });
    ['pointerup', 'pointercancel', 'lostpointercapture'].forEach(function (t) { btn.addEventListener(t, function () { cancel('pointer'); }); });
    btn.addEventListener('contextmenu', function (e) { e.preventDefault(); });   // mobilde uzun basış menüsü açılmasın
    btn.addEventListener('selectstart', function (e) { e.preventDefault(); });
    btn.addEventListener('click', function (e) { e.preventDefault(); });         // tek tık hiçbir şey yapmaz
    function holdKey(e) { return e.code === 'Space' || e.key === ' ' || e.key === 'Enter'; }
    // Oyun Space tuşunu genel olarak dinler (kod yazma); burada yayılım durdurulur, basılı tutma kod yazmaz.
    btn.addEventListener('keydown', function (e) {
      if (!holdKey(e)) return;
      e.preventDefault(); e.stopPropagation();
      if (!e.repeat) start('key');
    });
    btn.addEventListener('keyup', function (e) {
      if (!holdKey(e)) return;
      e.preventDefault(); e.stopPropagation();
      cancel('key');
    });
    btn.addEventListener('blur', function () { cancel(); });
    return { btn: btn, cancel: cancel };
  }

  function openResetDialog() {
    if (blockedAction()) return;       // v4.3.1: daha yeni kayıt okunduysa sıfırlama yok (yenile bandı)
    var signed = signedIn();
    var extra = document.createElement('div'); extra.className = 'reset-extra';
    var cols = document.createElement('div'); cols.className = 'reset-cols';
    cols.appendChild(listBlock(resetText('reset.deleteTitle'), resetText('reset.deleteList'), 'del'));
    cols.appendChild(listBlock(resetText('reset.keepTitle'), resetText('reset.keepList'), 'keep'));
    extra.appendChild(cols);
    var hint = document.createElement('p'); hint.className = 'reset-hint'; hint.textContent = resetText('reset.prestigeHint');
    extra.appendChild(hint);
    var pbtn = document.createElement('button'); pbtn.type = 'button'; pbtn.id = 'resetPrestige'; pbtn.className = 'btn ghost reset-prestige';
    pbtn.textContent = resetText('reset.prestigeBtn');
    pbtn.addEventListener('click', function () { closeModal(); goPrestige(); });
    extra.appendChild(pbtn);
    if (signed) {
      var bk = document.createElement('p'); bk.className = 'reset-backup'; bk.textContent = resetText('reset.backup');
      extra.appendChild(bk);
    }
    modal({ emoji: '⚠️', title: resetText('reset.title'), html: esc(resetText('reset.body')), extra: extra, cardClass: 'reset-card',
      buttons: [{ label: resetText('reset.cancel'), cls: 'ghost' }] });
    var hold = makeHoldButton(performReset);
    el.modalActions.appendChild(hold.btn);
    try { el.modalActions.firstChild.focus(); } catch (e) {}
  }

  function withTimeout(p, ms) {
    return new Promise(function (resolve, reject) {
      var t = setTimeout(function () { var e = new Error('timeout'); e.code = 'timeout'; reject(e); }, ms);
      p.then(function (v) { clearTimeout(t); resolve(v); }, function (e) { clearTimeout(t); reject(e); });
    });
  }

  // Sıfırla. Girişliyse önce sunucu: kodhane_reset_save RPC (satır silinmez; yedek alınır, revision artar). RPC başarısızsa
  // sıfırlama yapılmaz (yerelde sıfırlansa bir sonraki eşitlemede buluttaki kayıt geri gelirdi). Sonra yerel: kaydın
  // kopyası bu sekmede tutulur (Geri al), yeni kuşak yazılır, kayıt silinir, sayfa yeniden açılır.
  // Başarımlar/itibar/seri dahil kaydın tamamı silinir (v4.1.1 ile aynı; Yatırım Turu bunları korur).
  function performReset() {
    if (blockedAction()) return;
    if (resetBusy) return;
    save();
    if (readEpoch() > meta.epoch) return; // bu sekme bayatmış; güncel kayıt yüklendi, sıfırlama yapılmadı
    resetBusy = true;
    var snapshot = serialize();
    var carryLog = resetCarryLog(S);
    var signed = signedIn();
    var p = signed && typeof Core.beforeReset === 'function' ? withTimeout(Promise.resolve(Core.beforeReset()), 10000) : Promise.resolve(null);
    resetting = true;
    p.then(finish, function (e) {
      resetting = false; resetBusy = false; closeModal();
      Core.lastResetError = (e && (e.code || e.message)) || 'error';
      toast(resetText('reset.cloudFailed'), 5000);
    });
    function finish(res) {
      var epoch = newEpoch();
      try {
        sessionStorage.setItem(UNDO_KEY, JSON.stringify({ v: 1, at: Date.now(), epoch: epoch,
          backupId: res && res.backupId ? res.backupId : null, save: snapshot }));
      } catch (e) { /* sessionStorage yoksa geri alma gösterilmez */ }
      try {
        localStorage.setItem(EPOCH_KEY, String(epoch));
        localStorage.setItem(LOG_CARRY_KEY, JSON.stringify({ epoch: epoch, log: carryLog }));
        localStorage.removeItem(SAVE_KEY); LEGACY_KEYS.forEach(function (k) { localStorage.removeItem(k); });
      } catch (e) {}
      track('reset_or_prestige'); // Umami isteği keepalive ile gider; yeniden açılış onu kesmez
      location.reload();
    }
  }

  // ---- Geri al (sayfa yeniden açıldıktan sonra, CFG.reset.undoSeconds boyunca)
  function readUndo() { try { var m = JSON.parse(sessionStorage.getItem(UNDO_KEY) || 'null'); return m && m.v === 1 ? m : null; } catch (e) { return null; } }
  function clearUndo() { try { sessionStorage.removeItem(UNDO_KEY); } catch (e) {} }
  function hideUndo(clear) {
    clearInterval(undoState.timer); undoState.timer = 0; undoState.marker = null;
    if (el.undoBar) el.undoBar.classList.add('hidden');
    if (clear) clearUndo();
  }
  function initUndo() {
    var m = readUndo();
    if (!m) return;
    var now = Date.now();
    if (!m.expiresAt) {
      if (now - num0(m.at) > UNDO_RELOAD_MS || m.epoch !== meta.epoch || typeof m.save !== 'string') { clearUndo(); return; }
      m.expiresAt = now + CFG.reset.undoSeconds * 1000;
      try { sessionStorage.setItem(UNDO_KEY, JSON.stringify(m)); } catch (e) { clearUndo(); return; }
    } else if (m.epoch !== meta.epoch) { clearUndo(); return; }
    if (now >= m.expiresAt) { clearUndo(); return; }
    undoState.marker = m;
    el.undoText.textContent = resetText('reset.done');
    el.undoBtn.disabled = false;
    el.undoBar.classList.remove('hidden');
    var paint = function () {
      var left = Math.ceil((m.expiresAt - Date.now()) / 1000);
      if (left <= 0 || !undoState.marker) { hideUndo(true); return; }
      el.undoBtn.textContent = resetText('reset.undo', { s: left });
    };
    paint();
    undoState.timer = setInterval(paint, 250);
  }
  function doUndo() {
    if (blockedAction()) return;
    var m = undoState.marker;
    if (!m || Date.now() >= m.expiresAt) { hideUndo(true); return; }
    el.undoBtn.disabled = true;
    clearInterval(undoState.timer); undoState.timer = 0;
    // Girişli: kodhane_restore_save RPC (sunucudaki yedekten). Misafir ya da yedek kimliği yoksa: bu sekmedeki kopyadan.
    var api = m.backupId ? cloudApi('restoreSave') : null;
    var p = api ? withTimeout(api.restoreSave({ backupId: m.backupId }), 10000) : Promise.reject(new Error('local'));
    p.then(function (res) {
      if (!res || !res.data) throw new Error('empty');
      applyRestored(res.data);
      Core.lastUndo = 'cloud';
    }).catch(function () {
      // RPC'ye ulaşılamadıysa da yerel kopya uygulanır; girişliyse bir sonraki yazma (revision + 1) onu buluta taşır.
      applyRestored(JSON.parse(m.save));
      Core.lastUndo = 'local';
      var c = cloudApi('push'); if (c && signedIn()) c.push(true);
    }).then(function () {
      hideUndo(true);
      toast('↩️ ' + resetText('reset.undoDone'), 4500);
      refreshRestoreBox();
    });
  }

  // ---- Yedekten geri yükle (yalnızca girişli oyuncu; İstatistik sekmesinde, geri yüklenebilir yedek varsa)
  var restoreSigned = null;
  function refreshRestoreBox() {
    var box = el.restoreBox;
    if (!box) return;
    var api = signedIn() ? cloudApi('latestBackup') : null;
    if (!api) { box.classList.add('hidden'); box._backup = null; return; }
    api.latestBackup().then(function (b) {
      box._backup = b && b.backupId ? b : null;
      box.classList.toggle('hidden', !box._backup || !signedIn());
    }, function () { box._backup = null; box.classList.add('hidden'); });
  }
  function onCloudRenderReset() {
    var s = signedIn();
    if (s !== restoreSigned) { restoreSigned = s; refreshRestoreBox(); }
  }
  function openRestoreDialog() {
    if (blockedAction()) return;
    var b = el.restoreBox && el.restoreBox._backup;
    if (!b || !signedIn()) return;
    modal({ emoji: '🗂️', title: resetText('reset.restoreTitle'), html: esc(resetText('reset.restoreBody')),
      buttons: [{ label: resetText('reset.cancel'), cls: 'ghost' }, { label: resetText('reset.restoreBtn'), cls: 'primary', onClick: function () {
        var api = cloudApi('restoreSave');
        if (!api) return;
        withTimeout(api.restoreSave({ backupId: b.backupId }), 10000).then(function (res) {
          if (!res || !res.data) throw new Error('empty');
          applyRestored(res.data);
          toast('✅ ' + resetText('reset.restoreDone'), 4500);
          refreshRestoreBox();
        }).catch(function () {
          toast(resetText('reset.restoreFailed'), 4500);
        });
      } }]
    });
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
      if (!genUnlocked(g)) {
        // yeni aşamanın çalışanı: aşamaya ulaşınca açılır (bir sonraki kilitli olan gösterilir)
        if (revealedNext) { r.btn.classList.add('hidden'); return; }
        revealedNext = true;
        var stg = STAGE_BY_ID[g.stage];
        r.btn.classList.remove('hidden', 'affordable');
        r.btn.classList.add('locked'); r.btn.disabled = true;
        r.name.textContent = '???';
        r.sub.textContent = stg.icon + ' ' + stg.name + ' aşamasında açılır';
        r.owned.textContent = '';
        r.cost.textContent = tl(g.base);
        return;
      }
      var revealed = owned > 0 || i === 0 || S.gens[GENERATORS[i - 1].id] > 0 || S.runEarned >= g.base || !!g.stage;
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
        var firstEver = i > S.stageBest;
        if (firstEver) S.stageBest = i;
        // İlk kez ulaşılan aşama: tam ekran kısa tebrik; sonraki turlarda yeniden ulaşınca yalnızca bildirim
        if (firstEver && !quiet()) showStageUp(i);
        else toast('🎉 ' + st.icon + ' ' + st.name + ' — ' + st.msg + ' (+%' + Math.round(i * STAGE_BONUS * 100) + ' üretim)', 6000);
        sfx('stage'); vibrate([15, 40, 15]);
      }
    }
    applyTint(Math.max(i, 0));
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
      ['Halka arz sayısı', fmt(S.ipoCount)],
      ['Borsa Payı (harcanabilir / toplam)', fmt(S.ipoShares) + ' / ' + fmt(S.ipoSharesEarned)],
      ['Sürüm', 'v' + VERSION]
    ];
    var html = rows.map(function (r) { return '<div><dt>' + r[0] + '</dt><dd>' + r[1] + '</dd></div>'; }).join('');
    if (el.statsList._html !== html) { el.statsList.innerHTML = html; el.statsList._html = html; }
  }
  function renderPrestige() {
    el.prShares.textContent = fmt(S.shares);
    el.prBonus.textContent = '+%' + pctText(investorBonus(S.shares));
    el.prPer.textContent = '+%' + pctText(shareBonus());
    var g = sharesGain();
    el.prGain.textContent = fmt(g) + ' hisse';
    el.prNext.textContent = tl(nextShareAt()) + ' tur kazancı';
    el.prestigeBtn.disabled = g < 1;
    renderIpo();
  }
  // Halka Arz bölümü + Borsa Payı Ağacı
  var treeSig = '';
  var ipoWasWaiting = null;   // bekleme bitince tek seferlik "yeniden açık" bildirimi için
  function renderIpo() {
    var H = CFG.halkaArz, roundsOk = ipoRoundsOk(), wait = ipoCooldownLeft(), open = roundsOk && !(wait > 0);
    el.ipoSection.classList.toggle('locked', !roundsOk);
    el.ipoLock.classList.toggle('hidden', roundsOk);
    if (!roundsOk) el.ipoLock.textContent = '🔒 ' + H.rounds + ' yatırım turundan sonra açılır. (' + Math.min(S.cycleRounds, H.rounds) + '/' + H.rounds + ')';
    // v4.4: bekleme satırı tur şartı satırının altında ayrı satır (tek satıra birleştirilmez; dar ekranda taşar)
    el.ipoWait.classList.toggle('hidden', !(wait > 0));
    if (wait > 0) {
      el.ipoWaitText.textContent = uiText('ipo.lockWait', { s: fmtSec(wait) });
      el.ipoWaitNote.textContent = uiText('ipo.lockWaitNote', { h: fmtDur(H.cooldownSec) });
    }
    if (ipoWasWaiting && !(wait > 0) && S.ipoCount > 0) toast(uiText('ipo.reopened'), 3500);
    ipoWasWaiting = wait > 0;
    var gain = ipoGain();
    el.ipoShares.textContent = fmt(S.ipoShares);
    el.ipoGain.textContent = fmt(gain) + ' Borsa Payı';
    el.ipoCount.textContent = fmt(S.ipoCount);
    el.ipoBonus.textContent = '+%' + num(Math.min(S.ipoShares, H.unspentCap) * H.unspentBonus * 100) + ' üretim' + (S.ipoShares >= H.unspentCap ? ' (en fazla)' : '');
    var z = num(accelEarned() * H.shareGainPerEarned * 100), zMax = H.accelCap != null && S.ipoSharesEarned >= H.accelCap;
    el.ipoAccel.textContent = uiText(zMax ? 'ipo.accelValueMax' : 'ipo.accelValue', { z: z });
    el.ipoAccelNote.textContent = uiText('ipo.accelNote', { k: num(H.shareGainPerEarned * 100), max: num(1 + H.shareGainPerEarned * H.accelCap) });
    var hint = open && gain < 1;
    el.ipoHint.classList.toggle('hidden', !hint);
    if (hint) { var ps = STAGES[ipoPayStage()]; el.ipoHint.textContent = 'Borsa Payı kazanmak için önce ' + ps.icon + ' ' + ps.name + ' aşamasına ulaşman gerekiyor.'; }
    el.ipoBtn.disabled = !open || gain < 1;
    var lbl = wait > 0 ? uiText('ipo.btnWait', { s: fmtSec(wait) }) : 'Halka arz et';
    if (el.ipoBtn.textContent !== lbl) el.ipoBtn.textContent = lbl;
    var sig = S.tree.join(',') + '|' + S.ipoShares;
    if (sig === treeSig) return;
    treeSig = sig;
    el.treeGrid.innerHTML = '';
    TREE.forEach(function (br) {
      var box = document.createElement('div'); box.className = 'tree-branch'; box.dataset.branch = br.id;
      var h = document.createElement('h4'); h.textContent = br.icon + ' ' + br.name; box.appendChild(h);
      br.nodes.forEach(function (n) {
        var st = nodeState(n.id), cost = nodeCost(n);
        var b = document.createElement('button'); b.type = 'button';
        b.className = 'tree-node ' + st; b.dataset.node = n.id; b.disabled = st !== 'ready';
        var nm = document.createElement('b'); nm.textContent = n.name;
        var c = document.createElement('span'); c.className = 'tn-cost'; c.textContent = st === 'owned' ? '✓' : cost + ' 🪙';
        var d = document.createElement('small'); d.textContent = n.desc();
        var m = document.createElement('small'); m.className = 'tn-state'; m.textContent = nodeStateText(n, st);
        b.appendChild(nm); b.appendChild(c); b.appendChild(d); b.appendChild(m);
        b.addEventListener('click', function () {
          if (buyNode(n.id)) {
            toast('🪙 ' + n.name + ' — Alındı! Bu bonus artık kalıcı.', 3500); sfx('buy'); vibrate(12); treeSig = ''; save(); renderAll();
            if (treeFull()) track('tree_full', treeEventData());   // v4.4: ağaç doldu (tüm düğümler = 40 pay)
          }
        });
        box.appendChild(b);
      });
      el.treeGrid.appendChild(box);
    });
  }
  function nodeStateText(n, st) {
    if (st === 'owned') return 'Alındı! Bu bonus artık kalıcı.';
    if (st === 'locked') return 'Önce ' + NODE_BY_ID[n.prev].name + ' gerekli.';
    if (st === 'poor') return nodeCost(n) + ' Borsa Payı gerekiyor. Bir halka arz daha?';
    return nodeCost(n) + ' Borsa Payı ile al';
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
    if (S.boostLeft > 0) parts.push('<span class="buff good">🔥 Acil teslim modu: tüm kazanç x2 — ' + fmtSec(Math.ceil(S.boostLeft)) + '</span>');
    S.pendingPay.forEach(function (p) {
      parts.push('<span class="buff good">⏳ ' + p.label + ': +' + tl(p.amount) + ' — ' + fmtSec(Math.ceil(p.left)) + '</span>');
    });
    S.buffs.forEach(function (b) {
      var good = b.mult >= 1;
      var eff = b.kind === 'click' ? 'tık x' + fmt(b.mult) : (b.mult === 0 ? 'üretim durdu' : 'verim ' + (good ? '+' : '-') + '%' + Math.round(Math.abs(1 - b.mult) * 100));
      parts.push('<span class="buff ' + (good ? 'good' : 'bad') + '">' + (good ? '🚀 ' : '🐢 ') + b.label + ': ' + eff + ' — ' + fmtSec(Math.ceil(b.left)) + '</span>');
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
      var txt = '🔮 Kahve falı: sıradaki olay ' + e.icon + ' ' + e.title + ' — yaklaşık ' + fmtSec(sec) + ' sonra';
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
    var r = first ? CFG.offerFirst : CFG.offerEvery, f = offerFreq();
    offer.nextAt = Date.now() + (r[0] + Math.random() * (r[1] - r[0])) * f * 1000;
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
    offer.dur = offerSec() * 1000;
    offer.until = Date.now() + offer.dur;
    offer.kind = kind || (Math.random() < 0.65 ? 'cash' : 'boost');
    var t = OFFER_TEXTS[Math.floor(Math.random() * OFFER_TEXTS.length)];
    if (offer.kind === 'cash') {
      offer.amount = Math.max(clickValue() * 40, baseTps() * (60 + Math.random() * 60), 50) * repMult() * offerPayMult();
      el.coText.textContent = t + ' — ' + tl(offer.amount) + ' ödeme!';
    } else {
      el.coText.textContent = t + ' — 30 sn boyunca tüm kazanç x2!';
    }
    var w = window.innerWidth, h = window.innerHeight;
    var bw = Math.min(290, w - 24);
    el.clientOffer.style.left = Math.round(12 + Math.random() * Math.max(0, w - bw - 24)) + 'px';
    var nb = nbSpace();                // v4.3: izin bandı görünürken teklif onun üstünde kalır
    el.clientOffer.style.top = Math.round(80 + Math.random() * Math.max(0, h - (isMobile() ? 300 : 200) - nb)) + 'px';
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
      el.coTimerFill.style.width = Math.max(0, left / (offer.dur || 10000) * 100) + '%';
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
    if (!id || !EVENT_BY_ID[id]) {
      id = evs.nextId;
      if (!id || !cardAvailable(EVENT_BY_ID[id])) id = pickEvent(evs.id);
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
      else if (n.type === 'paid') { toast('💸 ' + n.data.label + ' geldi: +' + tl(n.data.amount), 3800); sfx('buy'); }
      else if (n.type === 'newday') { toast('📅 Yeni günün görevleri hazır!' + (n.data.reset ? ' Dün görevler bitmediği için seri sıfırlandı.' : ''), 4200); }
    }
  }

  // ---- v4: tema rengi, aşama tebrik penceresi, paylaşım, haberler
  function quiet() { return !!root.KODHANE_QUIET; } // testler: tebrik penceresi ve haberler kapalı
  var tintShown = -1;
  function applyTint(i) {
    if (i === tintShown) return;
    tintShown = i;
    document.documentElement.style.setProperty('--stage-tint', STAGE_TINTS[i] || STAGE_TINTS[STAGE_TINTS.length - 1]);
  }
  var suTimer = 0;
  function showStageUp(i) {
    var st = STAGES[i];
    el.stageUp.dataset.stage = i;
    el.stageUp.style.setProperty('--su-tint', STAGE_TINTS[i] || STAGE_TINTS[0]);
    el.suIcon.textContent = st.icon;
    el.suTitle.textContent = st.name;
    el.suMsg.textContent = st.msg;
    el.suBonus.textContent = '+%' + Math.round(i * STAGE_BONUS * 100) + ' üretim';
    el.stageUp.classList.remove('hidden');
    clearTimeout(suTimer);
    suTimer = setTimeout(hideStageUp, CFG.stageModalSec * 1000);
  }
  function hideStageUp() { clearTimeout(suTimer); el.stageUp.classList.add('hidden'); }
  function shareLink(campaign) {
    var base;
    try { base = location.origin + location.pathname.replace(/index\.html$/, ''); } catch (e) { base = 'https://thejackaltr.github.io/kodhane/'; }
    if (!/^https?:/.test(base)) base = 'https://thejackaltr.github.io/kodhane/';
    return base + '?utm_source=paylasim&utm_medium=sosyal&utm_campaign=' + encodeURIComponent(campaign);
  }
  // Sıralamadaki paylaşım yapısı: Web Share, yoksa panoya kopyala, o da yoksa metni göster
  function shareText(text) {
    Core.lastShare = text;
    track('share_click');
    if (navigator.share) { navigator.share({ text: text }).catch(function () {}); }
    else if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () { toast('📋 Paylaşım metni kopyalandı.', 3000); }, function () { toast(text, 6000); });
    } else toast(text, 6000);
  }
  var news = { t0: Date.now(), shown: 0 };
  function maybeShowNews(now) {
    if (quiet() || news.shown >= CFG.newsPerSession || now - news.t0 < CFG.newsDelaySec * 1000) return;
    if (noticeBand()) return;          // v4.3: yanıtlanmamış izin bandının üstüne haber penceresi açılmaz (bant yanıtlanınca gelir)
    if (!el.modal.classList.contains('hidden') || !el.stageUp.classList.contains('hidden') || evs.visible || offer.visible) return;
    var acc = $('accountPanel');
    if (acc && !acc.classList.contains('hidden')) return;
    var n = nextNews();
    if (!n) return;
    news.shown++;
    markNewsSeen(n.id);
    save();
    if (n.count) countEvent(n.count + '_shown');
    var buttons = [];
    if (n.action) {
      buttons.push({ label: 'Kapat', cls: 'ghost' });
      buttons.push({ label: n.action, cls: 'primary', onClick: function () {
        if (n.count) countEvent(n.count + '_click');
        if (n.id === 'acik_ofis') track('acikofis_news_click');
        if (n.url) { Core.lastOpened = n.url; try { window.open(n.url, '_blank', 'noopener'); } catch (e) {} return; }
        if (isMobile()) setView('siralama'); else selectTab('siralama');
      } });
    } else buttons.push({ label: 'Tamam', cls: 'primary' });
    modal({ emoji: n.emoji, title: n.title, html: '', buttons: buttons });
    el.modalText.textContent = n.text();
    Core.lastNews = n.id;
  }
  // v4.3: anonim Supabase sayacı izne bağlı (GATE_SUPABASE_COUNTER); izin yoksa istek hiç yapılmaz
  function countEvent(name) { if (!tel.counterAllowed()) return; if (typeof Core.countEvent === 'function') { try { Core.countEvent(name); } catch (e) {} } }
  // ------------------------------------------------------------------
  // v4.3: İsimsiz sayaç izni (KVKK). Fenomen src/analytics.js + src/ui/privacy.js örneği.
  //   kodhane_tel_notice  herhangi bir değer = bildirim yanıtlandı ("Tamam" ya da "Kapat")
  //   kodhane_tel         'on' | 'off'     = "Tamam"/"Kapat" ya da İstatistik > Gizlilik düğmesi
  // Bu anahtarlar kayıttan (SAVE_KEY) ve kodhane_ayarlar_v1'den ayrıdır: sıfırlama, yatırım turu, halka arz, bulut
  // yükleme/çıkış ve yedekten geri yükleme onlara hiç dokunmaz (testler: tests/test_consent.js, tests/test_privacy.py).
  // Umami betiği index.html'de YOK. Yalnızca izin varken (bildirim "Tamam" ile yanıtlanmış ve kapatılmamış), izinli bir
  // alan adında (UMAMI_DOMAINS; localhost/127.0.0.1/file: asla) çalışırken sayfaya eklenir. İzinden önce gelen olaylar
  // (game_start dahil) ATILIR, sonradan gönderilmez. İzin verildikten sonra betik yüklenene kadar küçük bir bellek içi
  // kuyruk tutulur; betik gelince izin hâlâ açıksa gönderilir.
  // Kapatınca hemen durur: track() izni her çağrıda yeniden okur; betiğe data-before-send kancası verilir (Umami her
  // istekten, otomatik sayfa görüntülemesi dahil, önce onu çağırır; izin yoksa istek düşer); betiğin kendi kapatma
  // anahtarı localStorage 'umami.disabled' kapalıyken konur, açılınca kaldırılır.
  // Gizlilik: çerezsiz Umami, Do Not Track'e uyulur (data-do-not-track), sorgu dizesi ve # asla gönderilmez
  // (data-exclude-search / data-exclude-hash). Olay adı gider; v4.4'ten beri yalnızca ipo_complete ve tree_full olaylarında
  // sabit, kişisel olmayan birkaç oyun alanı da gider (ipoEventData / treeEventData). E-posta, takma ad, kimlik asla.
  // ------------------------------------------------------------------
  var TEL_KEYS = { pref: 'kodhane_tel', notice: 'kodhane_tel_notice', umamiOff: 'umami.disabled' };
  var UMAMI_SRC = 'https://analiz.teserix.com/script.js';
  var UMAMI_WEBSITE_ID = '6a036eb3-5974-482f-bcce-dbdf0a383f36';
  var UMAMI_DOMAINS = 'kodhane.teserix.com,thejackaltr.github.io';
  var UMAMI_BEFORE_SEND = '__kodhaneUmamiBeforeSend';
  // Anonim Supabase sayacı (kodhane_count_event: haber gösterimi/tıklaması) da AYNI izne bağlı. Yönetici kararı
  // değişirse yalnızca bu bayrak false yapılır. Giriş, bulut kaydı ve sıralama izinden bağımsızdır (oyun özellikleri).
  var GATE_SUPABASE_COUNTER = true;
  var LOCAL_HOST = /^(localhost|127\.\d+\.\d+\.\d+|\[?::1\]?|0\.0\.0\.0)$/i;
  function lsGet(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
  function lsSet(k, v) { try { localStorage.setItem(k, v); } catch (e) {} }
  function lsDel(k) { try { localStorage.removeItem(k); } catch (e) {} }
  var tel = {
    noticeNeeded: function () { return !lsGet(TEL_KEYS.notice); },
    consent: function () { return !!lsGet(TEL_KEYS.notice) && lsGet(TEL_KEYS.pref) !== 'off'; },
    hostOk: function () {
      try {
        var l = root.location;
        if (!l || !/^https?:$/.test(l.protocol) || LOCAL_HOST.test(l.hostname)) return false;
        return UMAMI_DOMAINS.split(',').indexOf(l.hostname) !== -1;
      } catch (e) { return false; }
    },
    allowed: function () { return tel.consent() && tel.hostOk(); },
    // bildirim yanıtı: "Tamam" (true) ya da "Kapat" (false)
    answer: function (ok) { lsSet(TEL_KEYS.notice, '1'); lsSet(TEL_KEYS.pref, ok ? 'on' : 'off'); return tel.sync(); },
    // Gizlilik düğmesi. Bildirim henüz yanıtlanmadıysa düğme onu da yanıtlar (bant kalkar).
    setEnabled: function (on) { lsSet(TEL_KEYS.notice, '1'); lsSet(TEL_KEYS.pref, on ? 'on' : 'off'); return tel.sync(); },
    // İzin değişince, her track()'te ve başka sekmeden gelen 'storage' olayında çağrılır. Umami şu an çalışabilir mi?
    sync: function () {
      if (!tel.allowed()) {
        if (lsGet(TEL_KEYS.pref) === 'off') lsSet(TEL_KEYS.umamiOff, '1');
        umamiQueue.length = 0;
        return false;
      }
      if (lsGet(TEL_KEYS.umamiOff)) lsDel(TEL_KEYS.umamiOff);
      umamiLoad();
      return true;
    },
    counterAllowed: function () { return !GATE_SUPABASE_COUNTER || tel.consent(); }
  };
  var umamiScript = null, umamiQueue = [], umamiFailed = false;  // umamiFailed: betik yüklenemedi (engelli/çevrimdışı), bu oturumda olaylar atılır
  function umamiReady() { try { var u = root.umami; return u && typeof u.track === 'function' ? u : null; } catch (e) { return null; } }
  function umamiSend(u, name, data) { try { if (data) u.track(name, data); else u.track(name); } catch (e) {} }
  function umamiLoad() {
    if (umamiScript || !tel.allowed()) return umamiScript;
    root[UMAMI_BEFORE_SEND] = function (type, payload) { return tel.allowed() ? payload : null; };
    var s = document.createElement('script');
    s.async = true;                      // async: yavaş/erişilemeyen sunucu oyunu bekletmez
    s.src = UMAMI_SRC;
    s.setAttribute('data-website-id', UMAMI_WEBSITE_ID);
    s.setAttribute('data-domains', UMAMI_DOMAINS);
    s.setAttribute('data-before-send', UMAMI_BEFORE_SEND);
    s.setAttribute('data-do-not-track', 'true');
    s.setAttribute('data-exclude-search', 'true');
    s.setAttribute('data-exclude-hash', 'true');
    s.setAttribute('data-test', 'umami-script');
    s.addEventListener('load', function () {
      var q = umamiQueue.splice(0), u = umamiReady();
      if (u && tel.allowed()) q.forEach(function (n) { umamiSend(u, n.name, n.data); });
    });
    s.addEventListener('error', function () { umamiFailed = true; umamiQueue.length = 0; });
    (document.head || document.body || document.documentElement).appendChild(s);
    umamiScript = s;
    return s;
  }
  // Olay adı (ve v4.4'te iki olayda sabit alanlı veri) gönderir. İzin yoksa hiçbir şey yapmaz ve atar (kuyruğa almaz).
  // Asla hata fırlatmaz. data yalnız ipo_complete / tree_full için (ipoEventData / treeEventData); başka alan eklenmez.
  function track(name, data) {
    var st, d = data && typeof data === 'object' ? JSON.parse(JSON.stringify(data)) : null;
    try {
      if (!tel.sync()) st = 'off';
      else {
        var u = umamiReady();
        if (u) { umamiSend(u, name, d); st = 'sent'; }
        else if (umamiFailed) st = 'dropped';
        else if (umamiQueue.length < 20) { umamiQueue.push({ name: name, data: d }); st = 'queued'; }
        else st = 'dropped';
      }
    } catch (e) { st = 'off'; }
    if (st !== 'off') { Core.tracked.push(name); if (Core.tracked.length > 50) Core.tracked.shift(); }
    Core.trackLog.push(d ? [name, st, d] : [name, st]); if (Core.trackLog.length > 100) Core.trackLog.shift();
    return st;
  }
  // tracked: izinle kabul edilen olaylar; trackLog: her çağrı ve sonucu ('off' = atıldı) — yalnızca bellekte, testler için
  Core.tracked = []; Core.trackLog = []; Core.track = track; Core.umamiQueue = function () { return umamiQueue.map(function (q) { return q.name; }); };
  Core.tel = tel; Core.TEL_KEYS = TEL_KEYS; Core.GATE_SUPABASE_COUNTER = GATE_SUPABASE_COUNTER;
  Core.UMAMI = { src: UMAMI_SRC, websiteId: UMAMI_WEBSITE_ID, domains: UMAMI_DOMAINS, beforeSend: UMAMI_BEFORE_SEND };
  Core.counterAllowed = function () { return tel.counterAllowed(); };

  // ---- Bildirim bandı + ayrıntılar + Gizlilik düğmesi
  var NB_SPACE = '--nb-space';
  // Bant görünürken <html> üzerinde --nb-space'i (bandın üst kenarından ekranın altına + 8 px) tutar; style.css her
  // eylemi bunun üstünde tutar (gövde boşluğu, olay kartı, geri al çubuğu, masaüstü bildirimleri, müşteri teklifi).
  function reserveSpace(band) {
    var rootEl = document.documentElement, last = '', raf = 0;
    var fit = function () {
      if (!band.isConnected) return;
      var r = band.getBoundingClientRect();
      var v = Math.ceil(Math.max(0, window.innerHeight - r.top) + 8) + 'px';
      if (v !== last) { last = v; rootEl.style.setProperty(NB_SPACE, v); placeUpdateBar(); }
    };
    var soon = function () { if (!raf) raf = requestAnimationFrame(function () { raf = 0; fit(); }); };
    var ro = typeof ResizeObserver === 'function' ? new ResizeObserver(fit) : null;
    if (ro) ro.observe(band);
    window.addEventListener('resize', soon);
    rootEl.classList.add('nb-open');   // v4.3.1: :has() desteklemeyen tarayıcılar için de aynı boşluk (style.css)
    fit();
    return function () {
      if (ro) ro.disconnect(); if (raf) cancelAnimationFrame(raf);
      window.removeEventListener('resize', soon); rootEl.style.removeProperty(NB_SPACE); rootEl.classList.remove('nb-open');
      placeUpdateBar();
    };
  }
  // v4.3.1: kısa ekranda "Kod yaz" düğmesi ve altındaki ipucu satırı (.click-hint) bandın altında kalmasın. Bant açıkken
  // Kod görünümü açılınca (ilk açılış, alt çubukta Kod) sayfa, düğme ile ipucu birlikte bandın üstünde görünecek kadar
  // (en az kaydırma) kaydırılır; düğmenin üstü sabit üst çubuğun altına girmez. Bant yoksa ya da blok zaten görünüyorsa
  // hiçbir şey değişmez (uzun ekran ve masaüstü yerleşimi aynı).
  function keepKodClear() {
    if (!noticeBand() || !el.clickBtn || !el.panelKod || el.panelKod.classList.contains('mhide') && isMobile()) return 0;
    var hint = el.panelKod.querySelector('.click-hint');
    if (!hint) return 0;
    var limit = window.innerHeight - nbSpace();              // bandın üst kenarı - 8 px
    var tb = document.querySelector('.topbar'), pos = tb ? getComputedStyle(tb).position : '';
    var head = (pos === 'sticky' || pos === 'fixed') ? tb.getBoundingClientRect().height : 0;
    var btnTop = el.clickBtn.getBoundingClientRect().top, bottom = hint.getBoundingClientRect().bottom;
    if (bottom <= limit) return 0;
    var dy = Math.min(bottom - limit, Math.max(0, btnTop - head - 8));
    if (dy > 0) window.scrollBy(0, dy);
    return dy;
  }
  Core.keepKodClear = keepKodClear;
  function nbSpace() { var v = parseFloat(getComputedStyle(document.documentElement).getPropertyValue(NB_SPACE)); return isFinite(v) ? v : 0; }
  function noticeBand() { return document.querySelector('[data-test=tel-banner]'); }
  function dismissNoticeBand() { var b = noticeBand(); if (!b) return; if (b.__release) b.__release(); b.remove(); }
  function mk(tag, attrs, text) {
    var e = document.createElement(tag);
    for (var k in attrs) e.setAttribute(k, attrs[k]);
    if (text != null) e.textContent = text;
    return e;
  }
  // Ayrıntılar: bildirimi YANITLAMAZ (yalnızca okur); banttan ve Gizlilik bölümünden açılır
  function showTelDetails() {
    var box = mk('div', { 'class': 'tel-details', 'data-test': 'tel-details-body' });
    telText('telemetry.details').filter(function (p) { return String(p).trim(); }).forEach(function (p) { box.appendChild(mk('p', {}, p)); });
    modal({ emoji: '📊', title: telText('telemetry.detailsTitle'), html: '', extra: box, cardClass: 'tel-card',
      buttons: [{ label: telText('telemetry.detailsClose'), cls: 'primary' }] });
    var btn = el.modalActions.querySelector('button'); if (btn) btn.setAttribute('data-test', 'tel-details-close');
  }
  function showNoticeBand() {
    if (!tel.noticeNeeded() || noticeBand()) return null;
    var answer = function (ok) {
      tel.answer(ok);                  // "Tamam": sync() betiği şimdi yükler; "Kapat": kapalı kalır, hiçbir istek yok
      dismissNoticeBand(); renderTelSetting();
      if (!ok) toast(telText('telemetry.offToast'), 3500);
    };
    var band = mk('div', { 'class': 'notice-band', role: 'region', 'aria-label': telText('telemetry.title'), 'data-test': 'tel-banner' });
    var p = mk('p', { 'class': 'nb-text' });
    p.appendChild(mk('b', {}, telText('telemetry.title'))); p.appendChild(document.createTextNode(' ' + telText('telemetry.body')));
    var row = mk('div', { 'class': 'nb-row' });
    // KVKK: "Tamam" ve "Kapat" aynı sınıf = aynı görsel ağırlık
    var ok = mk('button', { type: 'button', 'class': 'btn nb-btn', 'data-test': 'tel-ok' }, telText('telemetry.ok'));
    var off = mk('button', { type: 'button', 'class': 'btn nb-btn', 'data-test': 'tel-off' }, telText('telemetry.off'));
    var det = mk('button', { type: 'button', 'class': 'nb-link', 'data-test': 'tel-details' }, telText('telemetry.detailsLink'));
    ok.addEventListener('click', function () { answer(true); });
    off.addEventListener('click', function () { answer(false); });
    det.addEventListener('click', showTelDetails);
    row.appendChild(ok); row.appendChild(off); row.appendChild(det);
    band.appendChild(p); band.appendChild(row);
    document.body.appendChild(band);
    band.__release = reserveSpace(band);
    keepKodClear();
    return band;
  }
  function renderTelSetting() {
    if (!el.telBtn) return;
    var on = tel.consent();
    el.telBtn.textContent = telText(on ? 'settings.telemetryOn' : 'settings.telemetryOff');
    el.telBtn.setAttribute('aria-pressed', String(on));
  }
  function toggleTel() {
    var on = !tel.consent();
    tel.setEnabled(on);                // kapalı: hemen durur (umami.disabled + before-send); açık: betik yoksa yüklenir
    dismissNoticeBand(); renderTelSetting();
    toast(telText(on ? 'telemetry.onToast' : 'telemetry.offToast'), 3500);
  }
  Core.showNoticeBand = showNoticeBand; Core.dismissNoticeBand = dismissNoticeBand; Core.showTelDetails = showTelDetails;
  Core.toggleTel = toggleTel; Core.nbSpace = nbSpace;

  function showWelcomeBack(res) {
    if (!res || res.elapsed < 60 || res.gain <= 0) return;
    modal({
      emoji: '👋', title: 'Tekrar hoş geldin!',
      html: 'Sen yokken ekibin <b>' + fmtTime(res.sec) + '</b> boyunca çalıştı ve <b>' + tl(res.gain) + '</b> kazandı.' +
        (res.capped ? '<br><small>Çevrimdışı kazanç en fazla ' + fmt(res.capHours) + ' saat için hesaplanır.</small>' : ''),
      buttons: [{ label: 'Harika, devam!', cls: 'primary' }]
    });
  }

  // Sekmeler ve mobil alt çubuk
  var TAB_GROUP = { upgrades: 'upgrades', daily: 'daily', achievements: 'daily', stats: 'prestige', prestige: 'prestige', siralama: 'siralama' };
  function selectTab(name, fromNav) {
    activeTab = name;
    document.querySelectorAll('.tabs button').forEach(function (x) {
      x.classList.toggle('active', x.dataset.tab === name);
      // Dar ekranda sekme şeridi kayar: etkin sekme görünür kalsın (sayfa kaydırılmadan).
      if (x.dataset.tab === name && x.parentNode && x.parentNode.scrollWidth > x.parentNode.clientWidth) {
        var bar = x.parentNode, l = x.offsetLeft - bar.offsetLeft, r = l + x.offsetWidth;
        if (l < bar.scrollLeft) bar.scrollLeft = l - 8;
        else if (r > bar.scrollLeft + bar.clientWidth) bar.scrollLeft = r - bar.clientWidth + 8;
      }
    });
    document.querySelectorAll('.tab').forEach(function (t) { t.classList.toggle('hidden', t.id !== 'tab-' + name); });
    if (!fromNav && view !== 'kod' && view !== 'ekip') { view = TAB_GROUP[name] || view; navActive(); }
    renderAll();
    if (name === 'siralama' && typeof Core.onLeaderboardShown === 'function') { try { Core.onLeaderboardShown(); } catch (e) {} }
    if (name === 'stats') refreshRestoreBox();
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
    if (v === 'kod') keepKodClear();   // v4.3.1: bant açıkken "Kod yaz" + ipucu bandın üstünde
  }

  // PWA: servis çalışanı ve güncelleme bildirimi.
  // v4.3.1: tek bant (#updateBar) iki durumu gösterir: servis çalışanı güncellemesi ("✨ Yeni sürüm hazır.", index.html) ve
  // daha yeni sürümün kaydı (update.newerSave.*; v4.4: bulut 426 ise update.olderTab.*). Aynı anda asla ayrı bant olmaz:
  // olderTab > newerSave > servis çalışanı güncellemesi; öncelikli olanın metni diğerinin yerine geçer. Bant üstte (sabit üst çubuğun altında), izin bandı altta: çakışmazlar; çok kısa
  // ekranda izin bandının üstünde kalacak şekilde yukarı kayar.
  var swWaiting = null, swUpdateText = '';
  function showUpdate(worker) { swWaiting = worker; renderUpdateBar(); }
  function reloadForNewer() {
    // Yazma zaten kapalı (save() hiçbir şey yazmaz). Bekleyen/yeni servis çalışanı varsa önce o etkinleşir ki yenilenen
    // sayfa önbellekteki eski sürümle açılmasın; yoksa hemen yenilenir.
    var go = function () { location.reload(); };
    var reg = Core.swRegistration;
    if (!reg || typeof reg.update !== 'function') return go();
    var kick = function () { if (reg.waiting) { updateRequested = true; reg.waiting.postMessage('skipWaiting'); setTimeout(go, 3000); return true; } return false; };
    if (kick()) return;
    reg.update().then(function () {
      if (kick()) return;
      var w = reg.installing;
      if (!w) return go();
      w.addEventListener('statechange', function () { if (w.state === 'installed' && !kick()) go(); if (w.state === 'redundant') go(); });
      setTimeout(go, 6000);
    }, go);
  }
  // v4.4: olderTab (bulut 426) ile newerSave (daha yeni kayıt okundu) aynı durumun iki yolu (hesaptaki kayıt bu istemciden
  // yeni); ikisi birden olsa da TEK bant ve olderTab metni gösterilir (bu sekmenin son ilerlemesinin buluta yazılamadığını
  // da kapsar, "ilerlemen korunuyor" demez).
  function setBandText(txt, key, short) {
    txt.textContent = '';
    if (key === 'olderTab') {
      var t = document.createElement('b'); t.className = 'ub-title'; t.textContent = uiText('update.olderTab.title');
      txt.appendChild(t);
      var s = document.createElement('span'); s.className = 'ub-text'; s.textContent = uiText(short ? 'update.olderTab.textShort' : 'update.olderTab.text');
      txt.appendChild(s);
    } else txt.textContent = uiText(short ? 'update.newerSave.textShort' : 'update.newerSave.text');
  }
  function renderUpdateBar() {
    if (!el.updateBar || !el.updateText) return;
    var newer = writesBlocked(), older = !!olderTab;
    if (!newer && !swWaiting) { el.updateBar.classList.add('hidden'); return; }
    var bar = el.updateBar, txt = el.updateText, key = older ? 'olderTab' : 'newerSave';
    bar.classList.remove('hidden');
    bar.classList.toggle('newer-save', newer);
    bar.classList.toggle('older-tab', older);
    bar.setAttribute('data-test', older ? 'older-tab-band' : newer ? 'newer-save-band' : 'update-band');
    bar.classList.remove('ub-short');
    if (newer) setBandText(txt, key, false); else txt.textContent = swUpdateText;
    el.updateBtn.textContent = newer ? uiText('update.' + key + '.btn') : 'Yenile';
    // Dar ekran: uzun metin bantta tek satıra sığmıyorsa kısa metin
    if (newer && txt.scrollWidth > txt.clientWidth + 1) { setBandText(txt, key, true); bar.classList.add('ub-short'); }
    el.updateBtn.onclick = newer ? reloadForNewer : function () {
      updateRequested = true; save();
      swWaiting.postMessage('skipWaiting');
      setTimeout(function () { location.reload(); }, 3000);
    };
    placeUpdateBar();
  }
  function placeUpdateBar() {
    var bar = el.updateBar;
    if (!bar || bar.classList.contains('hidden')) return;
    var tb = document.querySelector('.topbar'), pos = tb ? getComputedStyle(tb).position : '';
    var top = (pos === 'sticky' || pos === 'fixed') ? Math.max(0, tb.getBoundingClientRect().bottom) + 8 : 0;
    bar.style.top = top ? top + 'px' : '';
    // izin bandı açıksa onun üstünde bitsin (ikisi de tümüyle görünür ve tıklanabilir kalır)
    var nb = noticeBand();
    if (nb) {
      var limit = nb.getBoundingClientRect().top - 8, r = bar.getBoundingClientRect();
      if (r.bottom > limit) bar.style.top = Math.max(4, limit - r.height) + 'px';
    }
  }
  // Yazma kapalıyken sıfırlama, Yatırım Turu, Halka Arz, Geri al ve geri yükleme hiçbir şey yapmaz; bant öne çıkar.
  function blockedAction() {
    if (!writesBlocked()) return false;
    renderUpdateBar();
    if (el.updateBar) { el.updateBar.classList.remove('ub-flash'); void el.updateBar.offsetWidth; el.updateBar.classList.add('ub-flash'); }
    return true;
  }
  Core.onFutureSave = function () {
    if (Core.cloud && Core.cloud.state) { var c = Core.cloud.state; if (c.pushTimer) { clearTimeout(c.pushTimer); c.pushTimer = null; } }
    renderUpdateBar();
  };
  Core.onOlderTab = Core.onFutureSave;
  Core.renderUpdateBar = renderUpdateBar; Core.blockedAction = blockedAction; Core.showUpdate = showUpdate;
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
      'eventCard', 'evIcon', 'evTitle', 'evText', 'evChoices', 'evLater', 'evTimerFill', 'toast', 'updateBar', 'updateBtn', 'updateText',
      'modal', 'modalEmoji', 'modalTitle', 'modalText', 'modalActions', 'panelKod', 'panelEkip', 'panelSide', 'bottomNav',
      'prPer', 'ipoSection', 'ipoLock', 'ipoWait', 'ipoWaitText', 'ipoWaitNote', 'ipoAccel', 'ipoAccelNote', 'ipoBody', 'ipoShares', 'ipoGain', 'ipoCount', 'ipoBonus', 'ipoHint', 'ipoBtn', 'treeGrid',
      'stageUp', 'suIcon', 'suTitle', 'suMsg', 'suBonus', 'suShare', 'suClose',
      'modalCard', 'modalExtra', 'undoBar', 'undoText', 'undoBtn', 'restoreBox', 'restoreTitle', 'restoreBody', 'restoreNote', 'restoreBtn',
      'telBtn', 'telTitle', 'telHint', 'telDetailsBtn'
    ].forEach(function (id) { el[id] = $(id); });

    var offlineRes = load();
    lastStageShown = stageIndex(S.runEarned);
    S.stage = Math.max(S.stage, lastStageShown);
    S.stageBest = Math.max(S.stageBest, S.stage);
    checkDaily();
    var retro = checkAchievements();
    queue = queue.filter(function (n) { return n.type !== 'ach' && n.type !== 'newday'; });
    buildGenList();
    setCounter('money', S.money, true);
    setCounter('rate', tps(), true);

    function codeClick(cx, cy) {
      var v = doClick();
      var crit = Core.lastCrit;
      var rect = el.floaters.getBoundingClientRect();
      var x = (cx || rect.left + rect.width / 2) - rect.left;
      var y = (cy || rect.top + rect.height / 2) - rect.top;
      floater((crit ? 'KRİTİK! +' : '+') + tl(v), x + (Math.random() * 30 - 15), y - 20, crit ? 'crit' : '');
      burst(x, y, crit);
      sfx(crit ? 'crit' : 'click');
      vibrate(crit ? 25 : 10);
      renderTop(); renderStage();
    }
    el.clickBtn.addEventListener('click', function (e) {
      codeClick(e.clientX, e.clientY);
      // Fare/dokunma ile tıklandıysa odağı bırak: sonraki Space/Enter düğmeyi yerel olarak ikinci kez tetiklemesin.
      if (e.detail > 0) { try { el.clickBtn.blur(); } catch (x) {} }
    });
    // Klavye: Space her basışta bir kez kod yazar (basılı tutma sayılmaz); Enter basılı tutulunca tekrarlanmaz.
    el.clickBtn.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' && e.repeat) e.preventDefault();
    });
    function spaceTarget(e) {
      if (e.code !== 'Space' || e.ctrlKey || e.metaKey || e.altKey) return false;
      var t = e.target;
      if (t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))) return false;
      if (!el.modal.classList.contains('hidden')) return false;
      var acc = $('accountPanel');
      if (acc && !acc.classList.contains('hidden')) return false;
      return true;
    }
    document.addEventListener('keydown', function (e) {
      if (!spaceTarget(e)) return;
      e.preventDefault();
      if (e.repeat) return;
      codeClick();
    });
    document.addEventListener('keyup', function (e) {
      if (spaceTarget(e)) e.preventDefault();
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
    el.resetBtn.addEventListener('click', openResetDialog);
    // v4.3: İstatistik > Gizlilik
    el.telTitle.textContent = telText('settings.privacy');
    el.telHint.textContent = telText('settings.telemetryHint');
    el.telDetailsBtn.textContent = telText('telemetry.detailsLink');
    el.telBtn.addEventListener('click', toggleTel);
    el.telDetailsBtn.addEventListener('click', showTelDetails);
    // başka sekmede izin değişti: bu sekme de hemen uyar (kapalıysa durur, bant kalkar)
    window.addEventListener('storage', function (e) {
      if (e.key === null || e.key === TEL_KEYS.pref || e.key === TEL_KEYS.notice) { tel.sync(); if (!tel.noticeNeeded()) dismissNoticeBand(); renderTelSetting(); }
    });
    el.undoBtn.addEventListener('click', doUndo);
    el.restoreBtn.addEventListener('click', openRestoreDialog);
    el.restoreTitle.textContent = resetText('reset.restoreTitle');
    el.restoreBody.textContent = resetText('reset.restoreBody');
    el.restoreNote.textContent = resetText('reset.backup');
    el.restoreBtn.textContent = resetText('reset.restoreBtn');
    // Başka sekmede sıfırlama/geri alma: kuşak anahtarı değişince hemen kaydetmeyi dene (bayatsa yazma reddedilir,
    // güncel kayıt yüklenir).
    // Başka sekme sıfırladı/geri aldı: yazmadan (arka plan sekmesi de) güncel kaydı yükle
    window.addEventListener('storage', function (e) {
      if (e.key === SAVE_KEY && e.newValue && guardFuture(e.newValue, 'tab')) return;   // v4.3.1: yeni sürüm başka sekmede yazdı
      if ((e.key === EPOCH_KEY || e.key === SAVE_KEY) && !resetting) staleLocal();
    });
    el.prestigeBtn.addEventListener('click', function () {
      if (blockedAction()) return;     // v4.3.1: yazma kapalıyken Yatırım Turu yapılmaz
      var g = sharesGain();
      if (g < 1) return;
      modal({
        emoji: '💰', title: 'Yatırım turuna çık?',
        // {b}: bu turda kazanılacak g hissenin eklediği bonus (Yatırımcı Güveni dahil, üretimle aynı investorBonus())
        html: uiText('prestige.confirm', { g: fmt(g), b: pctText(investorBonus(g)) }),
        buttons: [
          { label: 'Vazgeç', cls: 'ghost' },
          { label: 'Anlaştık!', cls: 'primary', onClick: function () {
            if (blockedAction()) return;
            doPrestige(); lastStageShown = 0; upgSig = ''; save(); renderAll();
            track('reset_or_prestige');
            toast('🚀 Yatırım turu tamamlandı! Yeni bir başlangıç.'); sfx('stage');
          } }
        ]
      });
    });

    el.ipoBtn.addEventListener('click', function () {
      if (blockedAction()) return;     // v4.3.1: yazma kapalıyken Halka Arz yapılmaz
      var g = ipoGain();
      if (!ipoUnlocked() || g < 1) return;
      modal({
        emoji: '🔔', title: 'Halka arz et?',
        html: ipoConfirmHtml(),
        buttons: [
          { label: 'Vazgeç', cls: 'ghost' },
          { label: 'Halka arz et', cls: 'primary', onClick: function () {
            if (blockedAction()) return;
            if (!ipoUnlocked()) return;
            var stageBefore = S.cycleStage;
            var got = doIpo();
            if (!got) return;
            lastStageShown = 0; upgSig = ''; treeSig = ''; checkAchievements(); save(); renderAll();
            track('reset_or_prestige');
            track('ipo_complete', ipoEventData(stageBefore, got));   // v4.4: aşama ID'si, pay, kaçıncı Halka Arz
            sfx('stage'); vibrate([20, 60, 20]);
            modal({
              emoji: '🔔', title: 'Borsa zili çaldı!',
              html: uiText('ipo.done', { x: fmt(S.ipoShares) }),
              buttons: [
                { label: '📣 Paylaş', cls: 'ghost', onClick: function () { shareText('Kodhane\'de şirketimi halka arz ettim, borsa zili çaldı! ' + shareLink(CFG.utm.ipo)); } },
                { label: 'Tamam', cls: 'primary' }
              ]
            });
          } }
        ]
      });
    });
    el.suClose.addEventListener('click', hideStageUp);
    el.suShare.addEventListener('click', function () {
      var st = STAGES[el.stageUp.dataset.stage | 0];
      shareText('Kodhane\'de artık ' + st.name + ' aşamasındayım! Sen de ajansını kur: ' + shareLink(CFG.utm.stage));
    });
    el.stageUp.addEventListener('click', function (e) { if (e.target === el.stageUp) hideStageUp(); });

    window.addEventListener('beforeunload', save);
    window.addEventListener('pagehide', save);
    document.addEventListener('visibilitychange', function () { if (document.hidden) save(); });

    var last = Date.now(), slow = 0;
    setInterval(function () {
      var now = Date.now();
      var dt = Math.min((now - last) / 1000, offlineCapSec());
      last = now;
      tick(dt);
      updateOffer();
      updateEvent();
      if (++slow >= 10) { slow = 0; checkDaily(); }
      checkAchievements();
      drainQueue();
      maybeShowNews(now);
      renderAll();
    }, 100);
    setInterval(save, AUTOSAVE_MS);

    scheduleOffer(true);
    scheduleEvent(true);
    setView('kod');
    selectTab('upgrades', true);
    renderSettings();
    renderTelSetting();
    renderAll();
    showNoticeBand();                  // v4.3: ilk açılışta (yanıtlanana kadar her açılışta) izin bandı
    swUpdateText = el.updateText.textContent;
    renderUpdateBar();                 // v4.3.1: yüklenen kayıt daha yeni sürümdense "yenile" bandı
    window.addEventListener('resize', function () { if (!el.updateBar.classList.contains('hidden')) renderUpdateBar(); });
    tel.sync();                        // izin zaten açıksa betik şimdi yüklenir; değilse hiçbir istek yok
    showWelcomeBack(offlineRes);
    if (offlineRes && offlineRes.migrated) toast('📦 Kaydın yeni sürüme taşındı. Hoş geldin, Kodhane v2!', 4500);
    if (retro.length) toast('🏅 ' + retro.length + ' başarım açıldı! Her biri kalıcı +%1 üretim.', 4500);
    save();
    initUndo();
    initServiceWorker();
    track('game_start');
  }

  // Test ve hata ayıklama için
  root.Kodhane = Core;
  Core.save = save; Core.load = load; Core.renderAll = renderAll; Core.spawnOffer = spawnOffer; Core.claimOffer = claimOffer;
  Core.spawnEvent = spawnEvent; Core.chooseEvent = chooseEvent; Core.laterEvent = laterEvent; Core.setView = setView; Core.selectTab = selectTab;
  Core.eventState = evs; Core.getSettings = function () { return settings; };
  Core.SAVE_KEY = SAVE_KEY; Core.LEGACY_KEYS = LEGACY_KEYS; Core.SETTINGS_KEY = SETTINGS_KEY;
  Core.applySave = applySave; Core.toast = toast; Core.isResetting = function () { return resetting; };
  Core.activeTab = function () { return activeTab; };
  Core.showStageUp = showStageUp; Core.hideStageUp = hideStageUp; Core.shareLink = shareLink; Core.shareText = shareText;
  Core.maybeShowNews = maybeShowNews; Core.newsSession = news;
  Core.onResetCloudRender = onCloudRenderReset; Core.refreshRestoreBox = refreshRestoreBox; Core.openResetDialog = openResetDialog;
  Core.EPOCH_KEY = EPOCH_KEY; Core.UNDO_KEY = UNDO_KEY; Core.RESET_HOLD_MS = RESET_HOLD_MS; Core.LOG_CARRY_KEY = LOG_CARRY_KEY;
  Core.undoActive = function () { return !!undoState.marker; };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})(typeof window !== 'undefined' ? window : this);
