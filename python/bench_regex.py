#!/usr/bin/env python3
"""Cross-engine benchmark harness — Python PyPI `regex` module side.

Thin entry point sharing all logic with the stdlib `re` harness via `bench_lib`
(only the engine module / error class differ). `regex` is Python's de-facto
Unicode-aware engine — the one BPE / tokenizer code actually uses — supporting
`\\p{...}`, look-around, inline flags and possessive quantifiers, so it runs the
verbatim GPT-4 `tokenizer` pattern that stdlib `re` REJECTs. run_all.sh installs
it into a local git-ignored venv.

Corpus path: CORPUS env var, else corpus.txt (run from the repo root).
"""
import regex

import bench_lib

if __name__ == "__main__":
    bench_lib.main("python-regex", regex, regex.error, __file__)
