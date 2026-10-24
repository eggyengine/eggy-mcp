//! MCP: lets coding agents drive the Eggy editor through the Model Context Protocol. For now, the
//! MCP menu, which writes each agent's file pointing it at the editor's server.
const std = @import("std");
const eggy = @import("eggy");
const agent_files = @import("agent_files.zig");
const Agent = agent_files.Agent;

pub const Plugin = struct {
    pub const Preferences = struct {
        port: u16 = 7755,

        pub const descriptions = .{
            .port = "The port the editor's MCP server listens on, on this computer only. Generate the agents' files again after changing it.",
        };
    };

    pub const editor_menus = [_]eggy.plugins.EditorMenu{.{ .key = "mcp", .title = "MCP", .items = &.{
        .{ .key = "claude_code", .title = "Generate Claude Code files" },
        .{ .key = "cursor", .title = "Generate Cursor files" },
        .{ .key = "vs_code", .title = "Generate VS Code files" },
        .{ .key = "gemini_cli", .title = "Generate Gemini CLI files" },
        .{ .key = "codex", .title = "Generate Codex files" },
    } }};

    comptime {
        std.debug.assert(editor_menus[0].items.len == @typeInfo(Agent).@"enum".field_names.len);
    }

    pub fn editorBarAction(self: *Plugin, target: eggy.plugins.EditorBarTarget, editor: *eggy.editor.Context) !void {
        _ = self;
        const row = switch (target) {
            .menu_item => |row| row,
            else => return,
        };
        const agent: Agent = @fromBackingInt(@intCast(row.item));
        generate(editor, agent) catch |err| {
            std.log.err("MCP: couldn't write {s} for {s}: {t}", .{ agent.path(), agent.title(), err });
            return err;
        };
    }
};

/// Write `agent`'s file into the project, keeping what else it holds; one undo step.
fn generate(editor: *eggy.editor.Context, agent: Agent) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // What the file holds now, if anything.
    const folder = try editor.projectFolder(arena);
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const existing: ?[]const u8 = blk: {
        var dir = try std.Io.Dir.cwd().openDir(io, folder, .{});
        defer dir.close(io);
        break :blk dir.readFileAlloc(io, agent.path(), arena, .limited(16 << 20)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    };

    const url = try agent_files.serverUrl(arena, editor.app.preferences(Plugin.Preferences).port);
    try editor.writeFile(agent.path(), try agent_files.configure(arena, agent, existing, url));
    std.log.info("MCP: {s} now points {s} at {s}", .{ agent.path(), agent.title(), url });
}

test {
    _ = agent_files;
}
