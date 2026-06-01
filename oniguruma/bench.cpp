// Cross-engine benchmark harness — Oniguruma side (emits engine `oniguruma`).
//
// Oniguruma is the C backtracking engine behind Ruby, PHP's mbstring, and many
// editor grammars (TextMate / Atom / vim's `:h pattern` peers). Like PCRE2 it
// speaks the full Perl/Ruby syntax — lookbehind, backreferences, atomic groups,
// possessive quantifiers, named captures, \p{...} — so it rejects none of the
// workloads. It is interpreted only (no JIT), so unlike PCRE2 this binary emits
// a single engine.
//
// Emits the shared CSV schema (no header):
//   engine,model,workload,input_bytes,iterations,compile_ns,search_ns_per_op,throughput_mb_s,match_count,note
//
// Syntax/encoding: ONIG_SYNTAX_RUBY + ONIG_ENCODING_UTF8. Ruby is the closest
// peer to the leftmost-first PCRE family the correctness gate compares against,
// and its ^/$ are line-anchored by default — which is why `multiline_log` is
// fed its bare ^…$ pattern via an engine_patterns override (a `(?m)` prefix
// would mean DOTALL here, not multiline). UTF-8 matches the other Unicode
// engines; the corpus is ASCII in every matched region, so \w / \p{L} agree.
//
// Catastrophic backtracking (the `pathological` workload) is bounded by
// onig_set_retry_limit_in_match: when hit, onig_search returns
// ONIGERR_RETRY_LIMIT_IN_*_OVER and we emit a MATCH_LIMIT row instead of
// hanging — the direct analogue of PCRE2's MATCH_LIMIT.
//
// Workload table: gen/workloads_oniguruma.hpp (generated from benchmarks.json).
// Corpus path: CORPUS env var, else corpus.txt.

#include <oniguruma.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "../gen/workloads_oniguruma.hpp"

using clk = std::chrono::steady_clock;

// Bound the backtracker so the pathological workload fails fast instead of
// hanging (matches PCRE2's MATCH_LIMIT magnitude).
static const unsigned long MATCH_LIMIT = 50000000;

static uint64_t ns_since(clk::time_point t0) {
    return (uint64_t)std::chrono::duration_cast<std::chrono::nanoseconds>(
               clk::now() - t0)
        .count();
}

static void emit_row(const char* engine, const char* model, const char* workload,
                     size_t input_bytes, size_t iterations, int64_t compile_ns,
                     int64_t search_ns, double throughput, int64_t match_count,
                     const char* note) {
    printf("%s,%s,%s,%zu,%zu,%lld,%lld,%.2f,%lld,%s\n", engine, model, workload,
           input_bytes, iterations, (long long)compile_ns, (long long)search_ns,
           throughput, (long long)match_count, note);
}

// Set to the negative Oniguruma error (e.g. ONIGERR_RETRY_LIMIT_IN_MATCH_OVER)
// when a scan aborts; 0 means the last scan completed normally.
static int g_match_error = 0;

struct Eng {
    regex_t* reg;
    OnigRegion* region;
};

// count: leftmost, non-overlapping; canonical empty-match advance
// (pos = mend>mstart ? mend : mend+1).
static size_t scan_count(const Eng& e, const char* data, size_t len) {
    size_t count = 0, pos = 0;
    const OnigUChar* str = (const OnigUChar*)data;
    const OnigUChar* end = str + len;
    while (pos <= len) {
        int r = onig_search(e.reg, str, end, str + pos, end, e.region, ONIG_OPTION_NONE);
        if (r == ONIG_MISMATCH) break;
        if (r < 0) { g_match_error = r; break; }
        size_t mstart = (size_t)e.region->beg[0];
        size_t mend = (size_t)e.region->end[0];
        count++;
        pos = (mend > mstart) ? mend : mend + 1;
    }
    return count;
}

static size_t scan_spans(const Eng& e, const char* data, size_t len) {
    size_t sum = 0, pos = 0;
    const OnigUChar* str = (const OnigUChar*)data;
    const OnigUChar* end = str + len;
    while (pos <= len) {
        int r = onig_search(e.reg, str, end, str + pos, end, e.region, ONIG_OPTION_NONE);
        if (r == ONIG_MISMATCH) break;
        if (r < 0) { g_match_error = r; break; }
        size_t mstart = (size_t)e.region->beg[0];
        size_t mend = (size_t)e.region->end[0];
        sum += (mend - mstart);
        pos = (mend > mstart) ? mend : mend + 1;
    }
    return sum;
}

// grep: segments split on '\n' (trailing fragment included when non-empty)
// containing >=1 match.
static size_t scan_grep(const Eng& e, const char* data, size_t len) {
    size_t n = 0, start = 0;
    for (size_t i = 0; i < len; i++) {
        if (data[i] == '\n') {
            const OnigUChar* s = (const OnigUChar*)(data + start);
            const OnigUChar* en = (const OnigUChar*)(data + i);
            int r = onig_search(e.reg, s, en, s, en, e.region, ONIG_OPTION_NONE);
            if (r >= 0) n++;
            else if (r != ONIG_MISMATCH) { g_match_error = r; return n; }
            start = i + 1;
        }
    }
    if (start < len) {
        const OnigUChar* s = (const OnigUChar*)(data + start);
        const OnigUChar* en = (const OnigUChar*)(data + len);
        int r = onig_search(e.reg, s, en, s, en, e.region, ONIG_OPTION_NONE);
        if (r >= 0) n++;
        else if (r != ONIG_MISMATCH) g_match_error = r;
    }
    return n;
}

// count-captures: participating groups (region slot != ONIG_REGION_NOTPOS)
// summed over all matches, group 0 excluded.
static size_t scan_captures(const Eng& e, const char* data, size_t len) {
    size_t total = 0, pos = 0;
    const OnigUChar* str = (const OnigUChar*)data;
    const OnigUChar* end = str + len;
    while (pos <= len) {
        int r = onig_search(e.reg, str, end, str + pos, end, e.region, ONIG_OPTION_NONE);
        if (r == ONIG_MISMATCH) break;
        if (r < 0) { g_match_error = r; break; }
        size_t mstart = (size_t)e.region->beg[0];
        size_t mend = (size_t)e.region->end[0];
        for (int i = 1; i < e.region->num_regs; i++) {
            if (e.region->beg[i] != ONIG_REGION_NOTPOS) total++;
        }
        pos = (mend > mstart) ? mend : mend + 1;
    }
    return total;
}

// Generic timed measurement: warmup, probe, size the loop to ~50 ms in
// [5,500] iters, report the median. A retry-limit abort during warmup emits a
// MATCH_LIMIT row instead of a timing.
template <typename Fn>
static void measure(Fn fn, const char* engine, const char* model,
                    const char* wl_id, size_t input_bytes, int64_t compile_ns) {
    g_match_error = 0;
    size_t mc = fn();  // warmup
    if (g_match_error != 0) {
        const char* note = (g_match_error == ONIGERR_RETRY_LIMIT_IN_MATCH_OVER ||
                            g_match_error == ONIGERR_RETRY_LIMIT_IN_SEARCH_OVER)
                               ? "MATCH_LIMIT" : "ERROR";
        emit_row(engine, model, wl_id, input_bytes, 0, compile_ns, -1, 0.0, -1, note);
        return;
    }
    auto p0 = clk::now();
    mc = fn();
    uint64_t probe = std::max<uint64_t>(ns_since(p0), 1);

    size_t iters = (size_t)std::min<uint64_t>(
        500, std::max<uint64_t>(5, 50000000ull / probe));
    std::vector<uint64_t> samples;
    samples.reserve(iters);
    for (size_t i = 0; i < iters; i++) {
        auto t0 = clk::now();
        (void)fn();
        samples.push_back(ns_since(t0));
    }
    std::sort(samples.begin(), samples.end());
    uint64_t median = samples[iters / 2];

    double mb = (double)input_bytes / 1000000.0;
    double secs = (double)median / 1000000000.0;
    double throughput = secs > 0.0 ? mb / secs : 0.0;
    emit_row(engine, model, wl_id, input_bytes, iters, compile_ns,
             (int64_t)median, throughput, (int64_t)mc, "ok");
}

static void emit_rejected(const char* engine, const Workload& wl, size_t len) {
    emit_row(engine, "count", wl.id, len, 0, -1, -1, 0.0, -1, "REJECTED");
    if (wl.spans) emit_row(engine, "count-spans", wl.id, len, 0, -1, -1, 0.0, -1, "REJECTED");
    if (wl.grep) emit_row(engine, "grep", wl.id, len, 0, -1, -1, 0.0, -1, "REJECTED");
    if (wl.captures) emit_row(engine, "count-captures", wl.id, len, 0, -1, -1, 0.0, -1, "REJECTED");
}

static void run_models(const char* engine, const Workload& wl, const Eng& e,
                       const char* data, size_t len, int64_t compile_ns) {
    measure([&] { return scan_count(e, data, len); }, engine, "count", wl.id, len, compile_ns);
    if (wl.pathological) return;
    if (wl.spans) measure([&] { return scan_spans(e, data, len); }, engine, "count-spans", wl.id, len, compile_ns);
    if (wl.grep) measure([&] { return scan_grep(e, data, len); }, engine, "grep", wl.id, len, compile_ns);
    if (wl.captures) measure([&] { return scan_captures(e, data, len); }, engine, "count-captures", wl.id, len, compile_ns);
}

// Compile one pattern; report the min compile time over 50 constructions.
static regex_t* compile_one(const char* pattern, int64_t* compile_ns_out) {
    OnigErrorInfo einfo;
    const OnigUChar* pat = (const OnigUChar*)pattern;
    const OnigUChar* pat_end = pat + strlen(pattern);
    uint64_t cmin = UINT64_MAX;
    for (int i = 0; i < 50; i++) {
        regex_t* r = nullptr;
        auto t0 = clk::now();
        int rc = onig_new(&r, pat, pat_end, ONIG_OPTION_NONE, ONIG_ENCODING_UTF8,
                          ONIG_SYNTAX_RUBY, &einfo);
        uint64_t dt = ns_since(t0);
        if (rc != ONIG_NORMAL) return nullptr;
        onig_free(r);
        if (dt < cmin) cmin = dt;
    }
    regex_t* reg = nullptr;
    int rc = onig_new(&reg, pat, pat_end, ONIG_OPTION_NONE, ONIG_ENCODING_UTF8,
                      ONIG_SYNTAX_RUBY, &einfo);
    if (rc != ONIG_NORMAL) return nullptr;
    *compile_ns_out = (int64_t)cmin;
    return reg;
}

static void bench_one(const Workload& wl, const char* data, size_t len) {
    if (wl.force_reject) {
        emit_rejected("oniguruma", wl, len);
        return;
    }
    int64_t cns = 0;
    regex_t* reg = compile_one(wl.pattern, &cns);
    if (!reg) {  // Oniguruma rejected the pattern (should be rare)
        emit_rejected("oniguruma", wl, len);
        return;
    }
    OnigRegion* region = onig_region_new();
    Eng e{reg, region};
    run_models("oniguruma", wl, e, data, len, cns);
    onig_region_free(region, 1);
    onig_free(reg);
}

// regex-redux: compile all members, one rep = sum over members of
// scan_count(member, prefix).
static void bench_redux(const std::string& corpus) {
    if (REDUX_MEMBERS_N == 0) return;
    size_t n = std::min(REDUX_SIZE, corpus.size());
    const char* data = corpus.data();
    OnigErrorInfo einfo;

    // compile timing: min over 50 of compiling ALL members
    uint64_t cmin = UINT64_MAX;
    for (int it = 0; it < 50; it++) {
        auto t0 = clk::now();
        bool ok = true;
        std::vector<regex_t*> tmp;
        for (size_t k = 0; k < REDUX_MEMBERS_N; k++) {
            regex_t* r = nullptr;
            const OnigUChar* p = (const OnigUChar*)REDUX_MEMBERS[k];
            int rc = onig_new(&r, p, p + strlen(REDUX_MEMBERS[k]), ONIG_OPTION_NONE,
                              ONIG_ENCODING_UTF8, ONIG_SYNTAX_RUBY, &einfo);
            if (rc != ONIG_NORMAL) { ok = false; break; }
            tmp.push_back(r);
        }
        uint64_t dt = ns_since(t0);
        for (regex_t* r : tmp) onig_free(r);
        if (!ok) {
            emit_row("oniguruma", "regex-redux", "redux", n, 0, -1, -1, 0.0, -1, "REJECTED");
            return;
        }
        if (dt < cmin) cmin = dt;
    }

    std::vector<regex_t*> compiled;
    std::vector<OnigRegion*> regions;
    for (size_t k = 0; k < REDUX_MEMBERS_N; k++) {
        regex_t* r = nullptr;
        const OnigUChar* p = (const OnigUChar*)REDUX_MEMBERS[k];
        onig_new(&r, p, p + strlen(REDUX_MEMBERS[k]), ONIG_OPTION_NONE,
                 ONIG_ENCODING_UTF8, ONIG_SYNTAX_RUBY, &einfo);
        compiled.push_back(r);
        regions.push_back(onig_region_new());
    }

    auto redux_run = [&]() -> size_t {
        size_t t = 0;
        for (size_t k = 0; k < REDUX_MEMBERS_N; k++) {
            Eng e{compiled[k], regions[k]};
            t += scan_count(e, data, n);
        }
        return t;
    };

    g_match_error = 0;
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
    emit_row("oniguruma", "regex-redux", "redux", n, iters, (int64_t)cmin,
             (int64_t)median, throughput, (int64_t)total, "ok");

    for (OnigRegion* rg : regions) onig_region_free(rg, 1);
    for (regex_t* r : compiled) onig_free(r);
}

int main() {
    const char* env = std::getenv("CORPUS");
    std::string path = env ? env : "corpus.txt";
    std::ifstream f(path, std::ios::binary);
    if (!f) { fprintf(stderr, "cannot read corpus %s\n", path.c_str()); return 1; }
    std::ostringstream ss; ss << f.rdbuf();
    std::string corpus = ss.str();

    // Dense synthetic log corpus for the `input: logs` workloads; falls back to
    // the mixed corpus if $LOGCORPUS is absent (manual single-engine runs).
    const char* lenv = std::getenv("LOGCORPUS");
    std::string logs;
    { std::ifstream lf(lenv ? lenv : "logs.txt", std::ios::binary);
      if (lf) { std::ostringstream ls; ls << lf.rdbuf(); logs = ls.str(); } else { logs = corpus; } }

    std::string synth(SYNTHETIC_LEN, 'a');

    OnigEncoding use_encs[] = { ONIG_ENCODING_UTF8 };
    onig_initialize(use_encs, sizeof(use_encs) / sizeof(use_encs[0]));
    onig_set_retry_limit_in_match(MATCH_LIMIT);
    onig_set_retry_limit_in_search(MATCH_LIMIT);

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

    onig_end();
    return 0;
}
