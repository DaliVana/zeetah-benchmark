//! Cross-engine benchmark harness — Rust `regex` crate side.
//!
//! Emits CSV rows (no header) with the schema shared by all three harnesses:
//!   engine,workload,input_bytes,iterations,compile_ns,search_ns_per_op,throughput_mb_s,match_count,note
//!
//! Corpus path: CORPUS env var, else corpus.txt
//! (run_all.sh runs every harness from the repo root).

use regex::Regex;
use std::time::Instant;

struct Workload {
    id: &'static str,
    pattern: &'static str,
    pathological: bool,
}

const WORKLOADS: &[Workload] = &[
    Workload { id: "literal",      pattern: "Sherlock",                                              pathological: false },
    Workload { id: "quantifier",   pattern: "a+",                                                    pathological: false },
    Workload { id: "digits",       pattern: "[0-9]+",                                                pathological: false },
    Workload { id: "word",         pattern: r"\w+",                                                  pathological: false },
    Workload { id: "alternation",  pattern: "cat|dog|bird|fish",                                     pathological: false },
    Workload { id: "email",        pattern: r"[\w\.+-]+@[\w\.-]+\.[\w\.-]+",                          pathological: false },
    Workload { id: "uri",          pattern: r"[\w]+://[^/\s?#]+[^\s?#]+(?:\?[^\s#]*)?(?:#[^\s]*)?",   pathological: false },
    Workload { id: "ipv4",         pattern: r"(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)", pathological: false },
    // Real-world workloads. Shell `/.../` delimiters & stray markdown backticks
    // stripped; named groups -> non-capturing (harness compares match counts);
    // the k8s pattern's leading `^` is dropped so it matches log-shaped
    // substrings anywhere in the token corpus.
    Workload { id: "html_title",   pattern: r#"<h2 class="product-title">(.*?)</h2>"#, pathological: false },
    Workload { id: "href",         pattern: r#"href="([^"]+)""#, pathological: false },
    Workload { id: "price",        pattern: r#"\$[\d,]+\.?\d*"#, pathological: false },
    Workload { id: "nltk",         pattern: r#"(?:[A-Z]\.)+|\w+(?:-\w+)*|\$?\d+(?:\.\d+)?%?|\.\.\.|[.,;"'?():_\-]"#, pathological: false },
    Workload { id: "ssn",          pattern: r#"[0-9]{3,3}-[0-9]{2,2}-[0-9]{4,4}"#, pathological: false },
    Workload { id: "modsec_sqli",  pattern: r#"([~!@#$%^&*()\-+={}\[\]|:;"'´’‘<>\\].*?){4,}"#, pathological: false },
    Workload { id: "aws_eni",      pattern: r#"(?:eni-.*?) "#, pathological: false },
    Workload { id: "apache_post",  pattern: r#"POST (?:/[a-zA-Z0-9_]+){1,}"#, pathological: false },
    Workload { id: "k8s_fluentd",  pattern: r#"(?:\d{4}-\d{1,2}-\d{1,2} \d{1,2}:\d{1,2}:\d{1,2}.\d{3})\s+(?:[^\s]+)\s+(?:\d+).*?\[\s+(?:.*)\]\s+(?:.*)\s+:\s+(?:.*)"#, pathological: false },
    // Typical + portable-edge additions.
    Workload { id: "date_iso",     pattern: r"[0-9]{4}-[0-9]{2}-[0-9]{2}",                            pathological: false },
    Workload { id: "time_hms",     pattern: r"[0-9]{2}:[0-9]{2}:[0-9]{2}",                            pathological: false },
    Workload { id: "phone_us",     pattern: r"\(?[0-9]{3}\)?[ .-][0-9]{3}[ .-][0-9]{4}",              pathological: false },
    Workload { id: "hex_color",    pattern: r"#[0-9a-fA-F]{6}",                                       pathological: false },
    Workload { id: "uuid",         pattern: r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", pathological: false },
    Workload { id: "mac_addr",     pattern: r"(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}",                  pathological: false },
    Workload { id: "semver",       pattern: r"v?[0-9]+\.[0-9]+\.[0-9]+",                              pathological: false },
    Workload { id: "credit_card",  pattern: r"[0-9]{4}[ -][0-9]{4}[ -][0-9]{4}[ -][0-9]{4}",          pathological: false },
    Workload { id: "log_level",    pattern: r"(?:TRACE|DEBUG|INFO|WARN|ERROR|FATAL)",                 pathological: false },
    Workload { id: "html_tag",     pattern: r"<[^>]+>",                                               pathological: false },
    Workload { id: "hashtag",      pattern: r"#[A-Za-z0-9_]+",                                        pathological: false },
    Workload { id: "float_sci",    pattern: r"[-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?",              pathological: false },
    Workload { id: "json_string",  pattern: r#""(?:[^"\\]|\\.)*""#,                                   pathological: false },
    Workload { id: "base64",       pattern: r"(?:[A-Za-z0-9+/]{4})+={0,2}",                           pathological: false },
    Workload { id: "path_unix",    pattern: r"(?:/[A-Za-z0-9_.-]+)+",                                 pathological: false },
    Workload { id: "deep_alternation", pattern: r"\b(?:break|case|catch|class|const|continue|default|delete|do|else|enum|export|extends|false|finally|for|function|if|import|in|instanceof|new|null|return|super|switch|this|throw|true|try|typeof|var|void|while|with|yield|async|await|let)\b", pathological: false },
    Workload { id: "wildcard_gaps", pattern: r"foo.*bar.*baz",                                        pathological: false },
    // Real-world multiline: every full log line that begins with an ISO date
    // (`(?m)` makes `^`/`$` per-line anchors). Zeetah spells this with the
    // `.multiline` struct flag; without multiline `^…$` matches at most once.
    Workload { id: "multiline_log", pattern: r"(?m)^[0-9]{4}-[0-9]{2}-[0-9]{2}.*$",                   pathological: false },
    // Feature-heavy: the base `regex` crate has no backreferences, look-around
    // or atomic groups — these `Regex::new` -> Err -> REJECTED (gate-skipped).
    Workload { id: "backref_word", pattern: r"(\b[A-Za-z]+\b) \1",                                    pathological: false },
    Workload { id: "lookbehind_amount", pattern: r"(?<=\$)[0-9]+(?:\.[0-9]{2})?",                     pathological: false },
    Workload { id: "unicode_prop", pattern: r"[\p{L}\p{N}_]+",                                        pathological: false },
    Workload { id: "atomic_token", pattern: r"(?>[A-Za-z0-9_]+)@",                                    pathological: false },
    // GPT-4 pre-tokenizer. The Rust `regex` crate has no lookaround or
    // possessive quantifiers, so `Regex::new` errors -> REJECTED row.
    Workload { id: "tokenizer",    pattern: r"(?i:[sdmt]|ll|ve|re)|[^\r\n\p{L}\p{N}]?+\p{L}+|\p{N}{1,3}| ?[^\s\p{L}\p{N}]++[\r\n]|\s[\r\n]|\s+(?!\S)|\s+", pathological: false },
    Workload { id: "pathological", pattern: "(a+)+b",                                                pathological: true  },
];

// Capped at 32 KiB so Zeetah's O(n²) findAll finishes in tolerable time;
// RE2/Rust scale linearly and are nowhere near their limits here.
const CORPUS_SIZES: &[usize] = &[1024, 8192, 32768, 1048576];

fn bench_one(wl: &Workload, input: &[u8]) {
    let text = std::str::from_utf8(input).expect("corpus must be valid UTF-8");

    // --- compile timing ---
    let compile_iters = 50u32;
    let mut compile_min = u128::MAX;
    for _ in 0..compile_iters {
        let t0 = Instant::now();
        let r = Regex::new(wl.pattern);
        let dt = t0.elapsed().as_nanos();
        match r {
            Ok(_) => {}
            Err(_) => {
                println!("rust-regex,{},{},0,-1,-1,0.00,-1,REJECTED", wl.id, input.len());
                return;
            }
        }
        if dt < compile_min {
            compile_min = dt;
        }
    }
    let re = Regex::new(wl.pattern).unwrap();

    // --- search timing: count leftmost, non-overlapping matches ---
    let _ = re.find_iter(text).count(); // warmup
    let probe0 = Instant::now();
    let match_count = re.find_iter(text).count();
    let probe = probe0.elapsed().as_nanos().max(1);

    let iters = (50_000_000u128 / probe).clamp(5, 500) as usize;
    let mut samples = Vec::with_capacity(iters);
    for _ in 0..iters {
        let t0 = Instant::now();
        let c = re.find_iter(text).count();
        samples.push((t0.elapsed().as_nanos(), c));
    }
    samples.sort_by_key(|&(ns, _)| ns);
    let median = samples[iters / 2].0;

    let mb = input.len() as f64 / 1_000_000.0;
    let secs = median as f64 / 1_000_000_000.0;
    let throughput = if secs > 0.0 { mb / secs } else { 0.0 };

    println!(
        "rust-regex,{},{},{},{},{},{:.2},{},ok",
        wl.id, input.len(), iters, compile_min, median, throughput, match_count
    );
}

fn main() {
    let path = std::env::var("CORPUS")
        .unwrap_or_else(|_| "corpus.txt".to_string());
    let corpus = std::fs::read(&path)
        .unwrap_or_else(|e| panic!("cannot read corpus {path}: {e}"));

    let path_input = vec![b'a'; 50_000];

    for wl in WORKLOADS {
        if wl.pathological {
            bench_one(wl, &path_input);
        } else {
            for &sz in CORPUS_SIZES {
                let n = sz.min(corpus.len());
                bench_one(wl, &corpus[..n]);
            }
        }
    }
}
