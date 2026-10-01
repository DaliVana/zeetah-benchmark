//! rebar runner for zeetah's runtime meta-engine (`zeetah.Regex`).
//!
//! Reads one benchmark as KLV on stdin (see rebar's KLV.md), runs it under the
//! requested model, and prints one `duration_ns,count` line per sample —
//! exactly the contract of rebar's Rust runners (`shared/timer`).
//!
//! Semantics notes:
//! - zeetah is a byte-oriented engine; its Unicode mode is not implemented
//!   (`CompileFlags.unicode` → error.NotImplemented). A benchmark with
//!   `unicode = true` is therefore refused instead of silently run with ASCII
//!   semantics.
//! - Only single-pattern benchmarks are supported (no multi-pattern API is
//!   exposed through `Regex`).
//! - count-captures / grep-captures reuse one scratch buffer per match (reset
//!   after every match) — the analogue of PCRE2's reused match data / Rust's
//!   reused `Captures`. zeetah's runtime capture API allocates `groups`.
//!
//! Usage: main [--version | --quiet]  (KLV on stdin)

const std = @import("std");
const zeetah = @import("zeetah");
const build_info = @import("build_info");

const Regex = zeetah.Regex;
const alloc = std.heap.c_allocator;

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.UPTIME_RAW, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn writeAll(fd: c_int, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = std.c.write(fd, rest.ptr, rest.len);
        if (n <= 0) return;
        rest = rest[@intCast(n)..];
    }
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zeetah runner: " ++ fmt ++ "\n", args) catch "zeetah runner: error\n";
    writeAll(2, msg);
    std.c.exit(1);
}

fn readStdin() ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var chunk: [1 << 16]u8 = undefined;
    while (true) {
        const n = std.c.read(0, &chunk, chunk.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try list.appendSlice(alloc, chunk[0..@intCast(n)]);
    }
    return list.toOwnedSlice(alloc);
}

// --- KLV ---------------------------------------------------------------------

const Benchmark = struct {
    name: []const u8 = "",
    model: []const u8 = "",
    patterns: std.ArrayList([]const u8) = .empty,
    case_insensitive: bool = false,
    unicode: bool = false,
    haystack: []const u8 = "",
    max_iters: u64 = 0,
    max_warmup_iters: u64 = 0,
    max_time_ns: u64 = 0,
    max_warmup_time_ns: u64 = 0,
};

fn parseBool(key: []const u8, v: []const u8) bool {
    if (std.mem.eql(u8, v, "true")) return true;
    if (std.mem.eql(u8, v, "false")) return false;
    fail("invalid bool for '{s}': '{s}'", .{ key, v });
}

fn parseU64(key: []const u8, v: []const u8) u64 {
    return std.fmt.parseInt(u64, v, 10) catch fail("invalid integer for '{s}': '{s}'", .{ key, v });
}

/// `key:len:value\n`, repeated. Values may contain arbitrary bytes.
fn parseKlv(raw: []const u8) !Benchmark {
    var b: Benchmark = .{};
    var i: usize = 0;
    while (i < raw.len) {
        const c1 = std.mem.indexOfScalarPos(u8, raw, i, ':') orelse fail("KLV: missing key terminator", .{});
        const key = raw[i..c1];
        const c2 = std.mem.indexOfScalarPos(u8, raw, c1 + 1, ':') orelse fail("KLV: missing length terminator", .{});
        const len = parseU64("length", raw[c1 + 1 .. c2]);
        const vstart = c2 + 1;
        const vend = vstart + @as(usize, @intCast(len));
        if (vend >= raw.len or raw[vend] != '\n') fail("KLV: bad value framing for '{s}'", .{key});
        const v = raw[vstart..vend];
        i = vend + 1;

        if (std.mem.eql(u8, key, "name")) {
            b.name = v;
        } else if (std.mem.eql(u8, key, "model")) {
            b.model = v;
        } else if (std.mem.eql(u8, key, "pattern")) {
            try b.patterns.append(alloc, v);
        } else if (std.mem.eql(u8, key, "case-insensitive")) {
            b.case_insensitive = parseBool(key, v);
        } else if (std.mem.eql(u8, key, "unicode")) {
            b.unicode = parseBool(key, v);
        } else if (std.mem.eql(u8, key, "haystack")) {
            b.haystack = v;
        } else if (std.mem.eql(u8, key, "max-iters")) {
            b.max_iters = parseU64(key, v);
        } else if (std.mem.eql(u8, key, "max-warmup-iters")) {
            b.max_warmup_iters = parseU64(key, v);
        } else if (std.mem.eql(u8, key, "max-time")) {
            b.max_time_ns = parseU64(key, v);
        } else if (std.mem.eql(u8, key, "max-warmup-time")) {
            b.max_warmup_time_ns = parseU64(key, v);
        } else {
            fail("KLV: unrecognized key '{s}'", .{key});
        }
    }
    return b;
}

// --- timer (mirror of rebar shared/timer) --------------------------------------

const Sample = struct { dur: u64, count: u64 };

/// Warm up, then collect samples until max-iters or max-time — whichever first.
/// `Ctx.bench()` returns the value whose count is verified; for the compile
/// model `Ctx.count()` runs untimed after each timed `bench()`.
fn runSamples(b: *const Benchmark, ctx: anytype) ![]Sample {
    const warm0 = nowNs();
    var w: u64 = 0;
    while (w < b.max_warmup_iters) : (w += 1) {
        const r = try ctx.bench();
        _ = try ctx.count(r);
        if (nowNs() - warm0 >= b.max_warmup_time_ns) break;
    }

    var samples: std.ArrayList(Sample) = .empty;
    const run0 = nowNs();
    var it: u64 = 0;
    while (it < b.max_iters) : (it += 1) {
        const t0 = nowNs();
        const r = try ctx.bench();
        const dur = nowNs() - t0;
        const n = try ctx.count(r);
        try samples.append(alloc, .{ .dur = dur, .count = n });
        if (nowNs() - run0 >= b.max_time_ns) break;
    }
    return samples.toOwnedSlice(alloc);
}

// --- models ------------------------------------------------------------------

fn compileOne(b: *const Benchmark) !Regex {
    if (b.patterns.items.len != 1)
        fail("expected exactly 1 pattern, got {d} (multi-pattern unsupported)", .{b.patterns.items.len});
    if (b.unicode)
        fail("unicode mode is not supported (zeetah is a byte-oriented engine)", .{});
    return Regex.compileWithFlags(alloc, b.patterns.items[0], .{
        .case_insensitive = b.case_insensitive,
    }) catch |err| fail("compile error: {s}", .{@errorName(err)});
}

/// Iterate the lines of `hay` exactly like bstr's `lines()`: split on '\n',
/// strip one trailing '\r', and yield a final unterminated line if non-empty.
const Lines = struct {
    hay: []const u8,
    pos: usize = 0,

    fn next(self: *Lines) ?[]const u8 {
        if (self.pos >= self.hay.len) return null;
        const start = self.pos;
        var end: usize = undefined;
        if (std.mem.indexOfScalarPos(u8, self.hay, start, '\n')) |nl| {
            end = nl;
            self.pos = nl + 1;
        } else {
            end = self.hay.len;
            self.pos = self.hay.len;
        }
        var line = self.hay[start..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        return line;
    }
};

/// Scratch allocator for per-match capture groups, reset after every match.
var scratch_buf: [1 << 20]u8 = undefined;

/// Sum of participating groups (group 0 included) over all non-overlapping
/// matches in `hay`. rebar guarantees these regexes never match empty.
fn countCaptures(re: *const Regex, hay: []const u8) !usize {
    var fba = std.heap.FixedBufferAllocator.init(&scratch_buf);
    const a = fba.allocator();
    var n: usize = 0;
    var at: usize = 0;
    while (at <= hay.len) {
        const m = (try re.capturesFrom(a, hay, at)) orelse break;
        for (m.groups) |g| {
            if (g != null) n += 1;
        }
        at = m.end;
        fba.reset();
    }
    return n;
}

const CountCtx = struct {
    re: *const Regex,
    hay: []const u8,
    fn bench(self: @This()) !usize {
        return self.re.count(self.hay);
    }
    fn count(_: @This(), r: usize) !u64 {
        return r;
    }
};

const SpansCtx = struct {
    re: *const Regex,
    hay: []const u8,
    fn bench(self: @This()) !usize {
        var sum: usize = 0;
        var it = self.re.iterator(self.hay);
        while (try it.next(alloc)) |m| sum += m.end - m.start;
        return sum;
    }
    fn count(_: @This(), r: usize) !u64 {
        return r;
    }
};

const CapturesCtx = struct {
    re: *const Regex,
    hay: []const u8,
    fn bench(self: @This()) !usize {
        return countCaptures(self.re, self.hay);
    }
    fn count(_: @This(), r: usize) !u64 {
        return r;
    }
};

const GrepCtx = struct {
    re: *const Regex,
    hay: []const u8,
    fn bench(self: @This()) !usize {
        var n: usize = 0;
        var lines: Lines = .{ .hay = self.hay };
        while (lines.next()) |line| {
            if (try self.re.isMatch(line)) n += 1;
        }
        return n;
    }
    fn count(_: @This(), r: usize) !u64 {
        return r;
    }
};

const GrepCapturesCtx = struct {
    re: *const Regex,
    hay: []const u8,
    fn bench(self: @This()) !usize {
        var n: usize = 0;
        var lines: Lines = .{ .hay = self.hay };
        while (lines.next()) |line| n += try countCaptures(self.re, line);
        return n;
    }
    fn count(_: @This(), r: usize) !u64 {
        return r;
    }
};

/// compile: time only the build; verify with an untimed full count.
const CompileCtx = struct {
    b: *const Benchmark,
    fn bench(self: @This()) !Regex {
        return compileOne(self.b);
    }
    fn count(self: @This(), re_in: Regex) !u64 {
        var re = re_in;
        defer re.deinit();
        return try re.count(self.b.haystack);
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    var quiet = false;
    var args = init.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            var buf: [128]u8 = undefined;
            const v = zeetah.version;
            const line = try std.fmt.bufPrint(&buf, "{d}.{d}.{d} ({s})\n", .{ v.major, v.minor, v.patch, build_info.rev });
            writeAll(1, line);
            return;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else {
            fail("usage: main [--version | --quiet]", .{});
        }
    }

    const raw = try readStdin();
    const b = try parseKlv(raw);

    const samples: []Sample = blk: {
        if (std.mem.eql(u8, b.model, "compile")) {
            break :blk try runSamples(&b, CompileCtx{ .b = &b });
        }
        var re = try compileOne(&b);
        defer re.deinit();
        const hay = b.haystack;
        if (std.mem.eql(u8, b.model, "count"))
            break :blk try runSamples(&b, CountCtx{ .re = &re, .hay = hay });
        if (std.mem.eql(u8, b.model, "count-spans"))
            break :blk try runSamples(&b, SpansCtx{ .re = &re, .hay = hay });
        if (std.mem.eql(u8, b.model, "count-captures"))
            break :blk try runSamples(&b, CapturesCtx{ .re = &re, .hay = hay });
        if (std.mem.eql(u8, b.model, "grep"))
            break :blk try runSamples(&b, GrepCtx{ .re = &re, .hay = hay });
        if (std.mem.eql(u8, b.model, "grep-captures"))
            break :blk try runSamples(&b, GrepCapturesCtx{ .re = &re, .hay = hay });
        fail("unrecognized benchmark model '{s}'", .{b.model});
    };

    if (!quiet) {
        var out: std.ArrayList(u8) = .empty;
        for (samples) |s| {
            var buf: [64]u8 = undefined;
            try out.appendSlice(alloc, try std.fmt.bufPrint(&buf, "{d},{d}\n", .{ s.dur, s.count }));
        }
        writeAll(1, out.items);
    }
}
