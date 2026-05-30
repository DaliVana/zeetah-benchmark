//! Cross-engine benchmark harness — zeetah *comptime DFA* side.
//!
//! Same CSV schema, corpus, workloads, sizing and timing methodology as
//! `zig_bench.zig`, but every pattern is compiled at *build time* into a
//! minimized DFA via `ComptimeRegex` (see src/comptime_compile.zig). The
//! patterns are the fixed workload set, so they are comptime-known literals.
//!
//!   engine,workload,input_bytes,iterations,compile_ns,search_ns_per_op,throughput_mb_s,match_count,note
//!
//! `compile_ns` is reported as 0: the DFA is baked into `.rodata` at build
//! time, so there is no runtime compilation step (that is the whole point).
//!
//! Usage: zig_dfa_bench  (corpus via CORPUS env, default repo-relative path)

const std = @import("std");
const regex = @import("zeetah");
// Phase-6 cutover renamed `ComptimeRegex` -> `Pattern` (single shared meta
// planner) and `ComptimeOptions` -> `PatternOptions`. The old AST/VM runtime
// fallback was deleted: a DFA-ineligible comptime pattern (lazy `.*?`,
// lookaround, possessive, `\p{}`, backreference) is now a hard `@compileError`
// even with `on_explosion = .runtime_fallback`, so those workloads can no
// longer be probed here — they are excluded from this harness's set below and
// remain covered by the runtime VM harness (`zig_bench.zig`).
const ComptimeRegex = regex.Pattern;

const alloc = std.heap.c_allocator;

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
};

// Identical to zig_bench.zig's workload set.
const workloads = [_]Workload{
    .{ .id = "literal", .pattern = "Sherlock", .kind = .corpus },
    .{ .id = "quantifier", .pattern = "a+", .kind = .corpus },
    .{ .id = "digits", .pattern = "[0-9]+", .kind = .corpus },
    .{ .id = "word", .pattern = "\\w+", .kind = .corpus },
    .{ .id = "alternation", .pattern = "cat|dog|bird|fish", .kind = .corpus },
    .{ .id = "ipv4", .pattern = "(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)", .kind = .corpus },
    // Real-world workloads. Shell `/.../` delimiters and stray markdown
    // backticks stripped; named groups -> non-capturing `(?:...)` (the harness
    // compares match counts, not captures); the k8s pattern's leading `^` is
    // dropped so it matches log-shaped substrings anywhere in the token corpus.
    // Patterns with lazy quantifiers / nested repetition are DFA-ineligible and
    // surface as NO_DFA_FALLBACK rows, which the correctness gate ignores.
    // NOTE (Phase-6): `html_title`, `modsec_sqli`, `aws_eni`, `k8s_fluentd`
    // and `tokenizer` were dropped from this comptime-DFA set. They use lazy
    // `.*?`, lookahead `(?!)`, possessive `?+`/`++` or Unicode `\p{}` — all
    // DFA-ineligible. The runtime fallback that previously turned them into
    // skipped `NO_DFA_FALLBACK` rows was deleted at the cutover, so today they
    // would be a hard `@compileError` that fails the whole harness. They stay
    // covered by the runtime VM harness (`zig_bench.zig`).
    // Kept to the subset the comptime meta planner accepts AND that stays
    // under the fixed internal DFA construction ceiling (MAX_NFA/MAX_EDGES/
    // MAX_DFA — independent of max_dfa_states; no runtime fallback post-
    // Phase-6). Empirically ineligible and therefore runtime-VM-only:
    // `email`/`uri` (subset-construction explosion), `price`/`nltk`/`href`
    // (unsupported feature in the comptime path).
    .{ .id = "ssn", .pattern = "[0-9]{3,3}-[0-9]{2,2}-[0-9]{4,4}", .kind = .corpus },
    .{ .id = "apache_post", .pattern = "POST (?:/[a-zA-Z0-9_]+){1,}", .kind = .corpus },
    // New-workload subset that stays DFA-eligible AND under the comptime
    // construction ceiling. The lazy/lookaround/backref/possessive/`\p`
    // additions (json_string, backref_word, lookbehind_amount, unicode_prop,
    // atomic_token, …) are DFA-ineligible and would be a hard @compileError
    // here, so they are intentionally absent — they stay covered by the
    // runtime VM harness (zig_bench.zig).
    .{ .id = "date_iso", .pattern = "[0-9]{4}-[0-9]{2}-[0-9]{2}", .kind = .corpus },
    .{ .id = "time_hms", .pattern = "[0-9]{2}:[0-9]{2}:[0-9]{2}", .kind = .corpus },
    .{ .id = "hex_color", .pattern = "#[0-9a-fA-F]{6}", .kind = .corpus },
    .{ .id = "semver", .pattern = "v?[0-9]+\\.[0-9]+\\.[0-9]+", .kind = .corpus },
    .{ .id = "log_level", .pattern = "(?:TRACE|DEBUG|INFO|WARN|ERROR|FATAL)", .kind = .corpus },
    .{ .id = "html_tag", .pattern = "<[^>]+>", .kind = .corpus },
    .{ .id = "hashtag", .pattern = "#[A-Za-z0-9_]+", .kind = .corpus },
    .{ .id = "path_unix", .pattern = "(?:/[A-Za-z0-9_.-]+)+", .kind = .corpus },
    .{ .id = "pathological", .pattern = "(a+)+b", .kind = .pathological },
};

const corpus_sizes = [_]usize{ 1024, 8192, 32768, 262144, 1048576 };

// Build-time options: a generous state budget and runtime fallback so the
// harness never fails to build; rows note when a pattern fell back.
const dfa_opts = regex.PatternOptions{ .max_dfa_states = 100_000, .on_explosion = .runtime_fallback };

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
    const line = std.fmt.bufPrint(&buf, "zeetah-dfa,{s},{d},{d},{d},{d},{d:.2},{d},{s}\n", .{
        workload, input_bytes, iterations, compile_ns, search_ns, throughput, match_count, note,
    }) catch return;
    out(line);
}

/// Count non-overlapping leftmost matches with the comptime DFA. The Match
/// array is heap-allocated by findAll; per-match captures are the static
/// empty slice (DFA serves boundaries only), so only the array is freed.
fn scanCount(comptime C: type, input: []const u8) !usize {
    const matches = try C.findAll(alloc, input);
    defer alloc.free(matches);
    return matches.len;
}

fn benchOne(comptime C: type, comptime wl: Workload, input: []const u8) void {
    if (!C.has_dfa) {
        // Pattern not DFA-eligible / over budget: not this harness's job.
        emitRow(wl.id, input.len, 0, 0, -1, 0.0, -1, "NO_DFA_FALLBACK");
        return;
    }

    var match_count: usize = scanCount(C, input) catch 0; // warmup
    const probe0 = nowNs();
    match_count = scanCount(C, input) catch 0;
    const probe = @max(nowNs() - probe0, 1);

    const iters: usize = @intCast(@min(@as(u64, 500), @max(@as(u64, 5), 50_000_000 / probe)));

    const samples = alloc.alloc(u64, iters) catch {
        emitRow(wl.id, input.len, 0, 0, -1, 0.0, @intCast(match_count), "ALLOC_FAIL");
        return;
    };
    defer alloc.free(samples);

    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const t0 = nowNs();
        _ = scanCount(C, input) catch 0;
        samples[i] = nowNs() - t0;
    }
    std.mem.sort(u64, samples, {}, lessThanU64);
    const median = samples[iters / 2];

    const mb = @as(f64, @floatFromInt(input.len)) / 1_000_000.0;
    const secs = @as(f64, @floatFromInt(median)) / 1_000_000_000.0;
    const throughput = if (secs > 0) mb / secs else 0.0;

    // compile_ns = 0: DFA is baked at build time, no runtime compile step.
    emitRow(wl.id, input.len, iters, 0, @intCast(median), throughput, @intCast(match_count), "ok");
}

pub fn main() !void {
    const corpus_path: [*:0]const u8 = std.c.getenv("CORPUS") orelse
        "corpus.txt";

    const corpus = try readFileAll(corpus_path);
    defer alloc.free(corpus);

    const path_input = try alloc.alloc(u8, 50_000);
    defer alloc.free(path_input);
    @memset(path_input, 'a');

    inline for (workloads) |wl| {
        const C = ComptimeRegex(wl.pattern, dfa_opts);
        switch (wl.kind) {
            .corpus => {
                inline for (corpus_sizes) |sz| {
                    const n = @min(sz, corpus.len);
                    benchOne(C, wl, corpus[0..n]);
                }
            },
            .pathological => benchOne(C, wl, path_input),
        }
    }
}
