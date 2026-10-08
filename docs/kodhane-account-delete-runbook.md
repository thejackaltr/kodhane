# Kodhane: elle hesap silme runbook'u

Bir oyuncunun verisini siler. Kodhane Yöneticisi'nin kararları uygulanır. Her talep ayrı yürütülür.
**Her talep için Aryen'in yazılı onayı gerekir** (adım 3). Onay yoksa silme yapılmaz.
**Talep hesabın kayıtlı e-postasından gelmediyse silme yapılmaz** (adım 1). Bu kuralın istisnası yok.

Dosyalar:
- `supabase/ops/kodhane_account_delete_preflight.sql`: ön kontrol, salt okunur (`begin transaction read only … rollback`).
- `supabase/ops/kodhane_account_delete.sql`: silme, tek transaction. `-v mode=full | kodhane_only` zorunlu.
- `supabase/ops/kodhane_account_delete_verify.sql`: doğrulama, salt okunur. Aynı `mode` ile çalıştırılır; satır kalırsa hata verir (exit ≠ 0).
- Silme listesi (migration `20261003040000`, ayrı kurulum): `supabase/ops/kodhane_deletion_log_install.sh`, `kodhane_deletion_log_export.sh`, `kodhane_deletion_log_reapply.sh`. Aşağıdaki "Silme listesi" bölümü.
- Testler: `supabase/tests/account_delete/run_kodhane_account_delete_tests.sh`. Yerel docker; `KD_CT=<container>`. Oturum kapatma ve hesap alanlı `expect` sürümü .136'da (canlı imaj) koşuldu; önceki sürüm .136 ve .171'de koşulmuştu.

Parametreler psql değişkenidir: `uid` (auth kullanıcı id'si), `mode`, `confirm_uid`, `approval_ref`, `expect`.

> **Not: Açık Ofis ayrı veritabanına geçince** silme her oyun için ayrı yapılacak (her veritabanında kendi runbook'u).
> Bu iş Açık Ofis ayrılma planının **5. adımında**. O zamana kadar iki oyun aynı veritabanında ve aynı auth kullanıcısını paylaşıyor.
> Bu runbook bu yüzden iki mod içeriyor.

## İki mod ve hangi talepte hangisi
**Mod verilmezse ya da tanınmayan bir değer gelirse işlem hiçbir şey silmeden durur.**
Kullanıcının Açık Ofis verisi varsa hata mesajı `BLOCKED` der ve bu satırları listeler.

| Talep | Mod |
|---|---|
| "Hesabımı sil", "tüm verimi sil" (KVKK/GDPR), hesap kapatma. İki oyunu da kapsar. | `mode=full` |
| Yalnız Kodhane ilerlemesi ya da skoru silinsin; hesap ve Açık Ofis kalsın (ör. "Kodhane skorumu sıralamadan kaldırın", Kodhane hilesi temizliği). | `mode=kodhane_only` |
| Emin değilsen | Silme. Talep edene sor, Aryen'e iki seçeneği ön kontrol tablosuyla götür. |

### `mode=full`: her şey, iki oyun. Hepsi açık DELETE ile ve auth kullanıcısından önce yapılır.
1. `kodhane_saves` silinir. Tetikleyici bir `delete` kopyası yazar; dosya bunu kontrol eder.
2. Tüm `kodhane_save_backups` silinir, kopya dahil. Kopya kalsaydı satır yeniden oluşturulunca eski `best_score` geri gelirdi.
3. `kodhane_event_log_carry` (varsa), `kodhane_progress_log` (kazanç günlüğü, varsa) ve `kodhane_profiles` silinir.
4. Açık Ofis:
   - `acik_ofis_saves` silinir; tetikleyici `delete` kopyası yazar ve kontrol edilir.
   - Tüm `acik_ofis_save_backups` silinir, kopya dahil.
   - `acik_ofis_profiles` silinir (`acik_ofis_leaderboard` satırı).
   - `user_id` kolonu olan diğer `acik_ofis_*` tablolarındaki satırlar silinir.
5. `auth.audit_log_entries`: kullanıcının GoTrue denetim kayıtları silinir (eşleştirme aşağıda).
6. `auth.refresh_tokens`, `auth.flow_state` ve `auth.users` silinir. `identities`, `sessions`, `mfa_*`, `one_time_tokens`, `oauth_*` ve `webauthn_*` cascade ile gider.
7. Kontrol: sayılan her tabloda 0 satır olmalı (denetim kaydı dahil). Değilse her şey geri alınır.

Kodhane ve Açık Ofis dışında `auth.users`'a bağlı bir tabloda satır varsa `full` `BLOCKED` der ve durur, çünkü o satırlar cascade ile silinirdi.

### `mode=kodhane_only`: yalnız Kodhane verisi
1. `kodhane_saves` silinir (tetikleyici kopyası kontrol edilir).
2. Tüm `kodhane_save_backups` silinir, kopya dahil.
3. `kodhane_event_log_carry` (varsa) ve `kodhane_progress_log` (kazanç günlüğü, varsa) silinir.
4. **Kullanıcının tüm oturumları kapatılır:** `auth.refresh_tokens` (oturuma bağlı olanlar ve bağsız olanlar) ve `auth.sessions` satırları silinir. Yalnız bu uid'nin satırları gider; başka kullanıcıların oturumlarına dokunulmaz (testler K-O1, K-O2).

**Kalanlar:** auth kullanıcısı, `kodhane_profiles`, denetim kayıtları, Açık Ofis'in tüm verisi. Kontrol: `kodhane_saves`, `kodhane_save_backups`, `kodhane_progress_log`, `auth.sessions` ve `auth.refresh_tokens` 0, auth kullanıcısı duruyor. Oyuncu Açık Ofis'e de yeniden giriş yapmak zorunda kalır (aynı auth kullanıcısı).

**Kodhane sıralaması nasıl temizleniyor:**
- `kodhane_leaderboard` v6 ve B'deki `kodhane_leaderboard_v7`, `kodhane_profiles` ile `kodhane_saves` arasında **inner join** yapıyor. Kayıt satırı yoksa oyuncu listeye girmiyor; oturum açmış oyuncunun kendi "pending" satırı da çıkmıyor.
- Profil satırı kaldığı için Açık Ofis sıralamaları hiç değişmiyor. `kodhane_leaderboard(…,'acik_ofis')` takma adı `kodhane_profiles`'tan, `acik_ofis_leaderboard` ise `acik_ofis_profiles`'tan okuyor.
- Ek bir değişiklik gerekmedi. `kodhane_profiles.hidden` **kullanılmamalı**: o bayrak Açık Ofis sıralamasını da gizler.

**Dikkat: yerel kayıt.** Oyuncunun cihazındaki yerel Kodhane kaydı silinmez. İstemci bu kaydı yeniden buluta yazarsa o skor (makul bulunursa) sıralamaya yeni bir yazma olarak girer. Eski yedekler ve eski `best_score` geri gelmez. Oturumları kapatmak bu riski **azaltır ama tamamen kaldırmaz**:
- **Verilmiş access JWT süresi dolana kadar geçerli kalır.** PostgREST JWT'yi yalnız imza ve `exp` ile doğrular, `auth.sessions`'a bakmaz. Süre GoTrue `JWT_EXPIRY` kadardır (varsayılan 3600 sn; canlı değer bu runbook'ta doğrulanmadı). Bu pencerede istemci (`src/cloud/cloud.js`, `token()` süresi dolmadan yenilemez; `pushNow`/`flush` sekme gizlenince veya 30 sn sonra yazar) yerel kaydı yazabilir. Satır yok olduğu için insert başarılı olur.
- Süre dolunca refresh token geçersiz olduğundan yenileme 4xx döner, istemci oturumu siler ve misafire düşer. Buluta artık yazamaz.
- **Oyuncu aynı cihazda yeniden giriş yaparsa** `reconcile()` bulutta satır bulamaz ve yerel kaydı yükler (`cloud.js` ~189-212). Bu, oturum kapatmayla önlenemez.
- `full`: eski access token'la yazmalar FK hatasıyla reddedilir. Ama oyuncu aynı cihazda aynı e-postayla yeniden kaydolursa yeni uid'ye yerel kayıt yüklenir (eski yedekler ve sıralama geri gelmez).
- **Önlem:** Silmeden en az `JWT_EXPIRY` + birkaç dakika sonra (varsayılan için ~1 saat 5 dk) doğrulamayı aynı modla yeniden çalıştır. `kodhane_only`'de yeni bir `kodhane_saves` satırı ya da yeni oturum varsa doğrulama hata verir. Durumu Aryen'e bildir; yeniden silme yeni ön kontrol, yeni `expect` ve yeni onay ister. Gerekirse oyuncudan yerel kaydı sıfırlaması istenmeli.

### Denetim kaydı (`auth.audit_log_entries`) eşleştirmesi
- Tabloda kullanıcı kolonu yok. Canlı, .136 ve .171 şemalarının hepsinde kolonlar: `instance_id`, `id`, `payload json`, `created_at` (canlı ve .136'da ayrıca `ip_address`).
- Kullanıcı iki yerden eşleniyor:
  - `payload->>'actor_id'`: kullanıcının kendi işlemleri (login, token_refreshed, logout, recovery …).
  - `payload->'traits'->>'user_id'`: yönetici ya da servis rolünün o kullanıcı üzerindeki işlemleri (`user_signedup`, `user_deleted`, `user_invited` …). Canlıda bu 143 kayıtta actor başka biri, kullanıcı `traits` içinde. Yalnız `actor_id` ile eşleseydik bu kayıtlar kalırdı.
- `full` bu kayıtları siler, `kodhane_only` bırakır.

## Adımlar
1. **Talebi al.** Kim, hangi e-postayla ve ne istiyor (hesabın tamamı mı, yalnız Kodhane mi)? E-posta git'e, ticket başlığına ya da loglara yazılmaz.
   **Talep hesabın kayıtlı e-postasından gelmediyse silme yapılmaz.** Başka bir adresten, sosyal medyadan, telefondan ya da üçüncü kişiden gelen talep için oyuncudan talebi kayıtlı e-postasından yeniden göndermesi istenir. Ön kontroldeki maskeli e-posta talebin geldiği adresle uyuşmuyorsa da dur.
   uid için salt okunur sorgu: `begin transaction read only; select id from auth.users where email = '<e-posta>'; rollback;`
2. **Ön kontrol:**
   ```bash
   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -v uid=<uid> -f supabase/ops/kodhane_account_delete_preflight.sql
   ```
   Çıktıda:
   - Maskelenmiş e-posta.
   - Tablo tablo satırlar, gruplu: `kodhane` / `acik_ofis` / `auth` / `audit` / `other`. Her satırda iki modun ne yapacağı yazar (`act_full`, `act_kodhane_only`: delete, cascade, keep, block).
   - Oyun başına yedek nedenleri ve sıralama durumu.
   - `mode_full` ve `mode_kodhane_only` kararları ve `expect` token'ı.

   **`expect` iki oyunun satırlarını birlikte kapsar** (Kodhane + Açık Ofis + other) **ve auth kullanıcısının `id`, `email`, `created_at` alanlarını.** Böylece ön kontrolden sonra e-posta değişirse ya da hesap silinip aynı id ile yeniden oluşturulursa silme reddedilir; başka bir kullanıcının token'ı da kullanılamaz (testler E1, E2, C-E3). `last_sign_in_at`, oturum, refresh token ve denetim satırları token'a girmez, çünkü oyuncu oturumu açıkken her giriş ve token yenilemesinde değişirler; token bu yüzden kararlı kalır (testler F-E4, K-E4). Maskelenmiş e-posta talebin geldiği kayıtlı e-postayla uyuşmalı. İlgili mod `OK:` değilse dur.
3. **Aryen'in yazılı onayını al (zorunlu).**
   - Aryen'e gönder: uid, **seçilen mod ve gerekçesi**, ön kontrol tablosu (maskeli), `expect` token'ı.
   - Aryen bu uid ve bu mod için açıkça yazılı onay vermeli.
   - Onay referansı ver, ör. `KD-SIL-2026-09-29-01`; referansta kişisel veri olmasın.
   - Onay yoksa, belirsizse ya da başka bir uid veya mod içinse silme yapılmaz.
4. **Silme.** `-1` kullanma; `supabase_admin` ya da `postgres` rolüyle çalıştır.
   ```bash
   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -v mode=<full|kodhane_only> -v uid=<uid> -v confirm_uid=<uid> \
        -v approval_ref=KD-SIL-2026-09-29-01 -v expect=<token> -f supabase/ops/kodhane_account_delete.sql
   ```
   Hiçbir şey silmeden reddettiği durumlar:
   - Mod yok ya da tanınmıyor.
   - `confirm_uid` farklı.
   - `approval_ref` boş, 200 karakterden uzun ya da `@` `,` `"` `\` veya kontrol karakteri içeriyor. Referans silme listesine yazılır, bu yüzden e-posta adresi giremez.
   - Kullanıcı yok.
   - İki oyundan birinde satırlar ya da auth kullanıcısının `id` / `email` / `created_at` alanı ön kontrolden sonra değişmiş (`expect`).
   - (`full`) Kodhane ve Açık Ofis dışı bir tabloda satır var.

   Transaction ortasındaki her hata her şeyi geri alır. Başarılı olursa `kodhane account delete OK (mode …, approval …)` satırında her adımın sayısı yazar.
   Silme listesi kuruluysa aynı transaction'da listeye bir satır yazılır: uid, `scope` (`full` → `account`, `kodhane_only` → `kodhane`), silme zamanı ve `info:<approval_ref>`. Özetin sonunda `deletion log row written (scope …)` yazar. Liste kurulu değilse `deletion log not installed (no row)` yazar ve silme eskisi gibi çalışır.
5. **Doğrula:** Aynı modu ver.
   ```bash
   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -v mode=<full|kodhane_only> -v uid=<uid> -f supabase/ops/kodhane_account_delete_verify.sql
   ```
   - `full`: her satır 0, `verify OK (full)`.
   - `kodhane_only`: Kodhane kayıt ve yedekleri, oturumlar ve refresh token'lar 0; `kept:` satırında kalanlar listelenir.
   - Liste kuruluysa uid doğru scope ile listede olmalı (`deletion log: listed (scope …)`); yoksa doğrulama hata verir.
   - Silmeden sonraki ilk dışa aktarım (en geç 15 dakika) listeyi DB dışına alır. Zamanlayıcı kapalıysa dışa aktarımı elle çalıştır (aşağıda).
6. **Aryen'e bildir:** onay referansı, uid, mod ve adım sayıları. E-posta yazılmaz.
7. **JWT süresi dolunca yeniden doğrula** (yukarıdaki yerel kayıt notu). Sonucu Aryen'e bildir.

### Canlıda Portainer exec ile (`pexec.sh` `-v` alamaz)
Değişkenleri dosyanın başına `\set` ile ekle. Geçici dosya yalnız `/tmp`'de kalsın ve iş bitince silinsin:
```bash
{ printf "\\set mode '%s'\n\\set uid '%s'\n\\set confirm_uid '%s'\n\\set approval_ref '%s'\n\\set expect '%s'\n" "$MODE" "$UID_" "$UID_" "$REF" "$TOKEN"
  cat supabase/ops/kodhane_account_delete.sql; } > /tmp/kd_del_$$.sql
./pexec.sh /tmp/kd_del_$$.sql; rm -f /tmp/kd_del_$$.sql
```
Ön kontrol için `\set uid`, doğrulama için `\set mode` ve `\set uid` yeterli.

## Notlar
- Canlıda `kodhane_event_log_carry` yok (2026-09-29, salt okunur kontrol). Varsa silinir; `user_id` kolonu yoksa işlem durur.
- `public.kodhane_event_counts` yalnız gün, olay ve sayı tutuyor; kullanıcı verisi değil, dokunulmaz.
- `full` sonrası oturum JWT'si süresi dolana kadar geçerli kalır, ama `auth.users` satırı olmadığı için her yazma FK hatasıyla reddedilir.
- `kodhane_only` sonrası da JWT süresi dolana kadar geçerli kalır; `auth.users` satırı durduğu için bu pencerede yazmalar **başarılı olur**. Oturum kapatma yalnız yenilemeyi engeller.
- Aynı e-postayla yeni kayıt (yeni id) ya da aynı id ile yeniden oluşturma eski skoru, yedekleri ya da sıralamayı geri getirmez (testler F-S1–S6, K-S1–S4).
- Veritabanı yedekleri (GM'nin günlük DB yedekleri ~14 gün, Kodhane kayıt yedekleri 30 gün) eski veriyi kendi saklama süreleri boyunca tutar. Bu yedeklerden geri yükleme yapılırsa silinen hesapların geri gelmemesi için aşağıdaki "Silme listesi" bölümü uygulanır.
- Geri alma yok. Commit sonrası veri yalnız DB yedeğinden dönülebilir.
- **Kazanç günlüğü (`kodhane_progress_log`, migration 20261003020000):** ön kontrol tabloda gösterir, iki mod da siler, doğrulama
  0 bekler. Silme özeti sonuna `kodhane_progress_log N` ekler. Günlük `expect` token'ına **girmez**: oyuncu her kayıtta yeni
  satır üretir, token'a girseydi oynamaya devam eden oyuncuda ön kontrol hep yeniden istenirdi. Satırlar kayıttan türetilir,
  karar (uid + mod) değişmez. Tablo yoksa (migration öncesi) adım atlanır. `auth.users` silinince satırlar cascade ile de gider.
  Testler: `run_kodhane_account_delete_tests.sh` L-*.

## Silme listesi (geri yüklemeden sonra silinen hesaplar geri gelmesin)
Tasarım `plans/silme-listesi-kodhane-tasarim.md`. Referans uygulama Fenomen v2.2 (`feaec45`).
**Paket B'nin parçası değildir.** `install.sql` (`deefef0e…`) değişmedi. Kurulumu ayrı bir adımdır ve **Aryen'in ayrı onayını** ister; B onayı bunu kapsamaz.

**Tablo `kodhane_private.deletion_log`:** `user_id`, `scope`, `deleted_at`, `approval_ref`; PK `(user_id, scope)`.
- E-posta ve takma ad tutulmaz.
- Şemanın sahibi `postgres`'tir. anon, authenticated ve service_role'ün şemada USAGE hakkı yoktur, tabloda hiçbir yetkisi yoktur. RLS açık ve FORCE, policy yok.
- Tabloya yalnız `postgres` (sahip, BYPASSRLS) ve superuser'lar erişir.
- `scope` değerleri:
  - `account` (`mode=full`): Geri yüklemeden sonra hesap ve iki oyunun verisi yeniden silinir.
  - `kodhane` (`mode=kodhane_only`): Geri yüklemeden sonra yalnız Kodhane verisi yeniden silinir. Bu, yalnız silme zamanından **önceki** Kodhane satırları için yapılır.
    - Oyuncu silmeden sonra yeniden oynadıysa yeni kaydı korunur (`newer`).
    - Hem önceki hem sonraki satırlar varsa (`mixed`) hiçbir şey silinmez, liste raporlanır ve kararı Aryen verir.
    - Kodhane'de "önce/sonra" kararı şu zamanlara bakar: kayıt için `updated_at`, yedek için `created_at`, kazanç günlüğü için `created_at`.
    - Kaydın `updated_at` değeri istemciden gelir. Oyuncunun saati ileri ayarlıysa eski bir kayıt "yeni" sayılabilir; bu durumda o kayıt silinmez ve raporlanır.
- Uygulama içi silme RPC'si yoktur. Listeye yalnız bu runbook'taki silme betiği yazar. Açık Ofis'in kendi silme yolu yoktur.

**Kurulum (ayrı onayla):**
```bash
export KODHANE_TARGET=live KODHANE_OUT=/home/box/agent-data/kodhane-deletion-log-install-$(date +%Y%m%d-%H%M)
bash supabase/ops/kodhane_deletion_log_install.sh build
bash supabase/ops/kodhane_deletion_log_install.sh preflight     # salt okunur
bash supabase/ops/kodhane_deletion_log_install.sh dryrun        # ROLLBACK ile biter
KODHANE_LIVE_APPROVAL="<Aryen, tarih>" bash supabase/ops/kodhane_deletion_log_install.sh install
bash supabase/ops/kodhane_deletion_log_install.sh verify        # 12 kontrol; DLVERIFY|PASS
```
- Bağımlılıklar:
  - Yalnız Kodhane v2.2 gerekir. A, B, kazanç günlüğü ya da saklama paketi gerekmez.
  - Silme betiği listeyi kendisi bulur (`to_regclass`). Bu yüzden kurulumla betik arasında sıra yoktur.
- Rollback:
  - Komut: `bash supabase/ops/kodhane_deletion_log_install.sh rollback` (canlıda onay gerekir).
  - Liste doluyken reddeder. Önce dışa aktar, sonra `KODHANE_ALLOW_DELETION_LOG_LOSS=on` ver.
  - Saklama komutunda liste adımı varsa önce o adımsız komuta dön.

**Dışa aktarım (salt okunur, box):**
```bash
KODHANE_TARGET=live bash supabase/ops/kodhane_deletion_log_export.sh
```
- Dosya yeri: `/home/box/agent-data/backups/kodhane-deletion-log/kodhane-deletion-log-<UTC>.csv`, yanında `.csv.md5`. Dizin 700, dosyalar 600.
- Biçim:
  - Başlık `user_id,scope,deleted_at_utc,approval_ref`.
  - Var olan dosyanın üzerine yazılmaz (çıkış 4).
  - İçerik değişmediyse yeni dosya yazılmaz.
  - 45 günden eski dosyalar budanır; en yeni dosya hep kalır.
- Hedef kontrolü: Fenomen DB'si ya da listesi kurulmamış DB görürse durur.
- **Zamanlama: 15 dakikada bir.** Box'ta zamanlayıcı kurmak ayrı onaydır, şu an kurulu değildir. Kurulana kadar her silmeden sonra ve her geri yüklemeden önce elle çalıştırılır.
- **Dokploy host seçeneği (değerlendirme, uygulanmadı):**
  - Artısı: dosya DB'ye en yakın yerde durur, box'a bağlı kalmaz. Fenomen'de asıl kopya buradadır.
  - Eksileri:
    - Dokploy zamanlı komutu tek satırdır ve `'`, `$` içeremez. Bu betik orada satır içi çalışmaz; betik dosyasının host'a konması gerekir. Bu bir dağıtım adımıdır ve ayrı onay ister.
    - Host kaybolursa liste DB ile birlikte gider.
  - Öneri: box kopyası ilk adım olsun. Host kopyası ikinci kopya olarak ayrı onayla eklenir. Reapply iki yerdeki dosyaları birlikte kabul eder: dosyalar argüman olarak verilebilir.

**Geri yüklemeden sonra (B kurulum runbook'u "Yol 2" bunu kendisi çalıştırır):**
1. Geri yüklemeden önce API'yi (GoTrue, PostgREST) durdur. Böylece yeni silme ve yazma olmaz.
2. Mevcut DB'den son listeyi al: `kodhane_deletion_log_export.sh`. `kodhane_v44b_install.sh restore` bunu kendisi yapar. Dışa aktarım başarısız olursa geri yükleme durur. DB okunamıyorsa `KODHANE_RESTORE_WITHOUT_DELETION_LOG_EXPORT=on` ile var olan dosyalarla devam edilir.
3. Geri yükle.
4. Listeyi yeniden uygula:
   - Komut: `KODHANE_OUT=<dizin> KODHANE_LIVE_APPROVAL="<Aryen, tarih>" bash supabase/ops/kodhane_deletion_log_reapply.sh reapply`.
   - Önce prova istenirse `dryrun` kullanılır; ROLLBACK ile biter.
   - Dosya kontrolü: her dosyanın adı, `.md5`'i, başlığı ve satır biçimi kontrol edilir. **Tek bir bozuk dosya bütün çalıştırmayı durdurur.**
   - Tek transaction'dır. Önce liste satırları yazılır, sonra her uid için bu runbook'taki silme betiğinin DO bloğu birebir çalışır (token yok, ama uid ve scope listede olmalı), en sonda "kalan yok" kontrolü yapılır.
   - Kodhane ve Açık Ofis dışında bir satır (block) çıkarsa her şey geri alınır.
   - İkinci çalıştırma hiçbir şey değiştirmez.
   - Canlıda SQL pexec ile bir ortam değişkeninde gider: üretilen dosya 120000 bayttan küçük olmalı (gövde ~38 KB, satır başına ~95 bayt, yani ~800 liste satırı). Aşılırsa araç STOP der; dosyalar bölünerek ayrı ayrı uygulanır.
5. `... reapply.sh verify`: `VERIFY|PASS|0 left` beklenir.
6. **Yedek zamanından sonraki silme talepleri (destek e-postası ve uygulama logu) kontrol edilip elle yeniden silinir.** Liste yalnız
   betikle yapılmış ve listeye yazılmış silmeleri kapsar; listeden önceki, son dışa aktarımdan sonraki ya da bekleyen talepler burada
   yakalanır. Her biri bu runbook'un adımlarıyla (onay, preflight, silme, verify) yeniden silinir.
7. API'yi aç.
- Geri yüklenen yedek liste migration'ından eskiyse reapply durur. Önce `kodhane_deletion_log_install.sh` ile listeyi kur, sonra reapply'ı yeniden çalıştır.
- Çıkış 3: `mixed` kayıt kaldı. Satırlar silinmedi; kararı Aryen verir. Gerekirse o uid için bu runbook'taki `kodhane_only` adımları elle uygulanır.

**Saklama:**
- Süre 45 gündür: en uzun yedek saklaması (Kodhane kayıt yedekleri 30 gün; GM DB yedekleri ~14 gün) + 15 gün pay. Değer `kodhane_private.cfg_deletion_log_retention()` içindedir.
- Temizliği `kodhane_private.cleanup_deletion_log()` yapar; yalnız `postgres` çalıştırabilir.
- Mevcut saklama görevine **bir `-c` adımı** olarak eklenir; ayrıntı `kodhane-retention-runbook.md`, "Silme listesi adımı".
- **Bağımlılık:** bu adım yalnız saklama görevi kuruluysa (saklama paketi) ve liste migration'ı kurulduktan sonra eklenir. B paketine bağlı değildir.

**Kalan risk penceresi:**
1. API durdurulduysa ve mevcut DB okunabiliyorsa pencere **0**'dır (adım 2).
2. Mevcut DB okunamıyorsa son başarılı dışa aktarımdan sonraki silmeler kaybolur. Zamanlayıcı açıksa bu en fazla ~15 dakikadır, kapalıysa son elle dışa aktarımdan bu yana geçen süredir.
   - O penceredeki silmeler Aryen'in onay kayıtlarından uid ile bu runbook'la yeniden yapılır (uid'ler onay mesajlarında durur).
3. **DB tamamen kaybolursa** (volume ya da host gider, yalnız yedek kalır):
   - Liste yalnız box dosyalarından gelir.
   - Yedek liste migration'ından eskiyse önce migration kurulur, sonra reapply çalışır.
   - Son box dışa aktarımından sonraki silmeler 2. maddedeki gibi elle yeniden yapılır.
   - Box da kaybolduysa bütün liste kaybolur. Bu durumda yedekten sonraki tüm silmeler (≤ yedek yaşı, ~24 saat; eski bir yedekse daha fazlası) Aryen'in onay kayıtlarından yeniden yapılır.
4. 45 günden eski bir yedeğin geri yüklenmesi beklenmez (yedekler 14 ve 30 gün tutuluyor). Böyle bir yedek geri yüklenirse listede o yedekten bu yana yapılan silmelerin bir kısmı artık bulunmaz (budanmıştır); Aryen'e sorulur.
5. `kodhane` scope'unda istemci saatine bağlı `newer` / `mixed` kararı (yukarıda): bu durumlarda silme yapılmaz, raporlanır.

Testler: `supabase/tests/deletion_log/run_kodhane_deletion_log_tests.sh` (.136). Sonuçlar `supabase/tests/v4_4/results/kodhane_deletion_log_pg17.6.1.136.txt`.
