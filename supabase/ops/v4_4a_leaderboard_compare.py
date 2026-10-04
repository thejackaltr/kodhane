#!/usr/bin/env python3
"""Kodhane v4.4 PACKAGE A: compare two snapshots of ops/v4_4a_leaderboard_snapshot.sql (before / after the migration).

  python3 supabase/ops/v4_4a_leaderboard_compare.py lb-before.txt lb-after.txt

Expectation (Yazılım Yöneticisi, 2026-10-01 20:24 TSİ): package A changes no save's rule result (newly_accepted 0,
newly_flagged 0; the 07:57 allow list for one save was withdrawn), so the leaderboard only moves where a player wrote a save
between the two reads. Prints only row keys (left(md5(user_id), 16)), change kinds and counts: no nickname, no score / stage values.

Exit codes:
  0 PASS  no save's rule result changed; every leaderboard change (score / stage / status / rank) is explained by a player
          write inside the window (save updated_at or revision changed, or updated_at lies between before.TS0 and after.TS1).
          A rank-only move of a row counts as explained when another row of the same game has an explained score change.
  1 FAIL  -> ROLL BACK NOW (rollback_v44a_tx.sql) and notify Yazılım Yöneticisi:
          * the rule result (true/false) of ANY save changed before -> after (even if that player wrote in the window),
          * a save row or a leaderboard row appeared or vanished,
          * a leaderboard row changed without a player write in the window (unexplained),
          * kodhane_leaderboard's definition changed between the reads.
  3 WARN  snapshot unreadable (missing markers / sections, ambiguous row key): no decision; take the snapshot again.
"""
import sys
from decimal import Decimal


def load(path):
    s = {'ts0': None, 'ts1': None, 'sig': None, 'plaus': None, 'lb': {}, 'rule': {}, 'dup': [], 'ro': False, 'rb': False}
    for line in open(path, encoding='utf-8', errors='replace'):
        line = line.rstrip('\r\n')
        if line.strip() == 'on':
            s['ro'] = True
        if line.strip() == 'ROLLBACK':
            s['rb'] = True
        f = line.split('|')
        if f[0] == 'TS0': s['ts0'] = Decimal(f[1])
        elif f[0] == 'TS1': s['ts1'] = Decimal(f[1])
        elif f[0] == 'SIG': s['sig'] = f[1]
        elif f[0] == 'PLAUS': s['plaus'] = (f[1], f[2])
        elif f[0] == 'LB' and len(f) == 10:
            game, key, _fik, rank, score, stage, status, upd, ndup = f[1:]
            if ndup != '1' or key in s['lb'].get(game, {}):
                s['dup'].append((game, key))
            s['lb'].setdefault(game, {})[key] = (rank, Decimal(score) if score else None, stage, status)
        elif f[0] == 'RULE' and len(f) in (5, 6):   # 6th field (revision) since 2026-10-01
            if (f[1], f[2]) in s['rule']:
                s['dup'].append((f[1], f[2]))
            s['rule'][(f[1], f[2])] = (f[3], Decimal(f[4]), f[5] if len(f) == 6 else None)
    return s


def main(bp, ap):
    b, a = load(bp), load(ap)
    fails, warns, info = [], [], []
    for name, s in (('before', b), ('after', a)):
        if s['ts0'] is None or s['ts1'] is None or s['sig'] is None or not s['rule'] or 'kodhane' not in s['lb']:
            warns.append(f'{name}: snapshot incomplete (TS / SIG / RULE / LB kodhane missing)')
        if not s['ro'] or not s['rb']:
            warns.append(f'{name}: read only / ROLLBACK markers missing')
        if s['dup']:
            warns.append(f'{name}: row key ambiguous for {len(s["dup"])} row(s)')
    if warns:
        return report(fails, warns, info)
    w0, w1 = b['ts0'], a['ts1']
    info.append(f'window between reads: {float(w1 - w0):.1f} s')
    info.append(f'kodhane_score_plausible before {b["plaus"][0][:8]}… ({b["plaus"][1]}), after {a["plaus"][0][:8]}… ({a["plaus"][1]})')
    if b['sig'] != a['sig']:
        fails.append('kodhane_leaderboard definition changed between the reads')

    def wrote(k):
        x, y = b['rule'].get(k), a['rule'].get(k)
        return x is not None and y is not None and (x[1] != y[1] or x[2] != y[2] or w0 <= y[1] <= w1)

    # 1) rule results of every save
    n_rule = n_rule_w = 0
    for k in sorted(set(b['rule']) | set(a['rule'])):
        x, y = b['rule'].get(k), a['rule'].get(k)
        if x is None or y is None:
            fails.append(f'save {k[0]} {k[1]}: row {"appeared" if x is None else "vanished"}')
            continue
        n_rule += 1
        if wrote(k): n_rule_w += 1
        if x[0] != y[0]:
            fails.append(f'save {k[0]} {k[1]}: rule result {x[0]} -> {y[0]}' + (' (player wrote in the window)' if wrote(k) else ''))
    info.append(f'saves compared: {n_rule}, written by the player in the window: {n_rule_w}')
    # 2) leaderboard rows
    for game in sorted(set(b['lb']) | set(a['lb'])):
        rb_, ra_ = b['lb'].get(game, {}), a['lb'].get(game, {})
        explained_score = False; rank_only = []; n_same = n_expl = 0
        for key in sorted(set(rb_) | set(ra_)):
            x, y = rb_.get(key), ra_.get(key)
            if x is None or y is None:
                fails.append(f'{game} {key}: leaderboard row {"appeared" if x is None else "vanished"}')
                continue
            if x == y:
                n_same += 1; continue
            if x[1:] == y[1:]:
                rank_only.append(key); continue
            what = '/'.join(n for n, i in (('score', 1), ('stage', 2), ('status', 3)) if x[i] != y[i])
            if wrote((game, key)):
                explained_score = True; n_expl += 1
                info.append(f'{game} {key}: {what} changed, player write in the window')
            else:
                fails.append(f'{game} {key}: {what} changed WITHOUT a player write in the window')
        for key in rank_only:
            if explained_score or wrote((game, key)):
                info.append(f'{game} {key}: rank-only move (explained by a player write in the window)')
            else:
                fails.append(f'{game} {key}: rank changed, no player write in the window')
        info.append(f'{game}: rows before {len(rb_)}, after {len(ra_)}, unchanged {n_same}, explained changes {n_expl}, rank-only {len(rank_only)}')
    return report(fails, warns, info)


def report(fails, warns, info):
    for m in info: print('INFO ', m)
    for m in warns: print('WARN ', m)
    for m in fails: print('FAIL ', m)
    if fails:
        print('RESULT FAIL -> roll back now: pexec.sh rollback_v44a_tx.sql (or psql -1 -f supabase/rollback/20260929203000_v4_4a_kodhane_score_plausible.rollback.sql), then notify Yazılım Yöneticisi')
        return 1
    if warns:
        print('RESULT WARN -> snapshot unreadable: take it again (no decision on this output)')
        return 3
    print('RESULT PASS (no rule result changed; leaderboard changes only from player writes)')
    return 0


if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(__doc__); sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
