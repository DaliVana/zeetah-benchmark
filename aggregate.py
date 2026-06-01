#!/usr/bin/env python3
"""Merge per-engine CSVs into a comparison report.

Reads results.csv (the concatenated rows from all harnesses, with a header)
and writes results.md. Rows now carry a `model` column — every measurement is
one of: count (leftmost non-overlapping match count), count-spans (sum of match
lengths), count-captures (participating capture groups), grep (lines with >=1
match) or regex-redux (a compile-many-search-once composite). See README.md.

Correctness gate: for every (model, workload, input_bytes) the match_count must
agree across all engines that produced an `ok` result. The `pathological`
workload is exempt because zeetah's runtime and the linear engines diverge from
the backtrackers (which TIMEOUT) by design. A workload may optionally carry
per-engine `count_overrides` in benchmarks.json — an engine listed there is
checked against its override and excluded from the mutual-agreement set (escape
hatch for legitimately divergent semantics; unused today).

Exit code 1 if the correctness gate fails.
"""
import csv
import json
import os
import sys
from collections import defaultdict

RESULTS = sys.argv[1] if len(sys.argv) > 1 else "results.csv"
OUT = sys.argv[2] if len(sys.argv) > 2 else "results.md"

ENGINE_ORDER = ["zeetah", "zeetah-dfa", "mvzr", "re2", "pcre2", "pcre2-jit", "posix", "stdregex", "ctre", "rust-regex", "fancy-regex", "dotnet-regex", "python-re", "python-regex"]
MODEL_ORDER = ["count", "count-spans", "count-captures", "grep", "regex-redux"]

MODEL_BLURB = {
    "count": "leftmost, non-overlapping match count.",
    "count-spans": "sum of all match lengths (forces full match-bounds computation).",
    "count-captures": "participating capture groups summed over all matches (group 0 excluded) — exercises capture extraction.",
    "grep": "number of lines (split on `\\n`) containing at least one match.",
    "regex-redux": "compile a fixed set of patterns and count each over the corpus once — a compile-many-search-once composite (throughput is the aggregate bytes/s; not directly comparable to single-pattern rows).",
}


def load_overrides():
    """workload -> {engine: expected_count}. Empty unless benchmarks.json
    declares count_overrides (kept agreement-only per the project decision)."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "benchmarks.json")
    out = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            m = json.load(f)
        for w in m.get("workloads", []):
            if w.get("count_overrides"):
                out[w["id"]] = w["count_overrides"]
    except Exception:
        pass
    return out


def load_gate_exempt():
    """Engines excluded from the cross-engine match-count agreement gate
    because their match semantics legitimately differ from the leftmost-first
    PCRE family (e.g. POSIX leftmost-longest). Still measured and shown."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "benchmarks.json")
    try:
        with open(path, "r", encoding="utf-8") as f:
            return set(json.load(f).get("gate_exempt_engines", []))
    except Exception:
        return set()


def fmt_ns(ns):
    ns = int(ns)
    if ns < 0:
        return "—"
    if ns >= 1_000_000:
        return f"{ns/1_000_000:.2f} ms"
    if ns >= 1_000:
        return f"{ns/1_000:.2f} µs"
    return f"{ns} ns"


def human_bytes(n):
    n = int(n)
    if n >= 1_048_576:
        return f"{n//1_048_576} MiB"
    if n >= 1024:
        return f"{n//1024} KiB"
    return f"{n} B"


def main():
    rows = []
    with open(RESULTS, newline="") as f:
        for r in csv.DictReader(f):
            rows.append(r)

    overrides = load_overrides()
    gate_exempt = load_gate_exempt()

    # group: (model, workload, input_bytes) -> engine -> row
    groups = defaultdict(dict)
    models_seen = []
    wl_by_model = defaultdict(list)
    for r in rows:
        key = (r["model"], r["workload"], int(r["input_bytes"]))
        groups[key][r["engine"]] = r
        if r["model"] not in models_seen:
            models_seen.append(r["model"])
        if r["workload"] not in wl_by_model[r["model"]]:
            wl_by_model[r["model"]].append(r["workload"])

    # --- correctness gate ---
    gate_failures = []
    for (model, wl, ib), per_engine in groups.items():
        if wl == "pathological":
            continue
        wl_ov = overrides.get(wl, {})
        # engines with a declared override are checked separately, not against
        # the mutual-agreement set.
        bad_override = {}
        agree = {}
        for e, row in per_engine.items():
            if row["note"] != "ok":
                continue
            if e in gate_exempt:  # semantically divergent: shown, never gated
                continue
            c = int(row["match_count"])
            if e in wl_ov:
                if c != int(wl_ov[e]):
                    bad_override[e] = (c, wl_ov[e])
            else:
                agree[e] = c
        if len(set(agree.values())) > 1:
            gate_failures.append((model, wl, ib, agree))
        for e, (got, exp) in bad_override.items():
            gate_failures.append((model, wl, ib, {e: got, "expected": exp}))

    md = []
    md.append("# Cross-Engine Regex Benchmark Results\n")
    md.append(
        "Generated by `run_all.sh`. Every engine runs the same workloads (from "
        "the single source of truth `benchmarks.json`) over byte-identical input "
        "from a deterministic corpus. Each measurement is one **model** — `count`, "
        "`count-spans`, `count-captures`, `grep` or `regex-redux`. `compile` and "
        "`search` are timed in separate loops; reported figures are the "
        "**median** of the timed iterations (each loop sized to run ≥50 ms, "
        "bounded to [5, 500] iterations).\n"
    )

    if gate_failures:
        md.append("## ⚠️ Correctness gate FAILED\n")
        md.append(
            "Match counts disagree across engines for the rows below — the "
            "timing comparison for those rows is **not valid** until the "
            "semantic difference is explained:\n"
        )
        for model, wl, ib, counts in gate_failures:
            md.append(f"- `{model}` `{wl}` @ {human_bytes(ib)}: {counts}")
        md.append("")

    ordered_models = [m for m in MODEL_ORDER if m in models_seen] + \
        [m for m in models_seen if m not in MODEL_ORDER]

    for model in ordered_models:
        md.append(f"# Model: `{model}`\n")
        md.append(MODEL_BLURB.get(model, "") + "\n")
        for wl in wl_by_model[model]:
            md.append(f"## `{wl}`\n")
            keys = sorted(k for k in groups if k[0] == model and k[1] == wl)
            md.append(
                "| Input | Engine | Compile | Search (median) | Throughput | Matches | Rel. speed | Note |"
            )
            md.append(
                "|-------|--------|---------|-----------------|------------|---------|-----------|------|"
            )
            for key in keys:
                per_engine = groups[key]
                ok_times = [
                    int(per_engine[e]["search_ns_per_op"])
                    for e in per_engine
                    if per_engine[e]["note"] == "ok"
                ]
                best = min(ok_times) if ok_times else None
                for e in ENGINE_ORDER:
                    if e not in per_engine:
                        continue
                    row = per_engine[e]
                    note = row["note"]
                    if note == "ok":
                        s_ns = int(row["search_ns_per_op"])
                        rel = f"{s_ns/best:.2f}×" if best else "—"
                        search = fmt_ns(s_ns)
                        tput = f"{float(row['throughput_mb_s']):.1f} MB/s"
                        matches = row["match_count"]
                    else:
                        search = "—"
                        rel = "—"
                        tput = "—"
                        matches = "—"
                    md.append(
                        f"| {human_bytes(key[2])} | {e} | {fmt_ns(row['compile_ns'])} "
                        f"| {search} | {tput} | {matches} | {rel} | {note} |"
                    )
            md.append("")

    with open(OUT, "w") as f:
        f.write("\n".join(md) + "\n")

    print(f"wrote {OUT}")
    if gate_failures:
        print("CORRECTNESS GATE FAILED:", file=sys.stderr)
        for model, wl, ib, counts in gate_failures:
            print(f"  {model} {wl} @ {ib}B: {counts}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
