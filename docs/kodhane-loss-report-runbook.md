# Kodhane: Kayıp bildir (v4.5 P7) runbook'u

Oyuncu oyunda giriş yapmışken "Kayıp bildir" formunu gönderir. Talep Aryen'in onay kuyruğuna düşer.
Aryen onaylarsa kayıp, kazanç günlüğünden (`kodhane_progress_log`) geri yüklenir.
**Onaysız geri yükleme yapılamaz:** `loss_report_apply` yalnız `approved` durumdaki ve onaydaki referansla çağrılan bildirimi yazar.
E-posta ile sorgu yok, e-posta tutulmaz. Oyuncu auth uid'iyle bağlanır.

Dosyalar:
- Migration: `supabase/migrations/20261003060000_v4_5_kodhane_loss_report.sql`. Rollback: `supabase/rollback/20261003060000_v4_5_kodhane_loss_report.rollback.sql`.
- Kurulum betiği: `supabase/ops/kodhane_loss_report_install.sh` (adımlar aşağıda). Girdi md5'leri: `supabase/ops/kodhane_loss_report/inputs.md5`.
- Ön kontrol (salt okunur): `supabase/ops/kodhane_loss_report/preflight.sql`.
- Kurulum kontrolü (salt okunur): `supabase/ops/kodhane_loss_report/install_verify.sql`. 9 kontrol yapar ve `LRVERIFY|PASS|9` yazar.
- İstemci eşleme notu (Frontend): `docs/kodhane-v4.5-kayip-bildir-istemci-notu.md`.
- Testler: `supabase/tests/loss_report/run_kodhane_loss_report_tests.sh` (yerel docker, `LR_CT=<container>`; 110 test, HTTP grubu L yerel PostgREST imajıyla, imaj yoksa SKIP).

## Kurulum (ayrı onay; B + kazanç günlüğünden sonra)
Önkoşul: B (`20260929204000`) ve kazanç günlüğü (`20261003020000`) kurulu olmalı. Değilse migration hiçbir şey oluşturmadan durur.
Silme listesinden (`20261003040000`) bağımsızdır: önce ya da sonra kurulabilir, kendi şeması `kodhane_loss`'tur.
Bu dal (`v4.5-kayip-bildir`) checkout'undan kurulur. B bu daldan **kurulmaz** (B: `docs/kodhane-v44b-install-runbook.md`).

**Zorunlu adım: P7'nin kurulduğu gün hesap silme betiği bu dalın sürümüne geçer.**
Eski (be96e03) betik `kodhane_only` modunda bildirimleri geride bırakır, `full` modunda durur.
Kurulum betiği bunu `delete-script-check` ile denetler. Kontrol, `KODHANE_ACCOUNT_DELETE_DIR` dizinindeki (varsayılan: bu checkout'un `supabase/ops`'u) şu dosyalara bakar:
`kodhane_account_delete.sql`, `_preflight.sql`, `_verify.sql` ve `kodhane_deletion_log/reapply.sql`.
Dosyaların md5'i `inputs.md5` ile aynı olmalı ve kayıp bildir işaretlerini taşımalıdır. Değilse `STOP` verir.
`build`, `preflight`, `dryrun`, `install` ve `verify` bu kontrolü kendileri de çalıştırır. **`delete-script-check` PASS olmadan kurulmaz.**
Silme işini başka bir checkout ya da kopya yapıyorsa `KODHANE_ACCOUNT_DELETE_DIR` o dizini göstermelidir.

```bash
export KODHANE_OUT=/root/kodhane-loss-report-$(date +%Y%m%d-%H%M)      # bir koşu dizini
# yerel prova: KODHANE_TARGET=local KODHANE_CT=<container> KODHANE_DB=<db>; canlı: KODHANE_TARGET=live (DevOps, pexec)
supabase/ops/kodhane_loss_report_install.sh build                 # girdi md5'leri + SQL üretimi + delete-script-check
supabase/ops/kodhane_loss_report_install.sh delete-script-check   # DELETECHECK|PASS
supabase/ops/kodhane_loss_report_install.sh preflight             # salt okunur: hedef Kodhane mi, B koruması + günlük trigger'ı açık mı → PREFLIGHT|PASS
supabase/ops/kodhane_loss_report_install.sh dryrun                # migration + 9 kontrol tek transaction, ROLLBACK → DRYRUN|PASS
KODHANE_LIVE_APPROVAL='Aryen, <tarih saat>' supabase/ops/kodhane_loss_report_install.sh install   # aynısı COMMIT → INSTALL|PASS
supabase/ops/kodhane_loss_report_install.sh verify                # LRVERIFY|PASS|9 + silme yolu + silme kontrolü (DELCHECK|PASS|5, ROLLBACK) → VERIFY|PASS
```
- `install`, aynı koşu dizininde `preflight` ve `dryrun` PASS ister. Canlıda ayrıca `KODHANE_LIVE_APPROVAL` ister.
- `verify`'ın silme yolu kontrolü, var olmayan bir uid ile `KODHANE_ACCOUNT_DELETE_DIR`'deki hesap silme preflight'ını çalıştırır. Çıktıda `kodhane_loss.loss_report` satırı `delete|delete` olarak beklenir.
- `verify`'ın **silme kontrolü** (`kodhane_loss_report/delete_check.sql`, davranış; C4/C6) tek bir işlemde çalışır ve **ROLLBACK** ile biter, canlıda iz bırakmaz (yalnız `loss_report` id sırası birkaç sayı ilerler). İki sentetik auth kullanıcısı (`a7a70000-…-d1e01`, bystander `…-d1e02`) ve bildirimleri oluşturulur; `KODHANE_ACCOUNT_DELETE_DIR/kodhane_account_delete.sql`'in DO bloğu **aynen** (`pg_temp.kodhane_del_run()`) her denemede kendi geri alınan alt işleminde çağrılır:
  1. `kodhane_only`: oyuncunun bildirimleri 0, auth kullanıcısı duruyor, diğer bildirimler aynı
  2. `full`: bildirimler 0, auth kullanıcısı silindi, diğer bildirimler aynı
  3. auth kullanıcısı doğrudan silinince (GoTrue / panel) FK `ON DELETE CASCADE` bildirimleri götürür
  4. 12 aylık saklama + silme birlikte: `cleanup_loss_reports()` yalnız 13 aylık kapalı bildirimi alır, ardından `kodhane_only` kalanı; bystander aynı
  5. geri alınan denemelerden sonra sentetik bildirimler (2 + 1) ve kullanıcılar yerinde
  Sentetik uid'ler hedefte zaten varsa kontrol hiçbir şey yapmadan `STOP` der. `DELCHECK|PASS|5` gelmezse `verify` durur. Eski (be96e03) silme betiği zaten `delete-script-check`'te durur; test I6 aynı kontrolün eski DO blokla `delcheck_1,2,4` FAIL verdiğini gösterir.
- Migration yalnız nesne ekler, kendi yedek adımı yoktur. Son DB yedeği güncel değilse önce olağan yedek alınır.
- Canlıda `postgres` olarak bağlanılır (DevOps). İstemci tarafı (form, durum ekranı) Frontend'dedir; sunucu kurulmadan form açılmamalıdır.

`install_verify.sql`'in 9 kontrolü:
1. şema ve tablo, 27 kolon
2. constraint'ler (`loss_report_review_reason_check` dahil)
3. RLS açık, oyuncu rolünün tabloya doğrudan erişimi yok
4. fonksiyonlar ve `security definer` / `search_path`
5. EXECUTE yetkileri (oyuncu yalnız create/status)
6. config: 24 saatte 1, 30 günde 5, açıklama 280, `lost_since` 365 gün geri / 5 dk ileri, saklama 12 ay
7. B koruması ve kazanç günlüğü trigger'ı
8. kuyruk ve indeksler
9. `player_status_columns`: status RPC dönüş imzası (10 kolon, son kolon `applied_revision`; iç alan yok) + `review_reason` CHECK'i

## Oyuncu tarafı (RPC, PostgREST)
- `rpc/kodhane_loss_report_create` `{p_lost_items, p_lost_since, p_description, p_client_version}` → `{id, status: "in_review", created_at}`.
  Hatalar: 401/403 `not_authenticated`; 400 `loss_report_invalid` (`details` = alan adı); 404 `no_cloud_save`;
  409 `loss_report_open` (açık bildirim var); 429 `loss_report_daily_limit` / `loss_report_monthly_limit` (`details` = tekrar deneme zamanı, UTC).
- `rpc/kodhane_loss_report_status` `{p_limit}` → oyuncunun kendi bildirimleri: `status` = `in_review | approved | rejected | applied`,
  `status_changed_at`, `reason` (yalnız ret kodu), `applied_at`, `review_reason`, `applied_revision` (son kolon; yalnız `applied` iken geri yüklemenin yazdığı kayıt revision'ı, istemci eski sekmenin 409'unu bununla kesin ayırır). Açıklama, referans, iç not ve miktarlar gösterilmez.
- `review_reason` yalnız `save_changed`, `no_cloud_save` ya da `null` olur (tablo CHECK'i + test). Başka değer çıkmaz.
  Yalnız bildirim tekrar incelemedeyken (iç durum `needs_review`, oyuncuya `in_review`) dolu gelir:
  `save_changed` = onaydan sonra oyuncu oynadı, kayıt değişti; `no_cloud_save` = bulut kaydı yok ya da geri yüklenecek şey kalmadı.
- Sınırlar (`kodhane_loss.cfg_loss_report()`): 24 saatte 1, 30 günde 5, aynı anda tek açık bildirim, bulut kaydı şart.
  Açıklama en çok 280 karakter. `lost_since`: `null` ya da en çok 365 gün geri, en çok 5 dk ileri.
  İstemci "Bugün"/"Dün" için oyuncunun yerel gün başını (UTC+14 ve UTC−12 uçları dahil), "Son 7/30 gün" için şimdi−7/30 günü, "Bilmiyorum" için `null` gönderir.
- Geri yüklemeden sonra oyuncunun açık sekmesi eski revizyonla yazar ve 409 `stale_revision` alır. İstemci kaydı yeniden çeker:
  "Telafin yüklendi, sayfayı yenile" metni bu duruma ve `status = applied`'a bağlanır.

## Aryen'in onay akışı (psql, `postgres` olarak)
Her fonksiyon yalnız `postgres` / `supabase_admin` ile çalışır; başka rol 42501 alır.
1. **Kuyruk:**
   ```sql
   select * from kodhane_loss.loss_report_queue();          -- açıklar: pending, approved, needs_review
   select * from kodhane_loss.loss_report_queue('all');     -- hepsi
   ```
2. **İncele:** Günlük satırları ve öneri. `p_at` kayıptan **önceki** an olmalıdır. Verilmezse oyuncunun yazdığı `lost_since` kullanılır.
   ```sql
   select * from kodhane_loss.loss_report_timeline(<id>, 7);              -- lost_since'ten 7 gün önce → şimdi
   select jsonb_pretty(kodhane_loss.loss_report_proposal(<id>, '<p_at>'));
   ```
   Öneri `current` (şimdiki kayıt), `at_state` (p_at anındaki durum), `diff` (yalnız artacak alanlar), `tree_add`,
   `plausible_now` / `plausible_after` (skor kuralı ön denemesi) döner. Geri yükleme **hiçbir alanı düşürmez**: her alan
   `max(şimdiki, hedef)` olur, ağaçta yalnız eksik düğümler eklenir. `totalEarned`, `saveVersion` ve diğer alanlar değişmez.
   Bu yüzden `best_score`, sıralama ve B'nin sürüm koruması etkilenmez.
3. **Onay** (referans: `KD-TLF-YYYY-MM-DD-NN`, gerçek tarih, her bildirime ayrı; `@ , " \` ve kontrol karakteri reddedilir):
   ```sql
   select kodhane_loss.loss_report_approve(<id>, 'KD-TLF-2026-10-05-01', '<p_at>');                    -- öneriyle
   select kodhane_loss.loss_report_approve(<id>, 'KD-TLF-2026-10-05-01', null, '{"shares": 40}');      -- miktar düzeltme
   ```
   Kayıt skor kuralını geçerken sonrası geçmeyecekse onay durur. Oyuncu sıralamadan düşer. Bunu bilerek onaylamak için
   `p_accept_implausible => true` verilir. Onay, kaydın o anki revizyonunu saklar.
4. **Ret:** `select kodhane_loss.loss_report_reject(<id>, 'kayip_bulunamadi', '<iç not>');`
   Ret kodları: `kayip_bulunamadi`, `zaten_telafi_edildi`, `kural_disi`, `diger`. Kodu oyuncu görür, notu görmez.
5. **Geri yükleme** (tek transaction):
   ```sql
   select kodhane_loss.loss_report_apply(<id>, 'KD-TLF-2026-10-05-01');
   ```
   Akış şöyledir:
   - Kayıt kilitlenir ve revizyonun onaydaki revizyonla aynı olduğu kontrol edilir.
   - Kaydın o anki hâli `manual` yedek olarak alınır (oyuncu 30 gün geri alabilir).
   - Kayıt yazılır ve kazanç günlüğüne `telafi` satırları referansla düşer.
   - Bildirim `applied` olur.

   Sonuçlar:
   - `result = applied`: geri yükleme yapıldı.
   - `already_applied`: ikinci çağrı, hiçbir şey değişmez.
   - `needs_review`: Hiçbir şey yazılmaz. 2. adımdan tekrar incelenir ve aynı referansla yeniden onaylanır (ya da reddedilir).
     Sonuçtaki ve kuyruktaki `review_reason` nedeni söyler:
     - `save_changed`: oyuncu onaydan sonra oynadı, revizyon değişti
     - `no_cloud_save`: bulut kaydı yok (silinmiş) ya da onaydaki hedefe göre geri yüklenecek alan kalmadı
     Yeniden onay ya da ret `review_reason`'ı temizler.

   Onay ile geri yükleme arasında oyuncu kayıt yazarsa sonuç `needs_review` olur. Bu yüzden onay ve geri yükleme art arda çalıştırılır:
   ```sql
   begin;
   select kodhane_loss.loss_report_approve(<id>, '<ref>', '<p_at>');
   select kodhane_loss.loss_report_apply(<id>, '<ref>');
   commit;
   ```
6. **Kontrol:** `select * from public.kodhane_progress_log where approval_ref = '<ref>';` (telafi satırları),
   `select status, applied_diff, backup_id from kodhane_loss.loss_report where id = <id>;`

## Saklama
Kapanan bildirimler (`applied`, `rejected`) son durum değişikliğinden **12 ay** sonra `kodhane_loss.cleanup_loss_reports()` ile silinir.
Açık bildirimler (`pending`, `approved`, `needs_review`) karara kadar kalır. Süre config'te (`retention_months` 12).
Günlük saklama betiği (`supabase/ops/kodhane_retention_daily.sh`) 6. adımda fonksiyonu çağırır. Fonksiyon yoksa (P7 kurulmadan) adım `skipped` yazar.
Dokploy'daki günlük komutun kayıp bildir adımını içeren sürüme geçmesi **ayrı bir değişiklik ve ayrı onaydır.** Komut dosyası
`supabase/ops/kodhane_retention_dokploy_command_with_progress_log_and_loss_report.txt` (silme listesi de kuruluysa
`..._with_progress_log_and_deletion_log_and_loss_report.txt`). Değişiklik P7 kurulumuyla birlikte, onun ayrı onayıyla yapılır
(ayrıntı: `docs/kodhane-retention-runbook.md`, "Kayıp bildir adımı"). Bu iş kapsamında kurulmadı.
Hesap silme iki modda da bildirimleri siler (`docs/kodhane-account-delete-runbook.md`).

## Geri alma
```bash
psql "$DB_URL" -X -At -c "select * from kodhane_loss.loss_report_queue('all')" > kayip-bildir-$(date +%Y%m%d-%H%M).txt   # önce listele
KODHANE_ALLOW_LOSS_REPORT_LOSS=on KODHANE_LIVE_APPROVAL='Aryen, <tarih saat>' supabase/ops/kodhane_loss_report_install.sh rollback
# (betik olmadan: PGOPTIONS='-c kodhane.loss_report_allow_loss=on' psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/rollback/20261003060000_v4_5_kodhane_loss_report.rollback.sql)
```
- Dokploy komutu kayıp bildir sürümüne geçtiyse önce eski komuta dönülür. Dönülmezse 6. adım `skipped` yazar ve iş durmaz.
- Bildirim varken `allow_loss` olmadan durur.
- Uygulanmış geri yüklemeleri geri almaz. Kayıt, `manual` yedek ve günlükteki `telafi` satırları kalır.
- B, kazanç günlüğü ve silme listesi etkilenmez.
- Hesap silme tablo olmadan eski davranışla çalışır.
