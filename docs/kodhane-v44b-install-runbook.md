# Kodhane v4.4: paket B + kazanç günlüğü canlı kurulum runbook'u

**B canlıya `v4.4-backend` (`be96e03` ya da bu işten sonraki B-uyumlu HEAD) checkout'undan kurulur, `v4.5-kayip-bildir` dalından değil.**
(`v4.5-kayip-bildir` hesap silme dosyalarını değiştirir; orada `v44b_install/inputs.md5` tutmaz ve `build` durur.)

Kurulacaklar: paket B (`20260929204000_v4_4b_kodhane_stage_ids_version_guard.sql`: aşama kimlikleri, `kodhane_leaderboard_v7`,
sürüm koruması PT426, `kodhane_score_plausible` v4.4b) ve kazanç günlüğü (`20261003020000_v4_4_kodhane_progress_log.sql`).
İkisi **tek transaction'da** kurulur. Paket A (`969e1dc2…`) 2026-10-01 20:39 TSİ'den beri canlıda.

**Bu belge kurulum yetkisi değildir.** Zamanı YY belirler. Canlı adımlar (backup, install, rollback, restore, silme testi)
Aryen'in o adım için verdiği yazılı onayla koşulur; onay metni `KODHANE_LIVE_APPROVAL` değişkenine yazılır.

## Paket

| Dosya | İş |
|---|---|
| `supabase/ops/kodhane_v44b_install.sh` | Adım betiği: `build`, `backup`, `preflight`, `dryrun`, `install`, `verify`, `delete-path-check`, `rollback`, `restore` |
| `supabase/ops/v44b_install/*.sql` | Betiğin SQL parçaları; md5'leri `v44b_install/inputs.md5` dosyasında (migration'lar, rollback'ler, hesap silme dosyaları dahil). `build` farkta durur |
| `supabase/ops/kodhane_v44b_delete_test.sh` + `v44b_delete_test/*.sql` | İsteğe bağlı canlı silme testi. Kurulumdan **ayrı**, ayrı onay ister |
| `supabase/tests/v44b_install/run_v44b_install_rehearsal.sh` | .136'da tam prova (canlıya asla yönlendirilmez) |

Canlı hedef A'daki yolun aynısıdır. Portainer exec kullanılır, container `infrastructure-supabase-eqbmlp-db-1`, psql
`-h localhost -U supabase_admin -d postgres`. Dosyalar `/workspace/kodhane-cloud/pexec.sh` ile koşar. Her dosyanın container'a
bozulmadan ulaştığı önce `penv_md5.py` ile doğrulanır; uyuşmazlıkta betik durur. Yedek `pdump_env.py` ile alınır (`pg_dump -Fc`).
Token yalnızca ortamdan okunur (`PORTAINER_API_TOKEN`), hiçbir yere yazdırılmaz.

```bash
cd /workspace/kodhane-v44-backend
export KODHANE_TARGET=live KODHANE_OUT=/workspace/v44b-live/install-$(date +%Y%m%d-%H%M)
# PORTAINER_API_TOKEN: A kurulumundaki gibi sb_env.sh ile export edilir, ekrana basılmaz
```

## Zamanlama ve istemci push'u

Sıra:
1. Fikibok01 mesajı gider.
2. Aynı gün Frontend `clientVersion` push'u (v4.4.2) yapılır.
3. Ardından bu kurulum yapılır.

**Öneri: istemci push'u B'den hemen önce yapılsın.** Push'un yayında olduğu görüldükten sonra B kurulsun; ikisinin arası
30–60 dk olabilir.
- **B'siz `clientVersion` zararsız.** A bu alanı okumaz; .136 provasında R0b ile sınandı: alan olsa da olmasa da her kayıtta
  aynı sonuç çıktı. v4.4 istemcisi `kodhane_leaderboard_v7` yoksa 404 alır ve v6'ya düşer; bu istemci sözleşmesi ve testi
  (`tests/test_cloud.py`) içinde.
- **Günlük ilk yazmadan itibaren doğru istemci sürümünü görür.** Push B'den sonra olursa aradaki yazmalar `saveVersion 5`
  diye düşer, gerçek istemci sürümü görünmez. Telafi incelemesi tam bu bilgiye dayanır.
- **PT426 açısından sıra fark etmez.** Koruma yalnız saklı `saveVersion >= 5` olan hesapta, daha düşük sürümlü yazmayı
  reddeder. v4.4.0, v4.4.1 ve v4.4.2'nin hepsi 5 yazar; aralarında ret olmaz. Reddedilen tek şey v4.3.x sekmeleridir.
  Onlar zaten "Sayfayı yenile" bandını görür; B'yi beklemek onları korumaz.
- **Push'un ulaştığı preflight'ta görülür.** `INFO|client_versions_seen` satırında `4.4.2` sayısı artmaya başlar
  (yalnızca sayı; kimlik yazılmaz).
- B'den sonra push yapılırsa da güvenlidir; yalnızca aradaki günlük satırları istemci sürümü bilgisinden yoksun kalır.

## Adımlar (canlı)

Her adım `$KODHANE_OUT` içine `<adım>.out` yazar, `times.txt` dosyasına TSİ zamanını ekler. 0 dışında bir çıkış kodu
**STOP** demektir: dur, çıktıyı oku, devam etme.

| # | Komut | Ne yapar | Beklenen |
|---|---|---|---|
| 0 | `bash supabase/ops/kodhane_v44b_install.sh build` | `inputs.md5` kontrolü; preflight, dryrun, install, rollback, rollback_allow_loss ve delete_path_check SQL'lerini üretir, `sql.md5` yazar | `BUILD\|PASS` |
| 1 | `KODHANE_LIVE_APPROVAL='…' … backup` | Tam yedek: `pg_dump -Fc` → `/home/box/agent-data/backups/kodhane-shared-YYYYMMDD-HHMM.dump` (600) + `.md5` (600). `pg_restore -l` ile TOC'taki TABLE sayısı veritabanındaki tablo sayısına eşit olmalı (eklenti tabloları hariç); `kodhane_saves` verisi dump'ta olmalı | `BACKUP\|PASS` |
| 2 | `… preflight` | SALT OKUNUR. Bkz. "Preflight" | `PREFLIGHT\|PASS` |
| 3 | `… dryrun` | B, sonra günlük; tek transaction'da kurulur, kontroller yapılır, **ROLLBACK** edilir. Yeni ya da değişen nesneler `objects_new_or_changed.diff` dosyasına yazılır | `DRYRUN\|PASS` |
| 4 | `KODHANE_LIVE_APPROVAL='…' … install` | Dryrun'un aynı SQL gövdesi, sonunda **COMMIT**. Backup, preflight ve dryrun PASS değilse ya da `sql.md5` değiştiyse başlamaz | `INSTALL\|PASS`, `objects install = dry-run: MATCH` |
| 5 | `… verify` | Sentetik oyuncuyla tek transaction, **ROLLBACK** | `VERIFY\|PASS`, `objects verify = dry-run: MATCH` |
| 6 | `… delete-path-check` | SALT OKUNUR. Silme yolu günlüğü kaldırıyor mu (bkz. "Silme yolu") | `DELPATH\|PASS` |
| 7 | Dokploy saklama komutu | Bkz. "Saklama görevi" | — |

Install transaction'ının içeriği:
- `lock_timeout 5s`: B'nin `ALTER TABLE` kilidi oyuncu yazmalarını uzun süre bekletmez. Kilit alınamazsa hata verir,
  hiçbir şey değişmez, adım yeniden denenir. .136'da N4 ile sınandı.
- `statement_timeout 120s`.
- A md5 kontrolü (transaction'ın ilk ifadesi).
- Her iki oyunun leaderboard'ı ve her kaydın `kodhane_score_plausible` sonucu **kurulumdan önce** tutulur.
- B migration'ı, ardından günlük migration'ı (kendi `begin;` ve `commit;` satırları çıkarılmış hâliyle) uygulanır.
- `notify pgrst`.
- Kontroller: leaderboard'lar aynı mı, v7 = v6 mı, A ile v4.4b her kayıtta aynı sonucu veriyor mu, yapı kontrolleri.
  Herhangi biri tutmazsa exception atılır, **hiçbir şey kurulmaz**.
- Nesne md5'leri.

**Sıra B → günlük.** İkisi arasında bağımlılık yoktur; günlük yalnızca v2.2'ye ihtiyaç duyar. B önce gelir, çünkü
`kodhane_score_plausible` v4.4b ve sürüm koruması kurulduğunda günlüğün ilk satırları zaten B kuralından geçmiş yazmalar
olur. Rollback'te sıra tersine döner (günlük → B). Tek transaction olduğu için ara durum hiçbir oturuma görünmez.

## Preflight (salt okunur, `begin read only`)

STOP koşulları (biri bile varsa `STOP: …`, çıkış 1):
- Bağlı kullanıcı `supabase_admin` değil.
- Hedef veritabanı yanlış (`kodhane_saves`, `kodhane_leaderboard(integer,text)`, `auth.users`, `kodhane_save_backups` yok)
  ya da v2.2 kurulu değil.
- `md5(pg_get_functiondef(kodhane_score_plausible))` ≠ `969e1dc203fa1877a57e2cf3fcc2727c`.
- B'nin herhangi bir parçası (v7, guard, stage-id, `stage_rank`, `best_stage_id`) ya da günlüğün herhangi bir parçası
  (tablo, yazma fonksiyonu, temizlik fonksiyonu) zaten kurulu.
- `kodhane_saves` üzerinde yalnızca v2.2'nin iki tetikleyicisi yok; başka bir tetikleyici var.
- `auth.users` üzerinde tetikleyici var. Verify adımı sentetik kullanıcı ekler; o tetikleyici çalışırdı.
- Sentetik kullanıcı id'si (`b44b0000-…-c0de`) kullanılıyor.
- Saklı `saveVersion > 5` olan kayıt var. B, bu hesabın v4.4 (sv 5) yazmalarını PT426 ile reddederdi.
- 5 dakikadan uzun süredir `idle in transaction` duran bir oturum var.

**Bilgi notu (sayılar; kimlik, takma ad ve e-posta yazılmaz):** `INFO|saves_by_stored_format|<biçim>|toplam|son 1 gün|son 7 gün|etki`

| Saklı biçim | B kurulduktan sonra |
|---|---|
| `sv>=5` (v4.4 kaydı) | Eski istemci (v4.3.1 sv 4, v4.3.0 sv yok) bu hesaba **yazamaz** (PT426, "Sayfayı yenile" bandı); v4.4 istemcisi yazar |
| `sv1-4` (biçim 4) | Korunmaz; her istemci yazar. Hesap v4.4 ile bir kez kaydedince `sv>=5` satırına geçer |
| `no_sv` (en eski biçim) | Korunmaz; her istemci yazar. Hesap v4.4 ile bir kez kaydedince korumaya girer |

Not: "sv<5 ya da eski biçim" kayıtlarının sahipleri B'den sonra eski istemciyle **yazmaya devam eder**. Eski istemciyle
yazamayacak olanlar `sv>=5` satırındaki hesaplardır, yani bir kez v4.4 ile kaydetmiş olanlar. Sayı ve son 1/7 gün
etkinliği, "Sayfayı yenile" bandını kaç oyuncunun görebileceğini gösterir.

Diğer INFO satırları:
- `saves_columns`: `clientVersion` ve `stageId` taşıyan kayıt sayıları.
- `client_versions_seen`: sürüm başına kayıt sayısı.
- `other_objects`: saklama fonksiyonu, Açık Ofis, pg_cron.
- `sessions_on_db`.
- `LB|kodhane|n|md5` ve `LB|acik_ofis|n|md5`.

## Verify (transaction içinde, sonunda ROLLBACK)

Sentetik kullanıcı `b44b0000-0000-4000-8000-00000000c0de` kullanılır. Profili yoktur, bu yüzden hiçbir listede görünmez.
Yazmalar PostgREST'in yaptığı upsert ile, `authenticated` rolüyle yapılır:

| Kontrol | Beklenen |
|---|---|
| verify_1 | v4.4 istemcisinin ilk yazması (`clientVersion`, sv 5): kabul |
| verify_2, verify_3 | v4.3.1 (sv 4) ve v4.3.0 (sv yok) yazması: **PT426 `save_version_too_old`** |
| verify_4 | v4.4 istemcisinin sonraki yazması: kabul |
| verify_5, verify_6 | v7 / v6 Kodhane / v6 Açık Ofis leaderboard'ları `authenticated` ve `anon` rolüyle hatasız |
| verify_7 | Günlükte kabul edilen iki yazmanın satırları var (`client_version` = gönderilen değer, ağaç düğümü satırı dahil); reddedilen yazmaların satırı yok |
| verify_8 | Kayıt revision 2, sv 5; `best_stage_id` dolu (B tetikleyicisi) |
| verify_9 | Sentetik yazmalar leaderboard'u değiştirmedi |
| verify_10 | Kodhane leaderboard'u install adımındaki md5 ile aynı |
| verify_11 | Gerçek kullanıcıların kayıt, yedek, günlük ve profil satırları dokunulmamış |
| verify_12 | Hesap silme K3b adımının DELETE'i (iki modda da çalışır) sentetik oyuncunun günlük satırlarını 0'a indirir, başkalarınınkine dokunmaz. Alt transaction'da, geri alınır |
| verify_13 | `auth.users` silmesi (`mode=full` son adımı ya da GoTrue admin silmesi): FK `ON DELETE CASCADE` günlük satırlarını götürür, başkalarınınkine dokunmaz. Alt transaction'da, geri alınır |
| verify_14 | İki deneme gerçekten geri alındı: sentetik oyuncunun satırları yerinde |
| OBJ | Fonksiyon, tetikleyici, kolon ve kısıt md5'leri dryrun ile birebir aynı |

`verify_12`–`verify_14`, 43b9670'ın açık maddesini (EKSİK 4) B günü canlıda kapatır: hesap silmenin iki modda da kazanç günlüğünü sildiği,
yalnız katalogdan (`delete-path-check`) değil, canlı DB'de **davranışla** gösterilir. Hiçbir gerçek hesap silinmez: sentetik kullanıcı
aynı transaction'da oluşturulur, her silme kendi alt transaction'ında geri alınır, verify'ın tamamı ROLLBACK ile biter.
Silme betiğinin dosyası (md5 + K3b satırı) `delete-path-check`'te denetlenir. Gerçek bir hesapla uçtan uca deneme isteğe bağlı "canlı silme testi"dir.
`VERIFY|PASS|15 checks` beklenir.

Kurulumdan önceki ve sonraki sıralamanın aynı olduğu, install transaction'ının **içinde**, aynı `now()` ile kanıtlanır.
`verify_10` sonradan alınan bir ölçümdür. Tek başına `f` çıkarsa iki olası neden vardır: arada oyuncu yazmıştır ya da
zamana bağlı kural ilerlemiştir. Bu durumda geri dönüş kararı verilmez. Önce `verify` yeniden koşulur, gerekirse listeler
karşılaştırılır. Kurulumdan kalan tek iz, günlük tablosunun kimlik sayacının birkaç sayı ilerlemesidir.

## Silme yolu (`delete-path-check`, salt okunur, kurulumdan sonra)

- **delpath_1:** `kodhane_progress_log.user_id` → `auth.users(id)` `ON DELETE CASCADE` (`confdeltype = 'c'`). `auth.users`
  satırının her silinişi oyuncunun günlüğünü de götürür: GoTrue admin silmesi de, `kodhane_account_delete.sql`
  `mode=full` da.
- **delpath_2:** Tabloda başka FK yok.
- **delpath_3:** Günlük tetikleyicisi yalnızca INSERT/UPDATE'te çalışır.
- **delpath_4:** Tablonun tetikleyicisi ve politikası yok; anon ve authenticated okuyamaz, silemez.
- **delpath_5:** `auth.users` silen bir DB fonksiyonu yok. Hesap silme bir ops dosyasıdır, DB fonksiyonu değildir.
- **delpath_6:** Günlükten satır silen tek fonksiyon `kodhane_cleanup_progress_log` (saklama süresi);
  `kodhane_reset_save` / `kodhane_restore_save` günlüğe dokunmaz.
- **delpath_file_md5 ve delpath_file_stmt:** `ops/kodhane_account_delete.sql` ve `_verify.sql` incelenmiş md5'te
  (`inputs.md5`). K3b adımı (`delete from public.kodhane_progress_log where user_id = $1`), mod dalından önce yer aldığı için
  **iki modda da** çalışır.
- İlgili fonksiyonlar ve `auth.users`'a giden tüm public FK'ler INFO satırlarında listelenir.

Uygulama yolları (.136'da sınandı, bkz. D2–D4):
- **"Kaydı sıfırla"** (`kodhane_reset_save`) günlüğü silmez; `sifirlama` satırı ekler.
- **Geri yükleme** (`kodhane_restore_save`) `geri_yukleme` satırı ekler.
- Oyuncunun `kodhane_saves` DELETE yetkisi yoktur (v2.2). Yöneticinin bir kayıt satırını silmesi günlüğü bırakır; günlük
  yalnızca hesap silmeyle gider.

## Saklama görevi (Dokploy)

- **Ana komut** (`kodhane_retention_dokploy_command.txt`) günlüğe dokunmaz; B'den önce ve sonra aynen çalışır.
- **`_with_progress_log` komutu** `kodhane_cleanup_progress_log(365, 5000)` çağırır. **Yalnızca bu kurulum PASS olduktan
  sonra** Dokploy'da ana komutun yerine konur. Fonksiyon yokken çalışırsa son adım hata verir ve çıkış 1 olur (saklama
  testleri J8, J9). Önceki adımlar yine de commit edilmiş olur.
- Mevcut tasarım bu kurala uyar: `kodhane_retention_daily.sh` fonksiyon yoksa "progress log skipped" yazar ve 0 ile çıkar.
- **Rollback'ten önce** Dokploy komutu ana komuta geri alınır.

## Geri dönüş

### Yol 1: rollback SQL'leri (önce bu)

```bash
KODHANE_LIVE_APPROVAL='…' bash supabase/ops/kodhane_v44b_install.sh rollback
```

- Tek transaction: günlük rollback'i, ardından B rollback'i (A'ya dönüş).
- Sonunda kontrol: A md5'i `969e1dc203fa1877a57e2cf3fcc2727c`, B ve günlük nesneleri yok, `kodhane_saves` üzerinde yalnızca
  v2.2'nin iki tetikleyicisi var. Tutmazsa her şey geri alınır.
- **Veri kaybı koruması:** Günlükte satır varsa rollback reddedilir ve hiçbir şey değişmez. Kaybı kabul etmek için
  `KODHANE_ALLOW_PROGRESS_LOG_LOSS=on` verilir; bu, ayrı ve açık bir onaydır. Günlükteki satırlar gider.
- B rollback'i `best_stage_id`'yi düşürür; Unicorn / Şirketler Grubu ayrımı kaybolur. Kayıtların kendisine ve
  `best_score` / `best_stage` değerlerine dokunulmaz (B6).
- Satırları korumanın yolu, rollback yapmadan yalnızca tetikleyicileri kapatmaktır:
  - `alter table public.kodhane_saves disable trigger kodhane_saves_z_progress_log;` (günlük)
  - `… disable trigger kodhane_saves_a_version_guard;` (PT426)

### Yol 2: yedekten tam geri yükleme (son çare)

**Önce API'yi durdur** (GoTrue, PostgREST; Dokploy). Böylece geri yükleme sırasında yeni silme ya da yazma olmaz.

```bash
KODHANE_LIVE_APPROVAL='…' KODHANE_RESTORE_CONFIRM=kodhane-shared-YYYYMMDD-HHMM.dump \
  bash supabase/ops/kodhane_v44b_install.sh restore /home/box/agent-data/backups/kodhane-shared-YYYYMMDD-HHMM.dump
```

- **Yedekten sonraki her yazma kaybolur:** iki oyunun kayıtları, yeni hesaplar, oturumlar, auth audit kayıtları. Yol 1
  çalışmazsa ya da veri bozulduysa kullanılır.
- Yöntem:
  1. Dosyanın md5'i kontrol edilir.
  2. `pg_restore --clean --if-exists` SQL'e çevrilir.
  3. Başına `full_restore_prelude.sql` eklenir.
  4. Tamamı tek transaction'da `psql` ile koşar. Hata olursa hiçbir şey değişmez.
- **Silme listesi** (migration `20261003040000`, B'den ayrı kurulum; `docs/kodhane-account-delete-runbook.md` "Silme listesi"):
  - **0. Mevcut DB'den son liste (geri yüklemeden önce).** `restore`, önce `kodhane_deletion_log_export.sh` çalıştırır ve dosyayı
    `KODHANE_DL_DIR` dizinine yazar (canlıda `/home/box/agent-data/backups/kodhane-deletion-log/`).
    - Liste kurulu değilse "nothing to export" yazar ve devam eder.
    - Dışa aktarım başka bir nedenle başarısız olursa **geri yükleme yapılmaz**.
    - Mevcut DB okunamıyorsa `KODHANE_RESTORE_WITHOUT_DELETION_LOG_EXPORT=on` ile var olan dosyalarla devam edilir. Pencere için hesap silme runbook'undaki "Kalan risk penceresi" bölümüne bak.
  - **5. Geri yüklemeden sonra:** dizinde dışa aktarım dosyası varsa `kodhane_deletion_log_reapply.sh reapply` (tek transaction,
    idempotent) ve `verify` çalışır. Beklenen çıktı `RESTORE|DELETION_LOG|PASS` ve `VERIFY|PASS|0 left`.
    - Bozuk ya da md5'i tutmayan bir dosya reapply'ı durdurur.
    - Yedek liste migration'ından eskiyse reapply durur. Önce `kodhane_deletion_log_install.sh`, sonra reapply ve verify elle çalıştırılır.
    - Geri yükleme bu durumlarda commit edilmiş olur ve STOP mesajı bunu söyler.
  - Ardından API açılır.
- Prelude neden gerekli? Düz `pg_restore --clean`, Supabase'in `ALTER DEFAULT PRIVILEGES` ayarları yüzünden yeniden kurulan
  nesnelere fazladan GRANT ekler. .136'da 24 GRANT satırı çıktı (B kuruluyken 92); örneğin `acik_ofis_cleanup_save_backups()` anon'a açıldı (F3).
  Prelude bu varsayılanları geçici olarak kaldırır, dump'ın sonundaki varsayılan yetki satırları onları yedekteki hâline
  geri koyar. Ayrıca B ve günlük nesnelerini düşürür; aksi hâlde `--clean` onları bırakır, günlüğün FK'si de `auth.users`'ın
  yeniden kurulmasını engeller.
- .136'da (F5–F8): B ve günlük kuruluyken, üstelik bir oyuncu yazmasından sonra yapılan geri yüklemede şema ve veri, yedek
  anındaki hâlle birebir aynı çıktı. Ardından preflight PASS verdi.
- Canlı yol dosyayı Portainer archive API ile container'a yükler. Bu yol **Portainer'a karşı prova edilmedi**; .136'da
  aynı SQL `docker exec` ile koştu. Gerekirse önce zararsız bir dosyayla yükleme denenir.
- Alternatif: yedek yeni bir veritabanına geri yüklenir (F1, F2: birebir aynı) ve gereken satırlar oradan elle alınır.
- **Son adım (API açılmadan önce): yedek zamanından sonraki silme talepleri (destek e-postası ve uygulama logu) kontrol edilip elle yeniden silinir.**
  Silme listesi yalnız listeye yazılmış (kurulu olduğu dönemde betikle yapılmış) silmeleri geri getirir. Liste kurulmadan önce yapılan,
  dışa aktarımdan sonra yapılan ya da henüz uygulanmamış talepler bu kontrolle yakalanır. Her biri `docs/kodhane-account-delete-runbook.md`
  adımlarıyla, Aryen'in o talep için onayıyla, yeniden silinir.

## Ek: canlı silme testi (isteğe bağlı, ayrı onay; kurulum buna bağlı değil)

```bash
export KODHANE_TARGET=live KODHANE_OUT=/workspace/v44b-live/deltest-$(date +%Y%m%d-%H%M)
KODHANE_LIVE_APPROVAL='…' bash supabase/ops/kodhane_v44b_delete_test.sh create   # kodhane-deltest-YYYYMMDD-HHMMSS@example.invalid
KODHANE_LIVE_APPROVAL='…' bash supabase/ops/kodhane_v44b_delete_test.sh write    # 2 yazma; günlükte satır görünmeli
KODHANE_LIVE_APPROVAL='…' bash supabase/ops/kodhane_v44b_delete_test.sh delete   # preflight → mode=full → verify → 0 satır
```

- Hesap doğrudan SQL ile açılır: parolası, kimliği ve profili yoktur, giriş yapamaz, listede görünmez. Hesabın id'si,
  e-postası ve `created_at` değeri `testuser.txt` dosyasına kaydedilir.
- **Gerçek oyuncu koruması:** `write` ve `delete`, `guard.sql` ile başlar. Şunların hepsi tutmazsa STOP der, hiçbir şey
  yapmaz:
  - Aynı id.
  - E-posta `^kodhane-deltest-[0-9]{8}-[0-9]{6}@example\.invalid$` desenine uyuyor **ve** kaydedilenle aynı.
  - `created_at` kaydedilen anla mikro saniyesine kadar aynı.
  - Hiç giriş yok; identity, profil ve Açık Ofis verisi yok.
- Silme, gerçek hesap silme betikleriyle yapılır (`kodhane_account_delete_preflight.sql` → `kodhane_account_delete.sql`
  `mode=full`, `approval_ref=KD-DELTEST-YYYYMMDD` → `_verify.sql`).
- Ardından uid için kalan satırlar sayılır: günlük, kayıt, yedek, `auth.users` ve `auth.audit_log_entries` (payload'da uid).
  Hepsi 0 olmalı.
- Başka kullanıcıların silmeden önce var olan günlük satırları yerinde kalmalı.
- Doğrudan SQL ile açılan hesabın audit kaydı olmaz; olsaydı da `mode=full` onları siler.
- Silme listesi kuruluysa test hesabının uid'si de listeye yazılır (`scope account`, `info:KD-DELTEST-…`). Bu zararsızdır ve 45 günde temizlenir.

## Prova (.136, `public.ecr.aws/supabase/postgres:17.6.1.136`)

`RH_CT=v44x-136 bash supabase/tests/v44b_install/run_v44b_install_rehearsal.sh`

Prova veritabanı şunlardan kurulur:
- Canlı şema dökümü.
- A (md5 `969e1dc2…`).
- Takma adlı canlı kopyası (7 kullanıcı).
- `seed_extra.sql`: her saklı biçimden birer oyuncu (v4.4.2, v4.4.0, v4.3.1, v4.3.0 ve olanaksız bir kayıt).

Sonuçlar: `supabase/tests/v4_4/results/kodhane_v44b_install_rehearsal_pg17.6.1.136.txt`.

| Bölüm | Sonuç |
|---|---|
| 0. Prova veritabanı | R0: A md5 = canlı; R0b: A `clientVersion` alanını yok sayar |
| 1. build, backup, preflight, dryrun, install, verify | S1–S6c: hepsi PASS. Dryrun sonrası şema ve veri aynı. Install veri yazmadı. Verify 12/12, sonrasında iz yok |
| 2. Kurulumdan sonra oyuncular | P1: sv 5 kayda v4.3.1 yazması → PT426. P2: sv 4 kayda v4.3.1 → kabul. P3: v4.4.2 → kabul. P4: günlükte yalnızca kabul edilen yazmalar |
| 3. Korumalar | G1: kurulu veritabanında preflight STOP. G2: install.sql elle yeniden koşulunca transaction içinde STOP, şema aynı |
| 4. Rollback | B1: günlükte satır varken red, değişiklik yok. B2: onayla PASS. B3–B4: şema ve nesneler kurulum öncesiyle aynı. B5–B6: veri korunur |
| 5. İkinci tam koşu | Rollback'ten sonra tekrar PASS; fonksiyon md5'leri 1. koşuyla aynı |
| 5b. Silme | D1 `delete-path-check` PASS. D2 sıfırlama günlüğü silmez. D3 kayıt satırı silmek günlüğü silmez. D4 `kodhane_only` ve `full`: uid 0 satır, diğerleri aynı. T1–T7 silme testi (korumalar dahil) |
| 6. Tam geri yükleme | F1–F2: yeni veritabanına birebir. F3: düz `--clean` fazladan GRANT ekler. F4–F8: `restore` adımı yerinde, şema ve veri yedek anıyla aynı |
| 7. Diğer durumlar | N1: A yoksa STOP. N2: sv 6 kayıt STOP. N4: kilit varken 5 sn sonra vazgeçer, değişiklik yok. N5: kilit kalkınca PASS |

Prova 2026-10-03 03:29–03:31 TSİ: **62/62 PASS**. 2026-10-03 17:30 TSİ (verify_12–14 ile): **63/63 PASS**, `install.sql` md5 değişmedi (`deefef0e…`).

Dryrun'da 41 nesne satırı yeni ya da değişti; 1 satır yerini v4.4b'ye bıraktı. Yeni ya da değişen fonksiyonların
`md5(pg_get_functiondef)` değerleri:

| Fonksiyon | md5 |
|---|---|
| `kodhane_score_plausible(jsonb,timestamptz)` v4.4b | `463f2109c35b825827e57b8098b49947` (A: `969e1dc2…`) |
| `kodhane_leaderboard_v7(integer)` | `f555378d3cf4d133f613a183d579215e` |
| `kodhane_save_version_guard()` | `2f53fdfdfa3983cd536cccfd9d7a2105` |
| `kodhane_save_v44_stage_id()` | `d7572e2676d35d0182e545e8cf92846c` |
| `kodhane_progress_log_write()` | `6388d5cfd5a57dd3a68d26d23a0649b1` |
| `kodhane_cleanup_progress_log(integer,integer)` | `71a9ecfb074cfaeea8c6fcd33f6ff5ce` |
| `kodhane_save_format_version` / `_stage_id_checked` / `_vetted_stage_id` | `90c502e1…` / `f2707a85…` / `a3657004…` |
| `kodhane_stage_rank` / `_at` / `_id_max` / `_legacy_id` | `e97a3589…` / `b0aa4d9e…` / `55dd5449…` / `8af1b39b…` |

`build` çıktısında üretilen SQL'lerin md5'leri:

| Dosya | md5 |
|---|---|
| `preflight.sql` | `d0cda242…` |
| `dryrun.sql` | `55077b7b…` |
| `install.sql` | `deefef0e5c52cc3679dc997374d2edbb` |
| `rollback.sql` | `80c67a9b…` |
| `rollback_allow_loss.sql` | `9494bc26…` |
| `delete_path_check.sql` | `a66e5ae0…` |

Canlıda `build` aynı md5'leri vermelidir; vermiyorsa girdiler değişmiştir.
