#!/usr/bin/env bash
# Cross-engine regex benchmark orchestrator.
#
# Builds and runs the zeetah (runtime VM + comptime DFA), mvzr, Rust
# `regex`, Rust `fancy-regex`, RE2, .NET, Python stdlib `re` and Python PyPI
# `regex`-module harnesses against a shared deterministic corpus, concatenates
# their CSV output, then runs the aggregator (which also enforces the
# cross-engine correctness gate).
#
# This is a standalone repository: every path below is relative to this
# script's directory (the repo root). The zeetah engine source is NOT vendored
# here — it is resolved at build time from $ZEETAH_SRC (see below) so the
# benchmark always measures whatever zeetah tree you point it at.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Everything lives at the repo root now; keep a short alias so the per-engine
# paths below stay readable.
CMP="."
CORPUS="$CMP/corpus.txt"
export CORPUS

# Where to find zeetah's source. Default: a sibling checkout of the engine
# repo, so the benchmark measures your *uncommitted local* zeetah changes
# (the usual perf-iteration flow). Override with the ZEETAH_SRC env var — CI
# points this at a fetched/pinned checkout. Must be the path to zeetah's
# `src/root.zig`; the rest of the module's sources are resolved relative to it.
ZEETAH_SRC="${ZEETAH_SRC:-../zig-regex/src/root.zig}"
if [ ! -f "$ZEETAH_SRC" ]; then
    echo "ERROR: zeetah source not found at: $ZEETAH_SRC" >&2
    echo "  Point ZEETAH_SRC at zeetah's src/root.zig, e.g.:" >&2
    echo "    ZEETAH_SRC=/path/to/zig-regex/src/root.zig $0" >&2
    echo "  Default expects a sibling checkout at ../zig-regex/." >&2
    exit 1
fi
echo "==> Using zeetah source: $ZEETAH_SRC"

# Dedicated, always-clean Zig build cache for the benchmark harnesses.
# The shared project `.zig-cache` (also written by `zig build test`) was
# observed serving a STALE harness binary — the benchmarked engine did not
# reflect current source, producing phantom correctness/perf regressions.
# A private cache, wiped every run, makes every reported number reflect the
# source as it is right now (correctness of a benchmark > incremental speed).
BENCH_CACHE="$CMP/.zig-bench-cache"
rm -rf "$BENCH_CACHE"

echo "==> Checking toolchain"
command -v zig    >/dev/null || { echo "zig not found"; exit 1; }
command -v cargo  >/dev/null || { echo "cargo not found"; exit 1; }
command -v clang++ >/dev/null || { echo "clang++ not found"; exit 1; }
command -v dotnet >/dev/null || { echo "dotnet not found"; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found"; exit 1; }

echo "==> Ensuring RE2 + pkg-config (Homebrew, idempotent)"
command -v pkg-config >/dev/null || brew install pkg-config
brew list re2 >/dev/null 2>&1 || brew install re2
# Homebrew keg-only deps: make their .pc files discoverable.
export PKG_CONFIG_PATH="$(brew --prefix re2)/lib/pkgconfig:$(brew --prefix abseil)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

echo "==> Ensuring mvzr source (vendored, idempotent)"
MVZR_VER="v0.3.10"
MVZR_DIR="$CMP/mvzr"
if [ ! -f "$MVZR_DIR/src/mvzr.zig" ]; then
    mkdir -p "$MVZR_DIR"
    curl -fsSL "https://github.com/mnemnion/mvzr/archive/refs/tags/${MVZR_VER}.tar.gz" \
        | tar -xz -C "$MVZR_DIR" --strip-components=1
fi

echo "==> Ensuring Python 'regex' module venv (local, idempotent)"
# `regex` (PyPI) is Python's de-facto Unicode-regex library — what BPE
# tokenizer code actually uses. Installed into a local, git-ignored venv so
# the global site-packages / system Python stay untouched.
VENV_DIR="$CMP/.venv"
VENV_PY="$VENV_DIR/bin/python"
if [ ! -x "$VENV_PY" ]; then
    python3 -m venv "$VENV_DIR"
fi
"$VENV_PY" -c "import regex" 2>/dev/null || "$VENV_DIR/bin/pip" -q install regex

echo "==> Generating deterministic corpus"
python3 "$CMP/gen_corpus.py" "$CORPUS"

echo "==> [1/9] zeetah harness"
# Compiled directly (no build.zig step) so the benchmark stays fully
# self-contained and the zeetah source tree is untouched. The zeetah module
# is pulled from $ZEETAH_SRC (sibling checkout by default; CI overrides it).
zig build-exe \
    --dep zeetah -Mroot="$CMP/zig_bench.zig" -Mzeetah="$ZEETAH_SRC" \
    -lc -OReleaseFast --name bench_compare --cache-dir "$BENCH_CACHE" \
    -femit-bin="$CMP/bench_compare"
"$CMP/bench_compare" > "$CMP/zig.csv"

echo "==> [2/9] zeetah comptime-DFA harness"
# Same workloads/corpus as the runtime harness, but every pattern is baked
# into a minimized DFA at build time (ComptimeRegex). Emits engine "zeetah-dfa";
# DFA-ineligible patterns surface as NO_DFA_FALLBACK rows, which the
# correctness gate ignores (it only compares note=="ok" rows).
# Non-fatal: a DFA-ineligible pattern is a hard @compileError post-Phase-6
# (no runtime fallback). Failing this one supplementary harness must NOT abort
# the whole cross-engine comparison — emit an empty CSV and a loud warning so
# the aggregator simply omits the zeetah-dfa engine instead of the run dying here.
if zig build-exe \
    --dep zeetah -Mroot="$CMP/zig_dfa_bench.zig" -Mzeetah="$ZEETAH_SRC" \
    -lc -OReleaseFast --name zig_dfa_bench --cache-dir "$BENCH_CACHE" \
    -femit-bin="$CMP/zig_dfa_bench"; then
    "$CMP/zig_dfa_bench" > "$CMP/zig_dfa.csv"
else
    echo "WARNING: comptime-DFA harness failed to build — skipping (zeetah-dfa engine omitted from results)" >&2
    : > "$CMP/zig_dfa.csv"
fi

echo "==> [3/9] mvzr harness"
zig build-exe \
    --dep mvzr -Mroot="$CMP/mvzr_bench.zig" -Mmvzr="$MVZR_DIR/src/mvzr.zig" \
    -lc -OReleaseFast --name mvzr_bench --cache-dir "$BENCH_CACHE" \
    -femit-bin="$CMP/mvzr_bench"
# mvzr is a third-party backtracking VM: some patterns it accepts at compile
# time still panic at *match* time (integer overflow on deep backtracking).
# Drive one isolated, hard-timed child per workload so a crash/timeout becomes
# a CRASHED/TIMEOUT row (skipped by the correctness gate) instead of aborting
# the whole orchestrator. The catastrophic (a+)+b case is handled separately
# below, exactly like the Python harness — see mvzr_bench.zig.
python3 - "$CMP/mvzr_bench" "$CORPUS" > "$CMP/mvzr.csv" <<'PY'
import os, subprocess, sys
exe, corpus = sys.argv[1], sys.argv[2]
SIZES = [1024, 8192, 32768, 1048576]
TIMEOUT_S = 15.0
env = {**os.environ, "CORPUS": corpus}
ids = subprocess.run([exe], env={**env, "BENCH_MVZR_MODE": "list"},
                     capture_output=True, text=True, check=True).stdout.split()
for i, wid in enumerate(ids):
    try:
        r = subprocess.run(
            [exe],
            env={**env, "BENCH_MVZR_MODE": "one", "BENCH_MVZR_IDX": str(i)},
            capture_output=True, text=True, timeout=TIMEOUT_S)
        if r.returncode == 0 and r.stdout.strip():
            sys.stdout.write(r.stdout)
        else:
            for s in SIZES:
                print(f"mvzr,{wid},{s},0,-1,-1,0.00,-1,CRASHED")
    except subprocess.TimeoutExpired:
        for s in SIZES:
            print(f"mvzr,{wid},{s},0,-1,-1,0.00,-1,TIMEOUT")
PY
python3 - "$CMP/mvzr_bench" >> "$CMP/mvzr.csv" <<'PY'
import os, subprocess, sys, time
exe, N, TIMEOUT_S = sys.argv[1], 50000, 2.0
t0 = time.perf_counter_ns()
try:
    subprocess.run([exe], env={**os.environ, "BENCH_MVZR_MODE": "patho"},
                   timeout=TIMEOUT_S, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    dt = time.perf_counter_ns() - t0
    secs = dt / 1_000_000_000.0
    tput = (N / 1_000_000.0) / secs if secs > 0 else 0.0
    print(f"mvzr,pathological,{N},1,-1,{dt},{tput:.2f},0,ok")
except subprocess.TimeoutExpired:
    print(f"mvzr,pathological,{N},0,-1,-1,0.00,-1,TIMEOUT")
PY

echo "==> [4/9] Rust regex harness"
# One build produces both the base-`regex` and `fancy-regex` binaries.
cargo build --release --manifest-path "$CMP/rust/Cargo.toml" >/dev/null 2>&1
"$CMP/rust/target/release/rust_bench" > "$CMP/rust.csv"

echo "==> [5/9] Rust fancy-regex harness (look-around/possessive; tiktoken/rustbpe engine)"
"$CMP/rust/target/release/fancy_bench" > "$CMP/fancy.csv"

echo "==> [6/9] RE2 harness"
RE2_CXXFLAGS="$(pkg-config --cflags re2)"
RE2_LIBS="$(pkg-config --libs re2)"
# shellcheck disable=SC2086
clang++ -std=c++17 -O2 -o "$CMP/re2/re2_bench" "$CMP/re2/bench.cpp" \
    $RE2_CXXFLAGS $RE2_LIBS
"$CMP/re2/re2_bench" > "$CMP/re2.csv"

echo "==> [7/9] .NET regex harness"
dotnet build -c Release "$CMP/dotnet/Bench.csproj" >/dev/null
dotnet "$CMP/dotnet/bin/Release/net10.0/dotnet_bench.dll" > "$CMP/dotnet.csv"

echo "==> [8/9] Python stdlib re harness"
python3 "$CMP/python/bench.py" > "$CMP/python.csv"

echo "==> [9/9] Python regex-module harness (PyPI 'regex'; tokenizer-grade Unicode)"
"$VENV_PY" "$CMP/python/bench_regex.py" > "$CMP/python_regex.csv"

echo "==> Aggregating"
{
    echo "engine,workload,input_bytes,iterations,compile_ns,search_ns_per_op,throughput_mb_s,match_count,note"
    cat "$CMP/zig.csv" "$CMP/zig_dfa.csv" "$CMP/mvzr.csv" "$CMP/re2.csv" "$CMP/rust.csv" "$CMP/fancy.csv" "$CMP/dotnet.csv" "$CMP/python.csv" "$CMP/python_regex.csv"
} > "$CMP/results.csv"

python3 "$CMP/aggregate.py" "$CMP/results.csv" "$CMP/results.md"
echo "==> Done. See $CMP/results.md and $CMP/results.csv"
