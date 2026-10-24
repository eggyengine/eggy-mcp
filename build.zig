const std = @import("std");
const eggy = @import("eggy");

/// Publish the MCP plugin (`src/root.zig`) as module `eggy_mcp`, and `zig build test` its tests.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const plugin = eggy.addPlugin(b, .{
        .name = "eggy_mcp",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // LLVM links the tests: Zig's own linker rejects the .sframe sections in newer glibc.
    const test_step = b.step("test", "Run the plugin's tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = plugin, .use_llvm = true })).step);
}
