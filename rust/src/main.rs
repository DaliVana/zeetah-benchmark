//! Cross-engine benchmark harness — Rust `regex` crate side.
//!
//! Emits CSV rows (no header) with the schema shared by all harnesses (note
//! the `model` column — run_all.sh adds the header):
//!
//!   engine,model,workload,input_bytes,iterations,compile_ns,search_ns_per_op,throughput_mb_s,match_count,note
//!
//! The workload table is NOT declared here: it is generated from the single
//! source of truth (`benchmarks.json`) into `gen/workloads_rust.rs` by
//! `gen_workloads.py`, so patterns can never drift across the harnesses.
//! This file owns only the timing methodology and the per-model measurement
//! logic.
//!
//! Models: `count` (leftmost non-overlapping match count — always run),
//! `count-spans` (sum of match lengths over the SAME match walk as count),
//! `grep` (lines with >=1 match), `count-captures` (participating capture
//! groups, group 0 excluded) and `regex-redux` (compile-many-search-once over
//! a fixed member set). Which extra models run per workload is baked into the
//! generated table.
//!
//! Corpus path: CORPUS env var, else corpus.txt
//! (run_all.sh runs every harness from the repo root).

use regex::Regex;
use std::time::Instant;

// Brings in `Kind`, `Workload`, `WORKLOADS`, `REDUX_MEMBERS`, `CORPUS_SIZES`,
// `SYNTHETIC_LEN`, `REDUX_SIZE`. CARGO_MANIFEST_DIR is the rust/ dir, so this
// resolves to repo-root/gen/workloads_rust.rs.
include!(concat!(env!("CARGO_MANIFEST_DIR"), "/../gen/workloads_rust.rs"));

const ENGINE: &str = "rust-regex";

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

// --- per-model match functions (uniform signature) --------------------------

/// count: leftmost, non-overlapping match count.
fn m_count(re: &Regex, text: &str) -> usize {
    re.find_iter(text).count()
}

/// count-spans: sum of match lengths over the same match walk as count.
fn m_spans(re: &Regex, text: &str) -> usize {
    re.find_iter(text).map(|m| m.end() - m.start()).sum::<usize>()
}

/// grep: number of lines (segments split on '\n') containing >=1 match.
fn m_grep(re: &Regex, text: &str) -> usize {
    text.split('\n').filter(|seg| re.is_match(seg)).count()
}

/// count-captures: participating capture groups summed over all matches,
/// group 0 (the whole match) excluded.
fn m_captures(re: &Regex, text: &str) -> usize {
    let mut n = 0usize;
    for caps in re.captures_iter(text) {
        for i in 1..caps.len() {
            if caps.get(i).is_some() {
                n += 1;
            }
        }
    }
    n
}

/// Run one model: warm up, probe, size the timed loop to >=50 ms (5..500
/// iterations), report the median.
fn measure(
    f: &dyn Fn(&Regex, &str) -> usize,
    model: &str,
    wl_id: &str,
    re: &Regex,
    text: &str,
    compile_ns: i128,
) {
    let mc = f(re, text); // warmup
    let probe0 = Instant::now();
    let _ = f(re, text);
    let probe = probe0.elapsed().as_nanos().max(1);

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

/// Emit a REJECTED row for every model this workload would have run (keeps the
/// per-model report sections consistent).
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
            // base `regex` rejects lookaround/backref/atomic/possessive.
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
/// corpus prefix, reporting total compile time (min over 50), median search
/// time and the summed count. Its own report section; throughput is the
/// aggregate bytes/s (members * bytes).
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

    let run = |cs: &[Regex]| -> usize { cs.iter().map(|r| r.find_iter(text).count()).sum() };

    let total = run(&compiled); // warmup
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

    let synth = vec![b'a'; SYNTHETIC_LEN];

    for wl in WORKLOADS {
        match wl.kind {
            Kind::Corpus => {
                for &sz in CORPUS_SIZES {
                    let n = sz.min(corpus.len());
                    bench_one(wl, &corpus[..n]);
                }
            }
            Kind::Pathological => bench_one(wl, &synth),
        }
    }

    bench_redux(&corpus);
}
