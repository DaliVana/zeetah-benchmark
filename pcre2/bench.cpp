// Cross-engine benchmark harness — PCRE2 side (emits TWO engines).
//
// One binary produces both `pcre2` (interpreted) and `pcre2-jit` rows: every
// workload is compiled once, measured interpreted, then `pcre2_jit_compile`d in
// place and measured again. PCRE2 is the de-facto C backtracking engine (PHP,
// nginx, git, Apache, ripgrep's -P) and supports the full Perl syntax, so —
// unlike RE2 — it rejects none of the lookaround/backref/atomic/possessive
// workloads.
//
// Emits the shared CSV schema (no header):
//   engine,model,workload,input_bytes,iterations,compile_ns,search_ns_per_op,throughput_mb_s,match_count,note
//
// Catastrophic backtracking (the `pathological` workload) is bounded by a PCRE2
// match limit: when hit, pcre2_match returns PCRE2_ERROR_MATCHLIMIT and we emit
// a MATCH_LIMIT row instead of hanging — the linear-engine analogue of
// dotnet's TIMEOUT / fancy-regex's BACKTRACK_LIMIT.
//
// Workload table: gen/workloads_pcre2.hpp (generated from benchmarks.json).
// Corpus path: CORPUS env var, else corpus.txt.

#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "../gen/workloads_pcre2.hpp"

using clk = std::chrono::steady_clock;

// Bound the interpreter so the pathological workload fails fast instead of
// hanging. JIT honours the same limit.
static const uint32_t MATCH_LIMIT = 50000000;

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

// Set to the negative PCRE2 error (e.g. PCRE2_ERROR_MATCHLIMIT) when a scan
// aborts; 0 means the last scan completed normally.
static int g_match_error = 0;

struct Eng {
    pcre2_code* code;
    pcre2_match_data* md;
    pcre2_match_context* mctx;
};

// count: leftmost, non-overlapping; canonical empty-match advance
// (pos = mend>mstart ? mend : mend+1).
static size_t scan_count(const Eng& e, const char* data, size_t len) {
    size_t count = 0, pos = 0;
    PCRE2_SIZE* ov = pcre2_get_ovector_pointer(e.md);
    while (pos <= len) {
        int rc = pcre2_match(e.code, (PCRE2_SPTR)data, len, pos, 0, e.md, e.mctx);
        if (rc == PCRE2_ERROR_NOMATCH) break;
        if (rc < 0) { g_match_error = rc; break; }
        size_t mstart = ov[0], mend = ov[1];
        count++;
        pos = (mend > mstart) ? mend : mend + 1;
    }
    return count;
}

static size_t scan_spans(const Eng& e, const char* data, size_t len) {
    size_t sum = 0, pos = 0;
    PCRE2_SIZE* ov = pcre2_get_ovector_pointer(e.md);
    while (pos <= len) {
        int rc = pcre2_match(e.code, (PCRE2_SPTR)data, len, pos, 0, e.md, e.mctx);
        if (rc == PCRE2_ERROR_NOMATCH) break;
        if (rc < 0) { g_match_error = rc; break; }
        size_t mstart = ov[0], mend = ov[1];
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
            int rc = pcre2_match(e.code, (PCRE2_SPTR)(data + start), i - start, 0,
                                 0, e.md, e.mctx);
            if (rc >= 0) n++;
            else if (rc != PCRE2_ERROR_NOMATCH) { g_match_error = rc; return n; }
            start = i + 1;
        }
    }
    if (start < len) {
        int rc = pcre2_match(e.code, (PCRE2_SPTR)(data + start), len - start, 0, 0,
                             e.md, e.mctx);
        if (rc >= 0) n++;
        else if (rc != PCRE2_ERROR_NOMATCH) g_match_error = rc;
    }
    return n;
}

// count-captures: participating groups (ovector slot != PCRE2_UNSET) summed
// over all matches, group 0 excluded.
static size_t scan_captures(const Eng& e, const char* data, size_t len, uint32_t ngroups) {
    size_t total = 0, pos = 0;
    PCRE2_SIZE* ov = pcre2_get_ovector_pointer(e.md);
    while (pos <= len) {
        int rc = pcre2_match(e.code, (PCRE2_SPTR)data, len, pos, 0, e.md, e.mctx);
        if (rc == PCRE2_ERROR_NOMATCH) break;
        if (rc < 0) { g_match_error = rc; break; }
        size_t mstart = ov[0], mend = ov[1];
        for (uint32_t i = 1; i <= ngroups; i++) {
            if (ov[2 * i] != PCRE2_UNSET) total++;
        }
        pos = (mend > mstart) ? mend : mend + 1;
    }
    return total;
}

// Generic timed measurement: warmup, probe, size the loop to ~50 ms in
// [5,500] iters, report the median. A match-limit abort during warmup emits a
// MATCH_LIMIT row instead of a timing.
template <typename Fn>
static void measure(Fn fn, const char* engine, const char* model,
                    const char* wl_id, size_t input_bytes, int64_t compile_ns) {
    g_match_error = 0;
    size_t mc = fn();  // warmup
    if (g_match_error != 0) {
        const char* note = (g_match_error == PCRE2_ERROR_MATCHLIMIT ||
                            g_match_error == PCRE2_ERROR_DEPTHLIMIT ||
                            g_match_error == PCRE2_ERROR_JIT_STACKLIMIT)
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

// Run every model for one already-built engine view (interpreted or JIT).
static void run_models(const char* engine, const Workload& wl, const Eng& e,
                       const char* data, size_t len, int64_t compile_ns,
                       uint32_t ngroups) {
    measure([&] { return scan_count(e, data, len); }, engine, "count", wl.id, len, compile_ns);
    if (wl.pathological) return;
    if (wl.spans) measure([&] { return scan_spans(e, data, len); }, engine, "count-spans", wl.id, len, compile_ns);
    if (wl.grep) measure([&] { return scan_grep(e, data, len); }, engine, "grep", wl.id, len, compile_ns);
    if (wl.captures) measure([&] { return scan_captures(e, data, len, ngroups); }, engine, "count-captures", wl.id, len, compile_ns);
}

static pcre2_code* compile_one(const char* pattern, int64_t* compile_ns_out) {
    int errcode;
    PCRE2_SIZE erroffset;
    // compile timing: min over 50 constructions
    uint64_t cmin = UINT64_MAX;
    for (int i = 0; i < 50; i++) {
        auto t0 = clk::now();
        pcre2_code* c = pcre2_compile((PCRE2_SPTR)pattern, PCRE2_ZERO_TERMINATED,
                                      0, &errcode, &erroffset, nullptr);
        uint64_t dt = ns_since(t0);
        if (!c) return nullptr;
        pcre2_code_free(c);
        if (dt < cmin) cmin = dt;
    }
    pcre2_code* code = pcre2_compile((PCRE2_SPTR)pattern, PCRE2_ZERO_TERMINATED, 0,
                                     &errcode, &erroffset, nullptr);
    if (!code) return nullptr;
    *compile_ns_out = (int64_t)cmin;
    return code;
}

// Minimum time to JIT-compile a fresh copy of this pattern (10 reps).
static int64_t jit_compile_min(const char* pattern) {
    int errcode;
    PCRE2_SIZE erroffset;
    uint64_t jmin = UINT64_MAX;
    for (int i = 0; i < 10; i++) {
        pcre2_code* c = pcre2_compile((PCRE2_SPTR)pattern, PCRE2_ZERO_TERMINATED, 0,
                                      &errcode, &erroffset, nullptr);
        if (!c) return -1;
        auto t0 = clk::now();
        int rc = pcre2_jit_compile(c, PCRE2_JIT_COMPLETE);
        uint64_t dt = ns_since(t0);
        pcre2_code_free(c);
        if (rc != 0) return -1;
        if (dt < jmin) jmin = dt;
    }
    return (int64_t)jmin;
}

static void bench_one(const Workload& wl, const char* data, size_t len,
                      pcre2_match_context* mctx, pcre2_jit_stack* jstack) {
    if (wl.force_reject) {
        emit_rejected("pcre2", wl, len);
        emit_rejected("pcre2-jit", wl, len);
        return;
    }
    int64_t cns_interp = 0;
    pcre2_code* code = compile_one(wl.pattern, &cns_interp);
    if (!code) {  // PCRE2 rejected the pattern (should be rare)
        emit_rejected("pcre2", wl, len);
        emit_rejected("pcre2-jit", wl, len);
        return;
    }
    uint32_t ngroups = 0;
    pcre2_pattern_info(code, PCRE2_INFO_CAPTURECOUNT, &ngroups);

    pcre2_match_data* md = pcre2_match_data_create_from_pattern(code, nullptr);
    Eng e{code, md, mctx};

    // --- pass 1: interpreted ---
    run_models("pcre2", wl, e, data, len, cns_interp, ngroups);

    // --- pass 2: JIT (compile in place; pcre2_match then auto-dispatches) ---
    int jrc = pcre2_jit_compile(code, PCRE2_JIT_COMPLETE);
    if (jrc == 0) {
        pcre2_jit_stack_assign(mctx, nullptr, jstack);
        int64_t jmin = jit_compile_min(wl.pattern);
        int64_t cns_jit = (jmin < 0) ? cns_interp : cns_interp + jmin;
        run_models("pcre2-jit", wl, e, data, len, cns_jit, ngroups);
        pcre2_jit_stack_assign(mctx, nullptr, nullptr);
    } else {
        emit_rejected("pcre2-jit", wl, len);
    }

    pcre2_match_data_free(md);
    pcre2_code_free(code);
}

// regex-redux: compile all members, one rep = sum over members of
// scan_count(member, prefix). Reported for both interpreted and JIT.
static void bench_redux(const std::string& corpus, pcre2_match_context* mctx,
                        pcre2_jit_stack* jstack) {
    if (REDUX_MEMBERS_N == 0) return;
    size_t n = std::min(REDUX_SIZE, corpus.size());
    const char* data = corpus.data();

    // compile timing: min over 50 of compiling ALL members
    int errcode; PCRE2_SIZE erroffset;
    uint64_t cmin = UINT64_MAX;
    for (int it = 0; it < 50; it++) {
        auto t0 = clk::now();
        bool ok = true;
        std::vector<pcre2_code*> tmp;
        for (size_t k = 0; k < REDUX_MEMBERS_N; k++) {
            pcre2_code* c = pcre2_compile((PCRE2_SPTR)REDUX_MEMBERS[k],
                                          PCRE2_ZERO_TERMINATED, 0, &errcode,
                                          &erroffset, nullptr);
            if (!c) { ok = false; break; }
            tmp.push_back(c);
        }
        uint64_t dt = ns_since(t0);
        for (pcre2_code* c : tmp) pcre2_code_free(c);
        if (!ok) {
            emit_row("pcre2", "regex-redux", "redux", n, 0, -1, -1, 0.0, -1, "REJECTED");
            emit_row("pcre2-jit", "regex-redux", "redux", n, 0, -1, -1, 0.0, -1, "REJECTED");
            return;
        }
        if (dt < cmin) cmin = dt;
    }

    std::vector<pcre2_code*> compiled;
    std::vector<pcre2_match_data*> mds;
    for (size_t k = 0; k < REDUX_MEMBERS_N; k++) {
        pcre2_code* c = pcre2_compile((PCRE2_SPTR)REDUX_MEMBERS[k],
                                      PCRE2_ZERO_TERMINATED, 0, &errcode,
                                      &erroffset, nullptr);
        compiled.push_back(c);
        mds.push_back(pcre2_match_data_create_from_pattern(c, nullptr));
    }

    auto redux_run = [&]() -> size_t {
        size_t t = 0;
        for (size_t k = 0; k < REDUX_MEMBERS_N; k++) {
            Eng e{compiled[k], mds[k], mctx};
            t += scan_count(e, data, n);
        }
        return t;
    };
    auto run_pass = [&](const char* engine, int64_t compile_ns) {
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
        emit_row(engine, "regex-redux", "redux", n, iters, compile_ns,
                 (int64_t)median, throughput, (int64_t)total, "ok");
    };

    run_pass("pcre2", (int64_t)cmin);

    // JIT all members, then re-time.
    bool jit_ok = true;
    for (pcre2_code* c : compiled)
        if (pcre2_jit_compile(c, PCRE2_JIT_COMPLETE) != 0) jit_ok = false;
    if (jit_ok) {
        pcre2_jit_stack_assign(mctx, nullptr, jstack);
        run_pass("pcre2-jit", (int64_t)cmin);
        pcre2_jit_stack_assign(mctx, nullptr, nullptr);
    } else {
        emit_row("pcre2-jit", "regex-redux", "redux", n, 0, -1, -1, 0.0, -1, "REJECTED");
    }

    for (pcre2_match_data* m : mds) pcre2_match_data_free(m);
    for (pcre2_code* c : compiled) pcre2_code_free(c);
}

int main() {
    const char* env = std::getenv("CORPUS");
    std::string path = env ? env : "corpus.txt";
    std::ifstream f(path, std::ios::binary);
    if (!f) { fprintf(stderr, "cannot read corpus %s\n", path.c_str()); return 1; }
    std::ostringstream ss; ss << f.rdbuf();
    std::string corpus = ss.str();
    std::string synth(SYNTHETIC_LEN, 'a');

    pcre2_match_context* mctx = pcre2_match_context_create(nullptr);
    pcre2_set_match_limit(mctx, MATCH_LIMIT);
    pcre2_set_depth_limit(mctx, MATCH_LIMIT);
    pcre2_jit_stack* jstack = pcre2_jit_stack_create(32 * 1024, 1024 * 1024, nullptr);

    for (size_t w = 0; w < WORKLOADS_N; w++) {
        const Workload& wl = WORKLOADS[w];
        if (wl.pathological) {
            bench_one(wl, synth.data(), synth.size(), mctx, jstack);
        } else {
            for (size_t s = 0; s < CORPUS_SIZES_N; s++) {
                size_t n = std::min(CORPUS_SIZES[s], corpus.size());
                bench_one(wl, corpus.data(), n, mctx, jstack);
            }
        }
    }
    bench_redux(corpus, mctx, jstack);

    pcre2_jit_stack_free(jstack);
    pcre2_match_context_free(mctx);
    return 0;
}
