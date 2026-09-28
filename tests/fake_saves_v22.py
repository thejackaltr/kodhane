"""Backend v2.2 Kodhane kayıt sözleşmesinin (acik-ofis-v2.2-backend: 20260928160000_v2_2_kodhane_save_safety.sql, commit
edilmemiş taslak; önceki genel sürüm 1392c49) Python taklidi.
Playwright testlerindeki sahte Supabase'ler (test_cloud.py, test_reset_ui.py) bunu kullanır; cloud.js'teki
createSaveMock ile aynı kurallar ve aynı hata kodları/biçimleri:
  yazma: revision < sunucu -> 409 PT409 stale_revision; = sunucu -> strict satırda stale_revision, lenient'te
         totalEarned düşüyorsa stale_write, yoksa kabul (+1); > sunucu -> kabul, satır strict olur.
  kodhane_reset_save() -> {revision, backup_id, best_score, best_stage}; kodhane_restore_save(p_backup_id) -> {revision,
  backup_id, restored_from, best_score, best_stage} (404 PT404 backup_not_found); kodhane_list_save_backups() ->
  [{id, revision, reason, score, best_score, stage, best_stage, created_at, expires_at}]; DELETE -> 403 42501.
  best_score/best_stage/strict_revision yazılamaz (42501). Yanıtlarda 'game' alanı yok.
"""
import time
import uuid

RETENTION_DAYS = 30
# cloud.js RPC sabitiyle aynı adlar (tek yer cloud.js; testler oradan okur)
_CLOUD = open(__import__('os').path.join(__import__('os').path.dirname(__import__('os').path.abspath(__file__)), '..', 'cloud.js'), encoding='utf-8').read()
RPC = {k: __import__('re').search(k + r": '([a-z_]+)'", _CLOUD).group(1) for k in ('reset', 'restore', 'listBackups')}
DAY = 86400


def iso(t=None):
    t = time.time() if t is None else t
    return time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(t)) + '.%03dZ' % int((t % 1) * 1000)


def score(d):
    t = (d or {}).get('totalEarned')
    return float(t) if isinstance(t, (int, float)) and not isinstance(t, bool) and t >= 0 else 0.0


STAGE_AT = [0, 1e3, 5e4, 1e6, 5e7, 2.5e9, 1e15, 1e19, 1e23]


def stage(d):
    st = (d or {}).get('stage')
    return min(99, max(0, int(st))) if isinstance(st, (int, float)) and not isinstance(st, bool) else 0


def stage_checked(d):  # kodhane_save_stage_checked (makullük kontrolü taklit edilmez)
    st, sc = stage(d), score(d)
    return 0 if st == 0 or sc <= 0 or st > 8 or sc < STAGE_AT[st] else st


def err(status, code, message, details=None, hint=None):
    return status, {'code': code, 'message': message, 'details': details, 'hint': hint}


def reset_payload(old, ms):
    old = old or {}
    return {'version': old.get('version', 4) if isinstance(old.get('version'), (int, float)) else 4,
            'startedAt': ms, 'lastSaved': ms, 'resetAt': ms, 'money': 0, 'runEarned': 0, 'totalEarned': 0, 'cycleEarned': 0,
            'clicks': 0, 'clickEarned': 0, 'playTime': 0, 'eventsClicked': 0, 'offlineEarned': 0, 'gens': {}, 'upgrades': [],
            'achievements': [], 'shares': 0, 'prestigeCount': 0, 'cycleRounds': 0, 'ipoShares': 0, 'ipoSharesEarned': 0,
            'ipoCount': 0, 'tree': [], 'stage': 0, 'stageBest': 0, 'cycleStage': 0, 'reputation': 0, 'boostLeft': 0, 'buffs': [],
            'critClicks': 0, 'eventsResolved': 0, 'logoAccepted': 0, 'revisions': 0, 'meetings': 0, 'serverCrashes': 0,
            'noMeetingSec': 0, 'daily': {'date': None, 'tasks': [], 'streak': 0, 'best': 0, 'lastComplete': None, 'allDone': False,
                                         'daysCompleted': 0},
            'newsSeen': old.get('newsSeen') if isinstance(old.get('newsSeen'), list) else [], 'newsPending': [],
            'sectorCool': {}, 'followUps': {'kafe': 0, 'emlak': 0}, 'pendingPay': []}


class SaveStore:
    def __init__(self, table='kodhane_saves'):
        self.table = table
        self.rows = None  # dışarıdan bağlanır (FakeSupabase.rows ile aynı sözlük)
        self.backups = []
        self.mode = 'lenient'
        self.rpc_log = []

    def alive(self, b):
        return b['created'] > time.time() - RETENTION_DAYS * DAY

    def write(self, uid, it):
        """(status, body) döner; 201 = kabul."""
        if it.get('user_id') != uid:
            return err(403, '42501', 'new row violates row-level security policy for table "%s"' % self.table)
        if 'best_score' in it or 'best_stage' in it or 'strict_revision' in it:
            return err(403, '42501', 'permission denied for table %s' % self.table)
        old = self.rows.get(uid)
        sent = it.get('revision') if isinstance(it.get('revision'), (int, float)) else None
        upd = it.get('updated_at') or iso()
        if old is None:
            rev = max(int(sent or 0), 0)
            prev = max([b['best_score'] for b in self.backups if b['user_id'] == uid] or [0])
            prev_st = max([b['best_stage'] for b in self.backups if b['user_id'] == uid] or [0])
            self.rows[uid] = {'data': it['data'], 'save_version': it.get('save_version'), 'updated_at': upd, 'revision': rev,
                              'strict_revision': rev > 0, 'best_score': max(score(it['data']), prev),
                              'best_stage': max(stage_checked(it['data']), prev_st)}
            return 201, None
        orev = int(old.get('revision') or 0)
        rev = orev if sent is None else int(sent)
        detail = 'sent revision %s, server revision %s' % (rev, orev)
        if rev < orev:
            return err(409, 'PT409', 'stale_revision', detail, 'Pull the save again and send revision = server revision + 1.')
        if rev == orev:
            if old.get('strict_revision') or self.mode == 'strict':
                return err(409, 'PT409', 'stale_revision', detail, 'Send revision = server revision + 1.')
            if score(it['data']) < score(old.get('data')):
                return err(409, 'PT409', 'stale_write', 'totalEarned would drop', 'Use kodhane_reset_save() to start over; pull the save before writing.')
            rev, strict = orev + 1, False
        else:
            strict = True
        self.rows[uid] = {'data': it['data'], 'save_version': it.get('save_version'), 'updated_at': upd, 'revision': rev,
                          'strict_revision': strict, 'best_score': max(float(old.get('best_score') or 0), score(it['data'])),
                          'best_stage': max(int(old.get('best_stage') or 0), stage_checked(it['data']))}
        return 201, None

    def _backup(self, uid, row, reason):
        b = {'id': str(uuid.uuid4()), 'user_id': uid, 'game': 'kodhane', 'revision': int(row.get('revision') or 0), 'payload': row.get('data'),
             'best_score': float(row.get('best_score') or 0), 'best_stage': int(row.get('best_stage') or 0), 'reason': reason, 'created': time.time() + len(self.backups) * 1e-3}
        self.backups.append(b)
        return b

    def rpc(self, uid, name, body):
        self.rpc_log.append((name, body))
        if not uid:
            return err(401, '42501', 'permission denied for function %s' % name)
        if name == RPC['reset']:
            row = self.rows.get(uid)
            if not row:
                return 200, {'revision': 0, 'backup_id': None, 'best_score': 0, 'best_stage': 0}
            b = self._backup(uid, row, 'reset')
            row['data'] = reset_payload(row.get('data'), int(time.time() * 1000))
            row['revision'] = int(row.get('revision') or 0) + 1
            row['strict_revision'] = True
            row['updated_at'] = iso()
            return 200, {'revision': row['revision'], 'backup_id': b['id'], 'best_score': row.get('best_score', 0), 'best_stage': row.get('best_stage', 0)}
        if name == RPC['restore']:
            src = next((b for b in self.backups if b['id'] == body.get('p_backup_id') and b['user_id'] == uid and self.alive(b)), None)
            if not src:
                return err(404, 'PT404', 'backup_not_found')
            row = self.rows.get(uid)
            bid = None
            if row:
                bid = self._backup(uid, row, 'restore')['id']
                rev = int(row.get('revision') or 0) + 1
                row.update({'data': src['payload'], 'revision': rev, 'strict_revision': True, 'updated_at': iso(),
                            'best_score': max(float(row.get('best_score') or 0), score(src['payload'])),
                            'best_stage': max(int(row.get('best_stage') or 0), stage_checked(src['payload']))})
            else:
                rev = src['revision'] + 1
                self.rows[uid] = row = {'data': src['payload'], 'save_version': 4, 'updated_at': iso(), 'revision': rev, 'strict_revision': True,
                                        'best_score': max([b['best_score'] for b in self.backups if b['user_id'] == uid] or [0]),
                                        'best_stage': max([b['best_stage'] for b in self.backups if b['user_id'] == uid] or [0])}
                row['best_score'] = max(row['best_score'], score(src['payload']))
                row['best_stage'] = max(row['best_stage'], stage_checked(src['payload']))
            return 200, {'revision': rev, 'backup_id': bid, 'restored_from': src['id'], 'best_score': row['best_score'], 'best_stage': row.get('best_stage', 0)}
        if name == RPC['listBackups']:
            out = [b for b in self.backups if b['user_id'] == uid and self.alive(b)]
            out.sort(key=lambda b: -b['created'])
            return 200, [{'id': b['id'], 'revision': b['revision'], 'reason': b['reason'], 'score': score(b['payload']),
                          'best_score': b['best_score'], 'stage': stage(b['payload']), 'best_stage': b['best_stage'], 'created_at': iso(b['created']), 'expires_at': iso(b['created'] + RETENTION_DAYS * DAY)}
                         for b in out]
        return err(404, 'PGRST202', 'Could not find the function public.%s' % name)
