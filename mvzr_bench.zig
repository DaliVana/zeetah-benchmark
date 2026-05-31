//! Cross-engine benchmark harness — mvzr side.
//!
//! mvzr (https://github.com/mnemnion/mvzr) is a small, zero-allocation Zig
//! regex bytecode VM. Same CSV schema, sizing, timing and models as the other
//! harnesses (count / count-spans / grep — mvzr has no capture-count API and
//! is excluded from regex-redux, so those models do not apply):
//!
//!   engine,model,workload,input_bytes,iterations,compile_ns,search_ns_per_op,throughput_mb_s,match_count,note
//!
//! The workload table is generated from the single source of truth into
//! `gen/workloads_mvzr.zig`. Patterns mvzr silently mis-parses into a different
//! language (rather than rejecting) carry `force_reject = true` there and are
//! reported as REJECTED — same gate-skipped mechanism as the other harnesses.
//!
//! mvzr's default Regex caps at 64 ops / 8 char sets; we widen the VM via
//! SizedRegex so the richer corpus patterns compile. A null compile is also
//! reported as REJECTED.
//!
//! mvzr is a backtracking VM, so `(a+)+b` is catastrophic. Mirroring the Python
//! harness, the pathological workload is split out via BENCH_MVZR_MODE so
//! run_all.sh can run it in a hard-timed child:
//!   - unset / "corpus": run all corpus workloads in-process (skip pathological)
//!   - "list": print the ordered corpus workload ids (one per line)
//!   - "one" + BENCH_MVZR_IDX=i: run only corpus workload i (isolated child)
//!   - "patho": just attempt the catastrophic match; the parent times/limits us
//!
//! Usage: CORPUS=<path> mvzr_bench   (defaults to the repo-root corpus)

const std = @import("std");
const mvzr = @import("mvzr");
const gen = @import("gen/workloads_mvzr.zig");

const alloc = std.heap.c_allocator;

/// Widened VM: enough headroom for every corpus pattern.
const Regex = mvzr.SizedRegex(256, 64);

/// The catastrophic workload, extracted from the generated table (single
/// source) and run only in the timed child (BENCH_MVZR_MODE=patho).
const patho_pattern = blk: {
    for (gen.workloads) |w| {
        if (w.kind == .pathological) break :blk w.pattern;
    }
    break :blk "(a+)+b";
};

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
    const line = std.fmt.bufPrint(&buf, "mvzr,{s},{s},{d},{d},{d},{d},{d:.2},{d},{s}\n", .{
        model, workload, input_bytes, iterations, compile_ns, search_ns, throughput, match_count, note,
    }) catch return;
    out(line);
}

// --- per-model match functions ----------------------------------------------

fn mCount(re: *const Regex, input: []const u8) usize {
    var it = re.iterator(input);
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

fn mSpans(re: *const Regex, input: []const u8) usize {
    var it = re.iterator(input);
    var total: usize = 0;
    while (it.next()) |m| total += m.end - m.start;
    return total;
}

fn mGrep(re: *const Regex, input: []const u8) usize {
    var n: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\n') {
            if (re.isMatch(input[start..i])) n += 1;
            start = i + 1;
        }
    }
    if (start < input.len and re.isMatch(input[start..])) n += 1;
    return n;
}

fn measure(
    comptime f: anytype,
    model: []const u8,
    wl_id: []const u8,
    re: *const Regex,
    input: []const u8,
    compile_ns: i64,
) void {
    var mc: usize = f(re, input); // warmup
    const probe0 = nowNs();
    mc = f(re, input);
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
        _ = f(re, input);
        samples[i] = nowNs() - t0;
    }
    std.mem.sort(u64, samples, {}, lessThanU64);
    const median = samples[iters / 2];

    const mb = @as(f64, @floatFromInt(input.len)) / 1_000_000.0;
    const secs = @as(f64, @floatFromInt(median)) / 1_000_000_000.0;
    const throughput = if (secs > 0) mb / secs else 0.0;
    emitRow(model, wl_id, input.len, iters, compile_ns, @intCast(median), throughput, @intCast(mc), "ok");
}

fn emitRejected(wl: gen.Workload, len: usize) void {
    emitRow("count", wl.id, len, 0, -1, -1, 0.0, -1, "REJECTED");
    if (wl.spans) emitRow("count-spans", wl.id, len, 0, -1, -1, 0.0, -1, "REJECTED");
    if (wl.grep) emitRow("grep", wl.id, len, 0, -1, -1, 0.0, -1, "REJECTED");
}

fn benchOne(wl: gen.Workload, input: []const u8) void {
    // Patterns mvzr mis-parses into a different language (flagged in the
    // manifest) — report honestly as REJECTED so the gate compares only
    // faithful results.
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
        const re = Regex.compile(wl.pattern);
        const dt = nowNs() - t0;
        if (re == null) {
            emitRejected(wl, input.len);
            return;
        }
        if (dt < compile_min) compile_min = dt;
    }
    const re = Regex.compile(wl.pattern) orelse {
        emitRejected(wl, input.len);
        return;
    };
    const cns: i64 = @intCast(compile_min);

    measure(mCount, "count", wl.id, &re, input, cns);
    if (wl.spans) measure(mSpans, "count-spans", wl.id, &re, input, cns);
    if (wl.grep) measure(mGrep, "grep", wl.id, &re, input, cns);
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

    // Child mode: attempt the catastrophic match; the parent times/limits us
    // and prints the ok/TIMEOUT row, so we print nothing here.
    if (streq(mode, "patho")) {
        const input = try alloc.alloc(u8, gen.synthetic_len);
        defer alloc.free(input);
        @memset(input, 'a');
        const re = Regex.compile(patho_pattern) orelse return;
        _ = mCount(&re, input);
        return;
    }

    // Enumeration mode: ordered corpus workload ids (one per line) so the
    // orchestrator drives one isolated child per workload without duplicating
    // the id list. Pathological is excluded (handled via the patho mode).
    if (streq(mode, "list")) {
        for (gen.workloads) |wl| {
            if (wl.kind != .corpus) continue;
            out(wl.id);
            out("\n");
        }
        return;
    }

    const corpus_path: [*:0]const u8 = std.c.getenv("CORPUS") orelse "corpus.txt";
    const corpus = try readFileAll(corpus_path);
    defer alloc.free(corpus);

    // Single-workload child mode (BENCH_MVZR_MODE=one, BENCH_MVZR_IDX=i). idx
    // indexes the generated `workloads`; the driver only sends corpus indices
    // (the list mode skips pathological), so a backtracking crash costs one
    // workload's rows (back-filled CRASHED) instead of aborting the run.
    if (streq(mode, "one")) {
        const idx = envInt("BENCH_MVZR_IDX") orelse return;
        if (idx >= gen.workloads.len) return;
        const wl = gen.workloads[idx];
        if (wl.kind != .corpus) return;
        for (gen.corpus_sizes) |sz| {
            const n = @min(sz, corpus.len);
            benchOne(wl, corpus[0..n]);
        }
        return;
    }

    // Default (manual) mode: run every corpus workload in-process.
    for (gen.workloads) |wl| {
        if (wl.kind != .corpus) continue;
        for (gen.corpus_sizes) |sz| {
            const n = @min(sz, corpus.len);
            benchOne(wl, corpus[0..n]);
        }
    }
}
