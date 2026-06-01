// Cross-engine benchmark harness — POSIX regex.h side (the libc baseline).
//
// `regcomp`/`regexec` is the regex everyone gets for free in C. On macOS this
// is the BSD implementation. It is a DIFFERENT regex language from the PCRE
// family — POSIX ERE has leftmost-LONGEST semantics and treats `\d`/`\w`/`\p`
// as implementation extensions (or literals) — so this engine is marked
// `gate_exempt` in benchmarks.json: measured and shown, but excluded from the
// cross-engine match-count agreement gate. Patterns POSIX cannot express
// (`(?:…)`, lookaround, `\p{…}`, lazy quantifiers, …) fail `regcomp` and emit a
// REJECTED row.
//
// Compiled as C++ (regex.h is C, but this lets the shared gen_cpp workload
// table be reused). Walks with REG_STARTEND so there is no copy and embedded
// NULs are handled; a SIGALRM watchdog turns any catastrophic blowup into a
// TIMEOUT row instead of a hang (POSIX has no match-limit API).
//
// Emits: engine,model,workload,input_bytes,iterations,compile_ns,search_ns_per_op,throughput_mb_s,match_count,note
// Workload table: gen/workloads_posix.hpp. Corpus: CORPUS env var else corpus.txt.

#include <regex.h>
#include <setjmp.h>
#include <signal.h>
#include <unistd.h>

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

#include "../gen/workloads_posix.hpp"

using clk = std::chrono::steady_clock;

static const unsigned TIMEOUT_S = 20;  // per-model watchdog

static uint64_t ns_since(clk::time_point t0) {
    return (uint64_t)std::chrono::duration_cast<std::chrono::nanoseconds>(
               clk::now() - t0)
        .count();
}

static void emit_row(const char* model, const char* workload, size_t input_bytes,
                     size_t iterations, int64_t compile_ns, int64_t search_ns,
                     double throughput, int64_t match_count, const char* note) {
    printf("posix,%s,%s,%zu,%zu,%lld,%lld,%.2f,%lld,%s\n", model, workload,
           input_bytes, iterations, (long long)compile_ns, (long long)search_ns,
           throughput, (long long)match_count, note);
}

// --- SIGALRM watchdog: siglongjmp out of a stuck regexec ---
static sigjmp_buf g_jmp;
static void on_alarm(int) { siglongjmp(g_jmp, 1); }

// count: leftmost match walk via REG_STARTEND. REG_NOTBOL once past offset 0 so
// `^` does not spuriously re-anchor at each search start.
static size_t scan_count(const regex_t* re, const char* data, size_t len) {
    size_t count = 0, pos = 0;
    regmatch_t m[1];
    while (pos <= len) {
        m[0].rm_so = pos;
        m[0].rm_eo = len;
        int rc = regexec(re, data, 1, m, REG_STARTEND | (pos ? REG_NOTBOL : 0));
        if (rc != 0) break;
        size_t mstart = m[0].rm_so, mend = m[0].rm_eo;
        count++;
        pos = (mend > mstart) ? mend : mend + 1;
    }
    return count;
}

static size_t scan_spans(const regex_t* re, const char* data, size_t len) {
    size_t sum = 0, pos = 0;
    regmatch_t m[1];
    while (pos <= len) {
        m[0].rm_so = pos;
        m[0].rm_eo = len;
        int rc = regexec(re, data, 1, m, REG_STARTEND | (pos ? REG_NOTBOL : 0));
        if (rc != 0) break;
        size_t mstart = m[0].rm_so, mend = m[0].rm_eo;
        sum += (mend - mstart);
        pos = (mend > mstart) ? mend : mend + 1;
    }
    return sum;
}

// Mirrors RE2's scan_grep exactly: every segment split on '\n' is checked
// (including empty interior lines); the trailing fragment counts only when
// non-empty.
static size_t scan_grep(const regex_t* re, const char* data, size_t len) {
    size_t n = 0, start = 0;
    regmatch_t m[1];
    for (size_t i = 0; i < len; i++) {
        if (data[i] == '\n') {
            m[0].rm_so = start;
            m[0].rm_eo = i;  // each line is an independent string: bol applies
            if (regexec(re, data, 1, m, REG_STARTEND) == 0) n++;
            start = i + 1;
        }
    }
    if (start < len) {
        m[0].rm_so = start;
        m[0].rm_eo = len;
        if (regexec(re, data, 1, m, REG_STARTEND) == 0) n++;
    }
    return n;
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
}

static void bench_one(const Workload& wl, const char* data, size_t len) {
    if (wl.force_reject) { emit_rejected(wl, len); return; }

    // compile timing: min over 50; rejection if regcomp fails.
    uint64_t cmin = UINT64_MAX;
    regex_t re;
    bool ok = false;
    for (int i = 0; i < 50; i++) {
        auto t0 = clk::now();
        int rc = regcomp(&re, wl.pattern, REG_EXTENDED);
        uint64_t dt = ns_since(t0);
        if (rc != 0) { emit_rejected(wl, len); return; }
        if (dt < cmin) cmin = dt;
        if (i + 1 < 50) regfree(&re);  // keep the last one compiled
        else ok = true;
    }
    if (!ok) { emit_rejected(wl, len); return; }
    int64_t cns = (int64_t)cmin;

    measure([&] { return scan_count(&re, data, len); }, "count", wl.id, len, cns);
    if (!wl.pathological) {
        if (wl.spans) measure([&] { return scan_spans(&re, data, len); }, "count-spans", wl.id, len, cns);
        if (wl.grep) measure([&] { return scan_grep(&re, data, len); }, "grep", wl.id, len, cns);
    }
    regfree(&re);
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
    return 0;
}
