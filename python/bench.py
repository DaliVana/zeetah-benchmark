#!/usr/bin/env python3
"""Cross-engine benchmark harness — Python `re` (stdlib) side.

Thin entry point: all logic (workloads from the shared manifest, the count /
count-spans / grep / count-captures / regex-redux models, timing, and the
pathological-in-a-child handling) lives in `bench_lib`. stdlib `re` is a
backtracking engine; it has no `\\p{}` (so `unicode_prop`/`tokenizer` are
REJECTED) and on this Python version no atomic groups (`atomic_token`
REJECTED), but it does support backreferences and look-behind.

Corpus path: CORPUS env var, else corpus.txt (run from the repo root).
"""
import re

import bench_lib

if __name__ == "__main__":
    bench_lib.main("python-re", re, re.error, __file__)
