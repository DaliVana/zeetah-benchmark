// Cross-engine benchmark harness — RE2 side.
//
// Emits CSV rows (no header) with the schema shared by all harnesses
// (note the `model` column):
//
//   engine,model,workload,input_bytes,iterations,compile_ns,search_ns_per_op,throughput_mb_s,match_count,note
//
// The workload table is NOT declared here: it is generated from the single
// source of truth (benchmarks.json) into gen/workloads_re2.hpp by
// gen_workloads.py, so patterns can never drift across the harnesses. This
// file owns only the timing methodology and the per-model measurement logic.
//
// Models (faithful translation of zig_bench.zig):
//   count           — leftmost non-overlapping match count (always run)
//   count-spans     — sum of match lengths over the SAME walk (iff wl.spans)
//   grep            — lines with >=1 match (iff wl.grep)
//   count-captures  — participating capture groups, group 0 excluded (iff captures)
//   regex-redux     — compile-many-search-once over a fixed member set (one row)
//
// Corpus path: CORPUS env var, else corpus.txt
// (run_all.sh runs every harness from the repo root).

#include <re2/re2.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "../gen/workloads_re2.hpp"

using clk = std::chrono::steady_clock;

static uint64_t ns_since(clk::time_point t0) {
    return (uint64_t)std::chrono::duration_cast<std::chrono::nanoseconds>(
               clk::now() - t0)
        .count();
}

static void emit_row(const char* model, const char* workload, size_t input_bytes,
                     size_t iterations, int64_t compile_ns, int64_t search_ns,
                     double throughput, int64_t match_count, const char* note) {
    printf("re2,%s,%s,%zu,%zu,%lld,%lld,%.2f,%lld,%s\n", model, workload,
           input_bytes, iterations, (long long)compile_ns, (long long)search_ns,
           throughput, (long long)match_count, note);
}

// --- per-model match functions over [0, len) -------------------------------

// count: leftmost, non-overlapping match count (the empty-match advance is the
// canonical pos = mend>mstart ? mend : mend+1).
static size_t scan_count(const RE2& re, re2::StringPiece text) {
    size_t count = 0;
    size_t pos = 0;
    re2::StringPiece group;
    while (pos <= text.size() &&
           re.Match(text, pos, text.size(), RE2::UNANCHORED, &group, 1)) {
        size_t mstart = (size_t)(group.data() - text.data());
        size_t mend = mstart + group.size();
        count++;
        pos = (mend > mstart) ? mend : mend + 1;
    }
    return count;
}

// count-spans: sum of match lengths over the SAME walk as scan_count.
static size_t scan_spans(const RE2& re, re2::StringPiece text) {
    size_t sum = 0;
    size_t pos = 0;
    re2::StringPiece group;
    while (pos <= text.size() &&
           re.Match(text, pos, text.size(), RE2::UNANCHORED, &group, 1)) {
        size_t mstart = (size_t)(group.data() - text.data());
        size_t mend = mstart + group.size();
        sum += (mend - mstart);
        pos = (mend > mstart) ? mend : mend + 1;
    }
    return sum;
}

// grep: number of segments (split on '\n', trailing fragment included when
// non-empty) containing >=1 match.
static size_t scan_grep(const RE2& re, re2::StringPiece text) {
    const char* data = text.data();
    size_t len = text.size();
    size_t n = 0;
    size_t start = 0;
    for (size_t i = 0; i < len; i++) {
        if (data[i] == '\n') {
            if (RE2::PartialMatch(re2::StringPiece(data + start, i - start), re)) n++;
            start = i + 1;
        }
    }
    if (start < len &&
        RE2::PartialMatch(re2::StringPiece(data + start, len - start), re))
        n++;
    return n;
}

// count-captures: participating capture groups summed over all non-overlapping
// matches, group 0 (the whole match) excluded. A group participates iff its
// StringPiece slot has non-null data().
static size_t scan_captures(const RE2& re, re2::StringPiece text) {
    int ngroups = re.NumberOfCapturingGroups();
    if (ngroups < 0) ngroups = 0;
    size_t total = 0;
    size_t pos = 0;
    // groups[0] is the whole match; groups[1..=ngroups] are capture groups.
    std::vector<re2::StringPiece> groups((size_t)ngroups + 1);
    while (pos <= text.size() &&
           re.Match(text, pos, text.size(), RE2::UNANCHORED, groups.data(),
                    ngroups + 1)) {
        size_t mstart = (size_t)(groups[0].data() - text.data());
        size_t mend = mstart + groups[0].size();
        for (int i = 1; i <= ngroups; i++) {
            if (groups[i].data() != nullptr) total++;
        }
        pos = (mend > mstart) ? mend : mend + 1;
    }
    return total;
}

// --- generic per-model measurement -----------------------------------------

// Run one model: warm up, probe, size the timed loop (5..500 iters, ~50 ms),
// report the median. fn returns the match_count for that model.
template <typename Fn>
static void measure(Fn fn, const char* model, const char* wl_id,
                    const RE2& re, re2::StringPiece text, int64_t compile_ns) {
    size_t mc = fn(re, text);  // warmup
    auto p0 = clk::now();
    mc = fn(re, text);
    uint64_t probe = std::max<uint64_t>(ns_since(p0), 1);

    size_t iters = (size_t)std::min<uint64_t>(
        500, std::max<uint64_t>(5, 50000000ull / probe));
    std::vector<uint64_t> samples;
    samples.reserve(iters);
    for (size_t i = 0; i < iters; i++) {
        auto t0 = clk::now();
        (void)fn(re, text);
        samples.push_back(ns_since(t0));
    }
    std::sort(samples.begin(), samples.end());
    uint64_t median = samples[iters / 2];

    double mb = (double)text.size() / 1000000.0;
    double secs = (double)median / 1000000000.0;
    double throughput = secs > 0.0 ? mb / secs : 0.0;

    emit_row(model, wl_id, text.size(), iters, compile_ns, (int64_t)median,
             throughput, (int64_t)mc, "ok");
}

// Emit a REJECTED row for every model this workload would have run (mirrors
// zig_bench.zig's emitRejected so the per-model report sections stay aligned).
static void emit_rejected(const Workload& wl, size_t len) {
    emit_row("count", wl.id, len, 0, -1, -1, 0.0, -1, "REJECTED");
    if (wl.spans) emit_row("count-spans", wl.id, len, 0, -1, -1, 0.0, -1, "REJECTED");
    if (wl.grep) emit_row("grep", wl.id, len, 0, -1, -1, 0.0, -1, "REJECTED");
    if (wl.captures) emit_row("count-captures", wl.id, len, 0, -1, -1, 0.0, -1, "REJECTED");
}

static void bench_one(const Workload& wl, const char* data, size_t len) {
    re2::StringPiece text(data, len);

    if (wl.force_reject) {
        emit_rejected(wl, len);
        return;
    }

    // --- compile timing (min over 50 constructions; also rejection) ---
    const int compile_iters = 50;
    uint64_t compile_min = UINT64_MAX;
    for (int i = 0; i < compile_iters; i++) {
        auto t0 = clk::now();
        RE2 re(wl.pattern);
        uint64_t dt = ns_since(t0);
        // RE2 rejects lookaround/backref/atomic/possessive (linear-automaton by
        // design). \p{L} IS supported, so unicode_prop compiles.
        if (!re.ok()) {
            emit_rejected(wl, len);
            return;
        }
        if (dt < compile_min) compile_min = dt;
    }
    RE2 re(wl.pattern);
    if (!re.ok()) {
        emit_rejected(wl, len);
        return;
    }
    int64_t cns = (int64_t)compile_min;

    // count always runs. pathological workloads run ONLY count.
    measure(scan_count, "count", wl.id, re, text, cns);
    if (wl.pathological) return;

    if (wl.spans) measure(scan_spans, "count-spans", wl.id, re, text, cns);
    if (wl.grep) measure(scan_grep, "grep", wl.id, re, text, cns);
    if (wl.captures) measure(scan_captures, "count-captures", wl.id, re, text, cns);
}

// regex-redux: compile every member pattern, then one rep = sum over members
// of scan_count(member_re, corpus_prefix). Total compile = min over 50 of
// compiling ALL members; throughput over (REDUX_MEMBERS_N * input_bytes).
static void bench_redux(const std::string& corpus) {
    if (REDUX_MEMBERS_N == 0) return;
    size_t n = std::min(REDUX_SIZE, corpus.size());
    re2::StringPiece text(corpus.data(), n);

    // --- compile timing: min over 50 of compiling ALL members ---
    uint64_t compile_min = UINT64_MAX;
    for (int it = 0; it < 50; it++) {
        auto t0 = clk::now();
        bool ok = true;
        for (size_t k = 0; k < REDUX_MEMBERS_N; k++) {
            RE2 re(REDUX_MEMBERS[k]);
            if (!re.ok()) { ok = false; break; }
        }
        uint64_t dt = ns_since(t0);
        if (!ok) {
            emit_row("regex-redux", "redux", n, 0, -1, -1, 0.0, -1, "REJECTED");
            return;
        }
        if (dt < compile_min) compile_min = dt;
    }

    // --- build once for the search loop ---
    std::vector<RE2*> compiled;
    compiled.reserve(REDUX_MEMBERS_N);
    for (size_t k = 0; k < REDUX_MEMBERS_N; k++) {
        RE2* re = new RE2(REDUX_MEMBERS[k]);
        if (!re->ok()) {
            delete re;
            for (RE2* p : compiled) delete p;
            emit_row("regex-redux", "redux", n, 0, -1, -1, 0.0, -1, "REJECTED");
            return;
        }
        compiled.push_back(re);
    }

    auto redux_run = [&]() -> size_t {
        size_t t = 0;
        for (RE2* re : compiled) t += scan_count(*re, text);
        return t;
    };

    size_t total = redux_run();  // warmup
    auto p0 = clk::now();
    total = redux_run();
    uint64_t probe = std::max<uint64_t>(ns_since(p0), 1);

    size_t iters = (size_t)std::min<uint64_t>(
        500, std::max<uint64_t>(5, 50000000ull / probe));
    std::vector<uint64_t> samples;
    samples.reserve(iters);
    for (size_t i = 0; i < iters; i++) {
        auto t0 = clk::now();
        (void)redux_run();
        samples.push_back(ns_since(t0));
    }
    std::sort(samples.begin(), samples.end());
    uint64_t median = samples[iters / 2];

    double mb = (double)(REDUX_MEMBERS_N * n) / 1000000.0;
    double secs = (double)median / 1000000000.0;
    double throughput = secs > 0.0 ? mb / secs : 0.0;

    emit_row("regex-redux", "redux", n, iters, (int64_t)compile_min,
             (int64_t)median, throughput, (int64_t)total, "ok");

    for (RE2* p : compiled) delete p;
}

int main() {
    const char* env = std::getenv("CORPUS");
    std::string path = env ? env : "corpus.txt";
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        fprintf(stderr, "cannot read corpus %s\n", path.c_str());
        return 1;
    }
    std::ostringstream ss;
    ss << f.rdbuf();
    std::string corpus = ss.str();

    // Dense synthetic log corpus for the `input: logs` workloads; falls back to
    // the mixed corpus if $LOGCORPUS is absent (manual single-engine runs).
    const char* lenv = std::getenv("LOGCORPUS");
    std::string logs;
    { std::ifstream lf(lenv ? lenv : "logs.txt", std::ios::binary);
      if (lf) { std::ostringstream ls; ls << lf.rdbuf(); logs = ls.str(); } else { logs = corpus; } }

    std::string synth(SYNTHETIC_LEN, 'a');

    for (size_t w = 0; w < WORKLOADS_N; w++) {
        const Workload& wl = WORKLOADS[w];
        if (wl.pathological) {
            bench_one(wl, synth.data(), synth.size());
        } else {
            const std::string& src = wl.logs ? logs : corpus;
            for (size_t s = 0; s < CORPUS_SIZES_N; s++) {
                size_t n = std::min(CORPUS_SIZES[s], src.size());
                bench_one(wl, src.data(), n);
            }
        }
    }

    bench_redux(corpus);
    return 0;
}
