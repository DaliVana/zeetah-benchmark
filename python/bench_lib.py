#!/usr/bin/env python3
"""Shared harness logic for the two Python engine harnesses (stdlib `re` and
the PyPI `regex` module). The two entry points (`bench.py`, `bench_regex.py`)
differ only in the regex module / error class they pass in; all workload data,
model definitions, timing and the pathological-in-a-child handling live here.

Workloads come from the single source of truth via `bench_common.workloads_for`
— no patterns are declared in this file. CSV schema (no header; run_all.sh adds
it):

  engine,model,workload,input_bytes,iterations,compile_ns,search_ns_per_op,throughput_mb_s,match_count,note
"""
import os
import subprocess
import sys
import time

# Make the repo-root `bench_common` importable regardless of cwd (the harness's
# own dir, python/, is sys.path[0]; the manifest loader is one level up).
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import bench_common as bc  # noqa: E402

TIMEOUT_S = 2.0


# --- models (operate on a compiled regex `rx`) ------------------------------

def m_count(rx, text):
    return sum(1 for _ in rx.finditer(text))


def m_spans(rx, text):
    # Sum of match lengths over the same walk count enumerates.
    return sum(m.end() - m.start() for m in rx.finditer(text))


def m_grep(rx, text):
    # Lines (split on '\n') containing >=1 match. Empty segments never match
    # our patterns, so the trailing-empty from split('\n') is harmless.
    return sum(1 for line in text.split("\n") if rx.search(line))


def m_captures(rx, text):
    # Participating capture groups (group 0 excluded), summed over all matches.
    # m.groups() is the tuple of groups 1..N; a non-participating group is None.
    total = 0
    for m in rx.finditer(text):
        total += sum(1 for g in m.groups() if g is not None)
    return total


MODELS = {
    "count-spans": m_spans,
    "grep": m_grep,
    "count-captures": m_captures,
}


def _row(engine, model, wl_id, byte_len, iters, compile_ns, search_ns, tput, mc, note):
    print(f"{engine},{model},{wl_id},{byte_len},{iters},{compile_ns},{search_ns},"
          f"{tput:.2f},{mc},{note}")


def _measure(engine, model, wl_id, rx, text, byte_len, compile_ns, fn):
    fn(rx, text)  # warmup
    p0 = time.perf_counter_ns()
    mc = fn(rx, text)
    probe = max(time.perf_counter_ns() - p0, 1)
    iters = min(500, max(5, 50_000_000 // probe))
    samples = []
    for _ in range(iters):
        t0 = time.perf_counter_ns()
        fn(rx, text)
        samples.append(time.perf_counter_ns() - t0)
    samples.sort()
    median = samples[iters // 2]
    secs = median / 1_000_000_000.0
    tput = (byte_len / 1_000_000.0) / secs if secs > 0 else 0.0
    _row(engine, model, wl_id, byte_len, iters, compile_ns, median, tput, mc, "ok")


def _reject(engine, wl, byte_len):
    _row(engine, "count", wl.id, byte_len, 0, -1, -1, 0.0, -1, "REJECTED")
    if wl.spans:
        _row(engine, "count-spans", wl.id, byte_len, 0, -1, -1, 0.0, -1, "REJECTED")
    if wl.grep:
        _row(engine, "grep", wl.id, byte_len, 0, -1, -1, 0.0, -1, "REJECTED")
    if wl.captures:
        _row(engine, "count-captures", wl.id, byte_len, 0, -1, -1, 0.0, -1, "REJECTED")


def _bench_one(engine, mod, err, wl, text, byte_len):
    if wl.force_reject:
        _reject(engine, wl, byte_len)
        return
    # --- compile timing ---
    compile_min = None
    for _ in range(50):
        t0 = time.perf_counter_ns()
        try:
            mod.compile(wl.pattern)
        except err:
            _reject(engine, wl, byte_len)
            return
        dt = time.perf_counter_ns() - t0
        compile_min = dt if compile_min is None else min(compile_min, dt)
    rx = mod.compile(wl.pattern)

    _measure(engine, "count", wl.id, rx, text, byte_len, compile_min, m_count)
    if wl.spans:
        _measure(engine, "count-spans", wl.id, rx, text, byte_len, compile_min, m_spans)
    if wl.grep:
        _measure(engine, "grep", wl.id, rx, text, byte_len, compile_min, m_grep)
    if wl.captures:
        _measure(engine, "count-captures", wl.id, rx, text, byte_len, compile_min, m_captures)


def _bench_redux(engine, mod, err, corpus):
    members = bc.redux_for(engine)
    if not members:
        return
    n = min(bc.redux_size(), len(corpus))
    text = corpus[:n]
    # compile timing: min over 50 of compiling ALL members
    compile_min = None
    for _ in range(50):
        t0 = time.perf_counter_ns()
        try:
            compiled = [mod.compile(m) for m in members]
        except err:
            _row(engine, "regex-redux", "redux", n, 0, -1, -1, 0.0, -1, "REJECTED")
            return
        dt = time.perf_counter_ns() - t0
        compile_min = dt if compile_min is None else min(compile_min, dt)
    compiled = [mod.compile(m) for m in members]

    def total():
        return sum(sum(1 for _ in rx.finditer(text)) for rx in compiled)

    total()  # warmup
    p0 = time.perf_counter_ns()
    tot = total()
    probe = max(time.perf_counter_ns() - p0, 1)
    iters = min(500, max(5, 50_000_000 // probe))
    samples = []
    for _ in range(iters):
        t0 = time.perf_counter_ns()
        total()
        samples.append(time.perf_counter_ns() - t0)
    samples.sort()
    median = samples[iters // 2]
    secs = median / 1_000_000_000.0
    tput = (len(members) * n / 1_000_000.0) / secs if secs > 0 else 0.0
    _row(engine, "regex-redux", "redux", n, iters, compile_min, median, tput, tot, "ok")


def _patho_pattern(mod):
    for w in bc.workloads_for("python-re"):
        if w.kind == "pathological":
            return w.pattern
    return "(a+)+b"


def _run_pathological(engine, mod, script_path):
    """Parent: run the catastrophic match in a child with a hard timeout."""
    n = bc.synthetic_len()
    t0 = time.perf_counter_ns()
    try:
        subprocess.run(
            [sys.executable, os.path.abspath(script_path)],
            env={**os.environ, "BENCH_PATHO_CHILD": "1"},
            timeout=TIMEOUT_S, check=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        dt = time.perf_counter_ns() - t0
        secs = dt / 1_000_000_000.0
        tput = (n / 1_000_000.0) / secs if secs > 0 else 0.0
        _row(engine, "count", "pathological", n, 1, -1, dt, tput, 0, "ok")
    except subprocess.TimeoutExpired:
        _row(engine, "count", "pathological", n, 0, -1, -1, 0.0, -1, "TIMEOUT")


def main(engine, mod, err, script_path):
    # Child mode: just attempt the catastrophic match (parent times/limits us).
    if os.environ.get("BENCH_PATHO_CHILD") == "1":
        rx = mod.compile(_patho_pattern(mod))
        m_count(rx, "a" * bc.synthetic_len())
        return

    path = os.environ.get("CORPUS", "corpus.txt")
    with open(path, "r", encoding="ascii") as f:
        corpus = f.read()

    sizes = bc.sizes_for(engine)
    for wl in bc.workloads_for(engine):
        if wl.kind == "pathological":
            _run_pathological(engine, mod, script_path)
        else:
            for sz in sizes:
                n = min(sz, len(corpus))
                _bench_one(engine, mod, err, wl, corpus[:n], n)
    _bench_redux(engine, mod, err, corpus)
