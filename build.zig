const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
        .single_threaded = true,
        .omit_frame_pointer = optimize != .Debug,
        .stack_check = false,
        .stack_protector = false,
        .unwind_tables = .none,
        // Linking libc (libSystem on macOS) unlocks std.heap.c_allocator
        // as the gpa path in std.start; otherwise a single-threaded
        // no-libc build hits comptime unreachable. libSystem is already
        // loaded dynamically on macOS, so this is free.
        .link_libc = true,
    });

    // LTO needs LLD, and LLD can't link Mach-O on macOS in Zig 0.16. Enable
    // it only for Linux targets where LLD is the default linker. Saves
    // ~22% on Linux musl binaries.
    const enable_lto = target.result.os.tag == .linux;

    const exe = b.addExecutable(.{
        .name = "seetree",
        .root_module = module,
        .use_lld = if (enable_lto) true else null,
    });
    if (enable_lto) exe.lto = .full;
    exe.dead_strip_dylibs = true;
    exe.discard_local_symbols = true;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run seetree");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    // `zig build clean` wipes everything Zig writes into the project tree.
    // Standalone step: do not chain it into the verify graph because the
    // current `zig build` process is itself running out of `.zig-cache/`,
    // so deleting that mid-build trips the test step's manifest writer.
    // The verify pipeline below shells out to a fresh `zig build` so the
    // wipe + rebuild sequence happens cleanly across processes.
    const wipe = RemoveTree.create(b, &.{ ".zig-cache", "zig-out" });
    const clean_step = b.step("clean", "Remove .zig-cache/ and zig-out/");
    clean_step.dependOn(&wipe.step);

    // `zig build verify` is the pre-publish sanity check: wipe caches,
    // then in a fresh sub-process run tests, build ReleaseSafe, and
    // smoke-test `--version`. Each sub-`zig build` starts with no cache
    // and rebuilds from source, which is the whole point of verify.
    const sub_test = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test" });
    sub_test.step.dependOn(&wipe.step);
    sub_test.has_side_effects = true;

    const sub_build = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "--release=safe" });
    sub_build.step.dependOn(&sub_test.step);
    sub_build.has_side_effects = true;

    const sub_smoke = b.addSystemCommand(&.{ "./zig-out/bin/seetree", "--version" });
    sub_smoke.step.dependOn(&sub_build.step);
    sub_smoke.has_side_effects = true;

    const verify_step = b.step("verify", "Wipe caches, then run tests, build ReleaseSafe, smoke-test --version");
    verify_step.dependOn(&sub_smoke.step);
}

/// Build step that calls std.fs.deleteTree on each given path. POSIX-style
/// best-effort: missing entries are ignored, anything else propagates. The
/// previous std.Build had `addRemoveDirTree` baked in; 0.16 does not, so
/// this is a hand-rolled equivalent.
const RemoveTree = struct {
    step: std.Build.Step,
    paths: []const []const u8,

    fn create(b: *std.Build, paths: []const []const u8) *RemoveTree {
        const self = b.allocator.create(RemoveTree) catch @panic("OOM");
        self.* = .{
            .step = .init(.{
                .id = .remove_dir,
                .name = "wipe build artifacts",
                .owner = b,
                .makeFn = make,
            }),
            .paths = b.allocator.dupe([]const u8, paths) catch @panic("OOM"),
        };
        return self;
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
        const self: *RemoveTree = @fieldParentPtr("step", step);
        const io = step.owner.graph.io;
        const cwd = std.Io.Dir.cwd();
        for (self.paths) |p| try cwd.deleteTree(io, p);
    }
};
