const std = @import("std");

// Build entry for the two *zeetah* benchmark harnesses (`zig build bench` and
// `zig build bench-dfa`). The other engines (mvzr, Rust, RE2, .NET, Python) are
// built and driven by `run_all.sh`, which remains the full cross-engine
// orchestrator — this file exists so the zeetah side has a clean `zig build`
// entry and a single, documented place where the zeetah module is resolved.
//
// Resolving the zeetah source:
//   - default: a sibling checkout at ../zig-regex/src/root.zig (measures your
//     uncommitted local changes — the usual perf-iteration flow);
//   - override the path with -Dzeetah-src=PATH or the ZEETAH_SRC env var;
//   - -Dpinned=true uses the pinned build.zig.zon `zeetah` dependency instead
//     (the reproducible / CI path — see build.zig.zon).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const pinned = b.option(
        bool,
        "pinned",
        "Use the pinned build.zig.zon `zeetah` dependency instead of a local source path",
    ) orelse false;

    const zeetah_mod = resolveZeetah(b, target, optimize, pinned);

    const harnesses = [_]struct { name: []const u8, src: []const u8, step: []const u8, desc: []const u8 }{
        .{ .name = "bench_compare", .src = "zig_bench.zig", .step = "bench", .desc = "Build+run the zeetah runtime-VM harness" },
        .{ .name = "zig_dfa_bench", .src = "zig_dfa_bench.zig", .step = "bench-dfa", .desc = "Build+run the zeetah comptime-DFA harness" },
    };

    for (harnesses) |h| {
        const exe = b.addExecutable(.{
            .name = h.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(h.src),
                .target = target,
                .optimize = optimize,
                .link_libc = true, // harnesses use std.c for timing/IO + the c allocator
                .imports = &.{.{ .name = "zeetah", .module = zeetah_mod }},
            }),
        });
        b.installArtifact(exe);

        // `zig build <step>` builds and runs the harness. The corpus path comes
        // from $CORPUS (set by run_all.sh) or defaults to ./corpus.txt.
        const run = b.addRunArtifact(exe);
        if (b.args) |args| run.addArgs(args);
        const step = b.step(h.step, h.desc);
        step.dependOn(&run.step);
    }
}

/// Produce the `zeetah` module either from a local source path (default) or
/// from the pinned package dependency (`-Dpinned`).
fn resolveZeetah(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    pinned: bool,
) *std.Build.Module {
    if (pinned) {
        // Requires the `zeetah` dependency to be declared in build.zig.zon —
        // see the instructions there. Until then this branch panics with a
        // clear "dependency not declared" message.
        const dep = b.dependency("zeetah", .{ .target = target, .optimize = optimize });
        return dep.module("zeetah");
    }

    const rel = b.option([]const u8, "zeetah-src", "Path to zeetah's src/root.zig (default: ../zig-regex/src/root.zig)") orelse
        b.graph.environ_map.get("ZEETAH_SRC") orelse
        "../zig-regex/src/root.zig";

    const abs = if (std.fs.path.isAbsolute(rel)) rel else b.pathFromRoot(rel);
    std.Io.Dir.accessAbsolute(b.graph.io, abs, .{}) catch {
        std.debug.print(
            \\
            \\error: zeetah source not found at: {s}
            \\  Point it at zeetah's src/root.zig with -Dzeetah-src=PATH or $ZEETAH_SRC.
            \\  The default expects a sibling checkout at ../zig-regex/.
            \\  Or build the reproducible path with -Dpinned=true (see build.zig.zon).
            \\
        , .{abs});
        std.process.exit(1);
    };

    return b.createModule(.{
        .root_source_file = .{ .cwd_relative = abs },
        .target = target,
    });
}
