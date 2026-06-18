# zeetah-benchmark — Cross-Engine Regex Benchmark

A standalone, reproducible benchmark harness that compares
**[zeetah](https://github.com/zig-utils/zig-regex)** (the Zig regex engine)
against twelve other regex implementations on identical workloads and
byte-identical input.

Engines compared:

- **zeetah** — runtime meta-engine **and** the comptime-DFA path (`zeetah-dfa`)
- **[mvzr](https://github.com/mnemnion/mvzr)** — a small zero-allocation Zig regex VM
- **RE2** (Google) — C++ linear-time automaton
- **PCRE2** — the de-facto C backtracking engine (PHP, nginx, git, ripgrep `-P`),
  measured both **interpreted** (`pcre2`) and **JIT-compiled** (`pcre2-jit`)
- **POSIX `regex.h`** (`posix`) — the libc baseline (`regcomp`/`regexec`; BSD impl
  on macOS). A different regex *language* (leftmost-longest; `\d`/`\w`/`\p` are
  extensions or literals), so it is **gate-exempt** — measured and shown, but
  excluded from the cross-engine match-count agreement gate
- **C++ `std::regex`** (`stdregex`) — the libc++ standard-library engine (the slow
  default every C++ dev reaches for)
- **[CTRE](https://github.com/hanickadot/compile-time-regular-expressions)**
  (`ctre`) — Hana Dusíková's header-only **compile-time** C++ engine; the closest
  conceptual peer to zeetah's comptime-DFA path
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

## Performance highlights

Numbers below are from the full cross-engine `run_all.sh` against zeetah
**v0.16.0** (Zig 0.16.0, `-OReleaseFast`), `count` model, **1 MiB** corpus
slice — the size where throughput stabilises. Each figure is the better of
zeetah's two rows (runtime meta-engine and the comptime-DFA path). The
correctness gate passed: every non-pathological workload agrees on match count
across all PCRE-compatible engines.

**zeetah is a top-tier engine — neck-and-neck with PCRE2-JIT and ahead of every
other competitor measured.** Geometric mean of zeetah's throughput relative to
each engine across the 42 workloads:

| vs. engine | geomean speed | zeetah is faster on |
|---|---:|---:|
| **PCRE2-JIT** (de-facto C JIT backtracker) | **0.97×** | 17 / 42 |
| **Rust `regex`** crate | **1.42×** | 27 / 38 |
| **CTRE** (C++ compile-time regex) | **2.86×** | 27 / 34 |
| **RE2** (Google) | **3.51×** | 32 / 38 |
| **.NET** `Regex` | **4.40×** | 40 / 42 |
| **PCRE2** (interpreted) | **5.94×** | 40 / 42 |
| **Oniguruma** (Ruby/Perl C engine) | **7.46×** | 41 / 42 |
| PyPI **`regex`** (tokenizer-grade) | **17.8×** | 41 / 42 |
| **mvzr** (Zig VM) | **37.7×** | 17 / 17 |
| C++ **`std::regex`** | **235×** | 38 / 38 |

So zeetah trades blows with PCRE2-JIT (essentially a tie — 0.97× geomean) and
**beats everything else outright**, including the two engines production
tokenizers actually use (PyPI `regex`, `fancy-regex`).

Standouts:

- **Pure-literal search hits 33.7 GB/s** — the fastest of *any* engine here,
  edging PCRE2-JIT (29.7 GB/s) and beating Rust `regex` (24.9 GB/s) and RE2
  (12.9 GB/s) — zeetah's memchr/Teddy prefilter at work.
- **Beats PCRE2-JIT** on `literal`, `alternation`, `email`, `k8s_fluentd`,
  `hex_color`, `log_level`, `float_sci`, and every feature-heavy case it shares
  with PCRE2-JIT's only feature-complete rival (`backref_word`,
  `lookbehind_amount`, `unicode_prop`, `atomic_token`).
- **Where PCRE2-JIT still leads** — heavy capture/anchoring workloads
  (`html_title`/`href`, `tokenizer`, `multiline_log`); these remain the
  optimisation frontier.
- **Tokenizer parity, gate-enforced.** On the verbatim GPT-4 `cl100k_base`
  pre-tokenizer regex, zeetah produces the *identical* 306,542 match count as
  PCRE2, PCRE2-JIT, Oniguruma, .NET, `fancy-regex` and PyPI `regex` — eight
  independent engines in lock-step.

Full per-workload tables (across the `count`, `count-spans`, `grep` and
`count-captures` models and all input sizes) are regenerated into `results.md`
on every run.

## Run

The benchmark runs in two modes.

### 1. Ad-hoc full run — all competitors

```bash
./run_all.sh
```

Builds and runs **all fourteen engine rows** (zeetah runtime + comptime-DFA,
mvzr, RE2, PCRE2 interpreted + JIT, POSIX `regex.h`, C++ `std::regex`, CTRE,
Rust `regex`, `fancy-regex`, .NET, Python `re`, PyPI `regex`) against a sibling
checkout of the engine at `../zig-regex/` (see below). Outputs (git-ignored,
regenerated each run):

- `results.md` — per-workload comparison tables
- `results.csv` — raw rows from all engines
- `corpus.txt` — deterministic 1 MiB mixed corpus
- `logs.txt` — deterministic dense log corpus (every line a `timestamp level
  message` record) for the `log_parse` / `date_fields` workloads

The script installs RE2 + pkg-config + PCRE2 + CTRE via Homebrew if missing
(idempotent; POSIX `regex.h` and `std::regex` need no package — libc / libc++),
vendors the pinned mvzr source, sets up a local `.venv` with the PyPI `regex`
module (idempotent), generates the corpus, builds/runs all harnesses, then
aggregates.

### 2. Branch comparison — current vs target (the "PR" mode)

```bash
./run_compare.sh [TARGET_REF]      # TARGET_REF defaults to main
```

Builds **only the zeetah** runtime + comptime-DFA harnesses, twice: once against
a **target ref** (the baseline — materialized in a throwaway `git worktree`, so
your checkout is untouched) and once against the **current working tree** (the
candidate — your branch, including uncommitted changes). The competitors are
skipped (they don't change between zeetah branches), so this needs only `zig`,
`python3` and `git` — no Homebrew/cargo/dotnet.

Each side is measured `REPS` times (default 3), **interleaved** (base, cand,
base, cand, …), and reduced to its best (minimum) sample per row by
`reduce_runs.py`. That cancels the single-machine A/B bias where whichever side
runs first sees a colder, less-throttled box — without it, identical source can
show double-digit phantom regressions. `compare.py` then diffs per-workload
throughput into `compare.md`.

```bash
ZEETAH_DIR=../zeetah ./run_compare.sh feat/vector-opts   # compare working tree vs that ref
REGRESSION_PCT=10 REPS=5 ./run_compare.sh main           # gate threshold % / measurement rounds
```

It **exits non-zero** if any reliably-measured workload regresses past
`REGRESSION_PCT` (default 10%), or if a non-pathological workload's match count
changed between the two versions (a correctness divergence). Sub-microsecond ops
vary across separate binaries, so rows whose baseline is below 50 µs/op are
shown but never gated (`compare.py --min-ns`). This is the entry point the
per-PR CI uses — see [CI](#ci).

> **Platform note.** The suite is currently macOS-tuned: RE2 is installed via
> Homebrew and the zeetah harness clock uses the Darwin-only
> `clock_gettime(CLOCK_UPTIME_RAW)`. Running on Linux needs that clock ported to
> `CLOCK_MONOTONIC` and RE2 installed via the system package manager — see
> [CI](#ci).

### Prerequisites

`zig` (0.16.0), `cargo`, `clang++` (C++20-capable, for CTRE), `dotnet`,
`python3`, plus Homebrew (for RE2, PCRE2 and CTRE). `run_all.sh` checks for each
and exits with a clear message if one is missing. POSIX `regex.h` and
`std::regex` need no package — they ship with libc / libc++.

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

- **Single source of truth** — every workload (pattern, sizes, per-engine
  variants, which models apply) lives in `benchmarks.json`. `gen_workloads.py`
  emits the per-engine tables the compiled harnesses `@import`/`#include`; the
  Python harnesses read the manifest directly through `bench_common.py`. A
  pattern is therefore declared in exactly **one** place and cannot drift across
  the harnesses. The workload set spans:
  - **fundamentals:** literal, quantifier, digits, `\w+`, alternation;
  - **typical real-world:** email, URI, IPv4, HTML title/href/tag, price,
    nltk, SSN, ModSecurity SQLi, AWS ENI, Apache POST, k8s/Fluentd log,
    ISO date, 24h time, US phone, hex colour, UUID, MAC address, semver,
    credit-card group, log level, hashtag;
  - **structured extraction** (capture-bearing — exercise `count-captures`,
    where per-match allocation, not the search itself, dominates): `log_parse`
    pulls `(timestamp) (level) (message)` from every log line (high-throughput
    log ingestion — the per-line `Captures` allocation is the bottleneck) and
    `date_fields` splits `(\d{4})-(\d{2})-(\d{2})` into its three numbered
    groups (the ubiquitous date/structured-string case; with zeetah's comptime
    path and CTRE the pattern bakes to a DFA and the group indices resolve at
    compile time — `get<1/2/3>` — so it is both zero-alloc and fast). Unlike the
    other workloads these two run over a **dedicated dense log corpus**
    (`logs.txt`, `$LOGCORPUS`, generated by `gen_logs.py`) in which *every line*
    is a well-formed `timestamp level message` record with a wildly varied
    message length (a few chars to a couple of KiB), so the extraction hits on
    every line and the per-line cost — not match sparsity — is what is measured;
  - **edge but real:** scientific float, JSON string, base64, unix path,
    deep keyword alternation, `foo.*bar.*baz` wildcard gaps;
  - **feature-heavy edge** (only the engines that support the feature run
    these — the rest emit `REJECTED`, exactly like `tokenizer`): a
    backreference duplicate-word `(\b[A-Za-z]+\b) \1`, a `(?<=\$)` look-behind
    amount, a `\p{L}` Unicode-property class, an atomic-group `(?>…)@`. **PCRE2**
    (interpreted + JIT) runs all of these natively — it is the one C engine here
    with full Perl syntax — and **CTRE** runs the backreference, look-behind and
    atomic-group cases (it lacks the `\p{}` Unicode tables in this build);
  - **motivating:** a real GPT-4 `cl100k_base` `tokenizer` pre-tokenizer
    regex, plus a `(a+)+b` pathological case. The
  `tokenizer` row uses inline `(?i:)`, possessive `?+`/`++`, `\p{...}` and
  `(?!\S)` look-around. **Six** engine rows run it and produce **identical
  match counts** (gate-enforced — see below):
  - **zeetah** — natively (possessive parsed as greedy-equivalent).
  - **PCRE2** (interpreted + JIT) — the de-facto C engine; runs the verbatim
    pattern, possessive quantifiers and all.
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
- **Measurement models** (modeled on [rebar](https://github.com/BurntSushi/rebar)):
  each corpus workload is timed under `count` (leftmost non-overlapping match
  count), `count-spans` (sum of match lengths — forces full match-bounds
  computation), `grep` (number of `\n`-delimited lines with ≥1 match) and, for
  capture-bearing workloads, `count-captures` (participating capture groups,
  group 0 excluded — exercises capture extraction). A separate `regex-redux`
  row compiles a fixed set of patterns and counts each over the corpus once
  (compile-many-search-once). The CSV carries a `model` column.
- **Methodology:** compile and search timed in separate loops; reported value
  is the median of a loop sized to run ≥50 ms (5–500 iterations). zeetah
  uses libc for timing/IO because Zig 0.16 reworked `std.Io`/`std.time`.
  Every engine is built optimized (`clang++ -O2`, `cargo --release`, etc.). For
  the Zig harnesses this means **`-OReleaseFast` must precede the `-M` module
  args** — in Zig's multi-module CLI the optimize mode applies to modules defined
  *after* it, so placing it last silently leaves them at the Debug default
  (zeetah/mvzr ran ~10–18× slower, with std's SIMD `memchr` falling back to
  scalar). Verify a harness with `@import("builtin").mode`.
- **Correctness gate:** `aggregate.py` fails if match counts disagree across
  engines for any non-`pathological` `(model, workload, input_bytes)` row. This
  includes `tokenizer`: zeetah, PCRE2 (interp + JIT), `fancy-regex`, .NET and the
  PyPI `regex` module all run it and **must agree** at every size (gate-enforced),
  which gates zeetah's tokenizer semantics against four independent mainstream
  engines, including the ones production BPE libraries actually use. One engine is
  **gate-exempt** by declaration in `benchmarks.json` (`gate_exempt_engines`):
  **POSIX `regex.h`**, whose leftmost-longest semantics and extension handling of
  `\d`/`\w`/`\p` legitimately differ from the leftmost-first PCRE family — it is
  measured and shown but never gated. PCRE2, `std::regex` and CTRE are *not*
  exempt: they are PCRE-compatible and held to the same agreement.
- **Input sizes:** corpus slices run up to 1 MiB; zeetah's `findAll` is a
  single linear leftmost-first NFA pass (no per-match restart).

## CI

The per-PR comparison runs from a GitHub Actions workflow that lives **in the
zeetah engine repo** (where the PRs are), not here:
`.github/workflows/bench-compare.yml`. On each PR to `main` it:

1. checks out the PR (candidate) and clones this benchmark repo;
2. fetches the PR's base branch and runs `./run_compare.sh origin/<base>`, which
   builds the zeetah runtime + DFA harnesses against both the base (baseline)
   and the PR (candidate) and diffs them;
3. posts `compare.md` as a sticky PR comment, and turns the check **red** on a
   correctness divergence or a `>REGRESSION_PCT` slowdown.

Setup notes:

- **This repo must be reachable from CI.** It has no remote yet — push it to
  GitHub and point the workflow's `BENCH_REPO_URL` / the `actions/checkout`
  `repository:` at it (add a token if private).
- **Runner:** `macos-latest` — the harness clock is the Darwin-only
  `CLOCK_UPTIME_RAW`. Only zeetah is built in compare mode, so no
  Homebrew/cargo/dotnet is needed (unlike the full `run_all.sh`).
- **Zig version:** the workflow's `ZIG_VERSION` must compile **both** the engine
  and the harness. The engine's `ci.yml` pins `0.17.0-dev.56+a8226cd53`; the
  harness was validated locally on `0.16.0`. If a build fails, that env var is
  the first knob.
- **Signal:** shared CI runners are noisy. Sub-microsecond rows are excluded
  from the gate (`--min-ns 50000`) and the default threshold is a deliberately
  loose 10 %, so treat a green check as "no gross regression + correctness
  held", not a precise micro-benchmark.

## Files

| File | Role |
|------|------|
| `run_all.sh` | orchestrator (full cross-engine run — mode 1) |
| `run_compare.sh` | branch-comparison orchestrator (zeetah-only, baseline vs candidate — mode 2) |
| `reduce_runs.py` | reduce N interleaved measurement rounds of one side to its best (min) per row |
| `compare.py` | diff two zeetah runs → `compare.md`; gates on regression + correctness divergence |
| `benchmarks.json` | **single source of truth** — every workload pattern, sizes, per-engine variants and which models apply |
| `bench_common.py` | loads `benchmarks.json`, resolves the per-engine workload list (imported by the Python harnesses) |
| `gen_workloads.py` | emits per-engine workload tables into `gen/` for the compiled harnesses |
| `gen/` | generated per-engine workload sources (git-ignored; regenerated each run) |
| `build.zig` / `build.zig.zon` | `zig build bench` / `bench-dfa`; zeetah-source resolution + pinned-dep CI path |
| `gen_corpus.py` | deterministic mixed-corpus generator (`corpus.txt`) |
| `gen_logs.py` | deterministic dense log-corpus generator (`logs.txt`/`$LOGCORPUS`); every line a `timestamp level message` record with wildly varied message length — feeds the `log_parse`/`date_fields` workloads |
| `aggregate.py` | merge CSVs → `results.md`, enforce correctness gate (keyed on model+workload+size) |
| `zig_bench.zig` | zeetah runtime harness (compiled against `$ZEETAH_SRC`) |
| `zig_dfa_bench.zig` | zeetah comptime-DFA harness (`zeetah-dfa` engine) |
| `mvzr_bench.zig` | mvzr harness (compiled against vendored `mvzr/`) |
| `mvzr/` | vendored mvzr source (pinned tag, fetched by `run_all.sh`; git-ignored) |
| `rust/src/main.rs` | Rust base `regex` crate harness (Cargo bin `rust_bench`) |
| `rust/src/bin/fancy_bench.rs` | Rust `fancy-regex` harness (Cargo bin `fancy_bench`; tiktoken/rustbpe engine) |
| `re2/bench.cpp` | RE2 harness (clang++ + pkg-config) |
| `pcre2/bench.cpp` | PCRE2 harness (clang++); emits both `pcre2` (interpreted) and `pcre2-jit` |
| `posix/bench.cpp` | POSIX `regex.h` harness (clang++; libc baseline, gate-exempt, SIGALRM watchdog) |
| `stdregex/bench.cpp` | C++ `std::regex` harness (clang++/libc++; SIGALRM watchdog) |
| `ctre/bench.cpp` | CTRE compile-time-regex harness (clang++ `-std=c++20`; fork-isolated per workload) |
| `dotnet/` | .NET `Regex` harness (default backtracking engine, 2 s timeout) |
| `python/bench_lib.py` | shared Python harness logic (models, timing, pathological child) imported by both Python harnesses |
| `python/bench.py` | Python stdlib `re` harness (pathological run in a 2 s child) |
| `python/bench_regex.py` | Python PyPI `regex`-module harness (run via local `.venv`) |
| `FINDINGS.md` | historical cross-engine analysis writeup |
