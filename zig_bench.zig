//! Cross-engine benchmark harness — zeetah side (runtime meta-engine).
//!
//! Emits CSV rows (no header) to stdout with the schema shared by all
//! harnesses (note the `model` column — see README.md):
//!
//!   engine,model,workload,input_bytes,iterations,compile_ns,search_ns_per_op,throughput_mb_s,match_count,note
//!
//! The workload table is NOT declared here: it is generated from the single
//! source of truth (`benchmarks.json`) into `gen/workloads_zeetah.zig` by
//! `gen_workloads.py`, so patterns can never drift across the nine harnesses.
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
//! IO and timing go through libc (std.c) on purpose: Zig 0.16's std.Io was
//! reworked ("Writergate") and std.time lost nanoTimestamp/Timer, so libc is
//! the stable surface here. zeetah allocations use the libc allocator.
//!
//! Usage: zig_bench  (corpus via $CORPUS, default repo-relative corpus.txt)

const std = @import("std");
const Regex = @import("zeetah").Regex;
const gen = @import("gen/workloads_zeetah.zig");

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
    compile_ns: i64,
    search_ns: i64,
    throughput: f64,
    match_count: i64,
    note: []const u8,
) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "zeetah,{s},{s},{d},{d},{d},{d},{d:.2},{d},{s}\n", .{
        model, workload, input_bytes, iterations, compile_ns, search_ns, throughput, match_count, note,
    }) catch return;
    out(line);
}

// --- per-model match functions (uniform signature; close over `alloc`) ------

/// count: leftmost, non-overlapping match count (allocation-free).
fn mCount(re: *const Regex, input: []const u8) anyerror!usize {
    return re.count(input);
}

/// count-spans: sum of match lengths over the same match set `count` walks
/// (`findAll` uses the identical `nextSpanFrom` advance), so spans can only
/// diverge across engines if `count` already did.
fn mSpans(re: *const Regex, input: []const u8) anyerror!usize {
    const ms = try re.findAll(alloc, input);
    defer alloc.free(ms);
    var total: usize = 0;
    for (ms) |m| total += m.end - m.start;
    return total;
}

/// count-captures: participating capture groups summed over all matches,
/// group 0 (the whole match) excluded. A group "participates" iff its slot is
/// non-null (length-independent).
fn mCaptures(re: *const Regex, input: []const u8) anyerror!usize {
    const ms = try re.capturesAll(alloc, input);
    defer {
        for (ms) |*m| m.deinit(alloc);
        alloc.free(ms);
    }
    var total: usize = 0;
    for (ms) |m| {
        for (m.groups[1..]) |g| {
            if (g != null) total += 1;
        }
    }
    return total;
}

/// grep: number of lines (segments split on '\n', trailing fragment included
/// when non-empty) containing >=1 match. The same compiled regex is reused
/// per-segment — a `(?m)`/multiline flag is harmless on a single-line segment.
fn mGrep(re: *const Regex, input: []const u8) anyerror!usize {
    var n: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\n') {
            if (try re.isMatch(input[start..i])) n += 1;
            start = i + 1;
        }
    }
    if (start < input.len and try re.isMatch(input[start..])) n += 1;
    return n;
}

/// Run one model: warm up, probe, size the timed loop to >=50 ms (5..500
/// iterations), report the median. Identical methodology to the original
/// single-model harness.
fn measure(
    comptime f: fn (*const Regex, []const u8) anyerror!usize,
    model: []const u8,
    wl_id: []const u8,
    re: *const Regex,
    input: []const u8,
    compile_ns: i64,
) void {
    var mc: usize = f(re, input) catch 0; // warmup
    const probe0 = nowNs();
    mc = f(re, input) catch 0;
    const probe = @max(nowNs() - probe0, 1);

    const iters: usize = @intCast(@min(@as(u64, 500), @max(@as(u64, 5), 50_000_000 / probe)));
    const samples = alloc.alloc(u64, iters) catch {
        emitRow(model, wl_id, input.len, 0, compile_ns, -1, 0.0, @intCast(mc), "ALLOC_FAIL");
        return;
    };
    defer alloc.free(samples);

    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const t0 = nowNs();
        _ = f(re, input) catch 0;
        samples[i] = nowNs() - t0;
    }
    std.mem.sort(u64, samples, {}, lessThanU64);
    const median = samples[iters / 2];

    const mb = @as(f64, @floatFromInt(input.len)) / 1_000_000.0;
    const secs = @as(f64, @floatFromInt(median)) / 1_000_000_000.0;
    const throughput = if (secs > 0) mb / secs else 0.0;
    emitRow(model, wl_id, input.len, iters, compile_ns, @intCast(median), throughput, @intCast(mc), "ok");
}

/// Compile `wl`, selecting the `.multiline` struct flag (the API peer of the
/// inline `(?m)` the other engines spell into the pattern).
fn compileWl(wl: gen.Workload) !Regex {
    return if (wl.multiline)
        Regex.compileWithFlags(alloc, wl.pattern, .{ .multiline = true })
    else
        Regex.compile(alloc, wl.pattern);
}

/// Emit a REJECTED row for every model this workload would have run (keeps the
/// per-model report sections consistent).
fn emitRejected(wl: gen.Workload, len: usize) void {
    emitRow("count", wl.id, len, 0, -1, -1, 0.0, -1, "REJECTED");
    if (wl.spans) emitRow("count-spans", wl.id, len, 0, -1, -1, 0.0, -1, "REJECTED");
    if (wl.grep) emitRow("grep", wl.id, len, 0, -1, -1, 0.0, -1, "REJECTED");
    if (wl.captures) emitRow("count-captures", wl.id, len, 0, -1, -1, 0.0, -1, "REJECTED");
}

fn benchOne(wl: gen.Workload, input: []const u8) void {
    if (wl.force_reject) {
        emitRejected(wl, input.len);
        return;
    }

    // --- compile timing (and rejection handling) ---
    const compile_iters: usize = 50;
    var compile_min: u64 = std.math.maxInt(u64);
    var i: usize = 0;
    while (i < compile_iters) : (i += 1) {
        const t0 = nowNs();
        var re = compileWl(wl) catch {
            // zeetah's ReDoS guard rejects e.g. (a+)+b at compile time.
            emitRejected(wl, input.len);
            return;
        };
        const dt = nowNs() - t0;
        re.deinit();
        if (dt < compile_min) compile_min = dt;
    }

    var re = compileWl(wl) catch {
        emitRejected(wl, input.len);
        return;
    };
    defer re.deinit();
    const cns: i64 = @intCast(compile_min);

    measure(mCount, "count", wl.id, &re, input, cns);
    if (wl.spans) measure(mSpans, "count-spans", wl.id, &re, input, cns);
    if (wl.grep) measure(mGrep, "grep", wl.id, &re, input, cns);
    if (wl.captures) measure(mCaptures, "count-captures", wl.id, &re, input, cns);
}

/// regex-redux: compile every member pattern and `count` each once over the
/// corpus, reporting total compile time, total search time and the summed
/// count (which agrees across engines because each member's count does). Its
/// own report section; throughput is the aggregate bytes/s (members * bytes).
fn benchRedux(corpus: []const u8) void {
    const members = gen.redux_members;
    if (members.len == 0) return;
    const n = @min(gen.redux_size, corpus.len);
    const input = corpus[0..n];

    // --- compile timing: min over iters of compiling ALL members ---
    var compile_min: u64 = std.math.maxInt(u64);
    var it: usize = 0;
    while (it < 50) : (it += 1) {
        var compiled: [members.len]Regex = undefined;
        var built: usize = 0;
        const t0 = nowNs();
        var ok = true;
        for (members, 0..) |m, k| {
            compiled[k] = Regex.compile(alloc, m) catch {
                ok = false;
                break;
            };
            built = k + 1;
        }
        const dt = nowNs() - t0;
        for (compiled[0..built]) |*r| r.deinit();
        if (!ok) {
            emitRow("regex-redux", "redux", n, 0, -1, -1, 0.0, -1, "REJECTED");
            return;
        }
        if (dt < compile_min) compile_min = dt;
    }

    // --- build once for the search loop ---
    var compiled: [members.len]Regex = undefined;
    for (members, 0..) |m, k| {
        compiled[k] = Regex.compile(alloc, m) catch {
            emitRow("regex-redux", "redux", n, 0, -1, -1, 0.0, -1, "REJECTED");
            return;
        };
    }
    defer for (&compiled) |*r| r.deinit();

    const reduxCount = struct {
        fn run(cs: []const Regex, inp: []const u8) usize {
            var t: usize = 0;
            for (cs) |*r| t += r.count(inp) catch 0;
            return t;
        }
    }.run;

    var total: usize = reduxCount(&compiled, input); // warmup
    const probe0 = nowNs();
    total = reduxCount(&compiled, input);
    const probe = @max(nowNs() - probe0, 1);

    const iters: usize = @intCast(@min(@as(u64, 500), @max(@as(u64, 5), 50_000_000 / probe)));
    const samples = alloc.alloc(u64, iters) catch {
        emitRow("regex-redux", "redux", n, 0, @intCast(compile_min), -1, 0.0, @intCast(total), "ALLOC_FAIL");
        return;
    };
    defer alloc.free(samples);
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const t0 = nowNs();
        _ = reduxCount(&compiled, input);
        samples[i] = nowNs() - t0;
    }
    std.mem.sort(u64, samples, {}, lessThanU64);
    const median = samples[iters / 2];

    const mb = @as(f64, @floatFromInt(members.len * n)) / 1_000_000.0;
    const secs = @as(f64, @floatFromInt(median)) / 1_000_000_000.0;
    const throughput = if (secs > 0) mb / secs else 0.0;
    emitRow("regex-redux", "redux", n, iters, @intCast(compile_min), @intCast(median), throughput, @intCast(total), "ok");
}

pub fn main() !void {
    const corpus_path: [*:0]const u8 = std.c.getenv("CORPUS") orelse "corpus.txt";
    const corpus = try readFileAll(corpus_path);
    defer alloc.free(corpus);

    const synth = try alloc.alloc(u8, gen.synthetic_len);
    defer alloc.free(synth);
    @memset(synth, 'a');

    for (gen.workloads) |wl| {
        switch (wl.kind) {
            .corpus => {
                for (gen.corpus_sizes) |sz| {
                    const n = @min(sz, corpus.len);
                    benchOne(wl, corpus[0..n]);
                }
            },
            .pathological => benchOne(wl, synth),
        }
    }

    benchRedux(corpus);
}
