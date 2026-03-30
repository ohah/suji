const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main POC
    const exe = b.addExecutable(.{
        .name = "suji-poc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the POC");
    run_step.dependOn(&run_cmd.step);

    // Stress Test
    const stress = b.addExecutable(.{
        .name = "stress-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("stress_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(stress);

    const stress_cmd = b.addRunArtifact(stress);
    stress_cmd.step.dependOn(b.getInstallStep());
    const stress_step = b.step("stress", "Run stress test");
    stress_step.dependOn(&stress_cmd.step);

    // Full Integration Test (Rust + Go + Node)
    const full = b.addExecutable(.{
        .name = "full-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("full_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(full);

    const full_cmd = b.addRunArtifact(full);
    full_cmd.step.dependOn(b.getInstallStep());
    const full_step = b.step("full", "Run full integration test (requires Node backend)");
    full_step.dependOn(&full_cmd.step);
}
