// Cross-engine benchmark harness — RE2 side.
//
// Emits CSV rows (no header) with the schema shared by all three harnesses:
//   engine,workload,input_bytes,iterations,compile_ns,search_ns_per_op,throughput_mb_s,match_count,note
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

using clk = std::chrono::steady_clock;

static uint64_t ns_since(clk::time_point t0) {
    return (uint64_t)std::chrono::duration_cast<std::chrono::nanoseconds>(
               clk::now() - t0)
        .count();
}

struct Workload {
    const char* id;
    const char* pattern;
    bool pathological;
};

static const Workload WORKLOADS[] = {
    {"literal", "Sherlock", false},
    {"quantifier", "a+", false},
    {"digits", "[0-9]+", false},
    {"word", "\\w+", false},
    {"alternation", "cat|dog|bird|fish", false},
    {"email", "[\\w\\.+-]+@[\\w\\.-]+\\.[\\w\\.-]+", false},
    {"uri", "[\\w]+://[^/\\s?#]+[^\\s?#]+(?:\\?[^\\s#]*)?(?:#[^\\s]*)?", false},
    {"ipv4", "(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)", false},
    // Real-world workloads. Shell /.../ delimiters & stray markdown backticks
    // stripped; named groups -> non-capturing (harness compares match counts);
    // k8s leading ^ dropped so it matches log-shaped substrings anywhere.
    {"html_title", "<h2 class=\"product-title\">(.*?)</h2>", false},
    {"href", "href=\"([^\"]+)\"", false},
    {"price", "\\$[\\d,]+\\.?\\d*", false},
    {"nltk", "(?:[A-Z]\\.)+|\\w+(?:-\\w+)*|\\$?\\d+(?:\\.\\d+)?%?|\\.\\.\\.|[.,;\"'?():_\\-]", false},
    {"ssn", "[0-9]{3,3}-[0-9]{2,2}-[0-9]{4,4}", false},
    {"modsec_sqli", "([~!@#$%^&*()\\-+={}\\[\\]|:;\"'´’‘<>\\\\].*?){4,}", false},
    {"aws_eni", "(?:eni-.*?) ", false},
    {"apache_post", "POST (?:/[a-zA-Z0-9_]+){1,}", false},
    {"k8s_fluentd", "(?:\\d{4}-\\d{1,2}-\\d{1,2} \\d{1,2}:\\d{1,2}:\\d{1,2}.\\d{3})\\s+(?:[^\\s]+)\\s+(?:\\d+).*?\\[\\s+(?:.*)\\]\\s+(?:.*)\\s+:\\s+(?:.*)", false},
    // Typical + portable-edge additions.
    {"date_iso", "[0-9]{4}-[0-9]{2}-[0-9]{2}", false},
    {"time_hms", "[0-9]{2}:[0-9]{2}:[0-9]{2}", false},
    {"phone_us", "\\(?[0-9]{3}\\)?[ .-][0-9]{3}[ .-][0-9]{4}", false},
    {"hex_color", "#[0-9a-fA-F]{6}", false},
    {"uuid", "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", false},
    {"mac_addr", "(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}", false},
    {"semver", "v?[0-9]+\\.[0-9]+\\.[0-9]+", false},
    {"credit_card", "[0-9]{4}[ -][0-9]{4}[ -][0-9]{4}[ -][0-9]{4}", false},
    {"log_level", "(?:TRACE|DEBUG|INFO|WARN|ERROR|FATAL)", false},
    {"html_tag", "<[^>]+>", false},
    {"hashtag", "#[A-Za-z0-9_]+", false},
    {"float_sci", "[-+]?[0-9]*\\.?[0-9]+(?:[eE][-+]?[0-9]+)?", false},
    {"json_string", "\"(?:[^\"\\\\]|\\\\.)*\"", false},
    {"base64", "(?:[A-Za-z0-9+/]{4})+={0,2}", false},
    {"path_unix", "(?:/[A-Za-z0-9_.-]+)+", false},
    {"deep_alternation", "\\b(?:break|case|catch|class|const|continue|default|delete|do|else|enum|export|extends|false|finally|for|function|if|import|in|instanceof|new|null|return|super|switch|this|throw|true|try|typeof|var|void|while|with|yield|async|await|let)\\b", false},
    {"wildcard_gaps", "foo.*bar.*baz", false},
    // Real-world multiline: every full log line that begins with an ISO date
    // (`(?m)` makes `^`/`$` per-line anchors). Zeetah uses the `.multiline`
    // struct-flag peer of this inline form.
    {"multiline_log", "(?m)^[0-9]{4}-[0-9]{2}-[0-9]{2}.*$", false},
    // Feature-heavy: RE2 has no backreferences, look-around or atomic groups
    // (linear-automaton by design) — these fail re.ok() and emit REJECTED.
    {"backref_word", "(\\b[A-Za-z]+\\b) \\1", false},
    {"lookbehind_amount", "(?<=\\$)[0-9]+(?:\\.[0-9]{2})?", false},
    {"unicode_prop", "[\\p{L}\\p{N}_]+", false},
    {"atomic_token", "(?>[A-Za-z0-9_]+)@", false},
    // GPT-4 pre-tokenizer. RE2 has no lookaround or possessive quantifiers,
    // so RE2::ok() is false here -> REJECTED row.
    {"tokenizer", "(?i:[sdmt]|ll|ve|re)|[^\\r\\n\\p{L}\\p{N}]?+\\p{L}+|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]++[\\r\\n]|\\s[\\r\\n]|\\s+(?!\\S)|\\s+", false},
    {"pathological", "(a+)+b", true},
};

// Capped at 32 KiB so Zeetah's O(n^2) findAll finishes in tolerable time;
// RE2/Rust scale linearly and are nowhere near their limits here.
static const size_t CORPUS_SIZES[] = {1024, 8192, 32768, 1048576};

// Count leftmost, non-overlapping matches over [0, len).
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

static void bench_one(const Workload& wl, const char* data, size_t len) {
    re2::StringPiece text(data, len);

    // --- compile timing ---
    const int compile_iters = 50;
    uint64_t compile_min = UINT64_MAX;
    for (int i = 0; i < compile_iters; i++) {
        auto t0 = clk::now();
        RE2 re(wl.pattern);
        uint64_t dt = ns_since(t0);
        if (!re.ok()) {
            printf("re2,%s,%zu,0,-1,-1,0.00,-1,REJECTED\n", wl.id, len);
            return;
        }
        if (dt < compile_min) compile_min = dt;
    }
    RE2 re(wl.pattern);

    // --- search timing ---
    (void)scan_count(re, text);  // warmup
    auto p0 = clk::now();
    size_t match_count = scan_count(re, text);
    uint64_t probe = std::max<uint64_t>(ns_since(p0), 1);

    size_t iters = (size_t)std::min<uint64_t>(
        500, std::max<uint64_t>(5, 50000000ull / probe));
    std::vector<uint64_t> samples;
    samples.reserve(iters);
    for (size_t i = 0; i < iters; i++) {
        auto t0 = clk::now();
        (void)scan_count(re, text);
        samples.push_back(ns_since(t0));
    }
    std::sort(samples.begin(), samples.end());
    uint64_t median = samples[iters / 2];

    double mb = (double)len / 1000000.0;
    double secs = (double)median / 1000000000.0;
    double throughput = secs > 0.0 ? mb / secs : 0.0;

    printf("re2,%s,%zu,%zu,%llu,%llu,%.2f,%zu,ok\n", wl.id, len, iters,
           (unsigned long long)compile_min, (unsigned long long)median,
           throughput, match_count);
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

    std::string path_input(50000, 'a');

    for (const auto& wl : WORKLOADS) {
        if (wl.pathological) {
            bench_one(wl, path_input.data(), path_input.size());
        } else {
            for (size_t sz : CORPUS_SIZES) {
                size_t n = std::min(sz, corpus.size());
                bench_one(wl, corpus.data(), n);
            }
        }
    }
    return 0;
}
