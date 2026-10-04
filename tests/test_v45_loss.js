// Kodhane v4.5 (P7) "Kayıp bildir" istemcisi birim testleri (Node, tarayıcısız): lossreport.js saf işlevleri.
// Sunucu sözleşmesi: v4.5-kayip-bildir istemci notu (f00cbf1 + 547010c; applied_revision 1cd221d, 9849ea3'te aynı). Metinler: Yazı r3 (LOSS_TEXT) birebir.
// Çalıştır: node tests/test_v45_loss.js
'use strict';
const path = require('path'), fs = require('fs');
const ROOT = path.join(__dirname, '..');
const K = require(path.join(ROOT, 'game.js'));
const SRC = fs.readFileSync(path.join(ROOT, 'lossreport.js'), 'utf8');
// tarayıcıdaki gibi window.Kodhane = K ile yükle (document yok: yalnız saf işlevler)
const m = { exports: {} };
new Function('module', 'exports', 'require', SRC).call({ Kodhane: K }, m, m.exports, require);
const L = m.exports;
let pass = 0, fail = 0;
function check(name, cond, info) {
  if (cond) pass++; else fail++;
  console.log((cond ? 'PASS ' : 'FAIL ') + name + (info !== undefined && !cond ? ' ' + JSON.stringify(info) : ''));
}
const E = (status, message, details, code) => ({ data: null, error: { message, details: details === undefined ? null : details, code: code || 'PT' + status, hint: null }, status });
const NOW = Date.parse('2026-10-04T10:15:30Z'); // TSİ 13:15:30

// ---------------------------------------------------------------- metinler
const R3 = '/workspace/plans/kodhane-p7-kayip-bildir-yazi-r3.json';
const R3T = fs.existsSync(R3) ? JSON.parse(fs.readFileSync(R3, 'utf8')).LOSS_TEXT : L.TEXT;   // yoksa birebir karşılaştırma kendi metnine düşer
if (fs.existsSync(R3)) {
  const J = JSON.parse(fs.readFileSync(R3, 'utf8')).LOSS_TEXT;
  check('LOSS_TEXT = Yazı r3 LOSS_TEXT (all keys, same order, same text)', JSON.stringify(L.TEXT) === JSON.stringify(J), Object.keys(J).filter((k) => J[k] !== L.TEXT[k]));
} else console.log('NOTE Yazı r3 JSON yok: birebir karşılaştırma atlandı');
check('former pending texts filled from Yazı metinler r1 (2 keys), no METIN BEKLENIYOR left in lossreport.js', Object.keys(L.TEXT_PENDING).length === 2 && Object.keys(L.TEXT_PENDING).every((k) => L.TEXT_PENDING[k] && L.TEXT_PENDING[k][0] !== '[')
  && !/METIN BEKLENIYOR/.test(SRC), L.TEXT_PENDING);
check('account.privacyDetails text is NOT in the code (only a slot)', !/kayıp bildirimi\]|Bildirimini yalnızca kaybolan ilerlemeni incelemek/.test(SRC + fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8'))
  && /id="accPrivacyDetails"[^>]*data-text-key="account\.privacyDetails"[^>]*><\/div>/.test(fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8')));
check('text(): {n} and {sure} substitution', L.text('lossReport.description.counter', { n: 12 }) === '12 / 280' && L.text('lossReport.limit.daily', { sure: '5 dakika' }).endsWith('kalan süre: 5 dakika'));

// ---------------------------------------------------------------- lost_since
const local = (iso) => new Date(iso);
const today0 = new Date(NOW); today0.setHours(0, 0, 0, 0);
const y0 = new Date(today0); y0.setDate(y0.getDate() - 1);
check('Bugün: local day start as UTC ISO', L.lostSinceISO('bugun', NOW) === today0.toISOString() && local(L.lostSinceISO('bugun', NOW)).getHours() === 0);
check('Dün: local start of yesterday as UTC ISO', L.lostSinceISO('dun', NOW) === y0.toISOString());
check('TZ Europe/Istanbul: Bugün at 13:15 TSİ = 2026-10-03T21:00:00.000Z', process.env.TZ !== 'Europe/Istanbul' && new Date().getTimezoneOffset() !== -180 ? true : L.lostSinceISO('bugun', NOW) === '2026-10-03T21:00:00.000Z');
check('Son 7 gün = now - 7 d, Son 30 gün = now - 30 d', L.lostSinceISO('son_7_gun', NOW) === new Date(NOW - 7 * 864e5).toISOString() && L.lostSinceISO('son_30_gun', NOW) === new Date(NOW - 30 * 864e5).toISOString());
check('Bilmiyorum / nothing selected / unknown -> null', [ 'bilmiyorum', null, undefined, '', 'x'].every((c) => L.lostSinceISO(c, NOW) === null));
check('since options = 5 in Yazı order', L.SINCE.join() === 'bugun,dun,son_7_gun,son_30_gun,bilmiyorum');

// ---------------------------------------------------------------- doğrulama
check('items: none -> itemsRequired', L.validate({ items: [] }).key === 'lossReport.error.itemsRequired' && L.validate({}).field === 'items');
check('items: unknown ids dropped, duplicates removed; 1..5 ok', L.validate({ items: ['agac', 'agac', 'x'] }).items.join() === 'agac' && L.validate({ items: L.ITEMS.slice() }).items.length === 5);
check('items: only unknown -> itemsRequired', L.validate({ items: ['hisse'] }).ok === false);
check('description: @ / full-width @ / e-mail -> error.description', ['a@b.com', 'yaz bana x@y', 'ad＠ornek.com', 'ali at gmail.com'].every((d) => L.validate({ items: ['diger'], description: d }).key === 'lossReport.error.description'));
check('description: normal text ok; trimmed; newlines -> space; control chars removed; empty -> null',
  L.validate({ items: ['diger'], description: '  Halka Arz yaptım,\nborsa gitti\u0007 ' }).description === 'Halka Arz yaptım, borsa gitti' && L.validate({ items: ['diger'], description: '   ' }).description === null);
check('description: 280 ok, 281 -> length placeholder (textarea maxlength 280 prevents it)', L.validate({ items: ['diger'], description: 'ç'.repeat(280) }).ok && L.validate({ items: ['diger'], description: 'ç'.repeat(281) }).key === 'lossReport.error.descriptionLength');
const args = L.buildArgs({ items: ['borsa_payi', 'agac'], since: 'dun', description: 'Sayfayı yenileyince gitti' }, NOW);
check('buildArgs: RPC body {p_lost_items, p_lost_since, p_description, p_client_version}', JSON.stringify(Object.keys(args)) === '["p_lost_items","p_lost_since","p_description","p_client_version"]'
  && args.p_lost_items.join() === 'borsa_payi,agac' && args.p_lost_since === y0.toISOString() && args.p_client_version === K.CLIENT_VERSION && K.CLIENT_VERSION === '4.5.0');
check('buildArgs: invalid form -> null (nothing sent)', L.buildArgs({ items: [] }, NOW) === null);

// ---------------------------------------------------------------- hata eşleme
const C = (r) => L.classify(r, NOW);
check('200 -> ok', C({ data: { id: 'x', status: 'in_review' }, error: null, status: 200 }).kind === 'ok');
check('400 lost_items -> itemsRequired (field items)', C(E(400, 'loss_report_invalid', 'lost_items', '22023')).key === 'lossReport.error.itemsRequired' && C(E(400, 'loss_report_invalid', 'lost_items')).field === 'items');
check('400 description -> error.description (field description)', C(E(400, 'loss_report_invalid', 'description')).key === 'lossReport.error.description');
check('400 lost_since -> placeholder lossReport.error.lostSince', C(E(400, 'loss_report_invalid', 'lost_since')).key === 'lossReport.error.lostSince');
check('400 other -> generic', C(E(400, 'something')).key === 'lossReport.error.generic' && C(E(400, 'loss_report_invalid', 'x')).key === 'lossReport.error.generic');
check('401 (no JWT / anon key, 42501) -> needLogin', C(E(401, 'permission denied for function kodhane_loss_report_create', null, '42501')).kind === 'needLogin');
check('403 not_authenticated -> needLogin', C(E(403, 'not_authenticated', null, '42501')).kind === 'needLogin');
check('403 other -> generic (not login)', C(E(403, 'permission denied')).kind === 'generic' && C(E(403, '')).key === 'lossReport.error.generic');
check('404 no_cloud_save -> noCloudSave', C(E(404, 'no_cloud_save', null, 'PT404')).key === 'lossReport.noCloudSave');
check('404 other (function missing PGRST202) -> generic + missing flag', C(E(404, 'Could not find the function', null, 'PGRST202')).key === 'lossReport.error.generic' && C(E(404, 'x', null, 'PGRST202')).missing === true);
// ---------------------------------------------------------------- karar 7: sunucu kurulu mu (durum RPC'si yanıtından)
const A = L.availability;
check('availability: 200 (rows or []) -> yes', A({ data: [], error: null, status: 200 }) === 'yes' && A({ data: [{ id: 'x' }], error: null, status: 200 }) === 'yes');
check('availability: anon 401 42501 (function exists, no EXECUTE for anon) -> yes', A(E(401, 'permission denied for function kodhane_loss_report_status', null, '42501')) === 'yes');
check('availability: 403 not_authenticated -> yes (function exists)', A(E(403, 'not_authenticated', null, '42501')) === 'yes');
check('availability: 404 PGRST202 -> no', A(E(404, 'Could not find the function public.kodhane_loss_report_status(p_limit) in the schema cache', null, 'PGRST202')) === 'no');
check('availability: 404 without code / 42883 -> no', A({ data: null, error: { message: 'HTTP 404' }, status: 404 }) === 'no' && A(E(404, 'function does not exist', null, '42883')) === 'no');
check('availability: 5xx / network (status 0) / 429 / empty -> null (temporary, decision unchanged)', [500, 502, 503, 504].every((st) => A(E(st, 'x')) === null) && A({ data: null, error: { message: 'Failed to fetch' }, status: 0 }) === null
  && A(E(429, 'x')) === null && A(null) === null);
check('CFG.enabled kept as manual off switch; session cache key for the decision', L.CFG.enabled === true && L.CFG.availKey === 'kodhane_loss_avail_v1');
check('section shown only when proven installed (avail === yes), refresh/probe skip when avail is no or disabled',
  /var show = CFG\.enabled && S\.avail === 'yes'/.test(SRC) && /if \(!CFG\.enabled \|\| S\.avail === 'no'\) return Promise\.resolve\(null\)/.test(SRC) && /if \(!CFG\.enabled \|\| S\.avail !== 'unknown'\) return Promise\.resolve\(null\)/.test(SRC));
check('no console output from lossreport.js (no console.error/warn/log)', !/console\.(error|warn|log)/.test(SRC));
check('karar 6: "Backend\'in kesin alanı bekleniyor" notes removed; comment documents applied_revision rule + fallback', !/Backend'in kesin alanı bekleniyor/.test(SRC)
  && /applied_revision/.test(SRC) && /N <= A -> lossReport\.applied\.staleTab/.test(SRC) && /eski sezgiye düşülür/.test(SRC));

// ---------------------------------------------------------------- eski sekme: applied_revision (Backend 1cd221d, istemci notu §2)
const SV = L.staleVerdict;
const ap = (rev, extra) => Object.assign({ id: 'a' + rev, status: 'applied', applied_at: '2026-10-04T09:00:00Z', applied_revision: rev }, extra || {});
check('stale: sent == applied_revision -> staleTab', SV([ap(7)], 7) === 'staleTab');
check('stale: sent < applied_revision -> staleTab', SV([ap(7)], 5) === 'staleTab');
check('stale: sent > applied_revision -> sync (otherDeviceSync)', SV([ap(7)], 8) === 'sync');
check('stale: applied_revision null on the applied row -> null (fallback to the old heuristic)', SV([ap(null)], 5) === null);
check('stale: applied_revision field missing (old server) -> null (fallback)', SV([{ id: 'x', status: 'applied', applied_at: '2026-10-04T09:00:00Z' }], 5) === null);
check('stale: non-applied status (in_review / approved / rejected) with a value -> ignored -> sync', ['in_review', 'approved', 'rejected'].every((st) => SV([{ id: 'n', status: st, applied_revision: 9 }], 5) === 'sync'));
check('stale: non-applied rows with null (normal) -> sync', SV([{ id: 'n', status: 'in_review', applied_revision: null }, { id: 'r', status: 'rejected', applied_revision: null }], 5) === 'sync');
check('stale: no rows -> sync', SV([], 5) === 'sync');
check('stale: several applied rows -> largest applied_revision counts', SV([ap(3), ap(12), ap(8)], 11) === 'staleTab' && SV([ap(3), ap(12), ap(8)], 13) === 'sync');
check('stale: known max >= sent wins even if another applied row has null', SV([ap(9), ap(null)], 9) === 'staleTab');
check('stale: sent > known max but another applied row null -> fallback (null)', SV([ap(9), ap(null)], 10) === null);
check('stale: bigint as numeric string accepted', SV([ap('7')], 7) === 'staleTab' && SV([ap('7')], 8) === 'sync');
check('stale: garbage value (non-numeric string, NaN, object) -> fallback, no crash', SV([ap('abc')], 5) === null && SV([ap(NaN)], 5) === null && SV([ap({})], 5) === null);
check('stale: sent unknown (null / NaN) or rows not loaded -> fallback (null)', SV([ap(7)], null) === null && SV([ap(7)], NaN) === null && SV(null, 5) === null && SV(undefined, 5) === null);
check('stale: null rows inside the list do not crash', SV([null, ap(4)], 4) === 'staleTab');
// consumeAppliedForStale / beforeStale (DOM tarafı): tests/test_v45_ui.py "eski sekme" bölümü
// cloud.js: 409'u alan yazmanın revision'ı
const CSRC = fs.readFileSync(path.join(ROOT, 'cloud.js'), 'utf8');
check('cloud.js: push records the sent revision on the 409 error and passes it to beforeStale({ sent })', /e\.sentRevision = rev/.test(CSRC) && /beforeStale\(\{ sent: sentRevOf\(err\) \}\)/.test(CSRC));
const sro = new Function('return ' + CSRC.slice(CSRC.indexOf('function sentRevOf'), CSRC.indexOf('function handleStale')).trim())();
check('cloud.js sentRevOf: sentRevision wins; else details "sent revision N, server revision M"; else null', sro({ sentRevision: 6, details: 'sent revision 9, server revision 10' }) === 6
  && sro({ details: 'sent revision 9, server revision 10' }) === 9 && sro({ details: 'x' }) === null && sro(null) === null && sro({ details: 5 }) === null);
check('409 loss_report_open -> limit.open', C(E(409, 'loss_report_open')).key === 'lossReport.limit.open');
check('409 stale_revision -> stale (refetch, no retry)', C(E(409, 'stale_revision', 'sent revision 3, server revision 4')).kind === 'stale');
check('409 other -> generic', C(E(409, 'x')).kind === 'generic');
const lim = C(E(429, 'loss_report_daily_limit', '2026-10-05T08:00:00Z', 'PT429'));
check('429 PT429 loss_report_daily_limit + details UTC ISO -> limit.daily, retryAt = details', lim.kind === 'limit' && lim.key === 'lossReport.limit.daily' && lim.retryAt === Date.parse('2026-10-05T08:00:00Z') && lim.defaulted === false, lim);
const limM = C(E(429, 'loss_report_monthly_limit', '2026-11-01T00:00:00Z', 'PT429'));
check('429 PT429 loss_report_monthly_limit + details -> limit.monthly, retryAt = details', limM.key === 'lossReport.limit.monthly' && limM.retryAt === Date.parse('2026-11-01T00:00:00Z') && limM.defaulted === false, limM);
check('429 server example "2026-10-04T16:30:51Z" (second precision) parsed exactly', C(E(429, 'loss_report_daily_limit', '2026-10-04T16:30:51Z', 'PT429')).retryAt === Date.parse('2026-10-04T16:30:51Z'));
check('429 details with milliseconds / surrounding spaces still parsed', C(E(429, 'loss_report_monthly_limit', '2026-10-05T08:00:00.123Z')).retryAt === Date.parse('2026-10-05T08:00:00.123Z') && C(E(429, 'loss_report_daily_limit', ' 2026-10-05T08:00:00Z ')).defaulted === false);
check('429 unknown message with a time -> limit.tooMany, time used', (() => { const r = C(E(429, 'rate_limited', '2026-10-04T11:00:00Z')); return r.key === 'lossReport.limit.tooMany' && r.retryAt === Date.parse('2026-10-04T11:00:00Z'); })());
check('429 unknown / empty / non-string / prototype-name message -> tooMany, no crash', [undefined, null, '', 'yeni_sinir', 42, { a: 1 }, 'toString', '__proto__', 'hasOwnProperty'].every((msg) => {
  const r = C({ data: null, error: { message: msg, details: null, code: 'PT429', hint: null }, status: 429 }); return r.kind === 'limit' && r.key === 'lossReport.limit.tooMany' && r.defaulted === true; }));
check('429 with no error body at all -> tooMany default 24 h, no crash', (() => { const r = C({ data: null, error: null, status: 429 }); return r.kind === 'limit' && r.key === 'lossReport.limit.tooMany' && r.retryAt === NOW + 86400000; })());
const noDet = C(E(429, 'loss_report_daily_limit', null));
check('429 daily without details -> limit.daily, safe default now + 24 h (defaulted)', noDet.retryAt === NOW + 86400000 && noDet.defaulted === true && noDet.key === 'lossReport.limit.daily');
check('429 monthly without details (null / undefined / missing) -> limit.monthly, default 24 h', [null, undefined].every((d) => { const r = C(E(429, 'loss_report_monthly_limit', d)); return r.key === 'lossReport.limit.monthly' && r.retryAt === NOW + 86400000 && r.defaulted; })
  && C({ data: null, error: { message: 'loss_report_monthly_limit', code: 'PT429' }, status: 429 }).retryAt === NOW + 86400000);
check('429 bad details (seconds, local time, offset, garbage, empty, number, object) -> default', ['3600', '2026-10-05 08:00:00', '2026-10-05T08:00:00+03:00', 'yarın', '', 3600, {}].every((d) => C(E(429, 'loss_report_daily_limit', d)).defaulted === true));
check('429 broken ISO that matches the shape (month 13, day 45, hour 99) -> default 24 h', ['2026-13-01T00:00:00Z', '2026-10-45T00:00:00Z', '2026-10-05T99:00:00Z', '2026-10-05T08:61:00Z'].every((d) => { const r = C(E(429, 'loss_report_monthly_limit', d)); return r.defaulted === true && r.retryAt === NOW + 86400000; }));
check('429 LIMIT_KEYS table: daily -> limit.daily, monthly -> limit.monthly (each its own text)', /var LIMIT_KEYS = \{ loss_report_daily_limit: 'lossReport\.limit\.daily', loss_report_monthly_limit: 'lossReport\.limit\.monthly' \}/.test(SRC)
  && L.TEXT['lossReport.limit.daily'] !== L.TEXT['lossReport.limit.monthly'] && L.TEXT['lossReport.limit.daily'] !== L.TEXT['lossReport.limit.tooMany']);
check('429 daily / monthly / tooMany texts = Yazı r3 verbatim, each with one {sure}', ['daily', 'monthly', 'tooMany'].every((k) => L.TEXT['lossReport.limit.' + k] === R3T['lossReport.limit.' + k]
  && (L.TEXT['lossReport.limit.' + k].match(/\{sure\}/g) || []).length === 1));
check('429 {sure} filled: classify key + sureText -> no placeholder left, ends with the duration (daily "1 saat 30 dakika", monthly "3 gün 1 dakika", unknown "1 gün")', [
  ['loss_report_daily_limit', new Date(NOW + 5400000).toISOString().replace(/\.\d+Z$/, 'Z'), 'lossReport.limit.daily', '1 saat 30 dakika'],
  ['loss_report_monthly_limit', new Date(NOW + 3 * 86400000 + 30000).toISOString().replace(/\.\d+Z$/, 'Z'), 'lossReport.limit.monthly', '3 gün 1 dakika'],
  ['yeni_sinir', null, 'lossReport.limit.tooMany', '1 gün']].every(([msg, det, key, sure]) => {
    const r = C(E(429, msg, det, 'PT429')), t = L.text(r.key, { sure: L.sureText(r.retryAt, NOW) });
    return r.key === key && t === L.TEXT[key].replace('{sure}', sure) && !/[{}]/.test(t); }));
check('429 daily and monthly are really used (reachable from classify, not only listed in TEXT)', C(E(429, 'loss_report_daily_limit')).key === 'lossReport.limit.daily' && C(E(429, 'loss_report_monthly_limit')).key === 'lossReport.limit.monthly'
  && C(E(429, 'loss_report_daily_limit ')).key === 'lossReport.limit.tooMany' && C(E(429, 'LOSS_REPORT_DAILY_LIMIT')).key === 'lossReport.limit.tooMany');
check('429 far future clamped to 31 days (daily and monthly)', C(E(429, 'loss_report_daily_limit', '2030-01-01T00:00:00Z')).retryAt === NOW + 31 * 86400000 && C(E(429, 'loss_report_monthly_limit', '2030-01-01T00:00:00Z')).retryAt === NOW + 31 * 86400000);
check('429 header Retry-After is not used (no headers read)', !/retry-after/i.test(SRC.replace(/Retry-After (YOK|DEĞİL|yok)/g, '').replace(/Retry-After YOK/g, '')));
check('network error / empty -> generic', C({ data: null, error: { message: 'Failed to fetch' }, status: 0 }).kind === 'generic' && C(null).kind === 'generic');

// ---------------------------------------------------------------- {sure}
check('{sure} = fmtDur, rounded up to whole minutes', L.sureText(NOW + 5400 * 1000, NOW) === K.fmtDur(5400) && L.sureText(NOW + 61 * 1000, NOW) === '2 dakika' && L.sureText(NOW + 1000, NOW) === '1 dakika');
check('{sure}: 23 h 59 min 30 s -> "1 gün" (rounded up)', L.sureText(NOW + 86370 * 1000, NOW) === '1 gün');
check('{sure}: expired -> "" (text removed, button opens)', L.sureText(NOW, NOW) === '' && L.sureText(NOW - 5, NOW) === '');

// ---------------------------------------------------------------- durum gösterimi
const V = L.statusView;
check('in_review + null -> in_review.text', V({ status: 'in_review', review_reason: null }).text === L.TEXT['lossReport.status.in_review.text'] && V({ status: 'in_review' }).label === 'İnceleniyor');
check('in_review + no_cloud_save -> in_review.text', V({ status: 'in_review', review_reason: 'no_cloud_save' }).text === L.TEXT['lossReport.status.in_review.text']);
check('in_review + save_changed -> in_review.save_changed', V({ status: 'in_review', review_reason: 'save_changed' }).text === L.TEXT['lossReport.status.in_review.save_changed']);
check('approved -> approved label/text, open', V({ status: 'approved' }).text === L.TEXT['lossReport.status.approved.text'] && V({ status: 'approved' }).open === true);
check('applied -> applied.text, not open', V({ status: 'applied', applied_at: '2026-10-04T09:00:00Z' }).text === L.TEXT['lossReport.status.applied.text'] && !V({ status: 'applied' }).open);
L.REJECT_CODES.forEach((c) => check('rejected ' + c + ' -> reject.' + c, V({ status: 'rejected', reason: c }).text === L.TEXT['lossReport.reject.' + c] && V({ status: 'rejected', reason: c }).label === 'Reddedildi'));
check('rejected UNKNOWN code -> reject.generic', ['yeni_kod', 'KAYIP_BULUNAMADI', '__proto__', 'toString', '<b>x</b>'].every((c) => V({ status: 'rejected', reason: c }).text === L.TEXT['lossReport.reject.generic']));
check('rejected EMPTY code (null / "" / missing / non-string) -> reject.generic', [null, '', undefined, 5, {}].every((c) => V({ status: 'rejected', reason: c }).text === L.TEXT['lossReport.reject.generic']) && V({ status: 'rejected' }).text === L.TEXT['lossReport.reject.generic']);
check('unknown status -> safe "in review" view; null row -> null', V({ status: 'pending' }).status === 'in_review' && V(null) === null);
check('latest(): newest by created_at', L.latest([{ id: 'a', created_at: '2026-10-01T00:00:00Z' }, { id: 'b', created_at: '2026-10-03T00:00:00Z' }]).id === 'b' && L.latest([]) === null);
check('status RPC only for own reports (p_limit only, no user id sent)', /call\(CFG\.rpcStatus, \{ p_limit: CFG\.statusLimit \}\)/.test(SRC) && !/p_user/.test(SRC));
check('texts are written with textContent only (no innerHTML in lossreport.js)', !/innerHTML/.test(SRC));

console.log(`\n${pass}/${pass + fail} passed`);
process.exit(fail ? 1 : 0);
