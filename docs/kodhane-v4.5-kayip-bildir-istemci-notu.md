# Kodhane v4.5 "Kayıp bildir": istemci eşleme notu (Frontend)

Sunucu: migration `20261003060000_v4_5_kodhane_loss_report.sql` (dal `v4.5-kayip-bildir`). Runbook: `docs/kodhane-loss-report-runbook.md`.
Bu not istemcinin gönderdiği ve aldığı değerleri tek yerde toplar. Değerler sunucu testleriyle (`supabase/tests/loss_report/`) sabitlenmiştir.
**Sunucu canlıya kurulmadan form açılmamalıdır** (kurulum ayrı onay ister).

## 1. Bildirim gönder: `POST /rest/v1/rpc/kodhane_loss_report_create`
Oturum açmış oyuncunun JWT'si ile çağrılır (`authenticated`). E-posta gönderilmez, tutulmaz.
```json
{ "p_lost_items": ["borsa_payi", "agac"], "p_lost_since": "2026-10-02T21:00:00.000Z", "p_description": "…", "p_client_version": "4.5.0" }
```
| alan | tip | kural |
|---|---|---|
| `p_lost_items` | `text[]` | 1–5 değer, yalnız: `yatirim_turu`, `halka_arz`, `borsa_payi`, `agac`, `diger`. Tekrarlar tekilleştirilir. |
| `p_lost_since` | `timestamptz` ya da `null` | Aşağıdaki tablo. **Enum değildir**, zaman damgasıdır. |
| `p_description` | `text` ya da `null` | Baştaki ve sondaki boşluk kırpılır, boş metin `null` sayılır. En çok **280** karakter. `@` (e-posta adresi) ve kontrol karakteri içeremez. |
| `p_client_version` | `text` | `^[0-9A-Za-z._-]{1,32}$`. Uymazsa hata vermez, saklanmaz. |

`p_lost_since` seçenekleri (istemci hesaplar, UTC ISO gönderir):
| seçenek | gönderilen değer |
|---|---|
| Bugün | oyuncunun **yerel saatine göre** bugünün başlangıcı (00:00 yerel), UTC ISO. Ör. İstanbul 3 Ekim → `2026-10-02T21:00:00.000Z` |
| Dün | oyuncunun yerel saatine göre dünün başlangıcı, UTC ISO |
| Son 7 gün | şimdi − 7 gün |
| Son 30 gün | şimdi − 30 gün |
| Bilmiyorum | `null` |

Sunucu `null`'u kabul eder. Zaman damgasını en çok **5 dk ileri** (saat kayması toleransı) ve en çok **365 gün geri** kabul eder; dışı `loss_report_invalid` / `lost_since`.
Test C14 dört biçimi ve `null`'u doğrular. "Bugün" ve "Dün" başlangıcı Europe/Istanbul, UTC+14 (Pacific/Kiritimati) ve UTC−12 (Etc/GMT+12) için reddedilmez.
`Z` ile biten ISO metni, +4 dk ve 364 gün de geçer. +6 dk ve 366 gün reddedilir (C14b).

Başarılı yanıt (200): `{ "id": 123, "status": "in_review", "created_at": "…" }`.

## 2. Durum ekranı: `POST /rest/v1/rpc/kodhane_loss_report_status`
`{ "p_limit": 10 }` (1–50, varsayılan 10). Yeniden eskiye sıralı, yalnız oyuncunun kendi bildirimleri döner. Satır biçimi:
| kolon | anlam |
|---|---|
| `id`, `created_at`, `lost_items`, `lost_since` | gönderilen değerler |
| `status` | `in_review` / `approved` / `rejected` / `applied` (sunucunun iç `pending` ve `needs_review` durumları `in_review` görünür) |
| `status_changed_at` | son durum değişikliği |
| `reason` | yalnız `rejected` iken ret kodu, diğer durumlarda `null` |
| `applied_at` | geri yükleme anı (`applied`), yoksa `null` |
| `review_reason` | yalnız tekrar incelemedeyken dolu: `save_changed` ya da `no_cloud_save`, aksi hâlde `null` |
| `applied_revision` | **son kolon (10.)**, `bigint`. Yalnız `status = applied` iken dolu: geri yüklemenin yazdığı kayıt `revision`'ı (sunucuda `applied_rev_after`). `in_review` / `approved` / `rejected` iken `null` |

Açıklama, onay referansı, iç not ve miktarlar **dönmez**.

### Eski sekme ayrımı: `applied_revision` (kesin alan)
Önceden durum RPC'si bunu kesin söyleyen bir alan döndürmüyordu. `review_reason = save_changed` başka bir şeydir: onay ile
geri yükleme arasında kaydın değiştiğini (talebin yeniden incelemeye düştüğünü) söyler, sekmeyle ilgisi yoktur.
`lossreport.js` (`acff183`) bugün sezgiyle tahmin ediyor (karar 6): `applied_at` > sekmenin açılış anı ise ve 409'dan önceki
durum yenilemesinde yakalandıysa `staleTab` gösteriyor. Sekme geri yüklemeden *önce* açılıp yükleme anında uykudaysa ya da
yoklama gecikirse yanılabilir.
Kesin kural (`applied_revision` ile):
- Sekme son gördüğü kayıt `revision`'ını (L) zaten tutuyor; yazarken L + 1 gönderiyor.
- 409 `stale_revision` gelince durum RPC'sini çağır, en yeni `status = applied` satırının `applied_revision`'ına (A) bak.
- **L < A** (eşdeğeri: 409 `details` içindeki `sent revision N` için **N ≤ A**) ise bu sekme geri yüklemeden önceki kayıtla açık:
  `lossReport.applied.staleTab`. Aksi hâlde (A yok / `null`, ya da L ≥ A) 409 başka bir yazıdan: bugünkü `reset.otherDeviceSync`.
- `applied_revision` yalnız `applied` satırda doludur; `null` "geri yükleme yok" demektir, sıfır değildir.
- Aynı oyuncunun birden çok `applied` satırı olabilir (farklı günlerde); en büyük `applied_revision` yeterlidir.
- Ayrım yalnız 409 `stale_revision` anında yapılır; 409 yoksa `applied_revision`'a bakılmaz.
Testler: S1 (kolon listesi), A4c / N1b / N6 (`applied` dışında `null`), A10 (= geri yüklemenin yazdığı revision), HTTP L9
(10 kolon), L10, L11b (eski sekmenin 409'unda `sent revision` ≤ `applied_revision`). Kurulum kontrolü 9 (`player_status_columns`) kolon listesini sabitler.

Ret kodları (`reason`), istemcide metne eşlenir. Kodu oyuncu görür, Aryen'in iç notunu görmez. Metinler Yazı'nındır
(`/workspace/plans/kodhane-p7-kayip-bildir-yazi-r2.md` §5); burada yalnız kod → anahtar eşlemesi var:
| `reason` | metin anahtarı |
|---|---|
| `kayip_bulunamadi` | `lossReport.reject.kayip_bulunamadi` |
| `zaten_telafi_edildi` | `lossReport.reject.zaten_telafi_edildi` |
| `kural_disi` | `lossReport.reject.kural_disi` |
| `diger` | `lossReport.reject.diger` (geçerli, ayrı bir kod; yalnız kendi metniyle eşlenir) |
| boş / `null` / tanınmayan değer | `lossReport.reject.generic` |

`diger` genel karşılık **değildir**: boş, `null` ya da istemcinin tanımadığı bir `reason` gelirse `lossReport.reject.generic` gösterilir (Yazı r2 §5).

`review_reason` **yalnız** `save_changed`, `no_cloud_save` ya da `null` olabilir. Başka değer çıkmaz: tablo CHECK'i (`loss_report_review_reason_check`), kurulum kontrolü 9 ve testler N5/K3 bunu sabitler.
| kod | anlamı (oyuncuya, `status = in_review` iken) |
|---|---|
| `save_changed` | Onaydan sonra oynadın, kayıt değişti; talep yeniden inceleniyor |
| `no_cloud_save` | Bulut kaydı bulunamadı ya da geri yüklenecek bir şey kalmadı; talep yeniden inceleniyor |
| `null` | olağan inceleme |

## 3. Hatalar (PostgREST yanıtı `{code, message, details, hint}`; istemci `message`'a bakar)
Sunucu kontrolleri bu sırayla yapılır, ilk takılan döner: oturum → alanlar (400) → bulut kaydı (404) → açık bildirim (409) → 24 saat (429) → 30 gün (429).

| HTTP | `code` | `message` | `details` | ne zaman |
|---|---|---|---|---|
| 401 | `42501` | `permission denied for function …` | `null` | oturum yok: JWT yok (L1) **ya da anon anahtar** bearer olarak (supabase-js oturumsuzken bunu gönderir; L1b, iki RPC). anon'un bu RPC'lerde EXECUTE yetkisi yok, PostgREST rol `anon` iken 42501'i 401 yapar. **403 değil.** |
| 403 | `42501` | `not_authenticated` | `null` | JWT `authenticated` ama kullanıcı kimliği (`sub`) yok (bozuk / elle üretilmiş token). L1c doğruladı (create + status). Oturumu olan gerçek istemcide çıkmaz. |
| 400 | `22023` | `loss_report_invalid` | `lost_items` / `lost_since` / `description` | hatalı alan; `hint` sınırı yazar (İngilizce, oyuncuya gösterilmez) |
| 404 | `PT404` | `no_cloud_save` | `null` | oyuncunun bulut kaydı yok: önce buluta kaydet |
| 409 | `PT409` | `loss_report_open` | `null` | açık bildirim var (aynı anda tek; `in_review` ya da `approved`) |
| 429 | `PT429` | `loss_report_daily_limit` | **tekrar deneme zamanı**, UTC ISO `YYYY-MM-DDTHH:MM:SSZ` | 24 saatte 1 (son 24 saatteki ilk bildirim + 24 sa) |
| 429 | `PT429` | `loss_report_monthly_limit` | **tekrar deneme zamanı**, UTC ISO `YYYY-MM-DDTHH:MM:SSZ` | 30 günde 5 (pencerenin en eski bildirimi + 30 g) |

**429 tekrar deneme zamanı `Retry-After` başlığında DEĞİL, yanıt gövdesinin `details` alanında gelir:** UTC, ISO 8601, saniye hassasiyetinde, `Z` ile biten metin (`YYYY-MM-DDTHH:MM:SSZ`, örnek `2026-10-04T16:30:51Z`). Saniye cinsinden süre değil, mutlak zamandır. `Retry-After` başlığı hiç gönderilmez (L7b başlıkları kontrol eder); istemci başlığa bakmaz. Bu alan yalnız 429'da doludur. İstemci zamanı oyuncunun yerel saatine çevirip gösterir, o zamana kadar gönder düğmesini kapatır. 400 / 404 / 409'da otomatik tekrar deneme yok: 400 formu düzelttirir, 404 önce bulut kaydı ister, 409 durum ekranına yönlendirir.
429'un adı yalnız `message`'dadır ve günlük / aylık sınır **ayrı** iki koddur: `loss_report_daily_limit` (24 saatte 1) ve `loss_report_monthly_limit` (30 günde 5). İkisinde de `code` = `PT429`, `hint` boştur (`null`), `details` tekrar deneme zamanıdır. Sunucuda "çok sık bildirim" adlı ayrı bir kod yoktur; istemcideki `lossReport.limit.tooMany` yalnız bu iki ad dışında bir 429 gelirse (ör. ileride eklenecek bir sınır ya da ağ geçidi) kullanılır.
Ret edilen (`rejected`) bildirim açık sayılmaz ama 24 saat / 30 gün sayımına girer (L7).

### Geri yüklemeden sonra kayıt yazımı (B ve v2.2 tetikleyicisi, bu RPC değil)
Geri yükleme (`applied`) sunucuda kaydın `revision`'ını 1 artırır. Açık kalan eski sekme (eski `revision` ile) yazarsa:
- **409 `PT409` `stale_revision`**, `details` = `sent revision N, server revision M`, `hint` = kaydı yeniden çek. Geri yüklenmiş kayıt korunur, eski sekmenin yazısı düşer (L11).
- İstemci bu yazıyı **tekrar denemez**: kaydı yeniden çeker (`GET kodhane_saves`), sonraki yazıda `revision = sunucu revision + 1` gönderir. "Telafin yüklendi, sayfayı yenile" mesajı bu 409'a ve durum ekranında `status = applied`'a bağlanır.
- 426 `PT426` `save_version_too_old` (B): eski istemci sürümü; tekrar deneme yok, sayfa yenilenmeli.

Ops hataları (`22023` / `55000` / `42501` / `23505`, yalnız Aryen'in psql fonksiyonları) oyuncuya gitmez.
HTTP karşılıkları yerel PostgREST (v16.3, `.136` üstünde) testinde doğrulandı: `supabase/tests/loss_report/http_loss_report.sh`, L1–L11 (401 JWT yok + anon anahtar, 403 `not_authenticated`, 400 ×3, 404, 200, 409, 429 günlük + aylık ve `details`, durum RPC'si 10 kolon (`applied_revision` dahil), geri yükleme sonrası 409 `stale_revision` ve L11b `applied_revision` ile kesin ayrım).

## 4. Kodların tam listesi (kod, anlamı, oyuncuya görünür mü)
| alan | kod | anlamı | oyuncuya görünür mü |
|---|---|---|---|
| `status` | `in_review` | inceleniyor (iç `pending` ve `needs_review`) | evet |
| `status` | `approved` | Aryen onayladı, geri yükleme bekliyor | evet |
| `status` | `applied` | geri yüklendi (`applied_at` dolu) | evet |
| `status` | `rejected` | reddedildi (`reason` dolu) | evet |
| iç durum | `pending` | ilk inceleme | hayır (`in_review` görünür) |
| iç durum | `needs_review` | onaydan sonra kayıt değişti / bulut kaydı yok, yeniden inceleme | hayır (`in_review` + `review_reason` görünür) |
| `reason` (ret) | `kayip_bulunamadi` | kazanç günlüğünde kayıp bulunamadı | evet (yalnız kod; metni istemci verir) |
| `reason` (ret) | `zaten_telafi_edildi` | bu kayıp daha önce telafi edildi | evet |
| `reason` (ret) | `kural_disi` | talep kurallara uymuyor (ör. skor kuralını geçmeyen miktar) | evet |
| `reason` (ret) | `diger` | diğer | evet |
| `review_reason` | `save_changed` | onaydan sonra oyuncu oynadı, kayıt değişti | evet (yalnız `in_review` iken) |
| `review_reason` | `no_cloud_save` | bulut kaydı yok ya da geri yüklenecek bir şey kalmadı | evet (yalnız `in_review` iken) |
| `review_reason` | `null` | olağan inceleme | evet |
| `applied_revision` | sayı / `null` | geri yüklemenin yazdığı kayıt revision'ı (yalnız `applied`) | evet (metin değil; istemci 409 ayrımında kullanır) |
| iç not | `ops_note`, `approval_ref`, açıklama, miktarlar | Aryen'in notu, onay referansı | hayır (durum RPC'si döndürmez) |
| hata | `not_authenticated`, `loss_report_invalid`, `no_cloud_save`, `loss_report_open`, `loss_report_daily_limit`, `loss_report_monthly_limit` | bölüm 3 | evet (istemci metne eşler) |
| hata | `stale_revision`, `save_version_too_old` | bölüm 3, kayıt yazımı | evet (istemci metne eşler) |
| hata (ops) | `22023` / `55000` / `42501` / `23505` ops mesajları | Aryen'in psql fonksiyonları | hayır |

Ret kodları tablo CHECK'iyle (`loss_report_reject_reason_check`) sabit; yeni kod migration ister. `reason` boş / `null` ya da tanınmayan bir değerse istemci `lossReport.reject.generic` gösterir (Yazı r2 §5). `diger` geçerli, ayrı bir koddur ve yalnız kendi metniyle (`lossReport.reject.diger`) eşlenir; genel karşılık olarak kullanılmaz.
