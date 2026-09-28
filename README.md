# Kodhane: Ajans Tycoon

Kodhane: Ajans Tycoon, evde tek bir laptopla başlayıp kıtalar arası bir teknoloji holdingine uzanan, Türkçe bir yazılım ajansı idle (tıklama) oyunudur. "Kod yaz" düğmesine tıklayarak para kazan; stajyerden yapay zekâ kod ajanlarına kadar ekibini büyüt, geliştirmeler satın al, müşteri projelerini yakala ve Yatırım Turu ile kalıcı bonuslar kazan. Ekibin sen yokken de çalışır (en fazla 8 saat; Borsa Payı Ağacı ile 24 saate kadar) ve ilerlemen tarayıcında otomatik kaydedilir. Saf HTML, CSS ve JavaScript ile yazıldı; derleme adımı yok.

**Oyna:** https://thejackaltr.github.io/kodhane/

## Özellikler

- **Oyun hissi:** Yumuşak akan para sayaçları, harcamada kısa kırmızı parlama, "Kod yaz" düğmesinde parçacık patlaması ve %5 ihtimalle 10 kat kazandıran altın **kritik tık**. Hareket azaltma tercihine (prefers-reduced-motion) saygı gösterir.
- **Ajans olay kartları:** Birkaç dakikada bir iki seçenekli olaylar çıkar: "Logoyu biraz daha büyütebilir miyiz?", "Cuma akşamı deploy", "Yeğenim de biraz web'den anlıyor." ve daha fazlası. Her seçim bir ödünleşimdir: nakit, süreli verim artışı/düşüşü ya da **İtibar**. İtibar, müşteri projelerinin ödemesini artırır. Kart "Sonra" ile ertelenebilir ya da kendiliğinden kapanır.
- **Aşamalar:** Freelancer'dan Global Holding'e, ardından **Teknoloji Devi**, **Yapay Zekâ Laboratuvarı** ve **Mars Ofisi**. Her yeni aşama bir çalışan türü (Ar-Ge Kampüsü, Yapay Zekâ Araştırmacısı, Mars Ekibi) ve beşer geliştirme açar; ekranın tema rengi aşamayla değişir. Bir aşamaya ilk kez ulaşınca kısa, tam ekran bir tebrik penceresi çıkar (paylaş düğmesiyle); sonraki turlarda yalnızca bildirim.
- **Halka Arz (ikinci prestij):** Aynı döngüde 3 Yatırım Turu'ndan sonra Yatırım sekmesinin ikinci bölümü açılır. Halka arz kasa, çalışan, geliştirme ve Yatırımcı Hisselerini sıfırlar, karşılığında kalıcı **Borsa Payı** verir. v4.1: pay, o döngüde ulaşılan en yüksek aşamaya göredir (Global Holding 2, Teknoloji Devi 5, Yapay Zekâ Laboratuvarı 8, Mars Ofisi 12; ilk halka arzda en az 1, sonrakilerde en az Teknoloji Devi gerekir). Harcanmamış her Borsa Payı kalıcı +%1 üretim verir (en fazla +%50). Borsa Payları **Borsa Payı Ağacı**'nda harcanır: Kod, Ekip, Müşteri ve Yatırım dallarında sırayla açılan 3'er kalıcı bonus (1/3/6 pay). Sıralamadaki toplam kazanç halka arzda da korunur. Tüm sayılar `game.js` başındaki `CFG` ayarlarındadır; açıklama metinleri bu ayarlardan üretilir.
- **Müşteri sektörleri (v4.1):** Olay kartlarının yarısı sektör kartıdır: Mahalle Esnafı (baştan açık), E-ticaret (Butik Stüdyo), Oyun şirketi (Ajans), Kamu ihalesi (Dev Ajans). Kabul etmek ödeme, verim düşüşü, gecikmeli ödeme veya takip işleri getirir; reddetmek o sektörden teklifleri 10 dakika azaltır (itibar etkilenmez). Kartta yalnızca sektör simgesi ve adı görünür; 60 saniyeden uzun süreler ve sayaçlar dk:sn (ör. 9:00) biçimindedir (v4.1.1). Sayılar `CFG.sectors` içinde.
- **Oyun içi haberler:** Yeni özellikler oyuncu başına bir kez, oturum başına en fazla bir haber olarak sırayla duyurulur (görüldü bilgisi kayıtta tutulur, bulut kaydıyla cihazlar arasında birleşir). "Sıralamaya bak" tıklamaları, kişisel veri içermeyen günlük toplam sayaçla (`kodhane_count_event`) sayılır.
- **Büyük sayılar:** Bin, Mn, Mr, Tn, Kat (katrilyon) ve Kent (kentilyon) kısaltmaları; ötesi bilimsel gösterim (ör. 1,23e21).
- **34 başarım:** Her biri kalıcı +%1 üretim sağlar ve Yatırım Turu'nda sıfırlanmaz ("Localhost'ta Çalışıyordu", "Son Revize 7. Kez", "Logo Artık Ekrana Sığmıyor"...).
- **Yeni geliştirmeler:** Çay Ocağı Sözleşmesi, Push ve Dua, Cuma Deploy Yasağı, Müşteri Tercümanı, Kahve Falı Yol Haritası (sıradaki olayı önceden gösterir), Oturarak Stand-up, Sprint Planlaması ve 100 çalışan kilometre taşı (x2).
- **Günlük görevler ve seri:** Her gün tarihe göre belirlenen 3 görev, ilerlemeye göre ölçeklenen hedefler ve ödüller. Üçünü de bitirince seri artar ve ödül büyür; bir gün kaçarsa seri sıfırlanır.
- **Mobil uyum:** Dar ekranlarda alt sekme çubuğu (Kod, Ekip, Geliştir, Görevler, Yatırım, Sıralama), büyük dokunma alanları ve alınabilir öğelerde hafif parlama.
- **Ses ve titreşim:** Web Audio ile üretilen sesler (varsayılan olarak kapalı) ve mobilde titreşim. İkisi de İstatistik sekmesinden açılıp kapatılır.
- **Uygulama olarak yükle (PWA):** Ana ekrana eklenebilir, çevrimdışı çalışır. Yeni sürüm yayınlandığında "Yeni sürüm hazır" bildirimi çıkar.
- **Kayıt uyumluluğu:** Eski kayıtlar yeni biçime otomatik ve kayıpsız taşınır.
- **Bulut kaydı (isteğe bağlı):** Sağ üstteki **Hesap** düğmesinden e-posta adresine gelen tek kullanımlık giriş bağlantısıyla (şifresiz) giriş yap; ilerlemen Supabase üzerinde saklanır ve başka cihazlarda kaldığın yerden devam edersin. Girişliyken oyun hem cihaza hem de (değişiklik varsa yaklaşık 45 saniyede bir ve sekme kapanırken) buluta kaydedilir. İlk girişte cihazdaki kayıt buluta yüklenir; iki kayıt çakışırsa ömür boyu kazancı büyük olan (eşitse daha yeni olan) kazanır, diğeri `kodhane_ajans_save_backup` anahtarına yedeklenir. Giriş yapmadan misafir olarak ve çevrimdışıyken oynamaya her zaman devam edebilirsin; bulut kitaplığı yalnızca gerektiğinde yüklenir.

- **Sıralama:** En çok kazanan 50 ajans. Puan, oyuna başladığından beri kazandığın toplam paradır ve Yatırım Turu'nda sıfırlanmaz. Liste herkese açıktır; katılmak için giriş yapıp bir takma ad seçersin (3-16 karakter; Türkçe dahil harf, rakam, boşluk, `-` ve `_`). E-posta adresin hiçbir yerde görünmez. Kendi sıran listede vurgulanır, ilk 50'nin dışındaysan en altta ayrıca görünür. Puan bulut kaydından okunur (`kodhane_leaderboard(p_limit, p_game)` fonksiyonu); sunucu makul görünmeyen puanları ve yöneticinin gizlediği adları listeye almaz. Liste ~60 sn önbellekte tutulur. `tests/honest_sim.js` dürüst oyuncu simülasyonlarını üretir (makullük kontrolü testleri).
- **Klavye:** Masaüstünde Space tuşu da kod yazar (her basış bir tık; basılı tutmak sayılmaz).

## Yerelde çalıştırma

Depoyu indir ya da klonla, ardından `index.html` dosyasını tarayıcında aç. Kurulum veya sunucu gerekmez. Çevrimdışı mod (service worker) ve uygulama yükleme için bir yerel sunucu gerekir, örneğin `python3 -m http.server`; PNG simgeler `python3 tools/make_icons.py` ile üretilir.

Testler: `node tests/test_v4.js` (çekirdek: aşamalar, Halka Arz, ağaç, kayıt taşıma, haber kuyruğu), `node tests/test_v41.js` (v4.1: aşamaya göre pay, harcanmamış pay bonusu, sektörler, v4 → v4.1 kayıt taşıma), `python3 tests/test_idle.py`, `python3 tests/test_cloud.py` ve `python3 tests/test_v4_ui.py` (Playwright gerekir; bulut testleri Supabase'i taklit eder, gerçek projeye bağlanmaz). Denge: `node tests/balance_sim.js` ve `node tests/balance_v4.js <sinir|tutkulu|gunluk> <none|smart|asap>` (yeni aşamalara ve halka arzlara ulaşma süreleri).

Bulut kaydı ayarları `cloud.js` başındadır (proje adresi ve herkese açık publishable anahtar; veri erişimi veritabanındaki RLS kurallarıyla korunur).

## Ekran görüntüsü

![Kodhane: Ajans Tycoon oyun ortası ekran görüntüsü](screenshots/midgame-1280x800.png)
