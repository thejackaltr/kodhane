#!/usr/bin/env python3
"""Offline cases for ops/v4_4a_leaderboard_compare.py (no database, no docker): synthetic snapshot files in the exact format of
ops/v4_4a_leaderboard_snapshot.sql, real compare script. Expectation 0/0: any rule result change FAILs (no allow list).
The DB-backed cases (real snapshots of a local copy, preflight STOP / PASS) are in run_v4_4a_compare_tests.sh.
  python3 supabase/tests/v4_4/test_v4_4a_compare_offline.py
"""
import os, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
CMP = os.path.join(HERE, '..', '..', 'ops', 'v4_4a_leaderboard_compare.py')
AK, AREV, AUPD = 'fa7c574270bdf8c6', '1112', '1790860412.696000'
REF, OTH = 'a3a7039e7eb78104', '86be92d060609670'
V43, V44 = 'c92ea962f18652fad67710a312f6397d', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
T0 = 1790830000.0


def snap(ts, plaus, rules, lb):
    """rules: {key: (rule, updated_at, revision)}, lb: [(key, rank, score, stage, status, upd)]"""
    out = ['BEGIN', ' transaction_read_only ', '-----------------------', ' on', '(1 row)', '',
           f'TS0|{ts:.6f}', 'SIG|2d98962d2627f15ea96940c2207ad961', f'PLAUS|{plaus}|plpgsql']
    out += [f'LB|kodhane|{k}|f|{r}|{sc}|{st}|{status}|{u}|1' for k, r, sc, st, status, u in lb]
    out += [f'RULE|kodhane|{k}|{v[0]}|{v[1]}|{v[2]}' for k, v in sorted(rules.items())]
    out += [f'TS1|{ts + 0.02:.6f}', 'ROLLBACK', '__EXIT=0']
    return '\n'.join(out) + '\n'


def base_rules():
    return {REF: ('true', '1790816562.478000', '2077'), AK: ('true', AUPD, AREV), OTH: ('true', '1790801866.381000', '433')}


def base_lb(rules):
    rows = [(REF, 1, '2722622173947303600000', 7), (AK, 2, '5649953667046350', 6), (OTH, 3, '2234877082388.2485', 5)]
    return [(k, r, sc, st, 'ok', rules[k][1]) for k, r, sc, st in rows if k in rules]


def run(name, before_rules, after_rules, want_rc, want, after_plaus=V44, after_lb=None, dt=60.0):
    d = tempfile.mkdtemp()
    b, a = os.path.join(d, 'b.txt'), os.path.join(d, 'a.txt')
    open(b, 'w').write(snap(T0, V43, before_rules, base_lb(before_rules)))
    open(a, 'w').write(snap(T0 + dt, after_plaus, after_rules, after_lb or base_lb(after_rules)))
    p = subprocess.run([sys.executable, CMP, b, a], capture_output=True, text=True)
    ok = p.returncode == want_rc and all(w in p.stdout for w in want)
    print(('PASS ' if ok else 'FAIL ') + f'{name} (exit {p.returncode}, expected {want_rc})')
    if not ok:
        print('   ' + p.stdout.replace('\n', '\n   '))
    return ok


res = []
r0 = base_rules()                       # fa7c-like save true (state since 16:13), all true
r1 = dict(r0); r1[AK] = ('false', AUPD, AREV)
res.append(run('O1 no change at all (A applied, every rule result the same) -> PASS', r0, dict(r0), 0, ['RESULT PASS']))
res.append(run('O2 no change, rule definition unchanged -> PASS', r0, dict(r0), 0, ['RESULT PASS'], after_plaus=V43))
rf = dict(r0); rf[AK] = ('false', AUPD, AREV)
res.append(run('O3 fa7c-like single false -> true -> FAIL', rf, dict(r0), 1, [f'save kodhane {AK}: rule result false -> true', 'RESULT FAIL']))
res.append(run('O4 single true -> false (newly flagged) -> FAIL', r0, r1, 1, [f'save kodhane {AK}: rule result true -> false']))
ra = dict(r0); ra[AK] = ('true', f'{T0 + 30:.6f}', '1113')
res.append(run('O5 false -> true with a player write in the window -> still FAIL', rf, ra, 1, ['rule result false -> true (player wrote in the window)']))
ra = dict(r0); ra[OTH] = ('false', '1790801866.381000', '433')
res.append(run('O6 other save newly flagged -> FAIL', r0, ra, 1, [f'save kodhane {OTH}: rule result true -> false']))
ra = dict(r0); ra[AK] = ('true', f'{T0 + 30:.6f}', '1113')
lb = base_lb(ra); lb[1] = (AK, 2, '5650000000000000', 6, 'ok', ra[AK][1])
res.append(run('O7 player write in the window, rule same, score moves -> PASS', r0, ra, 0, ['score changed, player write in the window', 'RESULT PASS'], after_lb=lb))
ra = dict(r0); ra[AK] = ('true', AUPD, '1113')
lb = base_lb(ra); lb[1] = (AK, 2, '5650000000000000', 6, 'ok', ra[AK][1])
res.append(run('O8 revision moved (updated_at same) explains a score move -> PASS', r0, ra, 0, ['score changed, player write in the window'], after_lb=lb))
lb = base_lb(r0); lb[1] = (AK, 2, '5700000000000000', 6, 'ok', r0[AK][1])
res.append(run('O9 score moves without a write -> FAIL', r0, dict(r0), 1, ['score changed WITHOUT a player write'], after_lb=lb))
ra = dict(r0); del ra[OTH]
res.append(run('O10 save vanished -> FAIL', r0, ra, 1, [f'save kodhane {OTH}: row vanished']))
ra = dict(r0); ra['0123456789abcdef'] = ('true', '1790830010.000000', '1')
res.append(run('O11 save appeared -> FAIL', r0, ra, 1, ['save kodhane 0123456789abcdef: row appeared']))
print(f'== done: {sum(res)} pass / {len(res) - sum(res)} fail')
sys.exit(0 if all(res) else 1)
