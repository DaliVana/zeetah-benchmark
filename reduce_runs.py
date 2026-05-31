#!/usr/bin/env python3
"""Reduce several measurement rounds of one side to a best-of-N row set.

A/B benchmarking on one machine is confounded by machine state: the side built
or run first sees a cold/idle box, the other sees a warm/throttled one, which
can bias a whole workload by double-digit percent on identical source.
run_compare.sh defends against this by running each side multiple times,
*interleaved* (base, cand, base, cand, …), then calling this to keep — per
(engine, model, workload, input_bytes) — the round with the SMALLEST positive
search_ns_per_op. The minimum is the least-disturbed sample (closest to the true
cost), so transient slowdowns cancel and only a persistent change survives.

Reads one headerless rounds CSV (the concatenated harness output of every round
for one side, in the standard 10-column schema) and writes the reduced rows
(still headerless) to stdout, preserving first-seen key order.
"""
import csv
import sys

COLS = ["engine", "model", "workload", "input_bytes", "iterations",
        "compile_ns", "search_ns_per_op", "throughput_mb_s", "match_count", "note"]


def main():
    src = sys.argv[1]
    order = []
    best = {}   # key -> full row list
    with open(src, newline="") as f:
        for row in csv.reader(f):
            if not row or len(row) < len(COLS):
                continue
            key = (row[0], row[1], row[2], row[3])
            ns = int(row[6])
            prev = best.get(key)
            if prev is None:
                best[key] = row
                order.append(key)
            else:
                pns = int(prev[6])
                # Prefer the smallest positive ns. A row only replaces the held
                # one if it is positive AND (the held one is non-positive OR it
                # is faster) — so a single ok round beats any non-ok rounds.
                if ns > 0 and (pns <= 0 or ns < pns):
                    best[key] = row

    w = csv.writer(sys.stdout)
    for key in order:
        w.writerow(best[key])


if __name__ == "__main__":
    main()
