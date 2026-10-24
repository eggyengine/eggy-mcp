//! The configuration file each coding agent reads to find the editor's MCP server, merged into
//! whatever the project's copy already holds so the agent's other servers and settings stay.
const std = @import("std");

/// The agents the MCP menu writes files for, in menu order.
pub const Agent = enum {
    claude_code,
    cursor,
    vs_code,
    gemini_cli,
    codex,

    /// The file, relative to the project's folder.
    pub fn path(self: Agent) []const u8 {
        return switch (self) {
            .claude_code => ".mcp.json",
            .cursor => ".cursor/mcp.json",
            .vs_code => ".vscode/mcp.json",
            .gemini_cli => ".gemini/settings.json",
            .codex => ".codex/config.toml",
        };
    }

    pub fn title(self: Agent) []const u8 {
        return switch (self) {
            .claude_code => "Claude Code",
            .cursor => "Cursor",
            .vs_code => "VS Code",
            .gemini_cli => "Gemini CLI",
            .codex => "Codex",
        };
    }
};

/// What the server is called in each file.
const server_name = "eggy";

/// The editor's MCP server address on `port`.
pub fn serverUrl(arena: std.mem.Allocator, port: u16) ![]const u8 {
    return std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/mcp", .{port});
}

/// `existing` (the file's text, or null without one) with the `eggy` server at `url` set, in
/// `arena`. Fails with `error.NotAnObject` when a JSON file holds something other than an object
/// where the servers go, rather than overwriting it.
pub fn configure(arena: std.mem.Allocator, agent: Agent, existing: ?[]const u8, url: []const u8) ![]const u8 {
    if (agent == .codex) return configureToml(arena, existing orelse "", url);

    var root: std.json.Value = if (existing) |text| (if (std.mem.trim(u8, text, " \t\r\n").len == 0)
        .{ .object = .empty }
    else
        try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{})) else .{ .object = .empty };
    if (root != .object) return error.NotAnObject;

    // Each agent's own spelling of an HTTP server.
    var server: std.json.ObjectMap = .empty;
    switch (agent) {
        .claude_code, .vs_code => {
            try server.put(arena, "type", .{ .string = "http" });
            try server.put(arena, "url", .{ .string = url });
        },
        .cursor => try server.put(arena, "url", .{ .string = url }),
        .gemini_cli => try server.put(arena, "httpUrl", .{ .string = url }),
        .codex => unreachable,
    }

    const servers_key = if (agent == .vs_code) "servers" else "mcpServers";
    const servers = try root.object.getOrPut(arena, servers_key);
    if (!servers.found_existing) servers.value_ptr.* = .{ .object = .empty };
    if (servers.value_ptr.* != .object) return error.NotAnObject;
    try servers.value_ptr.object.put(arena, server_name, .{ .object = server });

    const text = try std.json.Stringify.valueAlloc(arena, root, .{ .whitespace = .indent_2 });
    return std.mem.concat(arena, u8, &.{ text, "\n" });
}

/// Codex's TOML: the `[mcp_servers.eggy]` table replaced (up to the next table), or added.
fn configureToml(arena: std.mem.Allocator, existing: []const u8, url: []const u8) ![]const u8 {
    const header = "[mcp_servers." ++ server_name ++ "]";
    const table = try std.fmt.allocPrint(arena, header ++ "\nurl = \"{s}\"\n", .{url});

    // Where the old table starts and ends, by whole lines.
    var start: ?usize = null;
    var end = existing.len;
    var at: usize = 0;
    while (at < existing.len) {
        const line_end = std.mem.indexOfScalarPos(u8, existing, at, '\n') orelse existing.len;
        const line = std.mem.trim(u8, existing[at..line_end], " \t\r");
        if (start == null) {
            if (std.mem.eql(u8, line, header)) start = at;
        } else if (line.len > 0 and line[0] == '[') {
            end = at;
            break;
        }
        at = line_end + 1;
    }

    if (start) |from| return std.mem.concat(arena, u8, &.{ existing[0..from], table, if (end < existing.len) "\n" else "", existing[end..] });
    const separator = if (existing.len == 0) "" else if (std.mem.endsWith(u8, existing, "\n")) "\n" else "\n\n";
    return std.mem.concat(arena, u8, &.{ existing, separator, table });
}

test "a new Claude Code file holds just the eggy server" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        \\{
        \\  "mcpServers": {
        \\    "eggy": {
        \\      "type": "http",
        \\      "url": "http://127.0.0.1:7755/mcp"
        \\    }
        \\  }
        \\}
        \\
    , try configure(arena.allocator(), .claude_code, null, "http://127.0.0.1:7755/mcp"));
}

test "VS Code's other servers and settings stay when eggy is added" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try configure(arena.allocator(), .vs_code,
        \\{ "inputs": [], "servers": { "github": { "type": "http", "url": "https://example.com" } } }
    , "http://127.0.0.1:1/mcp");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{});
    try std.testing.expect(parsed.object.get("inputs") != null);
    const servers = parsed.object.get("servers").?.object;
    try std.testing.expect(servers.get("github") != null);
    try std.testing.expectEqualStrings("http://127.0.0.1:1/mcp", servers.get("eggy").?.object.get("url").?.string);
}

test "a JSON file that isn't an object is refused, not overwritten" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.NotAnObject, configure(arena.allocator(), .cursor, "[1, 2]", "u"));
    try std.testing.expectError(error.NotAnObject, configure(arena.allocator(), .gemini_cli, "{ \"mcpServers\": 3 }", "u"));
}

test "Codex's eggy table is replaced in place and other tables stay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("[mcp_servers.eggy]\nurl = \"new\"\n", try configure(a, .codex, null, "new"));
    try std.testing.expectEqualStrings(
        \\model = "o3"
        \\
        \\[mcp_servers.eggy]
        \\url = "new"
        \\
        \\[mcp_servers.other]
        \\command = "x"
        \\
    , try configure(a, .codex,
        \\model = "o3"
        \\
        \\[mcp_servers.eggy]
        \\url = "old"
        \\
        \\[mcp_servers.other]
        \\command = "x"
        \\
    , "new"));
    try std.testing.expectEqualStrings("model = \"o3\"\n\n[mcp_servers.eggy]\nurl = \"new\"\n", try configure(a, .codex, "model = \"o3\"\n", "new"));
}
