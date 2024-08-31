const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Module: fizz
    const fizz = b.addModule("fizz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Command: zig build check
    //
    // Run a build without completing the fool exe_build. This is a workaround, a more stable
    // solution is tracked at https://github.com/ziglang/zig/issues/18877
    const check_test = b.addTest(.{
        .root_source_file = b.path("src/golden_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    check_test.root_module.addImport("fizz", fizz);
    const check_step = b.step("check", "Check for compile errors");
    check_step.dependOn(&check_test.step);

    // Command: zig build test
    const golden_test = b.addTest(.{
        .root_source_file = b.path("src/golden_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    golden_test.root_module.addImport("fizz", fizz);
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(golden_test).step);
}
