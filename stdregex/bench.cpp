// Cross-engine benchmark harness — C++ std::regex side (libc++).
//
// std::regex is what a C++ developer reaches for by default — and it is the
// slow baseline this comparison quantifies. Grammar is ECMAScript; the
// `multiline` syntax option is set globally so `^`/`$` behave per the
// `multiline_log` workload (which carries a `(?m)`-free override for this
// engine in benchmarks.json). Patterns libc++ cannot parse (lookbehind,
// atomic groups, possessive quantifiers, `\p{…}`) throw std::regex_error at
// construction → REJECTED row.
//
// std::regex has no match-limit/timeout API, so a SIGALRM watchdog turns a
// catastrophic scan into a TIMEOUT row; the designated `pathological` workload
// is skipped outright (force_reject) to avoid burning the watchdog on a
// guaranteed blow-up.
//
// The continuous-scan walk uses match_prev_avail once past offset 0 so `^` and
// `\b` see the real preceding character (no spurious anchor at each restart),
// mirroring the leftmost non-overlapping walk of the other harnesses.
//
// Emits: engine,model,workload,input_bytes,iterations,compile_ns,search_ns_per_op,throughput_mb_s,match_count,note
// Workload table: gen/workloads_stdregex.hpp. Corpus: CORPUS env var else corpus.txt.

#include <setjmp.h>
#include <signal.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

#include "../gen/workloads_stdregex.hpp"

using clk = std::chrono::steady_clock;

static const unsigned TIMEOUT_S = 20;

static uint64_t ns_since(clk::time_point t0) {
    return (uint64_t)std::chrono::duration_cast<std::chrono::nanoseconds>(
               clk::now() - t0)
        .count();
}

static void emit_row(const char* model, const char* workload, size_t input_bytes,
                     size_t iterations, int64_t compile_ns, int64_t search_ns,
                     double throughput, int64_t match_count, const char* note) {
    printf("stdregex,%s,%s,%zu,%zu,%lld,%lld,%.2f,%lld,%s\n", model, workload,
           input_bytes, iterations, (long long)compile_ns, (long long)search_ns,
           throughput, (long long)match_count, note);
}

static sigjmp_buf g_jmp;
static void on_alarm(int) { siglongjmp(g_jmp, 1); }

static const auto SYNTAX = std::regex::ECMAScript | std::regex::multiline;

static inline std::regex_constants::match_flag_type walk_flags(size_t pos) {
    auto f = std::regex_constants::match_default;
    if (pos > 0) f |= std::regex_constants::match_prev_avail;
    return f;
}

static size_t scan_count(const std::regex& re, const char* data, size_t len) {
    size_t count = 0, pos = 0;
    std::cmatch m;
    while (pos <= len) {
        if (!std::regex_search(data + pos, data + len, m, re, walk_flags(pos))) break;
        size_t mstart = pos + (size_t)m.position(0);
        size_t mend = mstart + (size_t)m.length(0);
        count++;
        pos = (mend > mstart) ? mend : mend + 1;
    }
    return count;
}

static size_t scan_spans(const std::regex& re, const char* data, size_t len) {
    size_t sum = 0, pos = 0;
    std::cmatch m;
    while (pos <= len) {
        if (!std::regex_search(data + pos, data + len, m, re, walk_flags(pos))) break;
        size_t mstart = pos + (size_t)m.position(0);
        size_t mend = mstart + (size_t)m.length(0);
        sum += (mend - mstart);
        pos = (mend > mstart) ? mend : mend + 1;
    }
    return sum;
}

// Mirrors RE2's scan_grep: every '\n'-split segment is checked (empty interior
// lines included); the trailing fragment counts only when non-empty. Each line
// is an independent string, so bol applies at its start (no match_prev_avail).
static size_t scan_grep(const std::regex& re, const char* data, size_t len) {
    size_t n = 0, start = 0;
    std::cmatch m;
    for (size_t i = 0; i < len; i++) {
        if (data[i] == '\n') {
            if (std::regex_search(data + start, data + i, m, re,
                                  std::regex_constants::match_default))
                n++;
            start = i + 1;
        }
    }
    if (start < len &&
        std::regex_search(data + start, data + len, m, re,
                          std::regex_constants::match_default))
        n++;
    return n;
}

// count-captures: participating groups (m[g].matched) summed over matches,
// group 0 excluded.
static size_t scan_captures(const std::regex& re, const char* data, size_t len) {
    size_t total = 0, pos = 0;
    std::cmatch m;
    while (pos <= len) {
        if (!std::regex_search(data + pos, data + len, m, re, walk_flags(pos))) break;
        size_t mstart = pos + (size_t)m.position(0);
        size_t mend = mstart + (size_t)m.length(0);
        for (size_t g = 1; g < m.size(); g++)
            if (m[g].matched) total++;
        pos = (mend > mstart) ? mend : mend + 1;
    }
    return total;
}

template <typename Fn>
static void measure(Fn fn, const char* model, const char* wl_id,
                    size_t input_bytes, int64_t compile_ns) {
    if (sigsetjmp(g_jmp, 1)) {
        alarm(0);
        emit_row(model, wl_id, input_bytes, 0, compile_ns, -1, 0.0, -1, "TIMEOUT");
        return;
    }
    alarm(TIMEOUT_S);
    size_t mc = fn();  // warmup
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
    alarm(0);
    std::sort(samples.begin(), samples.end());
    uint64_t median = samples[iters / 2];
    double mb = (double)input_bytes / 1000000.0;
    double secs = (double)median / 1000000000.0;
    double throughput = secs > 0.0 ? mb / secs : 0.0;
    emit_row(model, wl_id, input_bytes, iters, compile_ns, (int64_t)median,
             throughput, (int64_t)mc, "ok");
}

static void emit_rejected(const Workload& wl, size_t len) {
    emit_row("count", wl.id, len, 0, -1, -1, 0.0, -1, "REJECTED");
    if (wl.spans) emit_row("count-spans", wl.id, len, 0, -1, -1, 0.0, -1, "REJECTED");
    if (wl.grep) emit_row("grep", wl.id, len, 0, -1, -1, 0.0, -1, "REJECTED");
    if (wl.captures) emit_row("count-captures", wl.id, len, 0, -1, -1, 0.0, -1, "REJECTED");
}

// Compile (min over 50; std::regex_error => REJECTED) into *out.
static bool compile_one(const char* pattern, std::regex& out, int64_t* cns) {
    uint64_t cmin = UINT64_MAX;
    for (int i = 0; i < 50; i++) {
        try {
            auto t0 = clk::now();
            std::regex r(pattern, SYNTAX);
            uint64_t dt = ns_since(t0);
            if (dt < cmin) cmin = dt;
            if (i + 1 == 50) out = std::move(r);
        } catch (const std::regex_error&) {
            return false;
        }
    }
    *cns = (int64_t)cmin;
    return true;
}

static void bench_one(const Workload& wl, const char* data, size_t len) {
    if (wl.force_reject) { emit_rejected(wl, len); return; }
    std::regex re;
    int64_t cns = 0;
    if (!compile_one(wl.pattern, re, &cns)) { emit_rejected(wl, len); return; }

    measure([&] { return scan_count(re, data, len); }, "count", wl.id, len, cns);
    if (wl.pathological) return;
    if (wl.spans) measure([&] { return scan_spans(re, data, len); }, "count-spans", wl.id, len, cns);
    if (wl.grep) measure([&] { return scan_grep(re, data, len); }, "grep", wl.id, len, cns);
    if (wl.captures) measure([&] { return scan_captures(re, data, len); }, "count-captures", wl.id, len, cns);
}

static void bench_redux(const std::string& corpus) {
    if (REDUX_MEMBERS_N == 0) return;
    size_t n = std::min(REDUX_SIZE, corpus.size());
    const char* data = corpus.data();

    uint64_t cmin = UINT64_MAX;
    std::vector<std::regex> compiled;
    for (int it = 0; it < 50; it++) {
        try {
            auto t0 = clk::now();
            std::vector<std::regex> tmp;
            for (size_t k = 0; k < REDUX_MEMBERS_N; k++)
                tmp.emplace_back(REDUX_MEMBERS[k], SYNTAX);
            uint64_t dt = ns_since(t0);
            if (dt < cmin) cmin = dt;
            if (it + 1 == 50) compiled = std::move(tmp);
        } catch (const std::regex_error&) {
            emit_row("regex-redux", "redux", n, 0, -1, -1, 0.0, -1, "REJECTED");
            return;
        }
    }

    auto redux_run = [&]() -> size_t {
        size_t t = 0;
        for (auto& re : compiled) t += scan_count(re, data, n);
        return t;
    };
    if (sigsetjmp(g_jmp, 1)) {
        alarm(0);
        emit_row("regex-redux", "redux", n, 0, (int64_t)cmin, -1, 0.0, -1, "TIMEOUT");
        return;
    }
    alarm(TIMEOUT_S);
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
    alarm(0);
    std::sort(samples.begin(), samples.end());
    uint64_t median = samples[iters / 2];
    double mb = (double)(REDUX_MEMBERS_N * n) / 1000000.0;
    double secs = (double)median / 1000000000.0;
    double throughput = secs > 0.0 ? mb / secs : 0.0;
    emit_row("regex-redux", "redux", n, iters, (int64_t)cmin, (int64_t)median,
             throughput, (int64_t)total, "ok");
}

int main() {
    signal(SIGALRM, on_alarm);

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
