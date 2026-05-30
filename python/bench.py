#!/usr/bin/env python3
"""Cross-engine benchmark harness — Python `re` (stdlib) side.

Emits CSV rows (no header) with the schema shared by all harnesses:
  engine,workload,input_bytes,iterations,compile_ns,search_ns_per_op,throughput_mb_s,match_count,note

Python's `re` is a backtracking engine. On the pathological workload it
catastrophically backtracks, and a C-level regex match does not return to the
interpreter loop, so Python signal handlers cannot interrupt it. That one
workload is therefore run in a child process with a hard 2 s wall-clock
timeout (emitting note=TIMEOUT) — analogous to .NET's MatchTimeout.

Corpus path: CORPUS env var, else corpus.txt
(run_all.sh runs every harness from the repo root).
"""
import os
import re
import subprocess
import sys
import time

WORKLOADS = [
    ("literal",      "Sherlock",                                         False),
    ("quantifier",   "a+",                                               False),
    ("digits",       "[0-9]+",                                           False),
    ("word",         r"\w+",                                             False),
    ("alternation",  "cat|dog|bird|fish",                                False),
    ("email",        r"[\w\.+-]+@[\w\.-]+\.[\w\.-]+",                     False),
    ("uri",          r"[\w]+://[^/\s?#]+[^\s?#]+(?:\?[^\s#]*)?(?:#[^\s]*)?", False),
    ("ipv4",         r"(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)", False),
    # Real-world workloads. Shell /.../ delimiters & stray markdown backticks
    # stripped; named groups -> non-capturing (harness compares match counts);
    # k8s leading ^ dropped so it matches log-shaped substrings anywhere.
    ("html_title",   r'''<h2 class="product-title">(.*?)</h2>''', False),
    ("href",         r'''href="([^"]+)"''', False),
    ("price",        r'''\$[\d,]+\.?\d*''', False),
    ("nltk",         r'''(?:[A-Z]\.)+|\w+(?:-\w+)*|\$?\d+(?:\.\d+)?%?|\.\.\.|[.,;"'?():_\-]''', False),
    ("ssn",          r'''[0-9]{3,3}-[0-9]{2,2}-[0-9]{4,4}''', False),
    ("modsec_sqli",  r'''([~!@#$%^&*()\-+={}\[\]|:;"'´’‘<>\\].*?){4,}''', False),
    ("aws_eni",      r'''(?:eni-.*?) ''', False),
    ("apache_post",  r'''POST (?:/[a-zA-Z0-9_]+){1,}''', False),
    ("k8s_fluentd",  r'''(?:\d{4}-\d{1,2}-\d{1,2} \d{1,2}:\d{1,2}:\d{1,2}.\d{3})\s+(?:[^\s]+)\s+(?:\d+).*?\[\s+(?:.*)\]\s+(?:.*)\s+:\s+(?:.*)''', False),
    # Typical + portable-edge additions.
    ("date_iso",     r'''[0-9]{4}-[0-9]{2}-[0-9]{2}''', False),
    ("time_hms",     r'''[0-9]{2}:[0-9]{2}:[0-9]{2}''', False),
    ("phone_us",     r'''\(?[0-9]{3}\)?[ .-][0-9]{3}[ .-][0-9]{4}''', False),
    ("hex_color",    r'''#[0-9a-fA-F]{6}''', False),
    ("uuid",         r'''[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}''', False),
    ("mac_addr",     r'''(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}''', False),
    ("semver",       r'''v?[0-9]+\.[0-9]+\.[0-9]+''', False),
    ("credit_card",  r'''[0-9]{4}[ -][0-9]{4}[ -][0-9]{4}[ -][0-9]{4}''', False),
    ("log_level",    r'''(?:TRACE|DEBUG|INFO|WARN|ERROR|FATAL)''', False),
    ("html_tag",     r'''<[^>]+>''', False),
    ("hashtag",      r'''#[A-Za-z0-9_]+''', False),
    ("float_sci",    r'''[-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?''', False),
    ("json_string",  r'''"(?:[^"\\]|\\.)*"''', False),
    ("base64",       r'''(?:[A-Za-z0-9+/]{4})+={0,2}''', False),
    ("path_unix",    r'''(?:/[A-Za-z0-9_.-]+)+''', False),
    ("deep_alternation", r'''\b(?:break|case|catch|class|const|continue|default|delete|do|else|enum|export|extends|false|finally|for|function|if|import|in|instanceof|new|null|return|super|switch|this|throw|true|try|typeof|var|void|while|with|yield|async|await|let)\b''', False),
    ("wildcard_gaps", r'''foo.*bar.*baz''', False),
    # Real-world multiline: every full log line that begins with an ISO date
    # (`(?m)` makes `^`/`$` per-line anchors). Zeetah uses the `.multiline`
    # struct-flag peer of this inline form.
    ("multiline_log", r'''(?m)^[0-9]{4}-[0-9]{2}-[0-9]{2}.*$''', False),
    # Feature-heavy: stdlib `re` supports backref/look-behind, runs them; it
    # has no `\p{}` (and atomic groups only on 3.11+) -> re.error -> REJECTED.
    ("backref_word", r'''(\b[A-Za-z]+\b) \1''', False),
    ("lookbehind_amount", r'''(?<=\$)[0-9]+(?:\.[0-9]{2})?''', False),
    ("unicode_prop", r'''[\p{L}\p{N}_]+''', False),
    ("atomic_token", r'''(?>[A-Za-z0-9_]+)@''', False),
    # GPT-4 pre-tokenizer. This harness is stdlib `re`, which has no `\p{}`
    # Unicode-property syntax, so `re.compile` raises re.error -> REJECTED.
    # (Python's de-facto Unicode-regex library, the PyPI `regex` module,
    # runs this pattern verbatim — it just isn't a stdlib/toolchain dep.)
    ("tokenizer",    r"(?i:[sdmt]|ll|ve|re)|[^\r\n\p{L}\p{N}]?+\p{L}+|\p{N}{1,3}| ?[^\s\p{L}\p{N}]++[\r\n]|\s[\r\n]|\s+(?!\S)|\s+", False),
    ("pathological", "(a+)+b",                                           True),
]
CORPUS_SIZES = [1024, 8192, 32768, 1048576]
PATHO_PATTERN = "(a+)+b"
PATHO_INPUT_LEN = 50_000
TIMEOUT_S = 2.0


def scan_count(rx, text):
    return sum(1 for _ in rx.finditer(text))


def bench_one(wl_id, pattern, text, byte_len):
    # --- compile timing ---
    compile_min = None
    for _ in range(50):
        t0 = time.perf_counter_ns()
        try:
            re.compile(pattern)
        except re.error:
            print(f"python-re,{wl_id},{byte_len},0,-1,-1,0.00,-1,REJECTED")
            return
        dt = time.perf_counter_ns() - t0
        compile_min = dt if compile_min is None else min(compile_min, dt)
    rx = re.compile(pattern)

    # --- search timing ---
    scan_count(rx, text)  # warmup
    p0 = time.perf_counter_ns()
    match_count = scan_count(rx, text)
    probe = max(time.perf_counter_ns() - p0, 1)

    iters = min(500, max(5, 50_000_000 // probe))
    samples = []
    for _ in range(iters):
        t0 = time.perf_counter_ns()
        scan_count(rx, text)
        samples.append(time.perf_counter_ns() - t0)
    samples.sort()
    median = samples[iters // 2]

    mb = byte_len / 1_000_000.0
    secs = median / 1_000_000_000.0
    throughput = mb / secs if secs > 0 else 0.0
    print(f"python-re,{wl_id},{byte_len},{iters},{compile_min},{median},"
          f"{throughput:.2f},{match_count},ok")


def run_pathological():
    """Parent: run the catastrophic match in a child with a hard timeout."""
    t0 = time.perf_counter_ns()
    try:
        subprocess.run(
            [sys.executable, os.path.abspath(__file__)],
            env={**os.environ, "BENCH_PATHO_CHILD": "1"},
            timeout=TIMEOUT_S,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        # Completed in time (won't happen for true catastrophic backtracking).
        dt = time.perf_counter_ns() - t0
        mb = PATHO_INPUT_LEN / 1_000_000.0
        secs = dt / 1_000_000_000.0
        tput = mb / secs if secs > 0 else 0.0
        print(f"python-re,pathological,{PATHO_INPUT_LEN},1,-1,{dt},"
              f"{tput:.2f},0,ok")
    except subprocess.TimeoutExpired:
        print(f"python-re,pathological,{PATHO_INPUT_LEN},0,-1,-1,0.00,-1,TIMEOUT")


def main():
    # Child mode: just attempt the catastrophic match (parent times/limits us).
    if os.environ.get("BENCH_PATHO_CHILD") == "1":
        rx = re.compile(PATHO_PATTERN)
        scan_count(rx, "a" * PATHO_INPUT_LEN)
        return

    path = os.environ.get("CORPUS", "corpus.txt")
    with open(path, "r", encoding="ascii") as f:
        corpus = f.read()

    for wl_id, pattern, pathological in WORKLOADS:
        if pathological:
            run_pathological()
        else:
            for sz in CORPUS_SIZES:
                n = min(sz, len(corpus))
                bench_one(wl_id, pattern, corpus[:n], n)


if __name__ == "__main__":
    main()
