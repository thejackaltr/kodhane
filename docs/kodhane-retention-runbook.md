# Kodhane: saklama süreleri runbook'u (todo 26)

Üç saklama kuralı, tek günlük iş:
- **(a) Denetim kaydı 12 ay:** `auth.audit_log_entries` içinde `created_at < now() - interval '12 months'` olan satırlar partiler halinde silinir.
- **(b) Kayıt yedekleri 30 gün:** `kodhane_save_backups` ve `acik_ofis_save_backups`, silme kopyaları (`reason = 'delete'`) dahil, `backup_retention_days` (30) günden eski olanlar silinir.
- **(c) Kazanç günlüğü 12 ay (365 gün, Aryen 2026-10-03):** `public.kodhane_progress_log` içinde `created_at < now() - 365 gün` olan satırlar
  partiler halinde silinir (`public.kodhane_cleanup_progress_log(365, 5000)`, migration `20261003020000`, `docs/kodhane-progress-log-runbook.md`).
  **Yalnız o migration canlıdayken.** Saklama paketi kazanç günlüğünden önce kurulur; bu yüzden (c) ayrı komut dosyasında ve
  sonradan eklenen bir adım (aşağıda "Kazanç günlüğü adımı"). (a) + (b) görevi tek başına kurulabilir.

- **(d) Silme listesi 45 gün:** `kodhane_private.deletion_log` içinde `deleted_at < now() - 45 gün` olan satırlar silinir
  (`kodhane_private.cleanup_deletion_log()`, migration `20261003040000`, `docs/kodhane-account-delete-runbook.md` "Silme listesi").
  **Yalnız o migration canlıdayken**, sonradan eklenen tek bir `-c` adımı (aşağıda "Silme listesi adımı").

**Canlı kurulum ayrı onaya bağlıdır.** Aryen'in bu iş için yazılı onayı olmadan migration uygulanmaz, Dokploy işi kurulmaz.

> **Ortak veritabanı:** Kodhane ve Açık Ofis aynı Supabase'i ve aynı GoTrue auth'u paylaşıyor. GoTrue'nun denetim tablosu tek;
> bu yüzden 12 ay kuralı **Açık Ofis kullanıcılarının denetim kayıtlarını da kapsar** (aynı auth'taki herkes). Yedek kuralı da iki oyunun
> yedek tablosunu birlikte temizler. Açık Ofis ayrı veritabanına geçince her veritabanı kendi işini çalıştırır (ayrılma planı 5. adım).
> Fenomen'in kendi Supabase'i bu işten etkilenmez.

## Dosyalar
- `supabase/migrations/20261001210000_v4_4_kodhane_audit_log_retention.sql`: `public.kodhane_cleanup_audit_log(p_batch_size integer default 5000) returns integer`.
  - En fazla `p_batch_size` satır siler, en eskiler önce, ve silinen sayıyı döndürür.
  - `p_batch_size` 1–50000 olmalı; null, 0, negatif ya da 50000'den büyükse hata verir (22023) ve hiçbir şey silmez.
  - `created_at` boş olan satırları silmez (canlıda 0 satır).
  - `security definer`, sahibi `postgres`, `search_path = ''`.
  - EXECUTE yalnız `postgres` (sahip) ve `service_role`'de. PUBLIC, `anon` ve `authenticated`'dan geri alındı.
  - **Durdurma koşulları:** `postgres`'in `auth.audit_log_entries` üzerinde DELETE ya da SELECT yetkisi yoksa migration hata verir ve hiçbir şey oluşturmaz. Yanlış veritabanında da durur.
- `supabase/rollback/20261001210000_v4_4_kodhane_audit_log_retention.rollback.sql`: fonksiyonu kaldırır. Silinmiş satırlar geri gelmez.
- **Yedekler için yeni fonksiyon yok.** v2.2'deki `public.kodhane_cleanup_save_backups()` ve `public.acik_ofis_cleanup_save_backups()` olduğu gibi kullanılıyor.
  - İkisi de canlıda kurulu. Sahibi `postgres`, `security definer`, `search_path = ''`, EXECUTE yalnız `postgres` ve `service_role`. 2026-10-01'de salt okunur kontrol edildi.
  - Silinen sayıyı döndürürler ama **parti parametresi yok**: tek DELETE ile siler. Yeniden yazılmadı. Canlıda 2 yedek var; hacim büyürse partili sürüm ayrı iş olarak ele alınır.
- `supabase/ops/kodhane_retention_dokploy_command.txt`: **Dokploy görevinin komut alanına yazılan tek satır** (aşağıda birebir). Secret yok.
  Yalnız (a) + (b); kazanç günlüğü tablosu/fonksiyonu olmayan veritabanında da çıkış 0 (test JS1).
  - Tek tırnak, `$`, backtick ve ters bölü içermez. Bu yüzden Dokploy'un `sh -c '<komut>'` sarmalamasında tırnaklama güvenli (test D0b).
  - `-X` (psqlrc yok), `-P pager=off` (sayfalayıcı yok), `-v ON_ERROR_STOP=1`. `docker exec` `-u` olmadan, container'ın varsayılan
    kullanıcısı root ile çalışır; `supabase_map` ile `postgres` rolüne bağlanır (DevOps 2026-10-03'te canlı `db` container'ında teyit etti).
- `supabase/ops/kodhane_retention_dokploy_command_with_progress_log.txt`: aynı komut + sonda kazanç günlüğü adımı (iki `-c`). **Yalnız
  kazanç günlüğü migration'ı canlıya girdikten sonra** Dokploy'daki komutla değiştirilir (test D0e: ilk komutla birebir başlar).
- `supabase/ops/kodhane_retention_dokploy_command_with_deletion_log.txt` ve `..._with_progress_log_and_deletion_log.txt`: ilk iki
  komutun birebir aynısı + sonda silme listesi adımı (tek `-c`). Yalnız silme listesi migration'ı canlıdayken (aşağıda).
- `supabase/ops/kodhane_retention_daily.sh`: **yalnız yerel test ve elle kullanım aracı.** Dokploy bunu çalıştırmaz, çünkü dosya container'da yok. Aynı adımları aynı sırayla uygular;
  kazanç günlüğü adımı ve ondan sonra silme listesi adımı (5) en sonda; fonksiyon yoksa "skipped" yazıp atlanır (testler S8, deletion_log T6/T6b).
- Eski host betiği `kodhane_retention_dokploy_task.sh` kaldırıldı. Dokploy v0.30.8'de host tipi görev yok.
- Testler: `supabase/tests/retention/run_kodhane_retention_tests.sh` (`KR_CT=<container>`). Yalnız yerel container'da çalıştırılır.

## Kurulum listesi (sırayla; canlıya yazan adımlar Aryen'in ayrı onayıyla)
Saklama paketi kazanç günlüğünden **önce** ve ondan bağımsız kurulur. Ayrıntılar aşağıdaki bölümlerde.
- [ ] **(a) Migration, `supabase_admin` olarak (`pexec.sh`):** `penv_md5.py` ile
  `supabase/migrations/20261001210000_v4_4_kodhane_audit_log_retention.sql` md5'i MATCH, sonra `pexec.sh <dosya>` (`-1` yok).
  Önce ve sonra "Kurulum" 1. ve 3. adımdaki salt okunur kontroller (beklenen: `postgres | t | {search_path=""} | {postgres=X/postgres,service_role=X/postgres}`).
- [ ] **(b) Kuru çalışma ve sayım:** önce salt okunur sayım, sonra geri alınan bir transaction'da üç fonksiyon:
  ```sql
  begin transaction read only;
  select (select count(*) from auth.audit_log_entries where created_at < now() - interval '12 months') as audit_silinecek,
         (select count(*) from public.kodhane_save_backups where created_at <= now() - public.kodhane_save_backup_retention()) as kodhane_bk_silinecek,
         (select count(*) from public.acik_ofis_save_backups where created_at <= now() - public.acik_ofis_save_backup_retention()) as ao_bk_silinecek,
         (select min(created_at) + public.kodhane_save_backup_retention() from public.kodhane_save_backups) as kodhane_bk_ilk_silme;
  rollback;
  begin;
  select public.kodhane_cleanup_audit_log(5000) as audit, public.kodhane_cleanup_save_backups() as kodhane_bk,
         public.acik_ofis_cleanup_save_backups() as ao_bk;
  rollback;
  ```
  Beklenen: audit silinecek **0**, yedekler 0; Kodhane yedeğinde ilk silme **2026-10-30** (en eski yedek 2026-09-29 20:23 TSİ + 30 gün,
  ilk gece işi 2026-10-30 03:47). Kuru çalışma `0 | 0 | 0` döner ve `rollback` ile hiçbir şey silinmez (test A10).
- [ ] **(c) Dokploy zamanlanmış görevi:** tip compose, proje **Kodhane**, uygulama `<KODHANE_DB_COMPOSE>`, servis `db`,
  cron **`47 3 * * *`**, timezone **`Europe/Istanbul`**, komut `supabase/ops/kodhane_retention_dokploy_command.txt` **aynen** (aşağıda birebir).
  Kullanıcı alanı boş (`-u` yok, root).
- [ ] **(d) İlk çalışmadan sonra doğrulama:** görevi elle bir kez tetikle (aşağıda "İlk çalıştırma"). Dokploy logunda çıkış 0, `ERROR:` /
  `FATAL:` yok; beş sayı (`kodhane_save_backups`, `acik_ofis_save_backups`, `audit_log_entries`, `audit_batches`, `audit_left_over_12m`) bugün 0.
  Sonra "Doğrulama" sorgusu (audit ve yedek sayımı, hepsi 0). Ertesi gün otomatik koşu 03:47 TSİ'de görünmeli.
- [ ] **(e) Geri alma:** Dokploy'da görevi devre dışı bırak (ya da sil), sonra
  `supabase/rollback/20261001210000_v4_4_kodhane_audit_log_retention.rollback.sql` (`pexec.sh`, supabase_admin). Silinen satırlar dönmez.
- [ ] **Sonra (kazanç günlüğü canlıya girince, ayrı onay):** komutu `..._with_progress_log.txt` ile değiştir (aşağıda "Kazanç günlüğü adımı").

## Kurulum (ayrı onaydan sonra)
1. **Ön kontrol (salt okunur).** `begin transaction read only; … rollback;` ile:
   - `has_table_privilege('postgres', 'auth.audit_log_entries', 'DELETE')` ve aynısı `SELECT` için: ikisi de `t` olmalı (2026-10-01'de `t`/`t`).
   - `to_regprocedure('public.kodhane_cleanup_audit_log(integer)')`: kurulumdan önce boş olmalı.
2. **Migration** (`-1` kullanma; dosyanın kendi transaction'ı var). **`supabase_admin` ile çalıştır** (canlıdaki `pexec.sh` gibi).
   - Dosyada `set role postgres` yok, çünkü `postgres` public şemasında CREATE yetkisine sahip olmayabilir.
   - Fonksiyon oluşturulduktan sonra sahibi `postgres` yapılır (testler bu yolla, supabase_admin ile koşuldu).
   - Görevin kendisi ise `postgres` rolüyle çalışır (test Q).
   ```bash
   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/migrations/20261001210000_v4_4_kodhane_audit_log_retention.sql
   ```
   Portainer exec ile: önce `penv_md5.py` ile dosyanın md5'i eşleşmeli (MATCH), sonra `pexec.sh <dosya>`. Parametre yok.
3. **Kurulum doğrulaması (salt okunur):**
   ```sql
   select pg_get_userbyid(p.proowner), p.prosecdef, p.proconfig, p.proacl from pg_proc p
    where p.oid = 'public.kodhane_cleanup_audit_log(integer)'::regprocedure;
   ```
   Beklenen: `postgres | t | {search_path=""} | {postgres=X/postgres,service_role=X/postgres}`.
4. **Dokploy zamanlanmış görevi** (Dokploy v0.30.8; Umami'deki `umami-retention-13m` gibi). Alanlar:

   | Alan | Değer |
   |---|---|
   | Tip | **compose** |
   | Proje / uygulama | Kodhane projesi, compose `<KODHANE_DB_COMPOSE>` (değer yerel `sb_env.sh`'ta) |
   | Servis | `db` |
   | Ad | `kodhane-retention` (öneri) |
   | Cron | `47 3 * * *` (GM'nin 03:20 günlük yedeğiyle çakışmaz) |
   | Timezone | `Europe/Istanbul` |
   | Komut | aşağıdaki tek satır, birebir |

   ```sh
psql -X -P pager=off -U postgres -d postgres -v ON_ERROR_STOP=1 -x -c "select public.kodhane_cleanup_save_backups() as kodhane_save_backups, public.acik_ofis_cleanup_save_backups() as acik_ofis_save_backups" -c "select coalesce(sum(b.n), 0) as audit_log_entries, count(*) filter (where b.n > 0) as audit_batches from (select public.kodhane_cleanup_audit_log(5000) as n from generate_series(1, 20)) b" -c "select count(*) as audit_left_over_12m from auth.audit_log_entries a where a.created_at < now() - make_interval(months => 12)"
   ```
   - **Timezone boş bırakılırsa UTC kullanılır** ve iş 06:47 TSİ'de çalışır. Alanın `Europe/Istanbul` olduğunu kaydettikten sonra tekrar kontrol et.
   - Dokploy komutu `docker exec <db container> sh -c '<komut>'` olarak, container'ın varsayılan kullanıcısı ve env'iyle çalıştırır.
   - **Ne yapar:**
     1. Kodhane yedek temizliği ile Açık Ofis yedek temizliğini tek transaction'da çalıştırır.
     2. Denetim kaydı temizliğini 20 kez × 5000 satırlık partiyle çağırır; işi bitmiş partiler 0 döner. Tek ifade içinde olduğu için tek transaction.
     3. 12 aydan eski kalan satır sayısını basar.
   - **Üst sınır:** bir çalıştırmada en fazla 100000 denetim satırı silinir; fazlası ertesi gece gider (test J3). Canlıda günde birkaç yüz satır oluşuyor.
   - Sayılar stdout'a `-x` (genişletilmiş) biçimde yazılır: `kodhane_save_backups`, `acik_ofis_save_backups`, `audit_log_entries`, `audit_batches`, `audit_left_over_12m`
     (kazanç günlüğü adımıyla ayrıca `progress_log_rows`, `progress_log_batches`, `progress_log_left_over_365d`).
   - `-v ON_ERROR_STOP=1` ile ilk hatada psql durur ve **çıkış kodu 1** olur (.136'da denendi). Sonraki `-c` adımları çalışmaz.
   - **Varsayım: şifresiz bağlantı.** Komut container içinde `psql -U postgres` ile local socket üzerinden bağlanır, şifre kullanmaz.
     - Bu, canlı imajın (`supabase/postgres:17.6.1.136`) varsayılan yapılandırmasına dayanır. .136 test container'ında kontrol edildi (testler D1–D3):
       - Varsayılan kullanıcı `root` (`Config.User` boş).
       - Geçerli hba dosyası `/etc/postgresql/pg_hba.conf`. `$PGDATA/pg_hba.conf`'taki `trust` satırları **kullanılmıyor**.
       - Local socket kuralları sırayla: `local all supabase_admin trust`, ardından `local all all peer map=supabase_map`.
       - `pg_ident.conf` içindeki `supabase_map`: OS kullanıcısı `root` → `postgres` rolü (ayrıca `postgres` → `postgres`).
       - Sonuç: **root olarak çalışan `psql -U postgres` şifresiz bağlanır; mekanizma trust değil, peer + ident eşlemesi.** `PGPASSWORD` gerekmez.
     - **Canlı container'ın hba ve ident dosyaları ile Dokploy görevinin hangi OS kullanıcısıyla çalıştığı bu turda doğrulanmadı.**
       - Canlıdaki `pexec.sh` `-h localhost -U supabase_admin` ile şifresiz bağlanıyor. Bu, aynı imajın 127.0.0.1 trust kuralıyla tutarlı, ama `postgres` için socket/peer yolunu kanıtlamaz.
       - Görev `root` ya da `postgres` dışında bir OS kullanıcısıyla çalışırsa peer reddeder: `Peer authentication failed`.
     - İlk elle çalıştırma varsayımı doğrular. Şifre istenirse ya da peer reddederse görev hata verir; komuta secret eklenmez, durup Aryen'e bildirilir.

### Kazanç günlüğü adımı (kazanç günlüğü migration'ı canlıya girdikten sonra, ayrı onayla)
Dokploy görevinin komut alanı `supabase/ops/kodhane_retention_dokploy_command_with_progress_log.txt` ile değiştirilir:
```sh
psql -X -P pager=off -U postgres -d postgres -v ON_ERROR_STOP=1 -x -c "select public.kodhane_cleanup_save_backups() as kodhane_save_backups, public.acik_ofis_cleanup_save_backups() as acik_ofis_save_backups" -c "select coalesce(sum(b.n), 0) as audit_log_entries, count(*) filter (where b.n > 0) as audit_batches from (select public.kodhane_cleanup_audit_log(5000) as n from generate_series(1, 20)) b" -c "select count(*) as audit_left_over_12m from auth.audit_log_entries a where a.created_at < now() - make_interval(months => 12)" -c "select coalesce(sum(b.n), 0) as progress_log_rows, count(*) filter (where b.n > 0) as progress_log_batches from (select public.kodhane_cleanup_progress_log(365, 5000) as n from generate_series(1, 20)) b" -c "select count(*) as progress_log_left_over_365d from public.kodhane_progress_log p where p.created_at < now() - make_interval(days => 365)"
```
- İlk komutun birebir aynısı + sonda iki `-c`: `kodhane_cleanup_progress_log(365, 5000)` 20 kez (tek ifade, tek transaction;
  gece başına en fazla 100000 satır, J3) ve 365 günden eski kalan satır sayısı.
- **Neden en sonda:** psql `-1` olmadan her `-c`'yi ayrı transaction'da çalıştırır ve commit eder. Bu adım hata verirse (ör. migration
  geri alındı: `function public.kodhane_cleanup_progress_log(integer, integer) does not exist`) yedek ve denetim silmeleri zaten
  commit edilmiştir; çıkış kodu 1 olur, görev başarısız görünür (testler J8, J9). Hata görünür kalsın diye yutulmaz.
- Neden ayrı dosya: komut tek tırnak ve `$` içeremediği için "fonksiyon yoksa atla" SQL'de yazılamıyor (dinamik SQL metin sabiti
  ister). Bu yüzden adım migration canlıya girince eklenir; ondan önce ilk komut tek başına çalışır (JS1).
- Ekledikten sonra elle bir kez tetikle; sekiz sayı satırı ve çıkış 0 beklenir. Kazanç günlüğü geri alınırsa önce komut ilk dosyaya döner.

### Silme listesi adımı (silme listesi migration'ı canlıya girdikten sonra, ayrı onayla)
**Değerlendirme: evet, tek satır olarak eklenebilir.** Adım tek bir `-c`, sonda: `-c "select kodhane_private.cleanup_deletion_log() as deletion_log_rows"`.
Fonksiyon tek DELETE çalıştırır (liste küçük: 45 günlük silme sayısı), parti gerekmez. Tek tırnak ve `$` içermez (test T3b).
"Fonksiyon yoksa atla" bu komutta da yazılamaz. Bu yüzden adım ayrı komut dosyasındadır ve migration canlıya girince Dokploy'daki
komut şu ikisinden biriyle değiştirilir:
- Kazanç günlüğü adımı **yoksa** `supabase/ops/kodhane_retention_dokploy_command_with_deletion_log.txt`:
```sh
psql -X -P pager=off -U postgres -d postgres -v ON_ERROR_STOP=1 -x -c "select public.kodhane_cleanup_save_backups() as kodhane_save_backups, public.acik_ofis_cleanup_save_backups() as acik_ofis_save_backups" -c "select coalesce(sum(b.n), 0) as audit_log_entries, count(*) filter (where b.n > 0) as audit_batches from (select public.kodhane_cleanup_audit_log(5000) as n from generate_series(1, 20)) b" -c "select count(*) as audit_left_over_12m from auth.audit_log_entries a where a.created_at < now() - make_interval(months => 12)" -c "select kodhane_private.cleanup_deletion_log() as deletion_log_rows"
```
- Kazanç günlüğü adımı **varsa** `supabase/ops/kodhane_retention_dokploy_command_with_progress_log_and_deletion_log.txt`:
```sh
psql -X -P pager=off -U postgres -d postgres -v ON_ERROR_STOP=1 -x -c "select public.kodhane_cleanup_save_backups() as kodhane_save_backups, public.acik_ofis_cleanup_save_backups() as acik_ofis_save_backups" -c "select coalesce(sum(b.n), 0) as audit_log_entries, count(*) filter (where b.n > 0) as audit_batches from (select public.kodhane_cleanup_audit_log(5000) as n from generate_series(1, 20)) b" -c "select count(*) as audit_left_over_12m from auth.audit_log_entries a where a.created_at < now() - make_interval(months => 12)" -c "select coalesce(sum(b.n), 0) as progress_log_rows, count(*) filter (where b.n > 0) as progress_log_batches from (select public.kodhane_cleanup_progress_log(365, 5000) as n from generate_series(1, 20)) b" -c "select count(*) as progress_log_left_over_365d from public.kodhane_progress_log p where p.created_at < now() - make_interval(days => 365)" -c "select kodhane_private.cleanup_deletion_log() as deletion_log_rows"
```
- **Bağımlılık:**
  - Saklama paketi (audit migration'ı + Dokploy görevi) kurulu olmalı. Komut onun üstüne bir satır ekler.
  - Silme listesi migration'ı (`kodhane_deletion_log_install.sh`, ayrı onay) kurulu olmalı.
  - B paketine bağlı değil. Kazanç günlüğüne yalnız hangi dosyanın seçileceği bakımından bağlı.
  - Liste migration'ı kurulu değilse komut **son adımda** hata verir: çıkış 1, önceki adımlar commit edilmiş olur (test T4). Bu yüzden adım migration'dan önce eklenmez.
- `postgres` rolü tablonun sahibidir ve BYPASSRLS taşır. FORCE RLS'li tabloyu bu yüzden temizleyebilir (test T1, T5).
- Ekledikten sonra elle bir kez tetikle; sonda `deletion_log_rows | 0` (ilk 45 gün) ve çıkış 0 beklenir.
- Silme listesi geri alınacaksa önce komut, liste adımı olmayan dosyaya döner.
- Bu adımdan bağımsız olarak listenin DB dışına alınması (15 dakikada bir dışa aktarım) ayrı bir görevdir ve saklama işine dahil değildir.

## İlk çalıştırma (elle tetikle)
1. Görevi kaydettikten sonra Dokploy'da "Run" / "şimdi çalıştır" ile bir kez elle tetikle.
2. Görev logunda şunları kontrol et:
   - Beş sayı satırı.
   - Hata satırı (`ERROR:` / `FATAL:`) yok.
   - Çıkış kodu 0. Dokploy logu "success" ya da exit 0 göstermeli.

   2026-10-01 dry-run'ına göre beklenen çıktı (henüz süresi dolan satır yok):
   ```
   -[ RECORD 1 ]----------+--
   kodhane_save_backups   | 0
   acik_ofis_save_backups | 0

   -[ RECORD 1 ]-----+--
   audit_log_entries | 0
   audit_batches     | 0

   -[ RECORD 1 ]-------+--
   audit_left_over_12m | 0
   ```
3. Ertesi sabah otomatik çalışmanın logunu da kontrol et. Saat 03:47 TSİ olmalı; 06:47 görürsen timezone boş kalmıştır.
4. Sonucu Aryen'e bildir: sayılar, çıkış kodu, saat. Bu, gizlilik metni kuralının 2. koşulu.

## Başarısızlıkta
- **Çıkış kodu ≠ 0 ya da logda `ERROR:` / `FATAL:` varsa:** görevi Dokploy'da pasifleştir ve logu sakla. Kişisel veri yok; yalnız sayılar ve hata metni.
  Bilinen nedenler:
  - `function public.kodhane_cleanup_audit_log(integer) does not exist`: migration uygulanmamış ya da geri alınmış (test J4, çıkış 1).
    - Önceki `-c` adımı (yedekler) çalışmış olabilir; bu zararsız, yedekler zaten 30 günü geçmiş.
  - `function public.kodhane_cleanup_progress_log(integer, integer) does not exist`: kazanç günlüğü adımı eklenmiş ama migration yok ya da
    geri alınmış (test J8, çıkış 1). Yedek ve denetim adımları çalışmış ve commit edilmiştir. Komutu ilk dosyaya döndür.
  - `relation ... does not exist` ya da `permission denied`: şema değişmiş ya da yetki kaybolmuş. Sonraki adımlar çalışmaz (test J5).
  - `Peer authentication failed` / `password authentication failed` / `no pg_hba.conf entry`: şifresiz bağlantı varsayımı canlıda tutmuyor. Komuta şifre **eklenmez**; Aryen'e bildir, ayrı karar.
  - Yanlış servis ya da veritabanı (ör. Fenomen'in db'si): fonksiyonlar orada yok, ilk adım hata verir ve hiçbir şey silinmez.
- **Düzeltme:**
  - Nedeni salt okunur sorgularla bul (yukarıdaki kurulum doğrulaması ve aşağıdaki doğrulama sorgusu).
  - Düzeltme canlıya yazma gerektiriyorsa (migration'ı yeniden uygulamak gibi) ayrı onay al.
  - Sonra görevi etkinleştir ve tekrar elle tetikle.
- `audit_left_over_12m` ya da `progress_log_left_over_365d` > 0 ise parti üst sınırı dolmuştur. Hata değildir; ertesi gece devam eder. Birkaç gün üst üste > 0 ise Aryen'e bildir.

## Doğrulama (salt okunur, her zaman)
```sql
begin transaction read only;
select (select count(*) from auth.audit_log_entries where created_at < now() - interval '12 months') as audit_over_12m,
       (select count(*) from public.kodhane_save_backups where created_at <= now() - public.kodhane_save_backup_retention()) as kodhane_bk_over_30d,
       (select count(*) from public.acik_ofis_save_backups where created_at <= now() - public.acik_ofis_save_backup_retention()) as ao_bk_over_30d;
rollback;
```
Üçü de 0 olmalı. En fazla bir günlük gecikme normal.

## Takvim (2026-10-01 20:56 TSİ dry-run'ından)
| Kural | Toplam | Şu an silinecek | En eski kayıt (TSİ) | Süreyi doldurduğu an (TSİ) | Bunu silecek ilk gece işi |
|---|---|---|---|---|---|
| Denetim kaydı 12 ay | 535 satır, 240 kB | 0 | 2026-09-28 06:27 | **2027-09-28 06:27** | 2027-09-29 03:47 |
| Kodhane yedekleri 30 gün | 2 (`manual`) | 0 | 2026-09-29 20:23 | 2026-10-29 20:23 | 2026-10-30 03:47 (iş kuruluysa) |
| Açık Ofis yedekleri 30 gün | 0 | 0 | — | — | — |
| Kazanç günlüğü 365 gün | canlıda yok | 0 | — | ilk satırdan 365 gün sonra | kazanç günlüğü adımı eklendikten sonraki ilk gece |

- 30 günü geçen yedekler bugün de oyuncuya görünmüyor ve geri yüklenemiyor (v2.2 RLS ve restore kontrolü). Oyuncunun sıfırlama ve geri yükleme işlemleri kendi eski yedeklerini zaten temizliyor.
- Genel silme yalnız bu iş kurulunca başlar.

## Gizlilik metni kuralı
Saklama süreleri (denetim kaydı 12 ay, kayıt yedekleri 30 gün) gizlilik metnine **yalnız şu üç koşulun üçü de sağlanınca** girer:
1. **Canlıda kurulu:** migration uygulandı, kurulum doğrulaması beklenen sonucu verdi ve Dokploy günlük işi etkin.
2. **İlk çalıştırma hatasız:** elle başlatılan ilk çalıştırma `kodhane retention OK` satırını yazdı ve çıkış kodu 0.
3. **Silme, canlıyla aynı imajda testle kanıtlı:** `supabase/postgres:17.6.1.136` (`f519727303f0`) üzerinde `run_kodhane_retention_tests.sh` yeşil. Bu koşul 2026-10-01'de sağlandı (56/56). İmaj değişirse testler yeniden koşulur.

Üçü sağlanmadan metin bu süreleri vaat etmez. Kural Açık Ofis'in gizlilik metni için de geçerli (ortak auth). Metin değişikliği ayrı iştir ve ayrı onaya bağlıdır.

## Geri alma
1. Dokploy işini pasifleştir ya da sil.
2. `supabase/rollback/20261001210000_v4_4_kodhane_audit_log_retention.rollback.sql`.
   Yalnız kazanç günlüğü geri alınacaksa: komutu ilk dosyaya döndür, sonra kazanç günlüğü rollback'i.
3. Yedek fonksiyonları v2.2'ye aittir; burada kaldırılmaz.

Silinen denetim kayıtları ve yedekler yalnız DB yedeğinden (Dokploy ya da PITR, kendi saklama süreleri) dönebilir.

## Notlar
- `auth.audit_log_entries` GoTrue'nun tablosu (sahibi `supabase_auth_admin`). `created_at` için index yok; her parti tabloyu tarar. Bugün 535 satır, sorun değil. Auth şemasına index eklenmedi.
- Hesap silme (`docs/kodhane-account-delete-runbook.md`, `mode=full`) kullanıcının denetim kayıtlarını hemen siler; bu iş geri kalanların yaşını sınırlar.
- Supabase'de `postgres` rolü `service_role` üyeliğini miras alıyor. Bu yüzden testte "postgres yetkisiz" durumu EXECUTE geri alınarak değil, tablo adı değiştirilerek denendi (S7).
- Kazanç günlüğü saklama süresi 365 gün (Aryen, 2026-10-03). Fonksiyon ve tasarım: `docs/kodhane-progress-log-runbook.md`.
- `docs/v2.2-runbook.md`'deki isteğe bağlı pg_cron işleri (`17 0 * * *` UTC) bu Dokploy görevinden ayrı; canlıda pg_cron yok, kurulmadı.
