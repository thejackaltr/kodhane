#!/usr/bin/env python3
# Independent reference for the v4.5 rule's B bound (time x max income): units per employee are counted unit by unit
# (like the game's maxAffordable in the v4.5 simulation, sim45.js), NOT with the closed form of the migration. For each
# vector the elapsed time e* where t = 10 x e x cap(t) is computed; the save is then written once with e = e* x 1.001
# (expected plausible) and once with e = e* / 1.001 (expected implausible). Output: TSV  label \t d(json) \t p_now_ms \t expected
# Usage: boundary_vectors.py <curve id: f2|f3|v44>  (curve values = rows v45_f2 / v45_f3 of the migration; v44 = [[0, 1.15]])
import json, math, sys
CURVES = {'f2': [[0, 1.15], [300, 1.10], [500, 1.05], [1000, 1.025], [3000, 1.0125]],
          'f3': [[0, 1.15], [100, 1.20], [300, 1.10], [500, 1.05], [1000, 1.025], [3000, 1.0125]],
          'v44': [[0, 1.15]]}
TIER = 32 * 1.25 ** 14 if sys.argv[1] != 'v44' else 32
IK, CUT = 0.14 / 0.15, (0.8 if sys.argv[1] != 'v44' else 1.0)
GENS = [('stajyer', 15, 0.2, 0), ('junior', 100, 1, 0), ('senior', 1100, 8, 0), ('tasarimci', 12000, 47, 0), ('pm', 130000, 260, 0),
        ('ai', 1400000, 1400, 0), ('sunucu', 20000000, 7800, 0), ('ofis', 330000000, 44000, 0), ('veri', 1.5e9, 1.2e5, 1e11),
        ('arge', 6.0e9, 3.0e5, 1e13), ('cip', 2.5e10, 8.0e5, 1e15), ('yzlab', 1.2e11, 2.5e6, 1e19), ('mars', 3.0e12, 2.0e7, 1e23)]
def units_curve(t, b, f, segs):
    n, cost, logp, j = 0, 0.0, 0.0, 0
    while True:
        while j + 1 < len(segs) and n >= segs[j + 1][0]: j += 1
        p = b * math.exp(logp)
        if cost + p > t: return n
        cost += p; logp += math.log(1 + (segs[j][1] - 1) * f); n += 1
def units_v44(t, b, ipo):
    g = 1.14 if ipo else 1.15
    return math.floor(math.log(t * (g - 1) / b + 1) / math.log(g))
def cap(t, ipo, segs, s=0.0, p=0.0, ic=0.0, ge=0.0):
    f = IK * CUT if ipo else 1.0
    base = 10 + sum(tps * max(units_v44(t, b, ipo), units_curve(t, b, f, segs)) for _, b, tps, need in GENS if t >= need)
    sm = 2.0
    if ipo:
        sc = (1 + 0.1 * min(max(ge, 0), 40)) * math.sqrt((p + ic) * t / 1e8) + 1
        return (base * TIER * 1.1 * 2.4904 * sm * 3 * (1 + 0.125 * max(s, sc)) * 1.5 * 64 * (1 + 0.01 * min(ge, 50))
                + 20 * 12 * 2 * sm * (1 + 0.125 * max(s, sc)) * 10 * 10 * 2 + 1000)
    return base * TIER * 1.1 * 2.4904 * sm * 3 * (1 + 0.1 * s) * 32 + 20 * 12 * sm * (1 + 0.1 * s) * 10 * 2 + 1000
NOW = 2208988800000  # 2040-01-01 UTC: far after launch, so only startedAt limits the elapsed time
LAUNCH = 1790467200000  # 2026-09-27 00:00 UTC (the rule never counts time before it)
segs = CURVES[sys.argv[1]]
for t in [10 ** (k / 4) for k in range(36, 241)]:   # 1e9 ... 1e60; only t whose edge e* lies inside the rule's window
    for ipo in (False, True):
        fields = dict(totalEarned=t, runEarned=t, cycleEarned=t, saveVersion=5, version=5)
        if ipo: fields.update(ipoCount=1, prestigeCount=3, cycleRounds=0, shares=0, ipoSharesEarned=1)
        c = cap(t, ipo, segs, p=3 if ipo else 0, ic=1 if ipo else 0, ge=1 if ipo else 0)
        e = t / (10 * c)
        if e <= 3700 or e * 1.001 >= (NOW - LAUNCH) / 1000 + 3600: continue   # inside the rule's window (+1 h slack, since launch)
        for k, exp in (('in', True), ('out', False)):
            ee = e * 1.001 if exp else e / 1.001
            d = dict(fields, startedAt=NOW - (ee - 3600) * 1000, lastSaved=NOW)
            print(f"{sys.argv[1]}|t={t:g}|ipo={int(ipo)}|{k}\t{json.dumps(d)}\t{NOW}\t{'t' if exp else 'f'}")
