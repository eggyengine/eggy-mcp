//! The MCP server: JSON-RPC over Streamable HTTP on 127.0.0.1, each tool call queued for the
//! editor's frame to answer, as editor calls are only valid there.
const std = @import("std");
const Io = std.Io;

/// The protocol versions this server speaks, newest first: `initialize` echoes the client's when
/// it is one of these, else offers the newest.
const protocol_versions = [_][]const u8{ "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05" };

/// A tool call waiting for the editor's frame. The connection that queued it owns it; the frame
/// sets `text` and `failed`, then `done`.
pub const Job = struct {
    name: []const u8,
    /// The call's `arguments`: an object, or null when it gave none.
    arguments: std.json.Value,
    /// Owned with `std.heap.smp_allocator`, freed by the connection.
    text: []u8 = &.{},
    failed: bool = false,
    done: Io.Event = .unset,
};

/// A tool, as `tools/list` shows it.
pub const ToolListing = struct { name: []const u8, description: []const u8, input_schema: []const u8 };

pub const Server = struct {
    threaded: Io.Threaded,
    listener: Io.net.Server,
    /// The accept loop and each connection's task.
    tasks: Io.Group = .init,
    /// Guards `jobs`.
    mutex: Io.Mutex = .init,
    jobs: std.ArrayList(*Job) = .empty,
    /// Connections whose job is done but whose reply isn't sent yet; `stop` lets them finish.
    replying: std.atomic.Value(usize) = .init(0),
    /// The `tools/list` result.
    tools_json: []u8,
    instructions: []const u8,

    const gpa = std.heap.smp_allocator;

    /// Listen on 127.0.0.1:`port` and accept in the background. `tools` and `instructions` are
    /// read now; `instructions` must outlive the server. Fails with `error.AddressInUse` when
    /// something, such as another editor, already listens there.
    pub fn start(port: u16, tools: []const ToolListing, instructions: []const u8) !*Server {
        const self = try gpa.create(Server);
        errdefer gpa.destroy(self);
        self.* = .{ .threaded = .init(gpa, .{}), .listener = undefined, .tools_json = try listJson(tools), .instructions = instructions };
        errdefer gpa.free(self.tools_json);
        errdefer self.threaded.deinit();
        const io = self.threaded.io();

        const address = try Io.net.IpAddress.parseIp4("127.0.0.1", port);
        // Reusing the address lets a restarted server listen past its old connections, but on
        // POSIX it also lets a second editor share the port, and agents then reach either one.
        // ponytail: two editors starting at the same instant can both pass this; take a lock file if that happens.
        if (address.connect(io, .{ .mode = .stream })) |other| {
            other.close(io);
            return error.AddressInUse;
        } else |_| {}
        self.listener = try address.listen(io, .{ .reuse_address = true });
        errdefer self.listener.socket.close(io);
        try self.tasks.concurrent(io, acceptLoop, .{self});
        return self;
    }

    /// Answer every queued call as failed with `reason`, let replies already answered go out, then
    /// close the server and free it.
    pub fn stop(self: *Server, reason: []const u8) void {
        const io = self.threaded.io();
        while (self.nextJob()) |job| self.finish(job, reason, true);

        // Up to half a second for answered calls (Play's own) to reach their clients.
        var waited_ms: u32 = 0;
        while (self.replying.load(.acquire) > 0 and waited_ms < 500) : (waited_ms += 5) {
            Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(5), .clock = .awake }, io) catch break;
        }

        self.tasks.cancel(io);
        self.listener.socket.close(io);
        self.jobs.deinit(gpa);
        gpa.free(self.tools_json);
        self.threaded.deinit();
        gpa.destroy(self);
    }

    /// The oldest queued call, now the caller's to `finish`; null when none is waiting.
    pub fn nextJob(self: *Server) ?*Job {
        const io = self.threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.jobs.items.len == 0) return null;
        return self.jobs.orderedRemove(0);
    }

    /// Answer `job` with `text` (copied), an error result when `failed`.
    pub fn finish(self: *Server, job: *Job, text: []const u8, failed: bool) void {
        job.text = gpa.dupe(u8, text) catch @constCast("The editor ran out of memory answering this call.");
        job.failed = failed;
        _ = self.replying.fetchAdd(1, .acq_rel);
        job.done.set(self.threaded.io());
    }

    fn acceptLoop(self: *Server) Io.Cancelable!void {
        const io = self.threaded.io();
        while (true) {
            const stream = self.listener.accept(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    std.log.warn("MCP: couldn't accept a connection: {t}", .{err});
                    continue;
                },
            };
            self.tasks.concurrent(io, serveConnection, .{ self, stream }) catch {
                stream.close(io);
                std.log.warn("MCP: too many connections at once; one was turned away", .{});
            };
        }
    }

    /// One HTTP request, then the connection closes: agents open one per call.
    fn serveConnection(self: *Server, stream: Io.net.Stream) Io.Cancelable!void {
        const io = self.threaded.io();
        defer stream.close(io);
        var in_buffer: [16 * 1024]u8 = undefined;
        var out_buffer: [16 * 1024]u8 = undefined;
        var reader = stream.reader(io, &in_buffer);
        var writer = stream.writer(io, &out_buffer);
        var http = std.http.Server.init(&reader.interface, &writer.interface);
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        self.serveRequest(&http, arena_state.allocator()) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // A client that went away or sent something that isn't HTTP.
            else => {},
        };
    }

    fn serveRequest(self: *Server, http: *std.http.Server, arena: std.mem.Allocator) !void {
        var request = try http.receiveHead();

        // Only pages on this computer may call: another site's script in a browser can reach
        // 127.0.0.1 too, and says where it came from.
        var headers = request.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "origin") and !isLocalOrigin(header.value))
                return request.respond("Only this computer may use the editor's MCP server.\n", .{ .status = .forbidden, .keep_alive = false });
        }
        // No server-sent events: everything is answered in the POST's reply.
        if (request.head.method != .POST)
            return request.respond("", .{ .status = .method_not_allowed, .keep_alive = false, .extra_headers = &.{.{ .name = "allow", .value = "POST" }} });

        var body_buffer: [4096]u8 = undefined;
        const body_reader = try request.readerExpectContinue(&body_buffer);
        const body = try body_reader.allocRemaining(arena, .limited(64 << 20));
        const reply = try self.answer(arena, body) orelse
            return request.respond("", .{ .status = .accepted, .keep_alive = false });
        try request.respond(reply, .{ .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
    }

    /// The JSON-RPC reply to `body`, or null for a notification.
    fn answer(self: *Server, arena: std.mem.Allocator, body: []const u8) !?[]const u8 {
        const message = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch
            return try errorReply(arena, .null, -32700, "The request isn't JSON.");
        if (message != .object) return try errorReply(arena, .null, -32600, "Send one JSON-RPC request per POST.");
        const id = message.object.get("id") orelse return null;
        const method = switch (message.object.get("method") orelse .null) {
            .string => |text| text,
            else => return try errorReply(arena, id, -32600, "The request has no method."),
        };
        const params = message.object.get("params") orelse .null;

        if (std.mem.eql(u8, method, "initialize")) {
            const asked = switch (field(params, "protocolVersion")) {
                .string => |text| text,
                else => "",
            };
            const version = for (protocol_versions) |known| {
                if (std.mem.eql(u8, known, asked)) break known;
            } else protocol_versions[0];
            return try resultReply(arena, id, try std.json.Stringify.valueAlloc(arena, .{
                .protocolVersion = version,
                .capabilities = .{ .tools = .{ .listChanged = false } },
                .serverInfo = .{ .name = "eggy", .title = "Eggy editor", .version = "0.3.0" },
                .instructions = self.instructions,
            }, .{}));
        }
        if (std.mem.eql(u8, method, "ping")) return try resultReply(arena, id, "{}");
        if (std.mem.eql(u8, method, "tools/list")) return try resultReply(arena, id, self.tools_json);
        if (std.mem.eql(u8, method, "tools/call")) {
            const name = switch (field(params, "name")) {
                .string => |text| text,
                else => return try errorReply(arena, id, -32602, "tools/call needs a tool name."),
            };
            var job = Job{ .name = name, .arguments = field(params, "arguments") };
            try self.queueAndWait(&job);
            defer {
                gpa.free(job.text);
                _ = self.replying.fetchSub(1, .acq_rel);
            }
            const Content = struct { type: []const u8 = "text", text: []const u8 };
            return try resultReply(arena, id, try std.json.Stringify.valueAlloc(arena, .{
                .content = [_]Content{.{ .text = job.text }},
                .isError = job.failed,
            }, .{}));
        }
        return try errorReply(arena, id, -32601, "The editor's MCP server has no such method.");
    }

    /// Queue `job` for the editor's frame and wait for its answer. Cancelled (the server
    /// stopping), it takes the job back off the queue.
    fn queueAndWait(self: *Server, job: *Job) !void {
        const io = self.threaded.io();
        {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            try self.jobs.append(gpa, job);
        }
        job.done.wait(io) catch |err| {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            for (self.jobs.items, 0..) |queued, i| if (queued == job) {
                _ = self.jobs.orderedRemove(i);
                break;
            };
            return err;
        };
    }
};

/// `object`'s `name`, or null when it isn't an object or has none.
pub fn field(object: std.json.Value, name: []const u8) std.json.Value {
    return switch (object) {
        .object => |map| map.get(name) orelse .null,
        else => .null,
    };
}

fn isLocalOrigin(origin: []const u8) bool {
    for ([_][]const u8{ "http://localhost", "http://127.0.0.1", "https://localhost", "https://127.0.0.1" }) |local| {
        if (!std.mem.startsWith(u8, origin, local)) continue;
        const rest = origin[local.len..];
        if (rest.len == 0 or rest[0] == ':') return true;
    }
    return false;
}

fn listJson(tools: []const ToolListing) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"tools\":[");
    for (tools, 0..) |tool, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{{\"name\":{f},\"description\":{f},\"inputSchema\":{s}}}", .{ std.json.fmt(tool.name, .{}), std.json.fmt(tool.description, .{}), tool.input_schema });
    }
    try writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn resultReply(arena: std.mem.Allocator, id: std.json.Value, result_json: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"result\":{s}}}", .{ std.json.fmt(id, .{}), result_json });
}

fn errorReply(arena: std.mem.Allocator, id: std.json.Value, code: i32, message: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"error\":{{\"code\":{d},\"message\":{f}}}}}", .{ std.json.fmt(id, .{}), code, std.json.fmt(message, .{}) });
}

test "only pages on this computer count as local" {
    try std.testing.expect(isLocalOrigin("http://localhost:3000"));
    try std.testing.expect(isLocalOrigin("http://127.0.0.1"));
    try std.testing.expect(!isLocalOrigin("http://localhost.evil.com"));
    try std.testing.expect(!isLocalOrigin("https://example.com"));
}

test "a second server is refused the port, and a restarted one gets it back" {
    const port = 47755;
    const first = try Server.start(port, &.{}, "");
    try std.testing.expectError(error.AddressInUse, Server.start(port, &.{}, ""));
    first.stop("");
    const again = try Server.start(port, &.{}, "");
    again.stop("");
}

test "the tool list is MCP's shape" {
    const json = try listJson(&.{.{ .name = "undo", .description = "Say \"undo\"", .input_schema = "{\"type\":\"object\"}" }});
    defer std.heap.smp_allocator.free(json);
    try std.testing.expectEqualStrings("{\"tools\":[{\"name\":\"undo\",\"description\":\"Say \\\"undo\\\"\",\"inputSchema\":{\"type\":\"object\"}}]}", json);
}
