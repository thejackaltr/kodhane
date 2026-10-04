# Kodhane: kazanç günlüğü (`kodhane_progress_log`) runbook'u

Kapsam: `plans/kodhane-telafi-otomasyon-kapsam.md` 1. adım. Telafi botu (adım 2–3) kimin ne kazandığını bu tablodan okuyacak.
Günlük başladığı andan geçerlidir; öncesi için yalnız `kodhane_save_backups` var.

**Canlı kurulum ayrı onaya bağlıdır.** B ile aynı pakette girer; Aryen'in yazılı onayı olmadan migration uygulanmaz.

## Dosyalar
- `supabase/migrations/20261003020000_v4_4_kodhane_progress_log.sql`: tablo, tetikleyici, temizlik fonksiyonu. Kendi transaction'ı var (`-1` yok).
  Yalnız Kodhane v2.2'ye bağlı; A ya da B olmadan da kurulur. Yanlış veritabanında (tablolar yok) durur. İki kez çalıştırılabilir.
- `supabase/rollback/20261003020000_v4_4_kodhane_progress_log.rollback.sql`: hepsini kaldırır; tabloda satır varsa
  `kodhane.progress_log_allow_loss=on` olmadan durur.
- Testler: `supabase/tests/progress_log/run_kodhane_progress_log_tests.sh` (`PL_CT=<container>`), hesap silme L-* testleri
  `supabase/tests/account_delete/run_kodhane_account_delete_tests.sh` içinde. Yalnız yerel container'da.

## Kurulum sırası (öneri)
A (canlıda) → B → günlük, aynı pencerede. Günlük B'ye bağlı değil; B'den önce kurulursa da çalışır (testte A tek başına + günlük
varyantı). B önce kurulursa B'nin reddettiği yazmalar zaten hiç günlüğe gelmez.
```bash
psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/migrations/20261003020000_v4_4_kodhane_progress_log.sql
```
Kurulum kontrolü: tablo sahibi `postgres`, RLS açık, politika yok; tetikleyici `kodhane_saves_z_progress_log` etkin; ACL'ler
aşağıdaki gibi (test M3–M5, P1–P4).

## Tablo
| Kolon | Anlamı |
|---|---|
| `id` | bigint identity |
| `user_id` | `auth.users(id)`, `on delete cascade` |
| `rev_before`, `rev_after` | `kodhane_saves.revision` yazmadan önce / sonra (ilk kayıtta `rev_before` boş) |
| `client_version` | kayıtta `clientVersion` (B ile istemci yazacak) 1–32 karakter `^[0-9A-Za-z._-]+$` ise o; alan yok ya da JSON `null` ise `saveVersion <n>` (`saveVersion`, yoksa `version`, yoksa `save_version` kolonu); başka her değer (uzun, boşluk/özel karakter, sayı, dizi) boş (test F8, F8b) |
| `event` | `yatirim_turu`, `halka_arz`, `borsa_payi`, `agac`, `telafi`, `sifirlama`, `geri_yukleme` |
| `field` | `shares`, `prestigeCount`, `cycleRounds`, `ipoCount`, `ipoShares`, `ipoSharesEarned`, `tree` |
| `old_value`, `new_value` | numeric; boş = alan yok ya da sayı değil. `tree` için düğüm sayısı (önce / sonra) |
| `node_id` | yalnız `tree`: eklenen ya da çıkan düğüm kimliği (ör. `kod_1`) |
| `actor_role` | yazanın rolü: `authenticated` (oyuncu), `service_role`, `postgres`, `supabase_admin` |
| `created_at` | `now()` (yazmanın transaction zamanı) |
| `approval_ref` | yalnız `telafi`: onay referansı `KD-TLF-YYYY-MM-DD-NN` (`kodhane.progress_ref`); diğer olaylarda boş. Tablo kısıtı: `telafi` ⇔ referans var, biçim geçerli (E16, E17) |

E-posta, takma ad, kayıt içeriğinin geri kalanı yok. Miktar = `new_value - old_value`, sonrası toplam = `new_value`.

## JSON yolları (hepsi `kodhane_saves.data` kökünde)
| Alan | Kaynak | Olay |
|---|---|---|
| `shares` (Yatırım Turu hissesi) | `kodhane_score_plausible` v4.4a (`r.num ->> 'shares'`), game.js `newState` / `KEEP_ON_PRESTIGE` | `yatirim_turu` |
| `prestigeCount` (Yatırım Turu sayısı) | `kodhane_score_plausible` (`prestigeCount`) | `yatirim_turu` |
| `cycleRounds` (bu döngünün turları; Halka Arz'da 0'a döner) | `kodhane_score_plausible` (`cycleRounds`) | `yatirim_turu` |
| `ipoCount` (Halka Arz sayısı) | `kodhane_score_plausible` (`ipoCount`) | `halka_arz` |
| `ipoSharesEarned` (kazanılan toplam Borsa Payı, harcansa da sayılır) | `kodhane_score_plausible` (`ipoSharesEarned`), game.js `doIpo` | `borsa_payi` |
| `ipoShares` (harcanabilir Borsa Payı) | game.js `doIpo` (+), `buyNode` (−); sunucu fonksiyonları okumaz | `borsa_payi` |
| `tree` (Borsa Payı Ağacı: düğüm kimlikleri dizisi) | game.js `buyNode(id)`: `S.ipoShares -= maliyet; S.tree.push(id)`; düğümler `kod_1..3`, `ekip_1..3`, `musteri_1..3`, `yatirim_1..3` | `agac` |

Kural: `coalesce(eski, 0) <> coalesce(yeni, 0)` ise satır yazılır (yok = 0). Azalmalar da yazılır (ör. `ipoCount` 2 → 0).
Değişmeyen alan satır üretmez; `data` aynıysa (yalnız `revision` / `updated_at`) hiç satır yok. İlk kayıtta 0 olmayan alanlar yazılır.

Ağaç: dizideki `^[a-z][a-z0-9]{0,19}_[0-9]{1,2}$` biçimli metinler, ilk 64 farklı kimlik, dizi sırasıyla. Eklenen her kimlik
için bir satır (`old_value`/`new_value` = düğüm sayısı), eski bir sekmenin üstüne yazması gibi durumlarda çıkan kimlikler de.
Bir `buyNode` = iki satır: `borsa_payi ipoShares 3→2` ve `agac tree 0→1 kod_1`. Sınırlar, bir istemcinin tek yazmayla binlerce
satır üretmesini engeller (test T5). Bilinen liste yerine biçim kontrolü: yeni düğümler migration gerektirmez.

## Olay türleri
Alan olayı yukarıdaki tablodan gelir. Üç durumda yazmanın **bütün** satırları tek olay türü alır:
- `telafi`: aşağıdaki işaret.
- `sifirlama`: `kodhane_reset_save()`. Aynı transaction'da bu revizyonun `reset` yedeği yazılmışsa (`created_at = now()`).
- `geri_yukleme`: `kodhane_restore_save()`, aynı kural, `restore` yedeği.

### Telafi işareti: nasıl ve neden
Telafi yazması, aynı transaction'da iki ayarla yapılır (işaret + onay referansı):
```sql
begin;
select set_config('kodhane.progress_event', 'telafi', true),                -- true = yalnız bu transaction
       set_config('kodhane.progress_ref', 'KD-TLF-2026-10-03-01', true);    -- Aryen'in onay referansı
update public.kodhane_saves set data = <telafi edilmiş kayıt>, revision = revision + 1, updated_at = now() where user_id = '<uid>';
commit;
```
Tetikleyici `telafi` der, ancak **iki koşul birlikte** sağlanırsa:
1. `kodhane.progress_event` tam olarak `telafi` (büyük/küçük harf, boşluk farkı kabul edilmez).
2. Yazanın rolü `postgres`, `supabase_admin` ya da `service_role`. Rol = `current_setting('role')`, yani PostgREST'in `SET ROLE`
   ettiği rol; yoksa oturum kullanıcısı.

**Onay referansı zorunlu.** İki koşul sağlanıyorsa `kodhane.progress_ref` şu biçimde olmalı: `KD-TLF-YYYY-MM-DD-NN`
(gerçek bir takvim günü, `NN` iki hane; ör. `KD-TLF-2026-10-03-01`). Referans yoksa ya da biçimsizse **kayıt yazmasının tamamı
reddedilir** (`22023`, `telafi write refused: kodhane.progress_ref must be an approval reference …`; testler E12, E13). Bu red
yutulmaz: telafi yönetici işidir, yönetici hatayı görür ve referansla yeniden dener. Referans her telafi satırının
`approval_ref` kolonuna yazılır (E1–E3, E11). İşaretsiz yazmada referans yok sayılır (E14). Oyuncu iki ayarı da koysa yazması
normal oyuncu yazması olarak kabul edilir, telafi sayılmaz, referans yazılmaz (E15).

Gerekçe:
- Ayar tek başına yetmez. Özel ayarları (`kodhane.*`) her rol kendi oturumunda değiştirebilir. Bu yüzden karar rol ile verilir.
- Oyuncu PostgREST üzerinden yalnız `authenticated` (ya da `anon`) olarak yazar. `SET` ya da `set_config` çalıştıramaz:
  PostgREST yalnız açık şemalardaki (public) fonksiyonları çağırtır, `pg_catalog.set_config` açık değil. Ayarı bir yolla
  koysa bile rol `authenticated` kalır ve olay normal alan olayı olur (test E5).
- Rol, SECURITY DEFINER bir fonksiyonun içinde de değişmez. Oyuncunun çağırdığı `kodhane_reset_save()` /
  `kodhane_restore_save()` sahibinin (`postgres`) yetkisiyle çalışır ama `current_setting('role')` hâlâ `authenticated`.
  Bu yüzden oyuncu, ayarı koyup bir RPC çağırarak da `telafi` yazdıramaz (test E7). `current_user` kullanılsaydı her
  SECURITY DEFINER çağrısı `postgres` görünürdü; bu yüzden kullanılmadı.
- `set_config(..., true)` transaction bitince kalkar; aynı oturumdaki sonraki yazma normal olur (test E11). Oturum boyu
  (`false`) kullanılmamalı.
- v4.5 geri yükleme fonksiyonu (onaylı telafi) `service_role` ile ya da SQL ile çağrılacak; iki ayarı da kendi içinde
  `set_config(..., true)` ile koyar (referans parametre olarak alınır).
- Ayarsız yönetici yazması `telafi` sayılmaz; alan olayı olur ama `actor_role` (`supabase_admin` / `postgres`) görünür (test E4).

## Hata olursa: yazma bozulmaz (hata yutma)
Karar: tetikleyicinin gövdesi `begin … exception when others` içinde. Günlük satırı yazılamazsa (kısıt, yetki, beklenmeyen veri)
**kayıt yazması başarılı olur**, günlük satırı(ları) yazılmaz ve sunucu günlüğüne şu uyarı düşer:
`WARNING: kodhane_progress_log: not logged for this save write (SQLSTATE …: …); the save write itself is kept`.

Gerekçe:
- Oyuncunun ilerlemesi günlükten önemlidir. Hata yutulmasaydı her kayıt yazması reddedilir, istemci yeniden dener, oyuncu
  ilerlemesini kaybederdi; günlükteki bir hata bütün oyunu durdururdu.
- Günlük ikincil veridir: kaybolan satırlar kayıt ve yedeklerle sonradan yaklaşık hesaplanabilir; kaybolan bir kayıt yazması
  hesaplanamaz.
- Yalnız günlük bloğu geri alınır (alt transaction); kayıt satırı ve diğer tetikleyiciler etkilenmez. Reddeden tetikleyiciler
  (v2.2 PT409, B PT426) **yutulmaz**: onlar `BEFORE` tetikleyicisidir ve bu bloğun dışında kalır (test X2).
- Bedeli: günlükte sessiz boşluk olabilir. Kontrol: Postgres günlüğünde `kodhane_progress_log: not logged` araması (Dokploy db
  servisi logları). Testler: X1 (CHECK hatası), X3 (yetki hatası), X4 (düzelince devam).
- **İstisna: telafi yazması.** Telafi yazmasında günlük satırı yazılamazsa hata yutulmaz, yazma reddedilir (test X5). Telafi
  yönetici işidir ve kaydı tutulsun diye yapılır; iz bırakmayan bir telafi istenmez.
- Acil kapatma (geri almadan): `ALTER TABLE public.kodhane_saves DISABLE TRIGGER kodhane_saves_z_progress_log;`

## B ile etkileşim
- B'nin reddettiği yazma (PT426 `save_version_too_old`) ve v2.2'nin reddettikleri (PT409 `stale_revision` / `stale_write`)
  günlüğe düşmez: `BEFORE` tetikleyicisi hata verince `AFTER` tetikleyicisi hiç çalışmaz (testler B1, B2, B4).
- Kabul edilen yazma düşer (B3). A tek başına kuruluyken aynı eski biçimli yazma kabul edilir ve `client_version = saveVersion 4`
  ile yazılır (varyant a, B2).

## Yetki
- RLS açık, politika yok. `anon`, `authenticated`, `PUBLIC`: tabloda hiçbir yetki yok (`revoke all`), kimlik dizisinde de yok.
  Yanlışlıkla `GRANT SELECT` verilse bile RLS oyuncuya 0 satır gösterir (test P7).
- **Oyuncu okuması kapalı** (YY kararı, 2026-10-03). Oyuncu kendi satırlarını v4.5'te bir RPC ile görecek (SECURITY DEFINER,
  yalnız `auth.uid()` satırları, seçili kolonlar); tabloya doğrudan politika eklenmeyecek.
- `service_role`: yalnız SELECT (bot okuyacak). Yazma yalnız tetikleyiciyle (sahibi `postgres`, SECURITY DEFINER, `search_path ''`).
- Temizlik fonksiyonu: EXECUTE yalnız `postgres` (sahip) ve `service_role`.

## Saklama: 365 gün (Aryen, 2026-10-03; denetim kaydıyla aynı, 12 ay)
`public.kodhane_cleanup_progress_log(p_retention_days integer default 365, p_batch_size integer default 5000) returns integer`
- `created_at < now() - p_retention_days gün` olan satırlardan en eskiler önce en fazla `p_batch_size` siler, sayıyı döndürür.
- Varsayılan süre 365 gün (C6); gece görevi yine açıkça `365, 5000` ile çağırır. `p_retention_days` 1–3650, `p_batch_size` 1–50000; dışındaysa 22023 ve hiçbir şey silinmez (C1).
- Tam sınırdaki satır kalır (C4). Partiler: C2.

**Gece görevi.** Saklama paketi bu migration'dan önce, tek başına kurulur (`kodhane_retention_dokploy_command.txt`, günlük adımı yok).
Bu migration canlıya girince Dokploy görevinin komutu `supabase/ops/kodhane_retention_dokploy_command_with_progress_log.txt` ile
değiştirilir: ilk komutun aynısı + sonda şu iki `-c` (tek tırnak, `$`, backtick yok; `sh -c` içinde güvenli; komutun tamamı
`docs/kodhane-retention-runbook.md`, "Kazanç günlüğü adımı" içinde birebir):
```
-c "select coalesce(sum(b.n), 0) as progress_log_rows, count(*) filter (where b.n > 0) as progress_log_batches from (select public.kodhane_cleanup_progress_log(365, 5000) as n from generate_series(1, 20)) b" -c "select count(*) as progress_log_left_over_365d from public.kodhane_progress_log p where p.created_at < now() - make_interval(days => 365)"
```
- Gece başına üst sınır 20 × 5000 satır; kalan bir sonraki gece (`progress_log_left_over_365d` > 0).
- **En sonda çalışır:** her `-c` ayrı transaction. Bu adım hata verirse yedek ve denetim temizliği zaten commit edilmiştir;
  çıkış kodu 1 olur ve görev başarısız görünür (saklama testleri J8, J9). `kodhane_retention_daily.sh` aynı sırayla çalışır (S1, S8).
- Dokploy'daki komut ancak bu migration canlıda kurulduktan sonra değiştirilir (ayrı onay). `kodhane_retention_daily.sh` (yerel araç)
  fonksiyon yoksa bu adımı "skipped" yazıp atlar.

## Gizlilik ve hesap silme
- Gizlilik metni: süre seçilip iş canlıda çalışmadan günlük için saklama süresi vaat edilmez (saklama runbook'undaki üç koşul
  kuralı). Metne "oyun ilerleme günlüğü (hisse, Halka Arz, Borsa Payı, ağaç; e-posta yok)" eklenmesi Yazı'nın işi.
- Hesap silme: `docs/kodhane-account-delete-runbook.md`. İki mod da kullanıcının günlük satırlarını siler; `auth.users` silinince
  cascade ile de gider.

## Geri alma
```bash
PGOPTIONS='-c kodhane.progress_log_allow_loss=on' \
  psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/rollback/20261003020000_v4_4_kodhane_progress_log.rollback.sql
```
Satırlar kaybolur. Önce Dokploy komutu `kodhane_retention_dokploy_command.txt`'ye döndürülür, yoksa gece görevi çıkış 1 verir. Kayıt yazmaları etkilenmez (R3).

## Testler (yerel, `supabase/postgres:17.6.1.136`, `f519727303f0`)
- `run_kodhane_progress_log_tests.sh`: 145 (M0 + iki varyant × 72: a = A + günlük, ab = A + B + günlük).
- Hesap silme L-*: 12 (varyant abl = A + B + günlük).
