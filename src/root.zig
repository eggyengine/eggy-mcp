//! MCP: lets coding agents drive the Eggy editor through the Model Context Protocol: the editor's
//! server, and the MCP menu, which writes each agent's file pointing it at that server.
const std = @import("std");
const eggy = @import("eggy");
const agent_files = @import("agent_files.zig");
const Server = @import("server.zig").Server;
const tools = @import("tools.zig");
const Agent = agent_files.Agent;
const log = std.log.scoped(.mcp);

const instructions =
    \\This server drives the Eggy game editor that is open on this computer. Scenes are ZON:
    \\get_scene shows the world, replace_scene and add_to_scene change it (each an undo step),
    \\save_scene writes it. list_component_types shows what components take, list_files the
    \\assets' ids. The editor answers between its frames, and not while the game runs: play
    \\pauses by itself after some seconds so you can look again.
;

pub const Plugin = struct {
    /// Listening once the editor's first frame starts it; never in the runtime, which has no
    /// editor frames. The editor restarts plugins on Play, Stop and rebuilds, closing it.
    server: ?*Server = null,
    /// A port that couldn't be listened on, not tried again each frame.
    failed_port: ?u16 = null,

    pub fn deinit(self: *Plugin) void {
        const server = self.server orelse return;
        server.stop("The editor restarted its plugins (Play, Stop, undoing a scene change or a rebuild) before answering. Call get_status, then try again.");
    }

    /// Start the server, then answer each tool call queued since the last frame.
    pub fn editorUpdate(self: *Plugin, editor: *eggy.editor.Context) !void {
        const server = self.server orelse self.listen(editor) orelse return;
        while (server.nextJob()) |job| {
            var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena_state.deinit();
            const call = tools.Call{ .editor = editor, .arena = arena_state.allocator(), .arguments = job.arguments };
            // Every call and its answer, for seeing what an agent did.
            log.debug("{s} {f}", .{ job.name, std.json.fmt(job.arguments, .{}) });
            if (tools.run(job.name, call)) |text| {
                log.debug("{s} answered: {s}", .{ job.name, text });
                server.finish(job, text, false);
            } else |err| {
                const reason = tools.explainFailure(call, err);
                log.debug("{s} failed ({t}): {s}", .{ job.name, err, reason });
                server.finish(job, reason, true);
            }
        }
    }

    fn listen(self: *Plugin, editor: *eggy.editor.Context) ?*Server {
        const port = editor.app.preferences(Preferences).port;
        if (self.failed_port == port) return null;
        self.server = Server.start(port, &tools.listings, instructions) catch |err| {
            self.failed_port = port;
            std.log.err("MCP: couldn't listen on 127.0.0.1:{d} ({t}); choose another port in Preferences", .{ port, err });
            return null;
        };
        self.failed_port = null;
        return self.server;
    }

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
    _ = @import("server.zig");
    _ = tools;
}
