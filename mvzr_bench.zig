//! Cross-engine benchmark harness — mvzr side.
//!
//! mvzr (https://github.com/mnemnion/mvzr) is a small, zero-allocation Zig
//! regex bytecode VM. Emits CSV rows (no header) to stdout with the schema
//! shared by all harnesses:
//!
//!   engine,workload,input_bytes,iterations,compile_ns,search_ns_per_op,throughput_mb_s,match_count,note
//!
//! IO and timing go through libc (std.c) on purpose, matching zig_bench.zig:
//! Zig 0.16's std.Io was reworked and std.time lost nanoTimestamp/Timer.
//!
//! mvzr's default Regex caps at 64 ops / 8 char sets; we widen the VM via
//! SizedRegex so the richer corpus patterns (email, ipv4) actually compile
//! instead of being capacity-rejected. A null compile is still reported as
//! REJECTED (consistent with how the other harnesses flag unsupported rows).
//!
//! mvzr is a backtracking VM, so `(a+)+b` is catastrophic. Mirroring the
//! Python harness, the pathological workload is split out via the
//! BENCH_MVZR_MODE env var so run_all.sh can run it in a hard-timed child:
//!   - unset / "corpus": run only the corpus workloads (skip pathological)
//!   - "patho": just attempt the catastrophic match; the parent times/limits
//!     us and prints the resulting ok/TIMEOUT row
//!
//! Usage: CORPUS=<path> mvzr_bench   (defaults to the repo-root corpus)

const std = @import("std");
const mvzr = @import("mvzr");

const alloc = std.heap.c_allocator;

/// Widened VM: enough headroom for every corpus pattern below.
const Regex = mvzr.SizedRegex(256, 64);

/// Monotonic raw clock in nanoseconds (CLOCK_UPTIME_RAW on Darwin).
fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.UPTIME_RAW, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn out(bytes: []const u8) void {
    _ = std.c.write(1, bytes.ptr, bytes.len);
}

const Workload = struct {
    id: []const u8,
    pattern: []const u8,
};

const workloads = [_]Workload{
    .{ .id = "literal", .pattern = "Sherlock" },
    .{ .id = "quantifier", .pattern = "a+" },
    .{ .id = "digits", .pattern = "[0-9]+" },
    .{ .id = "word", .pattern = "\\w+" },
    .{ .id = "alternation", .pattern = "cat|dog|bird|fish" },
    .{ .id = "email", .pattern = "[\\w\\.+-]+@[\\w\\.-]+\\.[\\w\\.-]+" },
    .{ .id = "uri", .pattern = "[\\w]+://[^/\\s?#]+[^\\s?#]+(?:\\?[^\\s#]*)?(?:#[^\\s]*)?" },
    .{ .id = "ipv4", .pattern = "(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)" },
    // Real-world workloads (named groups -> non-capturing, k8s `^` dropped).
    // mvzr's subset will REJECT several of these; REJECTED rows are skipped
    // by the correctness gate, exactly like the tokenizer workload.
    .{ .id = "html_title", .pattern = "<h2 class=\"product-title\">(.*?)</h2>" },
    .{ .id = "href", .pattern = "href=\"([^\"]+)\"" },
    .{ .id = "price", .pattern = "\\$[\\d,]+\\.?\\d*" },
    .{ .id = "nltk", .pattern = "(?:[A-Z]\\.)+|\\w+(?:-\\w+)*|\\$?\\d+(?:\\.\\d+)?%?|\\.\\.\\.|[.,;\"'?():_\\-]" },
    .{ .id = "ssn", .pattern = "[0-9]{3,3}-[0-9]{2,2}-[0-9]{4,4}" },
    .{ .id = "modsec_sqli", .pattern = "([~!@#$%^&*()\\-+={}\\[\\]|:;\"'´’‘<>\\\\].*?){4,}" },
    .{ .id = "aws_eni", .pattern = "(?:eni-.*?) " },
    .{ .id = "apache_post", .pattern = "POST (?:/[a-zA-Z0-9_]+){1,}" },
    .{ .id = "k8s_fluentd", .pattern = "(?:\\d{4}-\\d{1,2}-\\d{1,2} \\d{1,2}:\\d{1,2}:\\d{1,2}.\\d{3})\\s+(?:[^\\s]+)\\s+(?:\\d+).*?\\[\\s+(?:.*)\\]\\s+(?:.*)\\s+:\\s+(?:.*)" },
    // Typical + portable-edge additions.
    .{ .id = "date_iso", .pattern = "[0-9]{4}-[0-9]{2}-[0-9]{2}" },
    .{ .id = "time_hms", .pattern = "[0-9]{2}:[0-9]{2}:[0-9]{2}" },
    .{ .id = "phone_us", .pattern = "\\(?[0-9]{3}\\)?[ .-][0-9]{3}[ .-][0-9]{4}" },
    .{ .id = "hex_color", .pattern = "#[0-9a-fA-F]{6}" },
    .{ .id = "uuid", .pattern = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}" },
    .{ .id = "mac_addr", .pattern = "(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}" },
    .{ .id = "semver", .pattern = "v?[0-9]+\\.[0-9]+\\.[0-9]+" },
    .{ .id = "credit_card", .pattern = "[0-9]{4}[ -][0-9]{4}[ -][0-9]{4}[ -][0-9]{4}" },
    .{ .id = "log_level", .pattern = "(?:TRACE|DEBUG|INFO|WARN|ERROR|FATAL)" },
    .{ .id = "html_tag", .pattern = "<[^>]+>" },
    .{ .id = "hashtag", .pattern = "#[A-Za-z0-9_]+" },
    .{ .id = "float_sci", .pattern = "[-+]?[0-9]*\\.?[0-9]+(?:[eE][-+]?[0-9]+)?" },
    .{ .id = "json_string", .pattern = "\"(?:[^\"\\\\]|\\\\.)*\"" },
    .{ .id = "base64", .pattern = "(?:[A-Za-z0-9+/]{4})+={0,2}" },
    .{ .id = "path_unix", .pattern = "(?:/[A-Za-z0-9_.-]+)+" },
    .{ .id = "deep_alternation", .pattern = "\\b(?:break|case|catch|class|const|continue|default|delete|do|else|enum|export|extends|false|finally|for|function|if|import|in|instanceof|new|null|return|super|switch|this|throw|true|try|typeof|var|void|while|with|yield|async|await|let)\\b" },
    .{ .id = "wildcard_gaps", .pattern = "foo.*bar.*baz" },
    // Real-world multiline (zeetah uses the `.multiline` struct flag). mvzr has
    // no inline-flag grammar, so it mis-parses `(?m)` -> REJECTED (gate-skipped).
    .{ .id = "multiline_log", .pattern = "(?m)^[0-9]{4}-[0-9]{2}-[0-9]{2}.*$" },
    // Feature-heavy (mvzr has no `\p{}`/look-around/backref/atomic — REJECTED).
    .{ .id = "backref_word", .pattern = "(\\b[A-Za-z]+\\b) \\1" },
    .{ .id = "lookbehind_amount", .pattern = "(?<=\\$)[0-9]+(?:\\.[0-9]{2})?" },
    .{ .id = "unicode_prop", .pattern = "[\\p{L}\\p{N}_]+" },
    .{ .id = "atomic_token", .pattern = "(?>[A-Za-z0-9_]+)@" },
    // GPT-4 pre-tokenizer: far beyond mvzr's feature set (no `\p{}`,
    // lookaround, possessive or inline flags) — reported as REJECTED.
    .{ .id = "tokenizer", .pattern = "(?i:[sdmt]|ll|ve|re)|[^\\r\\n\\p{L}\\p{N}]?+\\p{L}+|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]++[\\r\\n]|\\s[\\r\\n]|\\s+(?!\\S)|\\s+" },
};

// The catastrophic workload, run only in the timed child (BENCH_MVZR_MODE=patho).
const patho_pattern = "(a+)+b";
const patho_input_len: usize = 50_000;

// Same prefix sizes as the other harnesses for byte-identical comparison.
const corpus_sizes = [_]usize{ 1024, 8192, 32768, 1048576 };

fn readFileAll(path: [*:0]const u8) ![]u8 {
    const f = std.c.fopen(path, "rb") orelse return error.OpenFailed;
    defer _ = std.c.fclose(f);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = std.c.fread(&chunk, 1, chunk.len, f);
        if (n == 0) break;
        try list.appendSlice(alloc, chunk[0..n]);
    }
    return list.toOwnedSlice(alloc);
}

/// Count all leftmost, non-overlapping matches over `input` via mvzr's
/// native iterator. mvzr allocates nothing here.
fn scanCount(re: *const Regex, input: []const u8) usize {
    var it = re.iterator(input);
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

fn lessThanU64(_: void, a: u64, b: u64) bool {
    return a < b;
}

fn emitRow(
    workload: []const u8,
    input_bytes: usize,
    iterations: usize,
    compile_ns: i64,
    search_ns: i64,
    throughput: f64,
    match_count: i64,
    note: []const u8,
) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "mvzr,{s},{d},{d},{d},{d},{d:.2},{d},{s}\n", .{
        workload, input_bytes, iterations, compile_ns, search_ns, throughput, match_count, note,
    }) catch return;
    out(line);
}

fn benchOne(wl: Workload, input: []const u8) void {
    // mvzr has no Unicode property classes, look-around, possessive
    // quantifiers or inline flags, and its lazy-quantifier / non-capturing
    // group handling is incomplete. For these patterns its parser does not
    // *reject* the input — it silently best-effort-parses it into a different
    // language and emits a bogus match count (e.g. 0 for `html_title`/
    // `price`/`k8s_fluentd`, a large over-match for `aws_eni`, and likewise
    // for the GPT-4 `tokenizer`). Report them honestly as REJECTED so the
    // cross-engine correctness gate compares only faithful results.
    const unsupported = [_][]const u8{
        "tokenizer", "html_title", "price", "aws_eni", "k8s_fluentd",
        // Feature-heavy: mvzr has no `\p{}`, look-around, backreferences or
        // atomic groups — it would silently best-effort-parse these into a
        // different language and emit a bogus count.
        "backref_word", "lookbehind_amount", "unicode_prop", "atomic_token",
        // Constructs mvzr's lazy / non-capturing / large-program handling
        // mis-parses rather than rejects (verified bogus counts: e.g.
        // `log_level` over-matches ~1000x, `wildcard_gaps` collapses to 1).
        "json_string", "base64", "deep_alternation",
        "log_level", "wildcard_gaps",
        // Inline flags (`(?m)`) are not in mvzr's grammar — it would silently
        // mis-parse the multiline log workload into a different language.
        "multiline_log",
    };
    for (unsupported) |bad| {
        if (std.mem.eql(u8, wl.id, bad)) {
            emitRow(wl.id, input.len, 0, -1, -1, 0.0, -1, "REJECTED");
            return;
        }
    }

    // --- compile timing (and rejection handling) ---
    const compile_iters: usize = 50;
    var compile_min: u64 = std.math.maxInt(u64);
    var i: usize = 0;
    while (i < compile_iters) : (i += 1) {
        const t0 = nowNs();
        const re = Regex.compile(wl.pattern);
        const dt = nowNs() - t0;
        if (re == null) {
            // mvzr returns null on parse failure / capacity overflow.
            emitRow(wl.id, input.len, 0, -1, -1, 0.0, -1, "REJECTED");
            return;
        }
        if (dt < compile_min) compile_min = dt;
    }

    const re = Regex.compile(wl.pattern) orelse {
        emitRow(wl.id, input.len, 0, -1, -1, 0.0, -1, "REJECTED");
        return;
    };

    // --- search timing ---
    // Warmup + establish a per-scan estimate to size the timed run to >=50ms.
    var match_count: usize = scanCount(&re, input); // warmup
    const probe0 = nowNs();
    match_count = scanCount(&re, input);
    const probe = @max(nowNs() - probe0, 1);

    // Size the timed loop to run >=50 ms, bounded to [5, 500] iterations.
    const iters: usize = @intCast(@min(@as(u64, 500), @max(@as(u64, 5), 50_000_000 / probe)));

    const samples = alloc.alloc(u64, iters) catch {
        emitRow(wl.id, input.len, 0, @intCast(compile_min), -1, 0.0, @intCast(match_count), "ALLOC_FAIL");
        return;
    };
    defer alloc.free(samples);

    i = 0;
    while (i < iters) : (i += 1) {
        const t0 = nowNs();
        _ = scanCount(&re, input);
        samples[i] = nowNs() - t0;
    }
    std.mem.sort(u64, samples, {}, lessThanU64);
    const median = samples[iters / 2];

    const mb = @as(f64, @floatFromInt(input.len)) / 1_000_000.0;
    const secs = @as(f64, @floatFromInt(median)) / 1_000_000_000.0;
    const throughput = if (secs > 0) mb / secs else 0.0;

    emitRow(
        wl.id,
        input.len,
        iters,
        @intCast(compile_min),
        @intCast(median),
        throughput,
        @intCast(match_count),
        "ok",
    );
}

fn streq(a: ?[*:0]const u8, b: []const u8) bool {
    const p = a orelse return false;
    return std.mem.eql(u8, std.mem.span(p), b);
}

fn envInt(name: [*:0]const u8) ?usize {
    const v = std.c.getenv(name) orelse return null;
    return std.fmt.parseInt(usize, std.mem.span(v), 10) catch null;
}

pub fn main() !void {
    const mode = std.c.getenv("BENCH_MVZR_MODE");

    // Child mode: just attempt the catastrophic match. The parent (run_all.sh)
    // times and hard-limits us, then prints the ok/TIMEOUT row itself — so we
    // deliberately print nothing here, exactly like the Python harness.
    if (streq(mode, "patho")) {
        const input = try alloc.alloc(u8, patho_input_len);
        defer alloc.free(input);
        @memset(input, 'a');
        const re = Regex.compile(patho_pattern) orelse return;
        _ = scanCount(&re, input);
        return;
    }

    // Enumeration mode: print the ordered workload ids, one per line, so the
    // orchestrator can drive one isolated child per workload without having
    // to keep a duplicate id list in sync.
    if (streq(mode, "list")) {
        for (workloads) |wl| {
            out(wl.id);
            out("\n");
        }
        return;
    }

    const corpus_path: [*:0]const u8 = std.c.getenv("CORPUS") orelse
        "corpus.txt";

    const corpus = try readFileAll(corpus_path);
    defer alloc.free(corpus);

    // Single-workload child mode (BENCH_MVZR_MODE=one, BENCH_MVZR_IDX=i).
    // mvzr is a third-party backtracking VM: a few patterns it accepts at
    // compile time still panic at *match* time (e.g. integer overflow on
    // deep backtracking). Running each workload in its own short-lived child
    // means such a crash costs one workload's rows — which the parent
    // back-fills as CRASHED — instead of aborting the whole orchestrator.
    if (streq(mode, "one")) {
        const idx = envInt("BENCH_MVZR_IDX") orelse return;
        if (idx >= workloads.len) return;
        const wl = workloads[idx];
        for (corpus_sizes) |sz| {
            const n = @min(sz, corpus.len);
            benchOne(wl, corpus[0..n]);
        }
        return;
    }

    // Default (manual) mode: run everything in-process.
    for (workloads) |wl| {
        for (corpus_sizes) |sz| {
            const n = @min(sz, corpus.len);
            benchOne(wl, corpus[0..n]);
        }
    }
}
