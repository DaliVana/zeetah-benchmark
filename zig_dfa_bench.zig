//! Cross-engine benchmark harness — zeetah *comptime DFA* side.
//!
//! Same CSV schema, corpus, sizing, timing and models as `zig_bench.zig`, but
//! every pattern is compiled at BUILD time into a minimized DFA via
//! `Pattern` (comptime). The workload table is generated from the single
//! source of truth into `gen/workloads_zeetah_dfa.zig` — the `dfa: true`
//! subset of `benchmarks.json` (DFA-ineligible patterns are excluded; a
//! lazy/lookaround/possessive/`\p{}`/backref pattern here would be a hard
//! `@compileError` post-Phase-6, so the manifest's `dfa` flag is load-bearing).
//!
//!   engine,model,workload,input_bytes,iterations,compile_ns,search_ns_per_op,throughput_mb_s,match_count,note
//!
//! `compile_ns` is reported as 0: the DFA is baked into `.rodata` at build
//! time, so there is no runtime compilation step. Models: count, count-spans,
//! grep (the DFA serves boundaries only — no count-captures; the dfa subset
//! also carries no regex-redux members). `pathological` `(a+)+b` is regular,
//! so the DFA runs it linearly (unlike the runtime VM, which ReDoS-rejects it).
//!
//! Usage: zig_dfa_bench  (corpus via $CORPUS, default repo-relative corpus.txt)

const std = @import("std");
const regex = @import("zeetah");
const gen = @import("gen/workloads_zeetah_dfa.zig");

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

fn lessThanU64(_: void, a: u64, b: u64) bool {
    return a < b;
}

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

fn emitRow(
    model: []const u8,
    workload: []const u8,
    input_bytes: usize,
    iterations: usize,
    search_ns: i64,
    throughput: f64,
    match_count: i64,
    note: []const u8,
) void {
    var buf: [256]u8 = undefined;
    // compile_ns is always 0 here (DFA baked at build time).
    const line = std.fmt.bufPrint(&buf, "zeetah-dfa,{s},{s},{d},{d},0,{d},{d:.2},{d},{s}\n", .{
        model, workload, input_bytes, iterations, search_ns, throughput, match_count, note,
    }) catch return;
    out(line);
}

// --- per-model match functions (comptime `C` is the baked DFA type) ---------

fn mCount(comptime C: type, input: []const u8) usize {
    return C.count(input);
}

fn mSpans(comptime C: type, input: []const u8) usize {
    const ms = C.findAll(alloc, input) catch return 0;
    defer alloc.free(ms);
    var total: usize = 0;
    for (ms) |m| total += m.end - m.start;
    return total;
}

fn mGrep(comptime C: type, input: []const u8) usize {
    var n: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\n') {
            if (C.isMatch(input[start..i])) n += 1;
            start = i + 1;
        }
    }
    if (start < input.len and C.isMatch(input[start..])) n += 1;
    return n;
}

fn measure(
    comptime C: type,
    comptime f: anytype,
    model: []const u8,
    wl_id: []const u8,
    input: []const u8,
) void {
    var mc: usize = f(C, input); // warmup
    const probe0 = nowNs();
    mc = f(C, input);
    const probe = @max(nowNs() - probe0, 1);

    const iters: usize = @intCast(@min(@as(u64, 500), @max(@as(u64, 5), 50_000_000 / probe)));
    const samples = alloc.alloc(u64, iters) catch {
        emitRow(model, wl_id, input.len, 0, -1, 0.0, @intCast(mc), "ALLOC_FAIL");
        return;
    };
    defer alloc.free(samples);

    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const t0 = nowNs();
        _ = f(C, input);
        samples[i] = nowNs() - t0;
    }
    std.mem.sort(u64, samples, {}, lessThanU64);
    const median = samples[iters / 2];

    const mb = @as(f64, @floatFromInt(input.len)) / 1_000_000.0;
    const secs = @as(f64, @floatFromInt(median)) / 1_000_000_000.0;
    const throughput = if (secs > 0) mb / secs else 0.0;
    emitRow(model, wl_id, input.len, iters, @intCast(median), throughput, @intCast(mc), "ok");
}

fn benchOne(comptime C: type, comptime wl: gen.Workload, input: []const u8) void {
    measure(C, mCount, "count", wl.id, input);
    if (wl.spans) measure(C, mSpans, "count-spans", wl.id, input);
    if (wl.grep) measure(C, mGrep, "grep", wl.id, input);
}

pub fn main() !void {
    const corpus_path: [*:0]const u8 = std.c.getenv("CORPUS") orelse "corpus.txt";
    const corpus = try readFileAll(corpus_path);
    defer alloc.free(corpus);

    // Dense synthetic log corpus for the `input: logs` workloads (every line a
    // `timestamp level message` record); falls back to the mixed corpus if
    // $LOGCORPUS is absent (manual single-engine runs).
    const logs_path: [*:0]const u8 = std.c.getenv("LOGCORPUS") orelse "logs.txt";
    const logs = readFileAll(logs_path) catch try alloc.dupe(u8, corpus);
    defer alloc.free(logs);

    const synth = try alloc.alloc(u8, gen.synthetic_len);
    defer alloc.free(synth);
    @memset(synth, 'a');

    inline for (gen.workloads) |wl| {
        // Per-workload opts: thread `multiline` (the `^`/`$`-as-line-anchor flag
        // the manifest carries as a struct field, like the runtime; e.g.
        // `multiline_log`). All other opts are the shared generous-DFA defaults.
        const opts = regex.PatternOptions{
            .max_dfa_states = 100_000,
            .on_oversize = .allow_oversized,
            .multiline = wl.multiline,
        };
        const C = ComptimeRegex(wl.pattern, opts);
        switch (wl.kind) {
            .corpus => {
                const src = if (wl.logs) logs else corpus;
                inline for (gen.corpus_sizes) |sz| {
                    const n = @min(sz, src.len);
                    benchOne(C, wl, src[0..n]);
                }
            },
            .pathological => benchOne(C, wl, synth),
        }
    }
}
