#!/usr/bin/env python3
"""Exact rational oracle for finding A2-04 (cycle A, sceptic V040).

Reads the JSONL written by probes/cycle-A/Slots/V040 (every double as its IEEE bit pattern),
rebuilds each LP exactly with fractions.Fraction, and computes for the square nonsingular
equality system A x = b with box bounds:
  x_exact = A^-1 b (the only feasible point; the LP is infeasible if it leaves the box),
  opt     = c^T x_exact, the exact optimal objective of the LP that was actually solved,
  kappa1  = ||A||_1 ||A^-1||_1, exactly, and y = A^-T c (the duals), exactly.
For every .optimal answer it reports the relative objective error |obj - opt| / max(1, |opt|),
the exact row residual and distance of the returned point, and whether it carries a warning.
Identity used as a cross-check: c^T xhat - opt = y^T (A xhat - b) exactly.

Usage: python3 -I A2-04-V040-oracle.py file.jsonl [file.jsonl ...]
"""
import json
import math
import struct
import sys
from collections import defaultdict
from fractions import Fraction as F


def dbl(h):
    return struct.unpack('<d', struct.pack('<Q', int(h, 16)))[0]


def exact_inverse(A):
    n = len(A)
    M = [row[:] + [F(int(i == j)) for j in range(n)] for i, row in enumerate(A)]
    for k in range(n):
        p = next((i for i in range(k, n) if M[i][k] != 0), None)
        if p is None:
            return None
        M[k], M[p] = M[p], M[k]
        piv = M[k][k]
        if piv != 1:
            M[k] = [v / piv for v in M[k]]
        Mk = M[k]
        for i in range(n):
            if i != k and M[i][k] != 0:
                f = M[i][k]
                Mi = M[i]
                M[i] = [Mi[j] - f * Mk[j] for j in range(2 * n)]
    return [row[n:] for row in M]


BUCKETS = [(0, 1e8, 'k<1e8'), (1e8, 1e10, '1e8-1e10'), (1e10, 1e11, '1e10-1e11'), (1e11, 1e12, '1e11-1e12'),
           (1e12, 1e13, '1e12-1e13'), (1e13, 1e14, '1e13-1e14'), (1e14, 1e16, '1e14-1e16'), (1e16, math.inf, '>=1e16')]


def bucket(k):
    for lo, hi, name in BUCKETS:
        if lo <= k < hi:
            return name
    return '>=1e16'


def main(paths):
    # key: (family, objectiveKind, strategyGroup, bucket)
    stats = defaultdict(lambda: dict(inst=set(), solves=0, opt=0, e6=0, e3=0, e1=0, worst=0.0, warned_e6=0,
                                     illwarned_e6=0, unwarned_e6=[], nonopt=defaultdict(int), maxresid=0.0,
                                     maxbound=0.0, naive=0.0, identity=0.0, kappas=[], ynorm=0.0, consist=0.0))
    per_instance = []
    for path in paths:
        for line in open(path):
            rec = json.loads(line)
            n = rec['n']
            A = [[F(dbl(h)) for h in row] for row in rec['A']]
            b = [F(dbl(h)) for h in rec['b']]
            c = [F(dbl(h)) for h in rec['c']]
            xl = [dbl(h) for h in rec['xl']]
            xu = [dbl(h) for h in rec['xu']]
            nominal = [F(dbl(h)) for h in rec['nominal']]
            Ai = exact_inverse(A)
            x = [sum(Ai[i][j] * b[j] for j in range(n)) for i in range(n)]
            y = [sum(Ai[j][i] * c[j] for j in range(n)) for i in range(n)]
            opt = sum(c[j] * x[j] for j in range(n))
            inside = all((xl[j] == -math.inf or x[j] >= F(xl[j])) and (xu[j] == math.inf or x[j] <= F(xu[j]))
                         for j in range(n))
            k1 = float(max(sum(abs(A[i][j]) for i in range(n)) for j in range(n))
                       * max(sum(abs(Ai[i][j]) for i in range(n)) for j in range(n)))
            ynorm = float(max(abs(v) for v in y))
            scale = max(F(1), abs(opt))
            naive = float(abs(sum(c[j] * nominal[j] for j in range(n)) - opt) / scale)
            bk = bucket(k1)
            per_instance.append((rec['id'], k1, ynorm, inside, naive, float(opt)))
            for res in rec['results']:
                name = res['strategy']
                group = 'facade:' + name if name.endswith(')') else 'grid40'
                for g in (group, 'all'):
                    s = stats[(rec['family'], rec['objectiveKind'], g, bk)]
                    s['inst'].add(rec['id'])
                    s['solves'] += 1
                    s['kappas'].append(k1)
                    s['ynorm'] = max(s['ynorm'], ynorm)
                    s['naive'] = max(s['naive'], naive)
                    if not inside:
                        s['nonopt']['EXACTLY-INFEASIBLE-LP'] += 0  # marker only
                    if not res['optimal']:
                        s['nonopt'][res['status'].split('(')[0] + ('' if '(' not in res['status'] else '(' + res['status'].split('(', 1)[1])] += 1
                        continue
                    s['opt'] += 1
                    obj = F(dbl(res['obj']))
                    xh = [F(dbl(h)) for h in res['x']]
                    rel = float(abs(obj - opt) / scale)
                    cxh = sum(c[j] * xh[j] for j in range(n))
                    r = [sum(A[i][j] * xh[j] for j in range(n)) - b[i] for i in range(n)]
                    ident = abs((cxh - opt) - sum(y[i] * r[i] for i in range(n)))
                    s['identity'] = max(s['identity'], float(ident))
                    s['consist'] = max(s['consist'], float(abs(obj - cxh) / max(F(1), abs(cxh))))
                    s['maxresid'] = max(s['maxresid'], float(max(abs(v) for v in r)))
                    bv = 0.0
                    for j in range(n):
                        xv = float(xh[j])
                        if xl[j] > -math.inf:
                            bv = max(bv, xl[j] - xv)
                        if xu[j] < math.inf:
                            bv = max(bv, xv - xu[j])
                    s['maxbound'] = max(s['maxbound'], bv)
                    s['worst'] = max(s['worst'], rel)
                    if rel > 1e-6:
                        s['e6'] += 1
                        if res['warnings']:
                            s['warned_e6'] += 1
                        else:
                            s['unwarned_e6'].append((rec['id'], name, rel))
                        if any('ill-conditioned' in w for w in res['warnings']):
                            s['illwarned_e6'] += 1
                    if rel > 1e-3:
                        s['e3'] += 1
                    if rel > 1e-1:
                        s['e1'] += 1
    order = {name: i for i, (_, _, name) in enumerate(BUCKETS)}
    print('family objective group bucket | instances solves optimal | obj relerr>1e-6 >1e-3 >1e-1 worst | '
          '>1e-6 warned (ill-cond warning) | max |y|_inf, max row resid, max bound viol | naive-oracle err | non-optimal')
    for key in sorted(stats, key=lambda k: (k[0], k[1], k[2], order[k[3]])):
        s = stats[key]
        fam, kind, group, bk = key
        print(f"{fam} {kind} {group} {bk} | {len(s['inst'])} {s['solves']} {s['opt']} | {s['e6']} {s['e3']} {s['e1']} "
              f"{s['worst']:.2e} | {s['warned_e6']} ({s['illwarned_e6']}) | {s['ynorm']:.1e} {s['maxresid']:.1e} "
              f"{s['maxbound']:.1e} | {s['naive']:.1e} | {dict(s['nonopt']) if s['nonopt'] else ''}")
        for u in s['unwarned_e6'][:5]:
            print('   UNWARNED', u)
    print('identity check max |(c^T xhat - opt) - y^T r| =', max(s['identity'] for s in stats.values()),
          '; reported-objective vs c^T xhat max rel =', max(s['consist'] for s in stats.values()))
    print('instances: id kappa1 |y|inf x_exact-inside-box naive-oracle-relerr opt')
    for row in per_instance:
        print('  ', row[0], f"{row[1]:.2e}", f"{row[2]:.1e}", row[3], f"{row[4]:.1e}", f"{row[5]:.6g}")


if __name__ == '__main__':
    main(sys.argv[1:])
