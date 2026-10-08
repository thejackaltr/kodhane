# v4.4 A/B test sonuçları: canlı Postgres imajı (.136) ve .171

- Canlı DB container'ı `<KODHANE_DB_CONTAINER>` (Portainer, `<KODHANE_PORTAINER_URL>`) imajı: `supabase/postgres:17.6.1.136`,
  image id `sha256:f519727303f0…` (Portainer container inspect, salt okunur GET, 2026-09-29 21:19 TSİ).
  Canlıda `select version()` (read only transaction): `PostgreSQL 17.6 on x86_64-pc-linux-gnu, compiled by gcc (GCC) 15.2.0, 64-bit`.
- Box'taki `supabase/postgres:17.6.1.136` imajının id'si aynı (`f519727303f0`).
- Taban: `v44_base` (.171 container'ı) `pg_dump -Fc --schema-only` ile .136 container'ına taşındı. Tek eksik rol
  `supabase_functions_admin` aynı özniteliklerle oluşturuldu. İki container'da `pg_dump --schema-only v44_base` birebir aynı.
- Koşu: 2026-09-29 ~23:55 TSİ, `d385583` + B guard düzeltmesi (`sv_new < sv_old and sv_old >= 5`),
  `V44_CT=<container> run_v4_4a_tests.sh` / `run_v4_4a_compare_tests.sh` / `run_v4_4b_tests.sh` (HTTP dahil, PostgREST v16.3).
  Hesap silme paketi (`KD_CT=<container> run_kodhane_account_delete_tests.sh`, base + A+B): iki imajda 134/134.

| Paket | .136 | .171 | Fark |
|---|---|---|---|
| A | 86/86 (15 runner + 71 SQL) | 86/86 | yok |
| A compare (snapshot/compare) | 12/12 | 12/12 | yok |
| B | 60/60 (13 runner + 40 SQL + 7 HTTP) | 60/60 | yok |

Dosyalar: sıralanmış PASS/FAIL satırları (`v4_4{a,a_compare,b}_pg17.6.1.{136,171}.txt`). Aynı pakette iki dosya bayt bayt aynı:
hata kodları (PT426 `save_version_too_old`, PT409 `stale_revision`, 23514, 42501), mesajlar ve HTTP durumları (426/409/200)
aynı. Ham loglardaki tek fark stdout/stderr satır sırası (NOTICE araya girmesi). H7 yanıt gövdesi (sıralama verisi) maskelendi.

## 2026-10-01 08:00–08:15 TSİ: A beklentisi izin listesi (fa7c574270bdf8c6, rev 1107), `fc43336`
- 08:15'te DB testleri koşulamamıştı (box sıfırlanmış, docker/imaj yok). 2026-10-01 18:13–18:15 TSİ'de koşuldu: docker.io
  26.1.5+dfsg1, storage driver **vfs** (overlay2 `failed to mount overlay: invalid argument`), yalnız
  `public.ecr.aws/supabase/postgres:17.6.1.136` (image id `f519727303f0`, canlıyla aynı). `v44_base` = `live_schema_full.dump`
  pg_restore (+ `supabase_functions_admin` rolü); `pg_dump --schema-only -n public` canlı taban dosyasıyla birebir aynı.
  .171 bu değişiklikle koşulmadı (imaj çekilmedi); `*_pg17.6.1.171.txt` dosyaları `970b0d4` durumuna aittir.

| Grup | .136 | Dosya |
|---|---|---|
| A (`run_v4_4a_tests.sh`) | 86/86 (15 runner + 71 SQL; P0 artık 3 gövde kopyası) | `v4_4a_pg17.6.1.136.txt` |
| A compare (`run_v4_4a_compare_tests.sh`) | **30/30** (18:13'te 29/30, R1 test beklentisi düzeltildi, 18:21'de tekrar) | `v4_4a_compare_pg17.6.1.136.txt` |
| Hesap silme (base + A+B) | 134/134 (common 32, full 53, kodhane_only 49) | `kodhane_account_delete_pg17.6.1.136.txt` |
| Veritabanısız compare | 11/11 | `v4_4a_compare_offline.txt` |

- R1 (18:13 FAIL): test, yerel DB'de olmayan anahtarlar için boş alan bekliyordu; fonksiyonlar bulunamayan kayıtta
  `kodhane_score_plausible(NULL)` = f, `kodhane_save_vetted_score(NULL)` = 0, `kodhane_save_score(NULL)` = 0 döner. Yalnız R1
  beklentisi düzeltildi (rapor SQL'i değişmedi): iki satır da `rev boş | f | 0 | best boş | 0 | sıralama boş | n 0` olmalı;
  "bulunamadı" ayrımı = revizyon boş ve son sütun (eşleşen kayıt sayısı) 0. 18:21 TSİ'de .136'da compare 30/30, A 86/86,
  offline 11/11 (hesap silme bu değişiklikten etkilenmez, tekrar koşulmadı; 134/134 18:15 sonucu).
- İzin listesi vakaları: C9 onaylı durumdan false→true PASS; C13 aynı anahtar, farklı durum (rev 1108) FAIL; C10 / C9b başka
  yeni kabul FAIL; C11 izinli true→false FAIL; C12 başka yeni işaret FAIL; C14 izinli + pencere içi yazma PASS; C15 izinli
  false kalır FAIL; preflight PF1 PASS, PF2–PF7 STOP (PF5 zaten true, PF6 girdiler değişmiş, PF7 yeniden yazılmış).
- (20:24 sonrası geçersiz) Yukarıdaki izin listesi vakaları bir sonraki bölümde kaldırıldı.
- Atlanan: B'nin HTTP testleri (`http_v4_4b.sh`, PostgREST imajı gerekir) bu turda istenmedi ve koşulmadı.

## 2026-10-01 20:24 TSİ: izin listesi geri alındı, beklenti 0/0
- Neden: fa7c kaydı 16:13 TSİ'de yeniden yazıldı (artık v4.3'te de true); 20:22 kurulum öncesi preflight STOP verdi, A uygulanmadı.
- Preflight: izin kalktı; `EXPECTATION | PASS` yalnız newly_flagged 0 ve newly_accepted 0 iken; diğer STOP koşulları aynı.
  Compare: izin kalktı; her kural sonucu değişimi FAIL. scores_report: yalnız etiket (`allow-listed` → `compensated`).
- Koşu 2026-10-01 ~20:27–20:30 TSİ, aynı .136 imajı (`f519727303f0`, vfs), `v44_base` aynı yöntemle (şema diff 0).

| Grup | .136 |
|---|---|
| A (`run_v4_4a_tests.sh`) | 86/86 (15 runner + 71 SQL; P0 3 gövde kopyası) |
| A compare (`run_v4_4a_compare_tests.sh`) | 25/25 (S1, C1–C8, C3b, Z1–Z6 + preflight, K1, R1, N1, N2) |
| Hesap silme (base + A+B) | 134/134 |
| Veritabanısız compare | 11/11 (O1–O11) |

- Z1 hiçbir değişiklik yok → preflight PASS ve compare PASS. Z2 fa7c benzeri tek false→true → preflight STOP
  (`newly_accepted 1`) ve compare FAIL. Z3 aynısı + pencere içi yazma → yine STOP / FAIL. Z4 yeni işaret → STOP / FAIL.
  Z5 pencere içi yazma, kural aynı → PASS / PASS. Z6 A sonrası preflight → STOP (kural v4.3 değil). K1 izin listesi kalıntısı yok.

## 2026-10-01 20:48–20:50 TSİ: hesap silme, `kodhane_only` oturumları kapatır, `expect` hesap alanlarını kapsar
- `kodhane_only` artık kullanıcının `auth.refresh_tokens` (oturuma bağlı ve bağsız) ve `auth.sessions` satırlarını da siler.
  `expect` token'ı auth kullanıcısının `id`, `email`, `created_at` alanlarını kapsar; `last_sign_in_at`, oturum ve denetim
  sayıları kapsamaz (her girişte değişirler). Uyuşmazlıkta silme yapılmaz.
- Koşu: aynı .136 imajı (`f519727303f0`, vfs), `v44_base` = `live_schema_full.dump` pg_restore (şema diff 0). .171 koşulmadı.

| Grup | .136 |
|---|---|
| Hesap silme (base + A+B) | **156/156** (common 34, full 61, kodhane_only 61) |
| A (`run_v4_4a_tests.sh`) | 86/86 (15 runner + 71 SQL), dosya değişmedi |
| A compare (`run_v4_4a_compare_tests.sh`) | 25/25, dosya değişmedi |
| Veritabanısız compare | 11/11, dosya değişmedi |

- Yeni hesap silme testleri (her taban için, base ve A+B):
  - C-T0: kimlik bloğu ön kontrol ve silmede bayt bayt aynı.
  - C-E3: aynı satırlar, aynı e-posta (boş) ve aynı `created_at` olan başka kullanıcının token'ı reddedilir (yalnız id farklı).
  - F-E1 / K-E1: e-posta değişti → reddedildi, hiçbir şey değişmedi. F-E2 / K-E2: `created_at` değişti → reddedildi.
    F-E2b / K-E2b: geri alınınca token yine aynı.
  - F-E4 / K-E4: `last_sign_in_at`, yeni oturum ve yeni denetim satırı sonrası token aynı; silme eski token'la yapıldı.
  - K-R1: `auth.refresh_tokens 3, auth.sessions 3 (sessions closed)`. K-O1: u3'ün oturum ve refresh token'ı 0
    (oturuma bağlı ve bağsız). K-O2: başka kullanıcıların oturum ve refresh token satırları birebir aynı (u2: 1 / 1).

## 2026-10-01 21:03–21:05 TSİ: saklama süreleri (todo 26), migration `20261001210000`
- Denetim kaydı 12 ay: `public.kodhane_cleanup_audit_log(p_batch_size)`, yeni. Yedekler 30 gün: mevcut v2.2
  `kodhane_cleanup_save_backups()` / `acik_ofis_cleanup_save_backups()`. Günlük iş: `ops/kodhane_retention_daily.sh` ve Dokploy betiği.
- Koşu: aynı .136 imajı (`f519727303f0`, vfs), container `kdret-db136`, `v44_base` = `live_schema_full.dump` pg_restore (şema diff 0). .171 koşulmadı.

| Grup | .136 | Dosya |
|---|---|---|
| Saklama (`run_kodhane_retention_tests.sh`) | **56/56** (M 6, P 9, A 13, B 7, S 16, R 5) | `kodhane_retention_pg17.6.1.136.txt` |
| Hesap silme | 156/156, dosya değişmedi (yalnız `now()`'a bağlı 4 token değeri farklı) | `kodhane_account_delete_pg17.6.1.136.txt` |
| A | 86/86 (15 runner + 71 SQL), dosya değişmedi | `v4_4a_pg17.6.1.136.txt` |
| A compare | 25/25, dosya değişmedi | `v4_4a_compare_pg17.6.1.136.txt` |
| Veritabanısız compare | 11/11, dosya değişmedi | `v4_4a_compare_offline.txt` |

- Sınırlar: 12 ay + 1 gün silinir, 12 ay − 1 gün kalır; 30 gün + 1 gün silinir (silme kopyası dahil), 29 gün kalır.
  `created_at` boş satır kalır.
- Parti: 25 satır, parti 10 → 10, 10, 5, 0. 0 / −1 / null / 50001 reddedilir (22023), 50000 kabul edilir.
- Yetki: anon ve authenticated üç temizlik fonksiyonunu da çağıramaz (42501). ACL tam olarak
  `{postgres=X/postgres,service_role=X/postgres}`. service_role çağırır ve doğru sayıyı alır.
- Migration, `postgres`'in DELETE yetkisi yoksa hata verir ve hiçbir şey oluşturmaz (M0); yanlış hedefte de durur (M0b).
  Rollback sonrası public + auth şeması migration öncesiyle aynı (R2, R4).

## 2026-10-01 21:24–21:27 TSİ: saklama, Dokploy v0.30.8 compose görevi (tek satır psql)
- Host tipi görev yok. Görev compose tipinde, `<KODHANE_DB_COMPOSE>` / `db` servisinde çalışıyor.
  Komut: `supabase/ops/kodhane_retention_dokploy_command.txt`. Host betiği `kodhane_retention_dokploy_task.sh` kaldırıldı (S0, S8–S10 testleri onunla gitti).
- Koşu: aynı .136 imajı (`f519727303f0`, vfs), container `kdjob-db136`, `v44_base` aynı yöntemle (şema diff 0). .171 koşulmadı.

| Grup | .136 |
|---|---|
| Saklama | **73/73** (önceki 56 − 4 kaldırılan + 21 yeni: Q 3, D 8, J 10) |
| Hesap silme | 156/156, dosya değişmedi (yalnız `now()`'a bağlı 4 token değeri farklı) |
| A | 86/86, dosya değişmedi |
| A compare | 25/25, dosya değişmedi |
| Veritabanısız compare | 11/11, dosya değişmedi |

- **J testleri** komutu Dokploy'un çalıştırdığı biçimde, varsayılan kullanıcı (root) ile koşar: `sh -c "docker exec <c> sh -c '<komut>'"`.
  Test sırasında container'ın kendi `postgres` veritabanı geçici olarak canlı şemayla değiştirilir, sonra geri konur.
  - Başarı, exit 0: J1 (2 / 2 / 12001 satır, 3 parti), J2 (sıfırlar), J3 (üst sınır: 100000 satır, 20 parti, 5 kalan), J3b, J6.
  - Hata, exit 1: J4 (audit fonksiyonu yok; önceki yedek adımı çalışmış), J5 (ilk adım hata; sonraki adımlar çalışmadı).
- **D testleri:**
  - Komut tek satır; tek tırnak, `$`, backtick ve ters bölü içermiyor; runbook'ta birebir var.
  - Varsayılan kullanıcı `root`. Geçerli hba `/etc/postgresql/pg_hba.conf`: `local all supabase_admin trust`, ardından `local all all peer map=supabase_map`. ident eşlemesi `root>postgres`.
  - Yani şifresiz bağlantı trust değil, peer + ident eşlemesi.
- **Q testleri:** `postgres` rolü (süper kullanıcı değil) üç fonksiyonu çağırıp siliyor: 2 / 2 / 3 satır.

## 2026-10-03 TSİ: kazanç günlüğü (`kodhane_progress_log`, kapsam 1. adım)
- Box sıfırlanmıştı (docker yoktu). `docker.io` 26.1.5 yeniden kuruldu, dockerd vfs ile elle başlatıldı. .136 imajı yeniden çekildi; image id aynı (`f519727303f0`).
  Container `v44x-136`, `v44_base` aynı yöntemle (şema diff 0). .171 koşulmadı.
- Migration `20261003020000_v4_4_kodhane_progress_log.sql`, rollback ve runbook: `docs/kodhane-progress-log-runbook.md`.

| Grup | .136 |
|---|---|
| Kazanç günlüğü (yeni) | **125/125**: `[a]` A+günlük 62, `[ab]` A+B+günlük 62, `[once]` 1 |
| Hesap silme | **168/168** (156 + 12 yeni `[abl]` L-*: preflight/expect/verify ve iki silme modu günlük satırlarıyla) |
| Saklama | 73/73, dosya değişmedi |
| A | 86/86, dosya değişmedi |
| A compare | 25/25, dosya değişmedi |
| B | 53/53 (V44_HTTP=0; HTTP kontrolleri koşulmadı), dosya değişmedi |
| Veritabanısız compare | 11/11, dosya değişmedi |

- Kazanç günlüğü grupları: M (migration/ACL/idempotent), P (RLS/yetki), F (alan alan artış/azalış, değişmeyen alan satır yok),
  E (telafi/sıfırlama/geri yükleme; istemci telafi işaretini taklit edemez), T (ağaç düğümleri), B (B'nin reddettiği yazma günlüğe düşmez,
  kabul edilen düşer), X (günlük hatasında kayıt yazması başarılı), C (temizlik parti/sınır), R (rollback).
- Hesap silme sonuç dosyasında E2 satırlarındaki fark yalnız `now()`'a bağlı değerlerden.

## 2026-10-03 TSİ: saklama, kazanç günlüğü 365 gün + Dokploy komutu `-P pager=off`, cron `47 3 * * *`
- Aryen kazanç günlüğü saklamasını 12 ay (365 gün) seçti. Saklama paketi kazanç günlüğünden önce kurulacağı için iki komut dosyası:
  `kodhane_retention_dokploy_command.txt` (tek başına; kazanç günlüğü yokken de çıkış 0, JS1) ve
  `kodhane_retention_dokploy_command_with_progress_log.txt` (aynısı + sonda `kodhane_cleanup_progress_log(365, 5000)`; migration canlıya girince).
  İkisinde de `-X -P pager=off ... -v ON_ERROR_STOP=1`. Cron `47 3 * * *` Europe/Istanbul (GM'nin 03:20 yedeğiyle çakışmaz).
- Koşu: .136 (`f519727303f0`, vfs), container `v44x-136`, `v44_base` = `live_schema_full.dump` pg_restore (şema diff 0). .171 koşulmadı.

| Grup | .136 |
|---|---|
| Saklama | **82/82** (73 + 9 yeni: M4, S8, S8b, D0e, J0b, JS1, JS2, J8, J9; S1/S2/S7/D0–D0d/J1–J6 kazanç günlüğüyle genişletildi) |
| Kazanç günlüğü | 125/125, dosya değişmedi |

## 2026-10-03 TSİ: kazanç günlüğü YY kararları (aynı migration `20261003020000`, canlıya girmedi)
- Temizlik varsayılanı 365 gün; oyuncu okuması kapalı (v4.5 RPC); `client_version` = `data.clientVersion` (1–32, `[0-9A-Za-z._-]`),
  yoksa `saveVersion <n>`, geçersizse NULL; `approval_ref` kolonu: telafi için `kodhane.progress_ref` = `KD-TLF-YYYY-MM-DD-NN` zorunlu,
  yoksa/biçimsizse yazma reddedilir (22023, yutulmaz); telafi yazmasında günlük hatası da yutulmaz.

| Grup | .136 |
|---|---|
| Kazanç günlüğü | **145/145** (125 + 2 × 10 yeni: M6, F8b, E12–E17, X5, C6) |
| Hesap silme | 168/168 (L-K4 test satırına `approval_ref` eklendi), dosya değişmedi |
| Saklama | 82/82, dosya değişmedi |

## 2026-10-03 TSİ: B float8 sertleştirmesi (`kodhane_score_plausible` v4.4b, migration `20260929204000` içinde, canlıya girmedi)
- B, A kuralını float8 sınırlarıyla yeniden kurar: sayaçlar > 1e50, `totalEarned`/`runEarned`/`cycleEarned` 1e300 dışı → false (22003 yok);
  sınırlar içinde v4.4a ile aynı sonuç. B rollback'i v4.4a tanımını birebir geri koyar. `ops/v4_4b_verify.sql` 2. kontrol kazanç günlüğü
  tetikleyicisini (`kodhane_saves_z_progress_log`) kabul eder.
- HTTP (H1–H7) bu turda koşulmadı; satırlar önceki koşudan.

| Grup | .136 |
|---|---|
| B | **13 + 51** (yeni: O0–O10; O3 38400 kayıtta v4.4b = v4.4a) |
| A | 86/86, compare 25/25, offline 11/11, dosyalar değişmedi |
| Kazanç günlüğü 145/145, hesap silme 168/168, saklama 82/82 | dosyalar değişmedi |

## 2026-10-03 03:29–03:31 TSİ: B + kazanç günlüğü kurulum paketi provası (`ops/kodhane_v44b_install.sh`, canlıya dokunulmadı)
- Prova veritabanı: canlı şema + A + takma adlı canlı kopyası + `seed_extra.sql`. Kapsam: backup, preflight, dryrun,
  install, verify, silme yolu, silme testi, rollback (koruma dahil), ikinci tam koşu, yedekten tam geri yükleme, kilit
  ve STOP durumları. Ayrıntı: `docs/kodhane-v44b-install-runbook.md`, "Prova".

| Grup | .136 |
|---|---|
| Kurulum paketi provası | **62/62** (`kodhane_v44b_install_rehearsal_pg17.6.1.136.txt`) |

## 2026-10-03 TSİ: Kodhane silme listesi (migration `20261003040000`, B'den ayrı kurulum adımı, canlıya girmedi)
- `kodhane_private.deletion_log` (uid, scope `account` | `kodhane`, zaman, `info:<onay ref>`; e-posta yok; RLS FORCE, policy yok,
  API rollerine yetki yok). Hesap silme betiği aynı transaction'da yazar; dışa aktarım box'a (700/600), geri yüklemeden önce son
  liste mevcut DB'den alınır (`kodhane_v44b_install.sh restore` adım 0), sonra tek transaction'da idempotent reapply + verify.
  Saklama 45 gün (30 + 15), temizlik Dokploy komutuna tek `-c` (yeni iki varyant dosyası), günlük betikte adım 5.
- B `install.sql` md5 değişmedi: `deefef0e5c52cc3679dc997374d2edbb` (test M7). `v44b_install/inputs.md5` yalnız hesap silme iki
  dosyasının yeni md5'iyle güncellendi.
- md5: migration `239fb2e1…`, rollback `bfdde1f8…`, `kodhane_account_delete.sql` `28f379a4…` (önce `358fe2d1…`),
  `_verify.sql` `7cf7132c…` (önce `5a8868fc…`), `cleanup_deletion_log()` kaynağı `767bc92b…`.
- Mevcut testlerde değişiklik: hesap silme L-K1/L-F1 özet satırı sonuna `; deletion log not installed (no row)`; saklama S1/S2
  çıktısına "deletion log skipped" satırı.

| Grup | .136 |
|---|---|
| Silme listesi | **70/70** (`kodhane_deletion_log_pg17.6.1.136.txt`: M 12, D 9, X 8, R 16, K 4, F 11, T 10) |
| Hesap silme | 168/168 |
| B | 13 + 51 (HTTP kapalı) |
| Kurulum paketi provası | 62/62 (restore adımı: liste kurulu değil → "nothing to export", dosya yok → reapply yok) |
| Kazanç günlüğü | 145/145 |
| Saklama | 82/82 |
