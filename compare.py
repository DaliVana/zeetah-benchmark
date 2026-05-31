#!/usr/bin/env python3
"""Diff two zeetah benchmark runs (baseline vs candidate).

Reads two results CSVs in the standard harness schema

    engine,model,workload,input_bytes,iterations,compile_ns,search_ns_per_op,throughput_mb_s,match_count,note

— typically one built from a *target ref* (baseline) and one from the *current
working tree* (candidate) by `run_compare.sh`. Joins the two on
(engine, model, workload, input_bytes) and reports the per-workload speed
change, writing a Markdown report (default compare.md).

Two failure conditions make this exit non-zero (so it can gate a PR):
  1. Correctness divergence — a non-pathological workload whose match_count
     differs between baseline and candidate. The engine changed behaviour;
     any timing comparison is moot until that is explained.
  2. Performance regression — a workload that got slower by more than the
     --regression-pct threshold (default 5%).

Speed is compared on search_ns_per_op (the primary measurement; lower is
faster). speedup = baseline_ns / candidate_ns; a speedup of 1.10 means the
candidate is 10% faster. Only rows where BOTH sides have note=="ok" are
compared; rows present on only one side are listed separately.
"""
import argparse
import csv
from collections import defaultdict

ENGINE_ORDER = ["zeetah", "zeetah-dfa"]
MODEL_ORDER = ["count", "count-spans", "count-captures", "grep", "regex-redux"]


def human_bytes(n):
    n = int(n)
    if n >= 1_048_576:
        return f"{n // 1_048_576} MiB"
    if n >= 1024:
        return f"{n // 1024} KiB"
    return f"{n} B"


def load(path):
    """(engine, model, workload, input_bytes) -> row dict."""
    out = {}
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            key = (r["engine"], r["model"], r["workload"], int(r["input_bytes"]))
            out[key] = r
    return out


def geomean(values):
    if not values:
        return None
    prod = 1.0
    for v in values:
        prod *= v
    return prod ** (1.0 / len(values))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("baseline_csv")
    ap.add_argument("candidate_csv")
    ap.add_argument("out_md", nargs="?", default="compare.md")
    ap.add_argument("--baseline-label", default="baseline")
    ap.add_argument("--candidate-label", default="candidate")
    ap.add_argument("--regression-pct", type=float, default=10.0,
                    help="fail if any workload slows by more than this percent")
    ap.add_argument("--min-ns", type=float, default=50_000.0,
                    help="only GATE on rows whose baseline median ns/op is at "
                         "least this — faster ops are sub-microsecond-noisy "
                         "across separate binaries and would cause false "
                         "regressions. Such rows are still shown, tagged 'noisy'.")
    args = ap.parse_args()

    base = load(args.baseline_csv)
    cand = load(args.candidate_csv)

    keys = sorted(
        set(base) | set(cand),
        key=lambda k: (
            ENGINE_ORDER.index(k[0]) if k[0] in ENGINE_ORDER else len(ENGINE_ORDER),
            MODEL_ORDER.index(k[1]) if k[1] in MODEL_ORDER else len(MODEL_ORDER),
            k[2], k[3],
        ),
    )

    # per-engine comparable rows, plus the cross-cutting failure lists.
    by_engine = defaultdict(list)   # engine -> list of (key, base, cand, speedup, pct, gated)
    only_base, only_cand, not_ok = [], [], []
    correctness, regressions = [], []
    gated_speedups = []             # only the reliably-measurable rows

    for k in keys:
        b, c = base.get(k), cand.get(k)
        if b is None:
            only_cand.append(k)
            continue
        if c is None:
            only_base.append(k)
            continue
        if b["note"] != "ok" or c["note"] != "ok":
            not_ok.append((k, b["note"], c["note"]))
            continue

        # correctness: counts must match between the two versions (the engine
        # must not have changed *what* it matches). pathological is exempt.
        if k[2] != "pathological" and b["match_count"] != c["match_count"]:
            correctness.append((k, b["match_count"], c["match_count"]))

        bn, cn = int(b["search_ns_per_op"]), int(c["search_ns_per_op"])
        if bn <= 0 or cn <= 0:
            not_ok.append((k, b["note"], c["note"]))
            continue
        speedup = bn / cn            # > 1 => candidate faster
        pct = (speedup - 1.0) * 100.0
        # Only rows slow enough to measure reliably across separate binaries are
        # gated (counted in geomean / regression checks). Faster rows are shown
        # for context but tagged 'noisy' and never fail the build.
        gated = bn >= args.min_ns
        by_engine[k[0]].append((k, b, c, speedup, pct, gated))
        if gated:
            gated_speedups.append(speedup)
            if pct < -args.regression_pct:
                regressions.append((k, pct, speedup))

    # ---------------- report ----------------
    md = []
    md.append("# zeetah benchmark comparison\n")
    md.append(f"**baseline** = `{args.baseline_label}`  →  **candidate** = `{args.candidate_label}`\n")
    md.append(
        "Speed = `search_ns_per_op` (lower is faster). `speedup = baseline_ns / "
        "candidate_ns`; **+%** means the candidate is faster. Only rows where both "
        "sides reported `ok` are compared. Rows whose baseline is below "
        f"{args.min_ns/1000:.0f} µs/op are **noisy** (sub-microsecond ops vary "
        "across separate binaries) — shown for context but never gated on.\n"
    )

    # verdict banner
    if correctness:
        md.append("## ❌ Correctness divergence\n")
        md.append(
            "These non-pathological workloads return a **different match count** "
            "on the candidate — behaviour changed, so the timings below are not "
            "meaningful until this is explained:\n"
        )
        for (e, m, w, ib), bc, cc in correctness:
            md.append(f"- `{e}` `{m}` `{w}` @ {human_bytes(ib)}: baseline={bc} → candidate={cc}")
        md.append("")
    if regressions:
        md.append(f"## 🔴 Regressions (> {args.regression_pct:.0f}% slower)\n")
        for (e, m, w, ib), pct, sp in sorted(regressions, key=lambda x: x[1]):
            md.append(f"- `{e}` `{m}` `{w}` @ {human_bytes(ib)}: **{pct:+.1f}%** ({sp:.3f}×)")
        md.append("")
    if not correctness and not regressions:
        gm = geomean(gated_speedups)
        gm_txt = f" (geomean {gm:.3f}×, {(gm-1)*100:+.1f}%)" if gm else ""
        md.append(f"## ✅ No correctness divergence, no regression > {args.regression_pct:.0f}%{gm_txt}\n")

    gm = geomean(gated_speedups)
    if gm is not None:
        improved = sum(1 for s in gated_speedups if (s - 1) * 100 > args.regression_pct)
        regressed = sum(1 for s in gated_speedups if (s - 1) * 100 < -args.regression_pct)
        md.append("## Summary\n")
        md.append(f"- gated rows (baseline ≥ {args.min_ns/1000:.0f} µs/op): **{len(gated_speedups)}**")
        md.append(f"- geomean speedup: **{gm:.3f}×** ({(gm-1)*100:+.1f}%)")
        md.append(f"- improved (> {args.regression_pct:.0f}%): **{improved}**, "
                  f"regressed (> {args.regression_pct:.0f}%): **{regressed}**")
        md.append("")

    # per-engine detail tables, sorted worst-regression first
    for engine in [e for e in ENGINE_ORDER if e in by_engine] + \
            [e for e in by_engine if e not in ENGINE_ORDER]:
        rows = sorted(by_engine[engine], key=lambda x: x[4])
        if not rows:
            continue
        md.append(f"## `{engine}`\n")
        md.append("| Model | Workload | Input | Baseline | Candidate | Speedup | Change | |")
        md.append("|-------|----------|-------|----------|-----------|---------|--------|--|")
        for (e, m, w, ib), b, c, sp, pct, gated in rows:
            bt = f"{float(b['throughput_mb_s']):.1f} MB/s"
            ct = f"{float(c['throughput_mb_s']):.1f} MB/s"
            flag = " ⚠️" if (w != "pathological" and b["match_count"] != c["match_count"]) else ""
            tag = "" if gated else "noisy"
            md.append(f"| {m} | {w}{flag} | {human_bytes(ib)} | {bt} | {ct} | {sp:.3f}× | {pct:+.1f}% | {tag} |")
        md.append("")

    if only_base or only_cand or not_ok:
        md.append("## Unmatched / skipped rows\n")
        for k in only_base:
            md.append(f"- only in baseline: `{k[0]}` `{k[1]}` `{k[2]}` @ {human_bytes(k[3])}")
        for k in only_cand:
            md.append(f"- only in candidate: `{k[0]}` `{k[1]}` `{k[2]}` @ {human_bytes(k[3])}")
        for k, bn, cn in not_ok:
            md.append(f"- not `ok` both sides: `{k[0]}` `{k[1]}` `{k[2]}` @ {human_bytes(k[3])} "
                      f"(baseline={bn}, candidate={cn})")
        md.append("")

    with open(args.out_md, "w") as f:
        f.write("\n".join(md) + "\n")
    print(f"wrote {args.out_md}")

    # ---------------- exit code (gate) ----------------
    failed = False
    if correctness:
        print("CORRECTNESS DIVERGENCE:", file=__import__("sys").stderr)
        for (e, m, w, ib), bc, cc in correctness:
            print(f"  {e} {m} {w} @ {ib}B: {bc} -> {cc}", file=__import__("sys").stderr)
        failed = True
    if regressions:
        print(f"PERFORMANCE REGRESSION (> {args.regression_pct:.0f}%):",
              file=__import__("sys").stderr)
        for (e, m, w, ib), pct, sp in sorted(regressions, key=lambda x: x[1]):
            print(f"  {e} {m} {w} @ {ib}B: {pct:+.1f}%", file=__import__("sys").stderr)
        failed = True
    if failed:
        __import__("sys").exit(1)


if __name__ == "__main__":
    main()
