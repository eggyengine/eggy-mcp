//! MCP: lets coding agents drive the Eggy editor through the Model Context Protocol. For now, the
//! MCP menu on the editor's top bar.
const std = @import("std");
const eggy = @import("eggy");

/// The agents the MCP menu writes configuration files for, in menu order.
const Agent = enum { claude_code, cursor, vs_code, gemini_cli, codex };

pub const Plugin = struct {
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

    // ponytail: rows only log; writing each agent's files waits on the MCP server and an undoable file write in eggy.editor.
    pub fn editorBarAction(self: *Plugin, target: eggy.plugins.EditorBarTarget, editor: *eggy.editor.Context) !void {
        _ = self;
        _ = editor;
        const row = switch (target) {
            .menu_item => |row| row,
            else => return,
        };
        const agent: Agent = @fromBackingInt(@intCast(row.item));
        std.log.info("MCP: generating {t} files isn't written yet", .{agent});
    }
};
