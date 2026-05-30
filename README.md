# zeetah-benchmark — Cross-Engine Regex Benchmark

A standalone, reproducible benchmark harness that compares
**[zeetah](https://github.com/zig-utils/zig-regex)** (the Zig regex engine)
against eight other regex implementations on identical workloads and
byte-identical input.

Engines compared:

- **zeetah** — runtime meta-engine **and** the comptime-DFA path (`zeetah-dfa`)
- **[mvzr](https://github.com/mnemnion/mvzr)** — a small zero-allocation Zig regex VM
- **RE2** (Google)
- **Rust `regex` crate**
- **[`fancy-regex`](https://github.com/fancy-regex/fancy-regex)** — the
  look-around/backreference/possessive Rust engine used by OpenAI's `tiktoken`
  and BPE trainers like `rustbpe`
- **.NET `System.Text.RegularExpressions`** (default backtracking engine)
- **Python `re`** (stdlib)
- **PyPI [`regex`](https://pypi.org/project/regex/) module** — Python's de-facto
  Unicode-aware engine, what BPE/tokenizer code actually uses

This repo holds only the benchmark *harness*. The zeetah engine source is not
vendored — see **[zeetah source](#zeetah-source)** below.

## Run

```bash
./run_all.sh
```

By default this builds the zeetah harnesses against a **sibling checkout** of
the engine at `../zig-regex/` (see below). Outputs (git-ignored, regenerated
each run):

- `results.md` — per-workload comparison tables
- `results.csv` — raw rows from all engines
- `corpus.txt` — deterministic 1 MiB corpus

The script installs RE2 + pkg-config via Homebrew if missing (idempotent),
vendors the pinned mvzr source, sets up a local `.venv` with the PyPI `regex`
module (idempotent), generates the corpus, builds/runs all nine harnesses, then
aggregates.

> **Platform note.** The suite is currently macOS-tuned: RE2 is installed via
> Homebrew and the zeetah harness clock uses the Darwin-only
> `clock_gettime(CLOCK_UPTIME_RAW)`. Running on Linux needs that clock ported to
> `CLOCK_MONOTONIC` and RE2 installed via the system package manager — see
> [CI](#ci).

### Prerequisites

`zig` (0.16.0), `cargo`, `clang++`, `dotnet`, `python3`, plus Homebrew (for
RE2). `run_all.sh` checks for each and exits with a clear message if one is
missing.

## zeetah source

The Zig harnesses `@import("zeetah")`; the module is resolved at **build time**,
not vendored, so the benchmark always measures whatever zeetah tree you point it
at. Two ways to point it:

1. **Local sibling checkout (default).** `run_all.sh` resolves zeetah from
   `$ZEETAH_SRC`, defaulting to `../zig-regex/src/root.zig`. Clone the engine
   next to this repo:

   ```text
   …/regex/
   ├── zig-regex/          # the zeetah engine
   └── zeetah-benchmark/   # this repo
   ```

   This measures your **uncommitted local** zeetah changes — the usual
   perf-iteration flow. Override the path:

   ```bash
   ZEETAH_SRC=/path/to/zig-regex/src/root.zig ./run_all.sh
   ```

2. **Pinned package dependency (reproducible / CI).** `build.zig` /
   `build.zig.zon` can instead fetch a pinned zeetah ref via the Zig package
   manager (`-Dpinned=true`). It is disabled by default; see the instructions in
   `build.zig.zon` to wire it (a one-line `zig fetch --save`). This is the
   intended path for [CI](#ci).

The standalone Zig entry (`zig build bench` / `zig build bench-dfa`) builds the
two zeetah harnesses through the same resolution logic. `run_all.sh` is the full
cross-engine orchestrator.

## Design

- **Shared workload set** — see the `*_bench.*` sources. It spans:
  - **fundamentals:** literal, quantifier, digits, `\w+`, alternation;
  - **typical real-world:** email, URI, IPv4, HTML title/href/tag, price,
    nltk, SSN, ModSecurity SQLi, AWS ENI, Apache POST, k8s/Fluentd log,
    ISO date, 24h time, US phone, hex colour, UUID, MAC address, semver,
    credit-card group, log level, hashtag;
  - **edge but real:** scientific float, JSON string, base64, unix path,
    deep keyword alternation, `foo.*bar.*baz` wildcard gaps;
  - **feature-heavy edge** (only the engines that support the feature run
    these — the rest emit `REJECTED`, exactly like `tokenizer`): a
    backreference duplicate-word `(\b[A-Za-z]+\b) \1`, a `(?<=\$)` look-behind
    amount, a `\p{L}` Unicode-property class, an atomic-group `(?>…)@`;
  - **motivating:** a real GPT-4 `cl100k_base` `tokenizer` pre-tokenizer
    regex, plus a `(a+)+b` pathological case. The
  `tokenizer` row uses inline `(?i:)`, possessive `?+`/`++`, `\p{...}` and
  `(?!\S)` look-around. **Four** engines run it and produce **identical
  match counts** (gate-enforced — see below):
  - **zeetah** — natively (possessive parsed as greedy-equivalent).
  - **`fancy-regex`** — the look-around/possessive Rust engine used by
    OpenAI's `tiktoken` and BPE trainers like `rustbpe`; runs the verbatim
    pattern.
  - **.NET** — fully supports `\p{}`, `(?i:)`, `(?!\S)` and atomic groups;
    it lacks only the possessive *syntax* `?+`/`++`, so its harness uses the
    exactly-equivalent canonical spelling (`X?+`→`(?>X?)`, `X++`→`(?>X+)` —
    an atomic group *is* a possessive quantifier).
  - **PyPI `regex` module** — Python's de-facto Unicode-regex library (what
    BPE/tokenizer code actually uses); runs the verbatim pattern. Installed
    into a local git-ignored venv by `run_all.sh` (idempotent).

  The base Rust `regex` crate, RE2 and mvzr genuinely cannot express it
  (no look-around — by design for the linear automata engines) and emit
  `REJECTED`. Python's **stdlib `re`** lacks `\p{}` (verified) so it too
  emits `REJECTED` — but that is a stdlib limitation, not Python's: the
  `regex`-module row above is the fair Python data point.
- **Timed operation:** count all leftmost, non-overlapping matches.
- **Methodology:** compile and search timed in separate loops; reported value
  is the median of a loop sized to run ≥50 ms (5–500 iterations). zeetah
  uses libc for timing/IO because Zig 0.16 reworked `std.Io`/`std.time`.
- **Correctness gate:** `aggregate.py` fails if match counts disagree across
  engines for any non-`pathological` row. This includes `tokenizer`:
  zeetah, `fancy-regex`, .NET and the PyPI `regex` module all run it and
  **must agree** (they do — identical counts at every size: 212 / 1755 /
  7116), which gates zeetah's tokenizer semantics against three
  independent mainstream engines, including the ones production BPE
  libraries actually use.
- **Input sizes:** corpus slices run up to 1 MiB; zeetah's `findAll` is a
  single linear leftmost-first NFA pass (no per-match restart).

## CI

GitHub Actions is **not wired up yet** (deliberately deferred). When adding it:

- **Runner:** the suite is macOS-tuned, so `macos-latest` runs it as-is. A
  `ubuntu-latest` run first needs the zeetah harness clock ported off
  `CLOCK_UPTIME_RAW` and RE2 installed via `apt`.
- **zeetah source:** use the pinned dependency path. Push the zeetah ref under
  test, `zig fetch --save=zeetah <tarball-url>` (see `build.zig.zon`), then have
  the workflow build with `-Dpinned=true` — or, if measuring an in-tree zeetah
  PR, `actions/checkout` the engine into a sibling dir and keep the default
  `ZEETAH_SRC`.
- **Signal:** shared CI runners are noisy, so treat PR runs as a
  **correctness-gate** plus a coarse perf signal, not a precise
  regression detector. Commit a baseline CSV to diff against if you want a
  perf delta.

## Files

| File | Role |
|------|------|
| `run_all.sh` | orchestrator (full cross-engine run) |
| `build.zig` / `build.zig.zon` | `zig build bench` / `bench-dfa`; zeetah-source resolution + pinned-dep CI path |
| `gen_corpus.py` | deterministic corpus generator |
| `aggregate.py` | merge CSVs → `results.md`, enforce correctness gate |
| `zig_bench.zig` | zeetah runtime harness (compiled against `$ZEETAH_SRC`) |
| `zig_dfa_bench.zig` | zeetah comptime-DFA harness (`zeetah-dfa` engine) |
| `mvzr_bench.zig` | mvzr harness (compiled against vendored `mvzr/`) |
| `mvzr/` | vendored mvzr source (pinned tag, fetched by `run_all.sh`; git-ignored) |
| `rust/src/main.rs` | Rust base `regex` crate harness (Cargo bin `rust_bench`) |
| `rust/src/bin/fancy_bench.rs` | Rust `fancy-regex` harness (Cargo bin `fancy_bench`; tiktoken/rustbpe engine) |
| `re2/bench.cpp` | RE2 harness (clang++ + pkg-config) |
| `dotnet/` | .NET `Regex` harness (default backtracking engine, 2 s timeout) |
| `python/bench.py` | Python stdlib `re` harness (pathological run in a 2 s child) |
| `python/bench_regex.py` | Python PyPI `regex`-module harness (run via local `.venv`) |
| `FINDINGS.md` | historical cross-engine analysis writeup |
