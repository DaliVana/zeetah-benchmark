//! Cross-engine benchmark harness — zeetah side.
//!
//! Emits CSV rows (no header) to stdout with the schema shared by all three
//! harnesses:
//!
//!   engine,workload,input_bytes,iterations,compile_ns,search_ns_per_op,throughput_mb_s,match_count,note
//!
//! IO and timing go through libc (std.c) on purpose: Zig 0.16's std.Io was
//! reworked ("Writergate") and std.time lost nanoTimestamp/Timer, so libc is
//! the stable surface here. zeetah allocations use the libc allocator.
//!
//! Usage: zig_bench <corpus_path>

const std = @import("std");
const Regex = @import("zeetah").Regex;

const alloc = std.heap.c_allocator;

/// Monotonic raw clock in nanoseconds (CLOCK_UPTIME_RAW on Darwin).
fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.UPTIME_RAW, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn out(bytes: []const u8) void {
    _ = std.c.write(1, bytes.ptr, bytes.len);
}

const Kind = enum { corpus, pathological };

const Workload = struct {
    id: []const u8,
    pattern: []const u8,
    kind: Kind,
    /// Compile via the `.multiline` struct flag (the peer of inline `(?m)`):
    /// the other engines spell the same workload with a `(?m)` prefix in the
    /// pattern. `false` ⇒ plain `Regex.compile`.
    multiline: bool = false,
};

const workloads = [_]Workload{
    .{ .id = "literal", .pattern = "Sherlock", .kind = .corpus },
    .{ .id = "quantifier", .pattern = "a+", .kind = .corpus },
    .{ .id = "digits", .pattern = "[0-9]+", .kind = .corpus },
    .{ .id = "word", .pattern = "\\w+", .kind = .corpus },
    .{ .id = "alternation", .pattern = "cat|dog|bird|fish", .kind = .corpus },
    .{ .id = "email", .pattern = "[\\w\\.+-]+@[\\w\\.-]+\\.[\\w\\.-]+", .kind = .corpus },
    .{ .id = "uri", .pattern = "[\\w]+://[^/\\s?#]+[^\\s?#]+(?:\\?[^\\s#]*)?(?:#[^\\s]*)?", .kind = .corpus },
    .{ .id = "ipv4", .pattern = "(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)", .kind = .corpus },
    // Real-world workloads. Shell `/.../` delimiters and stray markdown
    // backticks stripped; named groups -> non-capturing `(?:...)` (the harness
    // compares match counts, not captures); the k8s pattern's leading `^` is
    // dropped so it matches log-shaped substrings anywhere in the token corpus.
    .{ .id = "html_title", .pattern = "<h2 class=\"product-title\">(.*?)</h2>", .kind = .corpus },
    .{ .id = "href", .pattern = "href=\"([^\"]+)\"", .kind = .corpus },
    .{ .id = "price", .pattern = "\\$[\\d,]+\\.?\\d*", .kind = .corpus },
    .{ .id = "nltk", .pattern = "(?:[A-Z]\\.)+|\\w+(?:-\\w+)*|\\$?\\d+(?:\\.\\d+)?%?|\\.\\.\\.|[.,;\"'?():_\\-]", .kind = .corpus },
    .{ .id = "ssn", .pattern = "[0-9]{3,3}-[0-9]{2,2}-[0-9]{4,4}", .kind = .corpus },
    .{ .id = "modsec_sqli", .pattern = "([~!@#$%^&*()\\-+={}\\[\\]|:;\"'´’‘<>\\\\].*?){4,}", .kind = .corpus },
    .{ .id = "aws_eni", .pattern = "(?:eni-.*?) ", .kind = .corpus },
    .{ .id = "apache_post", .pattern = "POST (?:/[a-zA-Z0-9_]+){1,}", .kind = .corpus },
    .{ .id = "k8s_fluentd", .pattern = "(?:\\d{4}-\\d{1,2}-\\d{1,2} \\d{1,2}:\\d{1,2}:\\d{1,2}.\\d{3})\\s+(?:[^\\s]+)\\s+(?:\\d+).*?\\[\\s+(?:.*)\\]\\s+(?:.*)\\s+:\\s+(?:.*)", .kind = .corpus },
    // --- Typical additions (portable; gate-checked across every engine) ---
    .{ .id = "date_iso", .pattern = "[0-9]{4}-[0-9]{2}-[0-9]{2}", .kind = .corpus },
    .{ .id = "time_hms", .pattern = "[0-9]{2}:[0-9]{2}:[0-9]{2}", .kind = .corpus },
    .{ .id = "phone_us", .pattern = "\\(?[0-9]{3}\\)?[ .-][0-9]{3}[ .-][0-9]{4}", .kind = .corpus },
    .{ .id = "hex_color", .pattern = "#[0-9a-fA-F]{6}", .kind = .corpus },
    .{ .id = "uuid", .pattern = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", .kind = .corpus },
    .{ .id = "mac_addr", .pattern = "(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}", .kind = .corpus },
    .{ .id = "semver", .pattern = "v?[0-9]+\\.[0-9]+\\.[0-9]+", .kind = .corpus },
    .{ .id = "credit_card", .pattern = "[0-9]{4}[ -][0-9]{4}[ -][0-9]{4}[ -][0-9]{4}", .kind = .corpus },
    .{ .id = "log_level", .pattern = "(?:TRACE|DEBUG|INFO|WARN|ERROR|FATAL)", .kind = .corpus },
    .{ .id = "html_tag", .pattern = "<[^>]+>", .kind = .corpus },
    .{ .id = "hashtag", .pattern = "#[A-Za-z0-9_]+", .kind = .corpus },
    // --- Edge additions, portable (still gate-checked across every engine) ---
    .{ .id = "float_sci", .pattern = "[-+]?[0-9]*\\.?[0-9]+(?:[eE][-+]?[0-9]+)?", .kind = .corpus },
    .{ .id = "json_string", .pattern = "\"(?:[^\"\\\\]|\\\\.)*\"", .kind = .corpus },
    .{ .id = "base64", .pattern = "(?:[A-Za-z0-9+/]{4})+={0,2}", .kind = .corpus },
    .{ .id = "path_unix", .pattern = "(?:/[A-Za-z0-9_.-]+)+", .kind = .corpus },
    .{ .id = "deep_alternation", .pattern = "\\b(?:break|case|catch|class|const|continue|default|delete|do|else|enum|export|extends|false|finally|for|function|if|import|in|instanceof|new|null|return|super|switch|this|throw|true|try|typeof|var|void|while|with|yield|async|await|let)\\b", .kind = .corpus },
    .{ .id = "wildcard_gaps", .pattern = "foo.*bar.*baz", .kind = .corpus },
    // Real-world multiline: pull out every full log line that begins with an
    // ISO date (`^`/`$` as per-line anchors). zeetah compiles it via the
    // `.multiline` struct flag; every other engine uses the inline `(?m)` peer
    // (`(?m)^[0-9]{4}-[0-9]{2}-[0-9]{2}.*$`). Multiline-defined: without it
    // `^…$` would match at most once over the whole corpus.
    .{ .id = "multiline_log", .pattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}.*$", .kind = .corpus, .multiline = true },
    // --- Edge additions, feature-heavy (subset engines run them; the rest
    // emit REJECTED — same gate mechanism as `tokenizer`). ---
    .{ .id = "backref_word", .pattern = "(\\b[A-Za-z]+\\b) \\1", .kind = .corpus },
    .{ .id = "lookbehind_amount", .pattern = "(?<=\\$)[0-9]+(?:\\.[0-9]{2})?", .kind = .corpus },
    .{ .id = "unicode_prop", .pattern = "[\\p{L}\\p{N}_]+", .kind = .corpus },
    .{ .id = "atomic_token", .pattern = "(?>[A-Za-z0-9_]+)@", .kind = .corpus },
    // Real-world GPT-4 (tiktoken `cl100k_base`) pre-tokenizer regex: inline
    // `(?i:...)`, possessive `?+`/`++`, Unicode property classes and `(?!\S)`
    // lookahead in one pattern. zeetah runs it natively; RE2/Rust/.NET/
    // Python-stdlib/mvzr reject it (no lookaround / possessive / `\p{}`),
    // emitting REJECTED — which the correctness gate skips.
    .{ .id = "tokenizer", .pattern = "(?i:[sdmt]|ll|ve|re)|[^\\r\\n\\p{L}\\p{N}]?+\\p{L}+|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]++[\\r\\n]|\\s[\\r\\n]|\\s+(?!\\S)|\\s+", .kind = .corpus },
    .{ .id = "pathological", .pattern = "(a+)+b", .kind = .pathological },
};

// Prefix slice sizes used for corpus workloads (bytes). zeetah's public
// findAll is now a single linear leftmost-first pass (O(n·m), no per-match
// VM restart), so large inputs are tractable and exercise the linear path.
const corpus_sizes = [_]usize{ 1024, 8192, 32768, 262144, 1048576 };

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

/// Count all leftmost, non-overlapping matches over `input`. Uses the
/// allocation-free `Regex.count` — the measurement-fair analogue of the
/// RE2 / Rust `find_iter().count()` the other harnesses use (no per-match
/// heap `Match` is materialised). Semantically identical to
/// `findAll(...).len` (asserted by a unit test in `src/regex.zig`).
fn scanCount(re: *const Regex, input: []const u8) !usize {
    return re.count(input);
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
    const line = std.fmt.bufPrint(&buf, "zeetah,{s},{d},{d},{d},{d},{d:.2},{d},{s}\n", .{
        workload, input_bytes, iterations, compile_ns, search_ns, throughput, match_count, note,
    }) catch return;
    out(line);
}

/// Compile `wl`, selecting the `.multiline` struct flag for multiline
/// workloads (the API peer of the inline `(?m)` the other engines use).
fn compileWl(wl: Workload) !Regex {
    return if (wl.multiline)
        Regex.compileWithFlags(alloc, wl.pattern, .{ .multiline = true })
    else
        Regex.compile(alloc, wl.pattern);
}

fn benchOne(wl: Workload, input: []const u8) void {
    // --- compile timing (and rejection handling) ---
    const compile_iters: usize = 50;
    var compile_min: u64 = std.math.maxInt(u64);
    var i: usize = 0;
    while (i < compile_iters) : (i += 1) {
        const t0 = nowNs();
        var re = compileWl(wl) catch {
            // zeetah's ReDoS guard rejects e.g. (a+)+ at compile time.
            emitRow(wl.id, input.len, 0, -1, -1, 0.0, -1, "REJECTED");
            return;
        };
        const dt = nowNs() - t0;
        re.deinit();
        if (dt < compile_min) compile_min = dt;
    }

    var re = compileWl(wl) catch {
        emitRow(wl.id, input.len, 0, -1, -1, 0.0, -1, "REJECTED");
        return;
    };
    defer re.deinit();

    // --- search timing ---
    // Warmup + establish a per-scan estimate to size the timed run to >=100ms.
    var match_count: usize = scanCount(&re, input) catch 0; // warmup
    const probe0 = nowNs();
    match_count = scanCount(&re, input) catch 0;
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
        _ = scanCount(&re, input) catch 0;
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

pub fn main() !void {
    // Corpus path: default relative to repo root (run_all.sh runs from there),
    // overridable via the CORPUS env var. Avoids Zig 0.16's reworked args API.
    const corpus_path: [*:0]const u8 = std.c.getenv("CORPUS") orelse
        "corpus.txt";

    const corpus = try readFileAll(corpus_path);
    defer alloc.free(corpus);

    // Synthetic input for the pathological / linear-time workload.
    const path_input = try alloc.alloc(u8, 50_000);
    defer alloc.free(path_input);
    @memset(path_input, 'a');

    for (workloads) |wl| {
        switch (wl.kind) {
            .corpus => {
                for (corpus_sizes) |sz| {
                    const n = @min(sz, corpus.len);
                    benchOne(wl, corpus[0..n]);
                }
            },
            .pathological => benchOne(wl, path_input),
        }
    }
}
