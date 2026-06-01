// Cross-engine benchmark harness — CTRE side (compile-time regular expressions).
//
// CTRE (Hana Dusíková) compiles the regex into native code at C++ compile time
// from a template-parameter pattern — the closest conceptual peer to zeetah's
// comptime-DFA path. Because the pattern is a template argument, an unsupported
// pattern is a *build* error, not a runtime rejection; the supported subset is
// resolved ahead of time via `skip_engines: ["ctre"]` in benchmarks.json and
// the generated table (gen/workloads_ctre.hpp) points each supported workload
// at `ctre_count<"pat">` / `ctre_spans<…>` / `ctre_grep<…>` instantiations
// defined below. Skipped workloads carry null function pointers → REJECTED row.
//
// CTRE runs only count / count-spans / grep (it is absent from the captures and
// regex-redux capability lists). There is no compile step to time at runtime —
// the matcher is baked into the binary — so compile_ns is reported as 0.
//
// count/spans use ctre::search_all (CTRE's own leftmost non-overlapping walk,
// which tracks the real previous position so `^`/`\b` anchor correctly); grep
// matches
// each '\n'-split line independently, mirroring the other harnesses.
//
// CTRE's matcher is a recursive backtracker with no heap-based stack, so a few
// supported patterns (e.g. modsec_sqli's `{4,}` over a large char class) blow
// the C stack outright — a crash the in-process SIGALRM cannot catch. Each
// (workload, size) measurement is therefore run in a forked child whose rows
// are buffered and written only on clean exit; a crash (signal) or a timeout
// (parent kills the child) leaves the parent to emit a CRASHED / TIMEOUT row,
// exactly like the mvzr subprocess driver. The catastrophic `pathological`
// workload is force-rejected outright.
//
// Emits: ctre,model,workload,input_bytes,iterations,compile_ns,search_ns_per_op,throughput_mb_s,match_count,note
// Corpus: CORPUS env var else corpus.txt.

#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

#include <ctre.hpp>

using clk = std::chrono::steady_clock;

static const unsigned TIMEOUT_S = 20;

// --- CTRE model templates (referenced by the generated workload table) ------

template <ctll::fixed_string P>
static size_t ctre_count(std::string_view text) {
    size_t count = 0;
    for (auto m : ctre::search_all<P, ctre::multiline>(text)) { (void)m; count++; }
    return count;
}

template <ctll::fixed_string P>
static size_t ctre_spans(std::string_view text) {
    size_t sum = 0;
    for (auto m : ctre::search_all<P, ctre::multiline>(text)) sum += m.size();
    return sum;
}

template <ctll::fixed_string P>
static size_t ctre_grep(std::string_view text) {
    size_t n = 0, start = 0, len = text.size();
    for (size_t i = 0; i < len; i++) {
        if (text[i] == '\n') {
            std::string_view line(text.data() + start, i - start);
            if (ctre::search<P, ctre::multiline>(line)) n++;
            start = i + 1;
        }
    }
    if (start < len) {
        std::string_view line(text.data() + start, len - start);
        if (ctre::search<P, ctre::multiline>(line)) n++;
    }
    return n;
}

#include "../gen/workloads_ctre.hpp"

static uint64_t ns_since(clk::time_point t0) {
    return (uint64_t)std::chrono::duration_cast<std::chrono::nanoseconds>(
               clk::now() - t0)
        .count();
}

// Rows are accumulated here so a forked child emits nothing until it has
// finished cleanly (a mid-scan crash must leave no partial output).
static std::string g_out;

static void emit_row(const char* model, const char* workload, size_t input_bytes,
                     size_t iterations, int64_t compile_ns, int64_t search_ns,
                     double throughput, int64_t match_count, const char* note) {
    char buf[256];
    int len = snprintf(buf, sizeof(buf), "ctre,%s,%s,%zu,%zu,%lld,%lld,%.2f,%lld,%s\n",
                       model, workload, input_bytes, iterations, (long long)compile_ns,
                       (long long)search_ns, throughput, (long long)match_count, note);
    g_out.append(buf, (size_t)len);
}

static void measure(CtreFn fn, const char* model, const char* wl_id,
                    const char* data, size_t len) {
    std::string_view text(data, len);
    size_t mc = fn(text);  // warmup
    auto p0 = clk::now();
    mc = fn(text);
    uint64_t probe = std::max<uint64_t>(ns_since(p0), 1);
    size_t iters = (size_t)std::min<uint64_t>(
        500, std::max<uint64_t>(5, 50000000ull / probe));
    std::vector<uint64_t> samples;
    samples.reserve(iters);
    for (size_t i = 0; i < iters; i++) {
        auto t0 = clk::now();
        (void)fn(text);
        samples.push_back(ns_since(t0));
    }
    std::sort(samples.begin(), samples.end());
    uint64_t median = samples[iters / 2];
    double mb = (double)len / 1000000.0;
    double secs = (double)median / 1000000000.0;
    double throughput = secs > 0.0 ? mb / secs : 0.0;
    // compile_ns = 0: the matcher is compiled into the binary, nothing to time.
    emit_row(model, wl_id, len, iters, 0, (int64_t)median, throughput,
             (int64_t)mc, "ok");
}

// Run every model for one (workload, size) into g_out (called inside the child).
static void run_models(const CtreWorkload& wl, const char* data, size_t len) {
    measure(wl.count_fn, "count", wl.id, data, len);
    if (wl.spans && wl.spans_fn) measure(wl.spans_fn, "count-spans", wl.id, data, len);
    if (wl.grep && wl.grep_fn) measure(wl.grep_fn, "grep", wl.id, data, len);
}

static void write_all(const std::string& s) {
    size_t off = 0;
    while (off < s.size()) {
        ssize_t w = write(STDOUT_FILENO, s.data() + off, s.size() - off);
        if (w <= 0) break;
        off += (size_t)w;
    }
}

// Emit a CRASHED/TIMEOUT row for every model this (workload, size) would run.
static void emit_failed(const CtreWorkload& wl, size_t len, const char* note) {
    g_out.clear();
    emit_row("count", wl.id, len, 0, -1, -1, 0.0, -1, note);
    if (wl.spans) emit_row("count-spans", wl.id, len, 0, -1, -1, 0.0, -1, note);
    if (wl.grep) emit_row("grep", wl.id, len, 0, -1, -1, 0.0, -1, note);
    write_all(g_out);
}

static pid_t g_child = -1;
static volatile sig_atomic_t g_timed_out = 0;
static void parent_alarm(int) {
    g_timed_out = 1;
    if (g_child > 0) kill(g_child, SIGKILL);
}

// Fork an isolated child to measure one (workload, size); crash -> CRASHED,
// timeout -> TIMEOUT.
static void run_isolated(const CtreWorkload& wl, const char* data, size_t len) {
    fflush(stdout);
    pid_t pid = fork();
    if (pid == 0) {  // child
        g_out.clear();
        run_models(wl, data, len);
        write_all(g_out);
        _exit(0);
    }
    if (pid < 0) {  // fork failed: run in-process (best effort)
        run_models(wl, data, len);
        write_all(g_out);
        g_out.clear();
        return;
    }
    g_child = pid;
    g_timed_out = 0;
    signal(SIGALRM, parent_alarm);
    alarm(TIMEOUT_S);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) { /* EINTR: retry */ }
    alarm(0);
    g_child = -1;
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) return;  // child wrote rows
    emit_failed(wl, len, g_timed_out ? "TIMEOUT" : "CRASHED");
}

int main() {
    const char* env = std::getenv("CORPUS");
    std::string path = env ? env : "corpus.txt";
    std::ifstream f(path, std::ios::binary);
    if (!f) { fprintf(stderr, "cannot read corpus %s\n", path.c_str()); return 1; }
    std::ostringstream ss; ss << f.rdbuf();
    std::string corpus = ss.str();
    std::string synth(SYNTHETIC_LEN, 'a');

    for (size_t w = 0; w < CTRE_WORKLOADS_N; w++) {
        const CtreWorkload& wl = CTRE_WORKLOADS[w];
        if (wl.force_reject) {  // includes the pathological workload
            g_out.clear();
            if (wl.pathological) {
                emit_row("count", wl.id, synth.size(), 0, -1, -1, 0.0, -1, "REJECTED");
            } else {
                for (size_t s = 0; s < CORPUS_SIZES_N; s++) {
                    size_t n = std::min(CORPUS_SIZES[s], corpus.size());
                    emit_row("count", wl.id, n, 0, -1, -1, 0.0, -1, "REJECTED");
                    if (wl.spans) emit_row("count-spans", wl.id, n, 0, -1, -1, 0.0, -1, "REJECTED");
                    if (wl.grep) emit_row("grep", wl.id, n, 0, -1, -1, 0.0, -1, "REJECTED");
                }
            }
            write_all(g_out);
            g_out.clear();
            continue;
        }
        for (size_t s = 0; s < CORPUS_SIZES_N; s++) {
            size_t n = std::min(CORPUS_SIZES[s], corpus.size());
            run_isolated(wl, corpus.data(), n);
        }
    }
    return 0;
}
