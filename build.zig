const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    {
        const mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });

        const dvui_dep = b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3 });
        mod.addImport("dvui", dvui_dep.module("dvui_sdl3"));

        const exe = b.addExecutable(.{
            .name = "sharelist",
            .root_module = mod,
        });

        const compile_step = b.step("compile", "Compile ShareList");
        compile_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        b.getInstallStep().dependOn(compile_step);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(compile_step);

        const run_step = b.step("run", "Run ShareList");
        run_step.dependOn(&run_cmd.step);
    }

    {
        const mod = b.createModule(.{
            .root_source_file = b.path("src/server.zig"),
            .target = target,
            .optimize = optimize,
        });

        const exe = b.addExecutable(.{
            .name = "server",
            .root_module = mod,
        });

        const compile_step = b.step("compile-server", "Compile Server");
        compile_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        b.getInstallStep().dependOn(compile_step);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(compile_step);

        const run_step = b.step("serve", "Run Server");
        run_step.dependOn(&run_cmd.step);
    }
}
