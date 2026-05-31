#!/usr/bin/env bash
# zeetah branch-comparison benchmark (the "PR" mode).
#
# Builds the zeetah runtime VM *and* comptime-DFA harnesses against TWO versions
# of the zeetah engine source — a target ref (the baseline, e.g. the PR's base
# branch) and the current working tree (the candidate, i.e. your branch /
# uncommitted changes) — over one shared deterministic corpus, then diffs the
# per-workload throughput (see compare.py).
#
# Only the zeetah engine is built here: the other competitors (RE2, Rust, .NET,
# Python, mvzr) do not change between zeetah branches, so re-running them would
# be wasted work. For the full cross-engine landscape use ./run_all.sh instead.
#
# Because only zeetah harnesses run, this needs just `zig` and `python3` — no
# Homebrew/cargo/dotnet toolchain. It is therefore the CI-friendly entry point.
#
# Usage:
#   ./run_compare.sh [TARGET_REF]
#     TARGET_REF   git ref in the zeetah repo to use as baseline (default: main,
#                  or $BENCH_TARGET_REF). The candidate is always the current
#                  working tree at $ZEETAH_DIR.
#
# Env:
#   ZEETAH_DIR      path to the zeetah engine checkout   (default: ../zeetah)
#   BENCH_TARGET_REF  default baseline ref               (default: main)
#   REGRESSION_PCT  fail if any workload slows by > this % (default: 10)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TARGET_REF="${1:-${BENCH_TARGET_REF:-main}}"
ZEETAH_DIR="${ZEETAH_DIR:-../zeetah}"
REGRESSION_PCT="${REGRESSION_PCT:-10}"
# Each side is measured REPS times, interleaved, and reduced to its best (min)
# per row — see reduce_runs.py. >1 is what cancels single-shot machine-state
# bias; keep it odd-ish and small (the builds happen once regardless).
REPS="${REPS:-3}"

command -v zig     >/dev/null || { echo "ERROR: zig not found"     >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 not found" >&2; exit 1; }
command -v git     >/dev/null || { echo "ERROR: git not found"     >&2; exit 1; }

[ -d "$ZEETAH_DIR/.git" ] || [ -f "$ZEETAH_DIR/.git" ] || {
    echo "ERROR: $ZEETAH_DIR is not a git checkout (set ZEETAH_DIR)" >&2; exit 1; }
ZEETAH_DIR="$(cd "$ZEETAH_DIR" && pwd)"
CAND_SRC="$ZEETAH_DIR/src/root.zig"
[ -f "$CAND_SRC" ] || { echo "ERROR: no zeetah source at $CAND_SRC" >&2; exit 1; }

CORPUS="./corpus.txt"
export CORPUS

echo "==> Generating deterministic corpus"
python3 gen_corpus.py "$CORPUS"
echo "==> Generating per-engine workload sources"
python3 gen_workloads.py

# Build (only) both zeetah harnesses against a given src root.
#   $1 = path to src/root.zig   $2 = output prefix   $3 = private build cache
# Sets ${prefix^^}_DFA_OK=1 if the comptime-DFA harness built.
build_side() {
    local src="$1" prefix="$2" cache="$3"
    rm -rf "$cache"
    echo "==> [$prefix] building zeetah runtime harness"
    zig build-exe \
        --dep zeetah -Mroot="zig_bench.zig" -Mzeetah="$src" \
        -lc -OReleaseFast --name "${prefix}_bench" --cache-dir "$cache" \
        -femit-bin="./${prefix}_bench"

    echo "==> [$prefix] building zeetah comptime-DFA harness"
    # Non-fatal, exactly as in run_all.sh: a DFA-ineligible pattern is a hard
    # @compileError, so a build failure must not abort the comparison — the
    # zeetah-dfa rows are simply omitted for this side.
    if zig build-exe \
        --dep zeetah -Mroot="zig_dfa_bench.zig" -Mzeetah="$src" \
        -lc -OReleaseFast --name "${prefix}_dfa_bench" --cache-dir "$cache" \
        -femit-bin="./${prefix}_dfa_bench"; then
        eval "${prefix}_DFA_OK=1"
    else
        echo "WARNING: [$prefix] comptime-DFA harness failed to build — zeetah-dfa omitted on this side" >&2
        eval "${prefix}_DFA_OK=0"
    fi
}

# Run one side's harnesses once, appending their CSV rows to ${prefix}.rounds.csv.
#   $1 = prefix   $2 = 1 if the DFA harness exists for this side
measure_side() {
    local prefix="$1" dfa_ok="$2"
    "./${prefix}_bench" >> "${prefix}.rounds.csv"
    if [ "$dfa_ok" = "1" ]; then
        "./${prefix}_dfa_bench" >> "${prefix}.rounds.csv"
    fi
}

# --- baseline: materialize the target ref in a throwaway worktree so the real
#     zeetah checkout (with your uncommitted candidate changes) is untouched. ---
WT="$(mktemp -d "${TMPDIR:-/tmp}/zeetah-base.XXXXXX")"
cleanup() {
    git -C "$ZEETAH_DIR" worktree remove --force "$WT" >/dev/null 2>&1 || true
    rm -rf "$WT"
}
trap cleanup EXIT

echo "==> Materializing baseline ref '$TARGET_REF' from $ZEETAH_DIR"
# --detach checks out the ref's commit without claiming the branch, so this
# works even when TARGET_REF is the branch already checked out in the main tree.
git -C "$ZEETAH_DIR" worktree add --detach --force "$WT" "$TARGET_REF"
BASE_SRC="$WT/src/root.zig"
[ -f "$BASE_SRC" ] || { echo "ERROR: baseline ref has no src/root.zig" >&2; exit 1; }

BASE_DESC="$(git -C "$ZEETAH_DIR" rev-parse --short "$TARGET_REF" 2>/dev/null || echo "$TARGET_REF")"
CAND_DESC="$(git -C "$ZEETAH_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo working-tree)"
if ! git -C "$ZEETAH_DIR" diff --quiet 2>/dev/null; then
    CAND_DESC="${CAND_DESC}+dirty"
fi

build_side "$BASE_SRC" "baseline"  "./.zig-bench-cache-base"
build_side "$CAND_SRC" "candidate" "./.zig-bench-cache-cand"

# Interleaved measurement: alternate sides each round so neither is
# systematically favoured by warm-up/thermal state. reduce_runs.py then keeps
# the best (min) sample per row for each side.
: > baseline.rounds.csv
: > candidate.rounds.csv
for r in $(seq 1 "$REPS"); do
    echo "==> measurement round $r/$REPS"
    measure_side baseline  "$baseline_DFA_OK"
    measure_side candidate "$candidate_DFA_OK"
done

echo "==> Comparing baseline ('$TARGET_REF') vs candidate ('$CAND_DESC'), best of ${REPS}, regression threshold ${REGRESSION_PCT}%"
HDR="engine,model,workload,input_bytes,iterations,compile_ns,search_ns_per_op,throughput_mb_s,match_count,note"
{ echo "$HDR"; python3 reduce_runs.py baseline.rounds.csv;  } > compare_baseline.csv
{ echo "$HDR"; python3 reduce_runs.py candidate.rounds.csv; } > compare_candidate.csv

# compare.py exits non-zero on a correctness divergence or a regression past the
# threshold — that propagates out of run_compare.sh to gate CI.
python3 compare.py compare_baseline.csv compare_candidate.csv compare.md \
    --baseline-label "$TARGET_REF ($BASE_DESC)" \
    --candidate-label "$CAND_DESC" \
    --regression-pct "$REGRESSION_PCT"

echo "==> Done. See compare.md"
