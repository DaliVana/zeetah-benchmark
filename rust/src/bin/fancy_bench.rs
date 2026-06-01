//! Cross-engine benchmark harness — Rust `fancy-regex` crate side.
//!
//! `fancy-regex` is the backtracking-capable Rust engine used in production
//! by OpenAI's `tiktoken` and BPE trainers such as `rustbpe`: it layers
//! look-around, backreferences, atomic groups and possessive quantifiers on
//! top of the `regex` crate. It therefore runs the real GPT-4 `tokenizer`
//! pre-tokenizer pattern that the base `regex` crate / RE2 reject by design.
//!
//! Same CSV schema, workloads, corpus, sizing and timing methodology as the
//! sibling `rust_bench` (the base `regex` crate harness), including the
//! `model` column. Engine column is `fancy-regex`.
//!
//! `fancy-regex` searches yield `Result` values (a backtrack-limit error is
//! possible): a search-time `Err` on any model row is reported as
//! BACKTRACK_LIMIT rather than silently counted.
//!
//! Corpus path: CORPUS env var, else corpus.txt
//! (run_all.sh runs every harness from the repo root).

use fancy_regex::Regex;
use std::time::Instant;

// Brings in `Kind`, `Workload`, `WORKLOADS`, `REDUX_MEMBERS`, `CORPUS_SIZES`,
// `SYNTHETIC_LEN`, `REDUX_SIZE`. CARGO_MANIFEST_DIR is the rust/ dir, so this
// resolves to repo-root/gen/workloads_rust.rs.
include!(concat!(env!("CARGO_MANIFEST_DIR"), "/../gen/workloads_rust.rs"));

const ENGINE: &str = "fancy-regex";

fn emit_row(
    model: &str,
    workload: &str,
    input_bytes: usize,
    iterations: usize,
    compile_ns: i128,
    search_ns: i128,
    throughput: f64,
    match_count: i128,
    note: &str,
) {
    println!(
        "{},{},{},{},{},{},{},{:.2},{},{}",
        ENGINE, model, workload, input_bytes, iterations, compile_ns, search_ns, throughput,
        match_count, note
    );
}

// --- per-model match functions (uniform signature). Each returns
// `Option<usize>`; `None` signals a search-time engine failure (e.g. a
// backtrack-limit exceeded), which the caller turns into a BACKTRACK_LIMIT row.

/// count: leftmost, non-overlapping match count.
fn m_count(re: &Regex, text: &str) -> Option<usize> {
    let mut n = 0usize;
    for m in re.find_iter(text) {
        match m {
            Ok(_) => n += 1,
            Err(_) => return None,
        }
    }
    Some(n)
}

/// count-spans: sum of match lengths over the same match walk as count.
fn m_spans(re: &Regex, text: &str) -> Option<usize> {
    let mut total = 0usize;
    for m in re.find_iter(text) {
        match m {
            Ok(m) => total += m.end() - m.start(),
            Err(_) => return None,
        }
    }
    Some(total)
}

/// grep: number of lines (segments split on '\n') containing >=1 match.
/// A per-segment search error counts as a non-match (unwrap_or(false)).
fn m_grep(re: &Regex, text: &str) -> Option<usize> {
    Some(
        text.split('\n')
            .filter(|seg| re.is_match(seg).unwrap_or(false))
            .count(),
    )
}

/// count-captures: participating capture groups summed over all matches,
/// group 0 (the whole match) excluded.
fn m_captures(re: &Regex, text: &str) -> Option<usize> {
    let mut n = 0usize;
    for caps in re.captures_iter(text) {
        match caps {
            Ok(caps) => {
                for i in 1..caps.len() {
                    if caps.get(i).is_some() {
                        n += 1;
                    }
                }
            }
            Err(_) => return None,
        }
    }
    Some(n)
}

/// Run one model: warm up, probe, size the timed loop to >=50 ms (5..500
/// iterations), report the median. A search-time `Err` (None) on the probe
/// emits a BACKTRACK_LIMIT row instead.
fn measure(
    f: &dyn Fn(&Regex, &str) -> Option<usize>,
    model: &str,
    wl_id: &str,
    re: &Regex,
    text: &str,
    compile_ns: i128,
) {
    let _ = f(re, text); // warmup
    let probe0 = Instant::now();
    let probe_count = f(re, text);
    let probe = probe0.elapsed().as_nanos().max(1);

    let mc = match probe_count {
        Some(c) => c,
        None => {
            emit_row(model, wl_id, text.len(), 0, compile_ns, -1, 0.0, -1, "BACKTRACK_LIMIT");
            return;
        }
    };

    let iters = (50_000_000u128 / probe).clamp(5, 500) as usize;
    let mut samples = Vec::with_capacity(iters);
    for _ in 0..iters {
        let t0 = Instant::now();
        let _ = f(re, text);
        samples.push(t0.elapsed().as_nanos());
    }
    samples.sort_unstable();
    let median = samples[iters / 2];

    let mb = text.len() as f64 / 1_000_000.0;
    let secs = median as f64 / 1_000_000_000.0;
    let throughput = if secs > 0.0 { mb / secs } else { 0.0 };
    emit_row(
        model,
        wl_id,
        text.len(),
        iters,
        compile_ns,
        median as i128,
        throughput,
        mc as i128,
        "ok",
    );
}

/// Emit a REJECTED row for every model this workload would have run.
fn emit_rejected(wl: &Workload, len: usize) {
    emit_row("count", wl.id, len, 0, -1, -1, 0.0, -1, "REJECTED");
    if wl.spans {
        emit_row("count-spans", wl.id, len, 0, -1, -1, 0.0, -1, "REJECTED");
    }
    if wl.grep {
        emit_row("grep", wl.id, len, 0, -1, -1, 0.0, -1, "REJECTED");
    }
    if wl.captures {
        emit_row("count-captures", wl.id, len, 0, -1, -1, 0.0, -1, "REJECTED");
    }
}

fn bench_one(wl: &Workload, input: &[u8]) {
    let len = input.len();

    if wl.force_reject {
        emit_rejected(wl, len);
        return;
    }

    let text = std::str::from_utf8(input).expect("corpus must be valid UTF-8");

    // --- compile timing (and rejection handling) ---
    let compile_iters = 50u32;
    let mut compile_min = i128::MAX;
    for _ in 0..compile_iters {
        let t0 = Instant::now();
        let r = Regex::new(wl.pattern);
        let dt = t0.elapsed().as_nanos() as i128;
        if r.is_err() {
            emit_rejected(wl, len);
            return;
        }
        if dt < compile_min {
            compile_min = dt;
        }
    }
    let re = Regex::new(wl.pattern).unwrap();

    measure(&m_count, "count", wl.id, &re, text, compile_min);
    if wl.spans {
        measure(&m_spans, "count-spans", wl.id, &re, text, compile_min);
    }
    if wl.grep {
        measure(&m_grep, "grep", wl.id, &re, text, compile_min);
    }
    if wl.captures {
        measure(&m_captures, "count-captures", wl.id, &re, text, compile_min);
    }
}

/// regex-redux: compile every member pattern and `count` each once over the
/// corpus prefix. A search-time `Err` on any member emits BACKTRACK_LIMIT.
fn bench_redux(corpus: &[u8]) {
    if REDUX_MEMBERS.is_empty() {
        return;
    }
    let n = REDUX_SIZE.min(corpus.len());
    let text = std::str::from_utf8(&corpus[..n]).expect("corpus must be valid UTF-8");

    // --- compile timing: min over 50 of compiling ALL members ---
    let mut compile_min = i128::MAX;
    for _ in 0..50 {
        let t0 = Instant::now();
        let mut ok = true;
        let mut compiled: Vec<Regex> = Vec::with_capacity(REDUX_MEMBERS.len());
        for m in REDUX_MEMBERS {
            match Regex::new(m) {
                Ok(r) => compiled.push(r),
                Err(_) => {
                    ok = false;
                    break;
                }
            }
        }
        let dt = t0.elapsed().as_nanos() as i128;
        if !ok {
            emit_row("regex-redux", "redux", n, 0, -1, -1, 0.0, -1, "REJECTED");
            return;
        }
        if dt < compile_min {
            compile_min = dt;
        }
    }

    // --- build once for the search loop ---
    let compiled: Vec<Regex> = REDUX_MEMBERS
        .iter()
        .map(|m| Regex::new(m).unwrap())
        .collect();

    // sum of counts; None on any backtrack-limit failure.
    let run = |cs: &[Regex]| -> Option<usize> {
        let mut t = 0usize;
        for r in cs {
            match m_count(r, text) {
                Some(c) => t += c,
                None => return None,
            }
        }
        Some(t)
    };

    let total = match run(&compiled) {
        Some(t) => t,
        None => {
            emit_row("regex-redux", "redux", n, 0, compile_min, -1, 0.0, -1, "BACKTRACK_LIMIT");
            return;
        }
    };
    let probe0 = Instant::now();
    let _ = run(&compiled);
    let probe = probe0.elapsed().as_nanos().max(1);

    let iters = (50_000_000u128 / probe).clamp(5, 500) as usize;
    let mut samples = Vec::with_capacity(iters);
    for _ in 0..iters {
        let t0 = Instant::now();
        let _ = run(&compiled);
        samples.push(t0.elapsed().as_nanos());
    }
    samples.sort_unstable();
    let median = samples[iters / 2];

    let mb = (REDUX_MEMBERS.len() * n) as f64 / 1_000_000.0;
    let secs = median as f64 / 1_000_000_000.0;
    let throughput = if secs > 0.0 { mb / secs } else { 0.0 };
    emit_row(
        "regex-redux",
        "redux",
        n,
        iters,
        compile_min,
        median as i128,
        throughput,
        total as i128,
        "ok",
    );
}

fn main() {
    let path = std::env::var("CORPUS").unwrap_or_else(|_| "corpus.txt".to_string());
    let corpus = std::fs::read(&path).unwrap_or_else(|e| panic!("cannot read corpus {path}: {e}"));

    // Dense synthetic log corpus for the `input: logs` workloads; falls back to
    // the mixed corpus if $LOGCORPUS is absent (manual single-engine runs).
    let logs_path = std::env::var("LOGCORPUS").unwrap_or_else(|_| "logs.txt".to_string());
    let logs = std::fs::read(&logs_path).unwrap_or_else(|_| corpus.clone());

    let synth = vec![b'a'; SYNTHETIC_LEN];

    for wl in WORKLOADS {
        match wl.kind {
            Kind::Corpus => {
                let src: &[u8] = if wl.logs { &logs } else { &corpus };
                for &sz in CORPUS_SIZES {
                    let n = sz.min(src.len());
                    bench_one(wl, &src[..n]);
                }
            }
            Kind::Pathological => bench_one(wl, &synth),
        }
    }

    bench_redux(&corpus);
}
