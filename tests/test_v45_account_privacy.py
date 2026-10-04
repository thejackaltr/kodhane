"""Kodhane v4.5 "Hesap ve bulut kaydı hakkında" (Yazı kodhane-hesap-bilgilendirme-yazi-r17): varsayılan KAPALI; kapalıyken DOM'da görünmez,
açıkça açılınca 360x640 / 390x844 / 568x320'de taşmadan sığar. Metinler r17 JSON bloklarıyla birebir.
Ekran görüntüleri: KODHANE_V45_SHOTS (varsayılan /workspace/kodhane-v45-shots), v45-hesap-bilgi-<durum>-<görünüm>.png
    python3 tests/test_v45_account_privacy.py
"""
import json
import mimetypes
import os
import re
import sys
from urllib.parse import urlsplit

from playwright.sync_api import sync_playwright

ROOT = os.environ.get('KODHANE_ROOT') or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.environ.get('KODHANE_V45_SHOTS', '/workspace/kodhane-v45-shots')
os.makedirs(SHOTS, exist_ok=True)
BASE = 'https://kodhane.teserix.com/'
SAVE_KEY = 'kodhane_ajans_save_v2'
SAFETY = ('MAP analiz.teserix.com 127.0.0.1:9, MAP kodhane-api.teserix.com 127.0.0.1:9, MAP supabase.teserix.com 127.0.0.1:9, '
          'MAP kodhane.teserix.com 127.0.0.1:9, MAP thejackaltr.github.io 127.0.0.1:9, MAP cdn.jsdelivr.net 127.0.0.1:9, '
          'MAP acikofis.teserix.com 127.0.0.1:9, MAP *.supabase.co 127.0.0.1:9')
results = []
MEAS = {}


def check(name, cond, info=''):
    results.append((name, bool(cond)))
    print(('PASS' if cond else 'FAIL'), name, info if not cond else '')


def file_route(root):
    def handler(route):
        path = urlsplit(route.request.url).path.lstrip('/') or 'index.html'
        fp = os.path.normpath(os.path.join(root, path))
        if not fp.startswith(root) or not os.path.isfile(fp):
            return route.fulfill(status=404, body='not found')
        route.fulfill(status=200, headers={'content-type': mimetypes.guess_type(fp)[0] or 'application/octet-stream', 'cache-control': 'no-store'},
                      body=open(fp, 'rb').read())
    return handler


def supabase(route):
    cors = {'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*', 'content-type': 'application/json'}
    if route.request.method == 'OPTIONS':
        return route.fulfill(status=204, headers=cors, body='')
    route.fulfill(status=200, headers=cors, body='[]')


NODES12 = ['kod_1', 'kod_2', 'kod_3', 'ekip_1', 'ekip_2', 'ekip_3', 'musteri_1', 'musteri_2', 'musteri_3', 'yatirim_1', 'yatirim_2', 'yatirim_3']
GENS = ['stajyer', 'junior', 'senior', 'tasarimci', 'pm', 'ai', 'sunucu', 'ofis', 'veri', 'arge', 'cip', 'yzlab', 'mars']


def save(**kw):
    d = {'version': 6, 'saveVersion': 6, 'money': 5e21, 'runEarned': 2e21, 'totalEarned': 3e21, 'cycleEarned': 2e21,
         'clicks': 10, 'clickEarned': 10, 'playTime': 9000, 'startedAt': 0, 'lastSaved': 0,
         'gens': {'stajyer': 160, 'junior': 120, 'senior': 40}, 'upgrades': [], 'shares': 1200, 'prestigeCount': 9, 'cycleRounds': 10,
         'stage': 7, 'stageBest': 7, 'cycleStage': 7, 'stageId': 'asama_1e21', 'stageBestId': 'asama_1e21', 'cycleStageId': 'asama_1e21',
         'achievements': [], 'reputation': 150, 'tree': NODES12[:11], 'ipoShares': 9, 'ipoSharesEarned': 60, 'ipoCount': 5, 'ipoAt': 0,
         'newsSeen': ['yeni_asama', 'siralama', 'acik_ofis'], 'newsPending': []}
    d.update(kw)
    return d


R17 = '/workspace/plans/kodhane-hesap-bilgilendirme-yazi-r17.md'
R8 = '/workspace/plans/kodhane-hesap-bilgilendirme-yazi-r8.md'
VP = {'360x640': dict(viewport={'width': 360, 'height': 640}, is_mobile=True, has_touch=True),
      '390x844': dict(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True, device_scale_factor=2),
      '568x320': dict(viewport={'width': 568, 'height': 320}, is_mobile=True, has_touch=True)}
ACC = {}
if os.path.exists(R17):
    for mm in re.finditer(r'```json\n(.*?)```', open(R17, encoding='utf-8').read(), re.S):
        ACC.update(json.loads(mm.group(1))['ACC_TEXT'])
R8_0 = None
if os.path.exists(R8):
    for mm in re.finditer(r'```json\n(.*?)```', open(R8, encoding='utf-8').read(), re.S):
        v = json.loads(mm.group(1))['ACC_TEXT'].get('account.privacyDetails[0]')
        if v and '12 ay' not in v:
            R8_0 = v
OVERFLOW = """([sel, W]) => {
  const bad = [];
  for (const root of document.querySelectorAll(sel)) for (const el of [root, ...root.querySelectorAll('*')]) {
    if (el.offsetParent === null && getComputedStyle(el).position !== 'fixed') continue;
    if (el.closest('.sr-only')) continue;
    const r = el.getBoundingClientRect(); if (!r.width && !r.height) continue;
    const cs = getComputedStyle(el);
    if ((el.scrollWidth > el.clientWidth + 1 && el.clientWidth > 0 && el.children.length === 0 && cs.textOverflow !== 'ellipsis') || r.right > W + 0.5 || r.left < -0.5) bad.push(el.id || el.className || el.tagName);
  }
  return { n: bad.length, bad: bad.slice(0, 8), doc: document.documentElement.scrollWidth };
}"""
SIGN_IN = """() => { Kodhane.cloud.state.user = { id: '11111111-2222-4333-8444-555555555555', email: 'oyuncu@ornek.com' };
  Kodhane.cloud.state.status = 'saved'; Kodhane.cloud.open(); Kodhane.onCloudRender && Kodhane.onCloudRender(); }"""

with sync_playwright() as p:
    b = p.chromium.launch(args=['--host-resolver-rules=' + SAFETY])

    def new_page(vp):
        ctx = b.new_context(locale='tr-TR', service_workers='block', timezone_id='Europe/Istanbul', **VP[vp])
        ctx.add_init_script('window.KODHANE_QUIET = true;')
        ctx.add_init_script("(() => { if (sessionStorage.getItem('kh_seeded')) return; sessionStorage.setItem('kh_seeded','1');"
                            "localStorage.setItem('kodhane_tel_notice', '1'); localStorage.setItem('kodhane_tel', 'off');"
                            "localStorage.setItem(%s, %s); })();" % (json.dumps(SAVE_KEY), json.dumps(json.dumps(save()))))
        ctx.route(re.compile(r'^https?://(?!kodhane\.teserix\.com/|analiz\.teserix\.com/|kodhane-api\.teserix\.com/|supabase\.teserix\.com/).*'), lambda r: r.abort('blockedbyclient'))
        ctx.route('https://kodhane.teserix.com/**', file_route(ROOT))
        ctx.route('https://analiz.teserix.com/**', lambda r: r.fulfill(status=404, body=''))
        ctx.route('https://kodhane-api.teserix.com/**', supabase)
        ctx.route('https://supabase.teserix.com/**', supabase)
        pg = ctx.new_page()
        errs = []
        pg.on('pageerror', lambda e: errs.append(str(e)))
        pg.goto(BASE)
        pg.wait_for_selector('#clickBtn')
        pg.wait_for_timeout(400)
        pg.evaluate("document.querySelectorAll('#modal:not(.hidden) .ghost, #modal:not(.hidden) .primary').forEach(b => b.click()); Kodhane.hideStageUp && Kodhane.hideStageUp()")
        return ctx, pg, errs

    def shot(pg, name, vp):
        pg.wait_for_timeout(200)
        pg.evaluate("document.querySelectorAll('#toast > *').forEach((t) => t.remove())")
        pg.screenshot(path=os.path.join(SHOTS, 'v45-hesap-bilgi-%s-%s.png' % (name, vp)))

    TITLE = 'Hesap ve bulut kaydı hakkında'
    # ---- kapalı (varsayılan): misafir + girişli, DOM'da görünmez
    ctx, pg, errs = new_page('360x640')
    ev = pg.evaluate
    A = ev('Kodhane.cloud.ACC_TEXT')
    if ACC:
        check('texts = Yazı r17 verbatim: privacyLink, privacyTitle = "%s"' % TITLE, A['account.privacyLink'] == ACC['account.privacyLink'] == TITLE and A['account.privacyTitle'] == ACC['account.privacyTitle'] == TITLE)
        check('paragraphs [0], [8], [9] = Yazı r17 verbatim', all(A['account.privacyDetails'][i] == ACC['account.privacyDetails[%d]' % i] for i in (0, 8, 9)))
    missing = [i for i, t in enumerate(A['account.privacyDetails']) if t.startswith('[')]
    check('paragraphs not in r17 stay [key] placeholders: [1]-[7] and veri sorumlusu', missing == [1, 2, 3, 4, 5, 6, 7, 10], missing)
    check('default OFF: PRIVACY = {enabled: false, loginLog12m: false, resetBackup30d: false}', ev('Kodhane.cloud.PRIVACY') == {'enabled': False, 'loginLog12m': False, 'resetBackup30d': False})
    pg.click('#accountBtn'); pg.wait_for_selector('#accountPanel:not(.hidden)'); pg.wait_for_timeout(250)
    off = ev("() => { const l = document.getElementById('accPrivacyLink'), d = document.getElementById('accPrivacyDetails'); return [l.classList.contains('hidden'), l.textContent, l.offsetParent === null, d.classList.contains('hidden'), d.innerHTML, d.offsetParent === null]; }")
    check('OFF, guest: link hidden + empty, panel hidden + empty (not visible in DOM)', off == [True, '', True, True, '', True], off)
    check('OFF, guest: title text nowhere in the visible page', TITLE not in ev('document.body.innerText'))
    ev("document.getElementById('accPrivacyLink').click()"); pg.wait_for_timeout(100)
    check('OFF: clicking the hidden link does nothing (panel stays empty)', ev("document.getElementById('accPrivacyDetails').innerHTML") == '')
    ev(SIGN_IN); pg.wait_for_timeout(250)
    check('OFF, signed in: still hidden, title nowhere', ev("document.getElementById('accPrivacyLink').offsetParent === null && document.getElementById('accPrivacyDetails').innerHTML === ''") and TITLE not in ev('document.body.innerText'))
    check('no page errors (off)', not errs, errs)
    ctx.close()

    # ---- açıkça açık: 3 görünüm, misafir + girişli, sığma + ekran görüntüleri
    for vp in VP:
        ctx, pg, errs = new_page(vp)
        ev = pg.evaluate
        ev('Kodhane.cloud.PRIVACY.enabled = true; Kodhane.cloud.renderPrivacy()')
        pg.click('#accountBtn'); pg.wait_for_selector('#accountPanel:not(.hidden)'); pg.wait_for_timeout(250)
        check('[%s] ON, guest: link visible "%s", panel closed' % (vp, TITLE), pg.is_visible('#accPrivacyLink') and pg.inner_text('#accPrivacyLink') == TITLE and not pg.is_visible('#accPrivacyDetails'))
        ev("document.getElementById('accPrivacyLink').scrollIntoView({block: 'center'})"); shot(pg, 'baglanti', vp)
        pg.click('#accPrivacyLink'); pg.wait_for_timeout(150)
        ps = ev("[...document.querySelectorAll('#accPrivacyDetails p')].map((p) => p.textContent)")
        check('[%s] ON: panel open, title + paragraphs, aria-expanded true' % vp, pg.is_visible('#accPrivacyDetails') and pg.inner_text('#accPrivacyDetails h4') == TITLE
              and ev("document.getElementById('accPrivacyLink').getAttribute('aria-expanded')") == 'true' and len(ps) == 10, len(ps))
        if vp == '360x640':
            check('flags off: [0] without the 12-month sentence (= r8 [0]), [8] (30-day reset backup) not shown', ps[0] == A['account.privacyDetails'][0].replace(' Bu giriş kayıtları 12 ay sonra silinir.', '')
                  and (R8_0 is None or ps[0] == R8_0) and A['account.privacyDetails'][8] not in ps, ps[0])
        r = ev(OVERFLOW, ['#accountPanel', VP[vp]['viewport']['width']])
        check('[%s] ON, open: no horizontal overflow in the account window' % vp, r['n'] == 0 and r['doc'] <= VP[vp]['viewport']['width'], r)
        reach = ev("""() => { const card = document.querySelector('#accountPanel .account-card'); const ps = [...document.querySelectorAll('#accPrivacyDetails p')]; const last = ps[ps.length - 1];
          last.scrollIntoView({ block: 'nearest' }); const r = last.getBoundingClientRect(), C = card.getBoundingClientRect();
          return r.bottom <= Math.min(innerHeight, C.bottom) + 0.5 && r.top >= Math.max(0, C.top) - 0.5 && card.scrollHeight >= card.clientHeight; }""")
        check('[%s] ON, open: last paragraph reachable by scrolling inside the account card' % vp, reach)
        ev("document.getElementById('accPrivacyDetails').scrollIntoView({block: 'start'})"); shot(pg, 'acik', vp)
        pg.click('#accPrivacyLink'); pg.wait_for_timeout(100)
        check('[%s] toggle closes the panel' % vp, not pg.is_visible('#accPrivacyDetails') and ev("document.getElementById('accPrivacyLink').getAttribute('aria-expanded')") == 'false')
        ev(SIGN_IN); pg.wait_for_timeout(200)
        pg.click('#accPrivacyLink'); pg.wait_for_timeout(150)
        r = ev(OVERFLOW, ['#accountPanel', VP[vp]['viewport']['width']])
        check('[%s] ON, signed in, open: visible, no overflow' % vp, pg.is_visible('#accPrivacyDetails') and r['n'] == 0, r)
        if vp == '360x640':
            ev('Kodhane.cloud.PRIVACY.loginLog12m = true; Kodhane.cloud.PRIVACY.resetBackup30d = true; Kodhane.cloud.renderPrivacy()')
            ps2 = ev("[...document.querySelectorAll('#accPrivacyDetails p')].map((p) => p.textContent)")
            check('flags on: [0] with the 12-month sentence (r17 verbatim) and [8] shown', ps2[0] == A['account.privacyDetails'][0] and A['account.privacyDetails'][8] in ps2 and len(ps2) == 11)
            ev('Kodhane.cloud.PRIVACY.enabled = false; Kodhane.cloud.renderPrivacy()')
            check('switching back OFF empties and hides link + panel', not pg.is_visible('#accPrivacyLink') and ev("document.getElementById('accPrivacyDetails').innerHTML") == '')
        check('[%s] no page errors' % vp, not errs, errs)
        ctx.close()
    b.close()

n_ok = sum(1 for _, ok in results if ok)
print('\nSUMMARY: %d/%d passed' % (n_ok, len(results)))
sys.exit(0 if n_ok == len(results) else 1)
