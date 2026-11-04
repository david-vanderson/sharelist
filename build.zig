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
        run_cmd.addPassthruArgs();
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

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(&b.addInstallArtifact(exe, .{}).step);

        const run_step = b.step("serve-native", "Run Native Server (no web client)");
        run_step.dependOn(&run_cmd.step);
    }

    {
        const mod = b.createModule(.{
            .root_source_file = b.path("src/make_list.zig"),
            .target = target,
            .optimize = optimize,
        });

        const exe = b.addExecutable(.{
            .name = "make-list",
            .root_module = mod,
        });

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(&b.addInstallArtifact(exe, .{}).step);

        const run_step = b.step("make-list", "New Random List");
        run_step.dependOn(&run_cmd.step);
    }

    {
        const web_target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        });

        const dvui_dep = b.dependency("dvui", .{ .target = web_target, .optimize = optimize, .backend = .web });

        const web_test = b.addExecutable(.{
            .name = "web",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = web_target,
                .optimize = optimize,
                .link_libc = false,
                .strip = if (optimize == .fast or optimize == .small) true else false,
            }),
        });

        web_test.entry = .disabled;
        web_test.root_module.addImport("dvui", dvui_dep.module("dvui_web"));

        const install_wasm = b.addInstallArtifact(web_test, .{
            .dest_dir = .{ .override = .{ .custom = "bin" } },
        });

        const cb = b.addExecutable(.{
            .name = "cacheBuster",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/cacheBuster.zig"),
                .target = b.graph.host,
            }),
        });
        const cb_run = b.addRunArtifact(cb);
        cb_run.addFileArg(b.path("src/index.html"));
        const web_js = dvui_dep.namedLazyPath("web.js");
        cb_run.addFileArg(web_js);
        cb_run.addFileArg(web_test.getEmittedBin());
        const output = cb_run.captureStdOut(.{ .basename = "index.html" });

        const compile_step = b.step("web", "Compile the Web app");
        compile_step.dependOn(&install_wasm.step);
        compile_step.dependOn(&b.addInstallFileWithDir(output, .prefix, "bin/index.html").step);
        compile_step.dependOn(&b.addInstallFileWithDir(web_js, .prefix, "bin/web.js").step);
        b.getInstallStep().dependOn(compile_step);

        const mod = b.createModule(.{
            .root_source_file = b.path("src/server.zig"),
            .target = target,
            .optimize = optimize,
        });

        const exe = b.addExecutable(.{
            .name = "server",
            .root_module = mod,
        });

        const compile_server = b.step("compile-server", "Compile Server");
        compile_server.dependOn(&b.addInstallArtifact(exe, .{}).step);
        b.getInstallStep().dependOn(compile_server);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(compile_server);

        const run_step = b.step("serve", "Run Server");
        run_step.dependOn(&run_cmd.step);
        run_cmd.addFileArg(output);
        run_cmd.addFileArg(web_js);
        run_cmd.addArtifactArg(web_test);
    }
}
