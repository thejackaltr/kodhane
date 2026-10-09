# Kodhane sunucu kodu (Supabase)

Bu dizinde Kodhane'nin ortak Teserix Supabase veritabanındaki (supabase.teserix.com = kodhane-api.teserix.com) sunucu
kodu var: migration'lar, rollback'ler, kurulum/doğrulama betikleri (`ops/`) ve testler. Runbook'lar `docs/` altında.
Oyun istemcisi (kök dizindeki `game.js`, `cloud.js`, ...) bu dosyaları kullanmaz. Pages ve Docker imajına girmezler
(`.github/workflows/pages.yml` yüklemeden önce `supabase` ve `docs`'u siler, `.dockerignore`'da da ikisi var).

Aynı veritabanını **Açık Ofis** de kullanır. Açık Ofis'in migration'ları onun reposunda (ya da yerelde) durur, **bu repoda yoktur**.
Aşağıdaki listede yalnız dosya adıyla anılırlar.

## Kaynak
Dosyalar 2026-10-04'te Açık Ofis reposundaki `v4.4-backend` (`63838e1`) ve `v4.5-kayip-bildir` (`518968d`) dallarından
alındı. Şu dosyalar dışında içerikleri bayt bayt aynı: altyapı adlarını ortam değişkenine taşıyan altı dosya ve `lib.sh`'ı
listeleyen iki `inputs.md5` (`kodhane_loss_report`, `kodhane_score_rule`), kayıp bildir testi (I3/I6 eski sürüm olarak
`tests/loss_report/fixtures/pre_v45_account_deletion/` altındaki dört dosyayı okur: v4.4 / B hesap silme dosyalarının
bayt bayt kopyası, git geçmişine bağlı değil) ve .136 sonuç dosyası (md5 tablosu ve fark gerekçeleri PR'da). **Kurulum bu repodaki dalın
commit'inden yapılır.** Paket B'nin üretilen `install.sql` md5'i `deefef0e5c52cc3679dc997374d2edbb` (63838e1 ile aynı).
Skor kuralı migration/rollback'i ve kayıp bildir (P7) migration'ı `518968d` ile aynı.

## Ortak veritabanının migration geçmişi (tarih sırasıyla)
Migration'lardan önce temel şema elle kuruldu (kodhane-cloud SQL dosyaları: `kodhane_saves`, `kodhane_profiles`, sıralama
fonksiyonları, `acik_ofis_saves`). Bu dosyalar bu repoda yok. Testler bu temeli canlı şema dökümünden kurar.

| sıra | migration | oyun | bu repoda | durum (2026-10-04, Backend notları) |
|---|---|---|---|---|
| 1 | `20260928160000_v2_2_kodhane_save_safety.sql` | Kodhane | var (+ rollback, ops) | canlıda |
| 2 | `20260928160100_v2_2_acik_ofis_save_safety.sql` | Açık Ofis | **yok: Açık Ofis reposunda/yerelde, bu repoda yok** | canlıda |
| 3 | `20260929203000_v4_4a_kodhane_score_plausible.sql` (Paket A) | Kodhane | var | canlıda (2026-10-01 20:39 TSİ) |
| 4 | `20260929204000_v4_4b_kodhane_stage_ids_version_guard.sql` (Paket B) | Kodhane | var | canlıda değil; kurulum `ops/kodhane_v44b_install.sh`, ayrı onay |
| 5 | `20261001210000_v4_4_kodhane_audit_log_retention.sql` (saklama) | Kodhane (denetim kaydı + iki oyunun kayıt yedekleri) | var | canlıda değil; ayrı onay |
| 6 | `20261003020000_v4_4_kodhane_progress_log.sql` (kazanç günlüğü) | Kodhane | var | canlıda değil; B ile aynı paket |
| 7 | `20261003040000_v4_4_kodhane_deletion_log.sql` (silme listesi) | Kodhane | var | canlıda değil; ayrı kurulum adımı |
| 8 | `20261003060000_v4_5_kodhane_loss_report.sql` (kayıp bildir, P7) | Kodhane | var | canlıda değil; B, kazanç günlüğü ve skor kuralından sonra, ayrı onay |
| 9 | `20261003080000_v4_5_kodhane_score_rule.sql` (skor kuralı, `asama_1e21`, `SET jit = off`) | Kodhane | var | canlıda değil; B'den sonra, v4.5 istemcisinden önce, ayrı onay |

Her Kodhane migration'ının `rollback/` altında aynı adlı `.rollback.sql` dosyası var. Canlı durum kurulumdan önce
ilgili preflight/verify ile yeniden doğrulanır; bu tablo bilgi içindir.

## Kurulum
- Paket B + kazanç günlüğü: `docs/kodhane-v44b-install-runbook.md` (`ops/kodhane_v44b_install.sh build → preflight → dryrun → install → verify`).
- Saklama: `docs/kodhane-retention-runbook.md`. Silme listesi: `ops/kodhane_deletion_log_install.sh`. Hesap silme: `docs/kodhane-account-delete-runbook.md`.
- Skor kuralı: `docs/kodhane-v4.5-score-rule-runbook.md` (`ops/kodhane_score_rule_install.sh`, verify `SRVERIFY|PASS|14`; önce salt okunur `show jit; select pg_jit_available();`).
- Kayıp bildir: `docs/kodhane-loss-report-runbook.md` (`ops/kodhane_loss_report_install.sh`, verify `LRVERIFY|PASS|9` + `DELCHECK|PASS|5`).
  Sıra: B (+ kazanç günlüğü) → skor kuralı → kayıp bildir.
- Canlı DB'ye her kurulum ayrı onayla yapılır. Bu repoya merge etmek yalnız kodu alır.

## Canlı hedef ortam değişkenleri
`KODHANE_TARGET=live` betikleri altyapı adlarını yalnız ortamdan okur; repoda gerçek değer yoktur, varsayılan da yoktur.
Değişken boşsa betik `STOP: … is not set` ile durur. Değerler yerel, commit edilmeyen `sb_env.sh`'tan gelir
(`.gitignore`'da); şablon `supabase/sb_env.example.sh` yalnız yer tutucu içerir.

| değişken | anlamı |
|---|---|
| `PORTAINER_API_TOKEN` | Portainer API anahtarı (ekrana basılmaz) |
| `KODHANE_PORTAINER_URL` | DB'yi çalıştıran endpoint'in Portainer Docker API adresi (`https://<portainer-host>/api/endpoints/<id>/docker`) |
| `KODHANE_DB_CONTAINER` | Supabase yığınının Postgres container adı |
| `KODHANE_DB_COMPOSE` | Aynı yığının Dokploy compose adı (yalnız runbook: saklama görevi) |

## Testler
Yalnız yerel, atılabilir veritabanlarında (Docker `supabase/postgres:17.6.1.136`). Taban veritabanı (`v44_base`) canlı
şema dökümünden kurulur (public şema + auth şeması, veri yok); döküm repoda değil. Setler: `tests/v4_4` (A, B + HTTP),
`tests/v44b_install` (prova), `tests/progress_log`, `tests/retention`, `tests/account_delete`, `tests/deletion_log`,
`tests/score_rule`, `tests/loss_report` (SQL + HTTP). Sonuçlar `tests/v4_4/results/`, `tests/score_rule/`, `tests/loss_report/`.

**Açık Ofis dosyasına bağlı iki eski v2.2 test betiği:** `tests/run_v2_2_tests.sh` ve `tests/http/run_http_tests.sh`
iki oyunun v2.2 migration'ını birlikte sınar ve şu Açık Ofis dosyalarını aynı yollarda bekler: `migrations/20260928160100_…`,
`rollback/20260928160100_…`, `ops/20260928160100_…`, `tests/v2_2_acik_ofis.test.sql`, `tests/v2_2_shared_ao_only.test.sql`,
`tests/fixtures/pre_v2_2_acik_ofis_only.sql`, `tests/fixtures/seed_acik_ofis.sql`. v2.2 canlıda olduğu için bunlar
yalnız geçmiş içindir. Yeniden koşmak gerekirse bu dosyalar Açık Ofis reposundan geçici olarak kopyalanır (commit edilmez).
Yukarıdaki v4.4 ve v4.5 setleri bu dosyalara bağlı değildir.
