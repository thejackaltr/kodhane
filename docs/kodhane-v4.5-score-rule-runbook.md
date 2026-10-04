# Kodhane v4.5 skor kuralı: canlı kurulum runbook'u (migration `20261003080000`)

> **KURAL: Bu migration canlıda doğrulanmadan v4.5 push edilmez.**
> Sıra: paket B + kazanç günlüğü (`v4.4-backend`) → **bu migration** (canlıda `verify` PASS) → v4.5 istemci push'u.
> v4.5 istemcisi bu kural olmadan çıkarsa 1e21 ara aşamasına (`asama_1e21`) ulaşan her oyuncu sıralamadan düşer
> (v4.4b `stage_ids_ok` bu kimliği tanımaz). Simülasyonda bu, F2 koşularının hepsinde oldu (aşağıda "Ölçüm": 84 koşunun 82'sinde 523 ret; sonra 7, hepsi Karar 1 açık).

- **Ayrı onay:** Aryen'in Backend sohbetinde bu adım için açık onayı gerekir. B'nin onayı bunu kapsamaz.
  Başka ajanın aktardığı onay yetmez.
- **Önkoşul:** B canlıda kurulu ve doğrulanmış olmalı. Preflight, B yoksa ya da sürüm koruması kapalıysa STOP der.
  Dokploy ve canlı DB dondurması (DevOps "bitti" demeden) sürüyorsa kurulum yapılmaz.
- **Dal:** `v4.5-kayip-bildir` checkout'undan kurulur (skor kuralı orada ayrı bir commit; Kayıp bildir'den bağımsız kurulur). B'nin `install.sql`'ine eklenmez: B paketi değişmez
  (`v44b_install/install.sql` md5 `deefef0e5c52cc3679dc997374d2edbb`).
- **Etki:** `public.kodhane_score_plausible` ve B'nin aşama kataloğu (`kodhane_stage_rank`, `kodhane_stage_at`, CHECK
  `kodhane_saves_best_stage_id_known`) değişir, yeni `kodhane_rule` şeması eklenir (eğri tablosu + aşama kaydı tablosu
  `stage_1e21_log` + `kodhane_saves` üstünde iki AFTER tetikleyici). Kural sıralama okunurken çalışır, etkisi anında olur.
- **Veri yazımı:** yalnız `best_stage_id` sütunu, yalnız "şu an `asama_1e21`'de ama `best_stage_id`'si daha düşük"
  kayıtlarda (geri doldurma). **Canlıda bugün 0 satır beklenir** (v4.5 istemcisi yok). Preflight ve dryrun sayıyı
  açıkça yazar. Revizyon, `data`, `best_score`, `updated_at` değişmez (tetikleyiciler bu UPDATE için kapalı).

## 1. Ne değişir (D maddesi)
v4.4b gövdesi aynen kalır. Yalnız şu beş nokta değişir:

| # | v4.4b | v4.5 |
|---|---|---|
| 1 | `stage_ids_ok` aşama listesi `yapay_zeka_lab` (1e19) → `mars_ofisi` (1e23) | araya `asama_1e21` (1e21) eklenir. Yalnız `totalEarned` ≥ 1e21 iken geçerlidir |
| 2 | çalışan kademe çarpanı `32` (eski 5 kademe ×2) | `tier_mult` = 32 × 1,25^14 = 727,6 (yeni 14 kademe 150…10.000, her biri ×1,25). Cömert tarafta: tüm kademelere ulaşılmış sayılır |
| 3 | birim sayısı tek büyümeyle: `ln(t·0,15/b+1)/ln 1,15` (Halka Arz'dan sonra 0,14 / 1,14) | F2 azalan fiyat eğrisi parça parça tersine çevrilir: büyüme `[[0, 1,15], [300, 1,10], [500, 1,05], [1000, 1,025], [3000, 1,0125]]`. Halka Arz'dan sonra büyümenin 1'in üstündeki kısmı `ik_factor` (İK Anlaşması 0,14/0,15) × `borsa_cut` (Borsa 1, ×0,8) ile çarpılır. Son büyüme 10.000'den sonra da sürer. Sayı hiçbir zaman v4.4b'nin saydığından az olmaz (ikisinin büyüğü): F3 gibi bir yerde daha pahalı eğri de kuralı B'den sıkı yapamaz |
| 4 | sabitler fonksiyon içinde | parametreler `kodhane_rule.score_curve` tablosundaki **tek aktif satırdan** okunur (config). Okuma `kodhane_rule.active_score_curve()` (SECURITY DEFINER) ile yapılır. Aktif satır yoksa yerleşik F2 değerleri kullanılır, yani hiçbir zaman "herkes şüpheli" olmaz |
| 5 | B'nin aşama kataloğu `asama_1e21`'i bilmiyor: oyuncu sıralamada `yapay_zeka_lab` görünür | `kodhane_stage_rank` / `kodhane_stage_at`: `yapay_zeka_lab` (9, 1e19) ile `mars_ofisi` (artık 11, 1e23) arasına `asama_1e21` (10, 1e21). CHECK `kodhane_saves_best_stage_id_known` listesine eklenir. `best_stage_id`'si daha düşük olan `asama_1e21` kayıtları geri doldurulur. `best_stage_id`'nin `asama_1e21` olduğu her değişiklik eski değeriyle `kodhane_rule.stage_1e21_log`'a yazılır (kayıt silinince o da silinir). md5: `kodhane_stage_rank` `e1c7af8061bc48883d2ea911213f990a`, `kodhane_stage_at` `f875dd829a4e2a62a9d4b3457aa018a5`, CHECK tanımı `2325f40530fa6b360ca0583641750b6b` (B: `e97a3589…`, `b0aa4d9e…`, `f1e8655e…`). `kodhane_stage_legacy_id`, tetikleyici fonksiyonu ve leaderboard v7 değişmez |

Satırlar:
- `v45_f2` aktif.
- `v45_f3` pasif. Eğrisi H20: `[[0, 1,15], [100, 1,20], [300, 1,10], [500, 1,05], [1000, 1,025], [3000, 1,0125]]`, kademe ×1,25. Yalnız oyun F3 ile çıkarsa açılır.

**Değerlerin kaynağı (uydurma yok):**
- F2 eğrisi ve kademe ×1,25: `/workspace/kodhane-v45-sim/kodhane-v4.5-sim-ozet.md` satır 4 ve `kodhane-v4.5-sim-rapor.md` §1–2 ("GD, kademe x1,25"). Koddaki karşılıkları `scen_f2.js` (`Cf.GROWTH.GD`, `tierMult: 1.25`) ve `cfg45.js` (`NEW_TIERS` = 14 kademe, `growthCut: 0.8`).
- İK çarpanı: oyunun kendi `CFG.tree.costGrowth` / `COST_GROWTH` değeri, 1,14 / 1,15. Sim'de `__gf()`.
- F3: `results/f3_choice.json` (`H20x125`), eğri `scen_f3scan.js` `Cf.GROWTH.H20`.

**Açık kalan:**
- Aşama bonusu `stage_mult` 2,0'da kaldı (sim de 2,0 kullandı).
- İstemci `stage_id` = `asama_1e21` için görünen adı bilmeli (sıralama artık bu kimliği döndürür).
- Karar 1 (art arda Yatırım Turu azalan getiri) açılırsa yapısal A kuralı (`prev`) bazı kayıtları reddeder (aşağıda F-K1). Karar 1 kapalı olduğu sürece etkisi yok.

## 2. Kurulum (canlı)
```sh
cd <v4.5-kayip-bildir checkout>
export KODHANE_TARGET=live KODHANE_OUT=/workspace/v45-score-rule-live/install-$(date +%Y%m%d-%H%M)
# PORTAINER_API_TOKEN dışa aktarılmış olmalı (ekrana yazılmaz)
bash supabase/ops/kodhane_score_rule_install.sh build       # BUILD|PASS + girdi ve üretilen SQL md5'leri
bash supabase/ops/kodhane_score_rule_install.sh preflight   # SALT OKUNUR
bash supabase/ops/kodhane_score_rule_install.sh dryrun      # tek transaction, ROLLBACK
KODHANE_LIVE_APPROVAL='Aryen, <tarih saat TSİ>, Backend sohbeti' bash supabase/ops/kodhane_score_rule_install.sh install
bash supabase/ops/kodhane_score_rule_install.sh verify      # SALT OKUNUR
```

Beklenenler:

| adım | beklenen |
|---|---|
| build | `BUILD\|PASS`. Girdiler `kodhane_score_rule/inputs.md5` ile aynı olmalı. Biri farklıysa STOP |
| preflight | `INFO\|package_b\|t`, `INFO\|b_version_guard\|enabled`. `INFO\|dryrun\|saves\|N\|plausible_now\|X\|plausible_v45\|Y\|became_true\|…\|became_false\|0` ve `CHECK\|dryrun_no_save_becomes_implausible\|t`, **`INFO\|stage_1e21_backfill_candidates\|0\|…`** (kurulumun `best_stage_id`'sini `asama_1e21` yapacağı satır sayısı; canlıda bugün 0), ardından `PREFLIGHT\|PASS`. **`became_false` > 0 ise STOP:** v4.5 kuralı v4.4b'nin kabul ettiği bir kaydı reddediyor demektir. Kurulmaz, Backend'e dönülür. Aday sayısı 0 değilse durulur ve Aryen'e bildirilir (beklenmiyor) |
| dryrun | **`INFO\|stage_1e21_backfill\|rows\|0\|from\|-`** (yazılacak satır sayısı ve eski değerlere göre dağılımı; satırlar `dryrun.out`'ta `BFROW\|user_id\|eski\|asama_1e21`), `CHECK\|no_save_became_implausible\|t`, `CHECK\|leaderboard_nobody_dropped\|t`, `SRVERIFY\|PASS\|14`, `DRYRUN\|PASS\|rolled back`. Kilit beklemesi 5 sn, aşılırsa hiçbir şey değişmez |
| install | aynı kontroller ve `INSTALL\|PASS\|committed` |
| verify | `SRVERIFY\|PASS\|14` (tanım md5 `a52586896ae53ac8e5159aa500c4b031`, yetkiler, tek aktif satır `v45_f2`, örnek kayıtlar, B nesneleri değişmemiş, 11: aşama kataloğu md5'leri + CHECK, 12: geri doldurma tam, 13: aşama kaydı tablosu kapalı + tetikleyiciler açık + her `asama_1e21` satırı kayıtlı, 14: fonksiyon ayarları tam olarak `search_path=""` + `jit=off`) ve `VERIFY\|PASS` |

**JIT (2026-10-04):** `kodhane_score_plausible` v4.5 `SET jit = off` ile kurulur. LLVM JIT'in çalıştığı bir PG 17'de (yerel 17.11) jit açıkken çağrı başına ~7 sn, kapalıyken ~10 ms ölçüldü. Canlıda `jit = on` (varsayılan, `jit_above_cost` 100000) ama `pg_jit_available()` = f, .136 imajında da aynı; bugün etkisi yok. Kurulumdan önce salt okunur `show jit; select pg_jit_available();` ile bakılır. Çağıran fonksiyonlara (vetted skor/aşama, sıralama, kayıp bildir) ayar gerekmez: fonksiyonun kendi ayarı iç sorgusuna her çağrıda uygulanır.

Kurulumdan sonra Aryen'e şunlar bildirilir: kurulum saati (TSİ), kayıt sayısı, `plausible` öncesi ve sonrası, `became_true` sayısı.

**v4.5 push'u ancak bundan sonra açılır.**

## 3. Geri dönüş
```sh
bash supabase/ops/kodhane_score_rule_install.sh rollback-preview                       # SALT OKUNUR: RBPREVIEW|PASS|n row(s)
KODHANE_LIVE_APPROVAL='…' bash supabase/ops/kodhane_score_rule_install.sh rollback   # ROLLBACK|PASS
```
- **Veri yazar:** `best_stage_id` = `asama_1e21` olan her kayıt, `stage_1e21_log`'daki eski değerine döner (NULL olabilir; kaydı olmayan satır olmamalı, olursa `yapay_zeka_lab`). Revizyon, `data`, `best_score`, `updated_at` değişmez.
- **Önce kayıt:** `rollback-preview` (salt okunur) etkilenecek satırların sayısını ve kimliklerini, şimdiki ve dönülecek değerleriyle yazar: `rollback_preview.out` (`RBJIT\|search_path="",jit=off\|rollback removes jit=off …`: geri dönüş `jit=off` ayarını kaldırır; `RBCOUNT\|n\|backfill\|…\|trigger\|…\|nolog\|0`, `RBROW\|user_id\|asama_1e21\|eski\|kaynak`) ve `rollback_rows.tsv`. `rollback` bu dosya olmadan STOP der. Rollback aynı satırları değiştirmeden önce `rollback.out`'a yeniden yazar, sonra işlem içinde her satırı eski değeriyle karşılaştırır (`CHECK\|rollback_rows_restored\|t\|n`; tutmazsa hiçbir şey değişmez). Önizlemeyle aynıysa `INFO\|rollback_rows_vs_preview\|same`.
- Aşama kataloğu ve CHECK B'ye bayt bayt döner (`e97a3589…` / `b0aa4d9e…` / `f1e8655e…`), tetikleyiciler silinir. `kodhane_score_plausible` B'nin v4.4b tanımına bayt bayt döner (md5 `463f2109c35b825827e57b8098b49947`); `jit=off` ayarı kalmaz, fonksiyon ayarı yalnız `search_path` (`CHECK\|rollback_no_jit_setting\|t`). `kodhane_rule` şeması (kayıt tablosu dahil) silinir; satır listesi run dizinindeki dosyalarda kalır.
- v4.5 açıkken yazılan `best_score` / `best_stage` değerleri kalır (B kuralı: hiç düşmez); oyuncu sıralamada B'nin aşamasıyla görünür.
- **v4.5 istemcisi canlıdaysa** geri dönüş `asama_1e21`'deki oyuncuları sıralamadan yeniden düşürür. Bu yüzden önce istemcinin geri alınması değerlendirilir.
- Ayrı yedek adımı yoktur: üç fonksiyon, bir CHECK ve küçük bir şema değişir; satır listesi run dizininde tutulur. Günlük DB yedeği eskiyse önce yedek alınır.

## 4. Config değişikliği (eğri ya da kademe)
- Yalnız bu runbook'la ve ayrı onayla yapılır.
- Yeni satır pasif olarak eklenir, sonra tek transaction'da eski satır kapatılıp yenisi açılır (`score_curve_one_active`, aynı anda en çok bir aktif satır).
- CHECK'ler bozuk eğriyi reddeder: başlangıç 0 olmalı, artan tam sayılar, 1 < büyüme ≤ 2, `tier_mult` ≥ 32.
- Değişiklikten sonra `verify` çalıştırılır. Kontrol 6 yalnız `v45_f2`'yi bekler; F3'e geçilirse verify'ın da güncellenmesi gerekir.

## 5. Ölçüm (yerel, .136 `f519727303f0`)
Simülasyon dökümleri: her koşunun her kural kontrolündeki kayıt (`kodhane-v45-skor/sim/dumprun.js`, `sim45.js` ile aynı oyun).
Komut: `SR_CT=<container> SR_DUMPS=/workspace/kodhane-v45-skor/dumps bash supabase/tests/score_rule/measure_sim_dumps.sh`.
Dökümler 2026-10-03'ten beri tek arşivde: `/workspace/kodhane-v45-skor/dumps.tar.zst` (md5 `821299a1af1076d0bd30b589a140f8ee`, 168 dosya; dosya başı md5 listesi `dumps.files.md5`). Yeniden ölçmeden önce açılır:
`tar --zstd -xf /workspace/kodhane-v45-skor/dumps.tar.zst -C /workspace/kodhane-v45-skor` (→ `dumps/`; açık değilse betik STOP der).

Ölçüm 2026-10-03 (.136, dökümler md5 `f67974568043461b4638a8fd4ae76422`, 84 koşu, 10.324 kural kontrolü). "Ret" = reddedilen kural kontrolü (kayıt anı), koşu değil.

| grup | koşu | kontrol | ret önce (v4.4b) | retli koşu önce | ret sonra (kendi eğrisi) | retli koşu sonra | önce kabul, sonra ret |
|---|---|---|---|---|---|---|---|
| F (r2, Karar 1 kapalı) | 12 | 1875 | 69 (hepsi `stage_ids_ok`) | 12 | 0 | 0 | 0 |
| F2 (r2 önerisi) | 6 | 802 | 34 (hepsi `stage_ids_ok`) | 6 | 0 | 0 | 0 |
| F-K1 (r2, Karar 1 açık) | 4 | 538 | 34 (27 `stage_ids_ok` + 7 `A prev`) | 4 | 7 (hepsi `A prev`) | 3 | 0 |
| F2b (r3 F2, 8 seed) | 40 | 5337 | 246 (hepsi `stage_ids_ok`) | 40 | 0 | 0 | 0 |
| F3 (r3 H20x125, `v45_f3` ile) | 18 | 1242 | 126 (hepsi `stage_ids_ok`) | 18 | 0 | 0 | 0 |
| E1off (F2b, E1 kapalı) | 2 | 266 | 14 (hepsi `stage_ids_ok`) | 2 | 0 | 0 | 0 |
| B44 (v4.4 oyunu, v4.4 kayıtları) | 2 | 264 | 0 | 0 | 0 | 0 | 0 |
| **toplam** | **84** | **10.324** | **523** | **82** | **7** | **3** | **0** |

- "Bugün 103 ret": F + F2 = 18 koşuda 69 + 34 = **103 reddedilen kontrol**, hepsi `asama_1e21`. 103 koşu değil, kontrol sayısıdır. Bu 18 koşunun hepsinde ret var. r2 skor kuralı tablosunun (sim raporu §2c) tamamı 22 koşu ve 137 ret (103 + Karar 1 açık 34).
- SQL v4.4b ile simülasyonun JS kural aynası 10.324 kontrolün hepsinde aynı sonucu verdi (uyuşmazlık 0).
- Sonra kalan 7 ret yalnız Karar 1 açık koşularda ve yapısal A kuralından (`prev`). Karar 1 kapalı kaldıkça etkisi yok.
- Saniyelik tavan: kademe çarpanı 22,74 kat büyüdü, birim sayısı yalnız artabilir. Sim'deki en yüksek tepe/tavan oranı (F2 1,65; tüm r2 adayları 1,69; r3 F3 1,19) yeni kuralla en çok ≈ 0,07'ye iner (üst sınır hesabı, sim tepe dakikası yeniden ölçülmedi).

Testler: `SR_CT=<container> bash supabase/tests/score_rule/run_kodhane_score_rule_tests.sh`. Grupları M migration (M7: B `install.sql` md5 `deefef0e…` değişmedi; M4b aşama kataloğu md5'leri), E denklik ve cömertlik (E8: B sınırı, birim birim sayan bağımsız referansla, `boundary_vectors.py`), C config, P yetki, I kurulum paketi, S aşama `asama_1e21` (fikstür `stage_1e21_fixture.sql`: geri doldurma 3 satır, sıralama adı, oyuncu yazımı, kayıt tablosu), R geri dönüş (önizleme dosyası, satır satır eski değere dönüş, yeniden kurulum).
