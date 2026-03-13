const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run unit tests");

    // Create root module for the shared library
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/gterm.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add Emacs module header include path.
    // Detected at build time; falls back to /Applications/Emacs.app.
    const emacs_include = b.option(
        []const u8,
        "emacs-include",
        "Path to directory containing emacs-module.h",
    ) orelse "/Applications/Emacs.app/Contents/Resources/include";

    lib_mod.addSystemIncludePath(.{ .cwd_relative = emacs_include });

    // Add ghostty-vt dependency.
    // We disable xcframework/macos-app/exe to avoid requiring full Xcode.
    if (b.lazyDependency("ghostty", .{
        .@"emit-xcframework" = false,
        .@"emit-macos-app" = false,
        .@"emit-exe" = false,
    })) |dep| {
        lib_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    // Build the Emacs dynamic module as a shared library (.dylib / .so)
    const lib = b.addLibrary(.{
        .name = "gterm-module",
        .linkage = .dynamic,
        .root_module = lib_mod,
    });

    b.installArtifact(lib);

    // Tests
    const tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
