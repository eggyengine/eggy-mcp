//! The MCP tools: what each does to the editor, run on the editor's frame with its context.
const std = @import("std");
const eggy = @import("eggy");
const ToolListing = @import("server.zig").ToolListing;
const field = @import("server.zig").field;

/// A tool call being answered: the editor, the call's arguments and memory for the answer.
pub const Call = struct {
    editor: *eggy.editor.Context,
    arena: std.mem.Allocator,
    arguments: std.json.Value,

    fn string(self: Call, name: []const u8) ![]const u8 {
        return switch (field(self.arguments, name)) {
            .string => |text| text,
            else => error.MissingArgument,
        };
    }
    fn optionalString(self: Call, name: []const u8, default: []const u8) []const u8 {
        return self.string(name) catch default;
    }
    fn number(self: Call, name: []const u8, default: f64) f64 {
        return switch (field(self.arguments, name)) {
            .integer => |value| @floatFromInt(value),
            .float => |value| value,
            else => default,
        };
    }
};

const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    run: *const fn (Call) anyerror![]const u8,
};

const no_arguments = "{\"type\":\"object\",\"properties\":{}}";
const path_argument = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Relative to the project, / separated, e.g. resources/scene/level.scene.zon\"}},\"required\":[\"path\"]}";
const path_and_folder = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"folder\":{\"type\":\"string\",\"description\":\"A project-relative folder\"}},\"required\":[\"path\",\"folder\"]}";
const seconds_argument = "{\"type\":\"object\",\"properties\":{\"seconds\":{\"type\":\"number\",\"description\":\"Pause by itself after this many seconds of play, so tools can look again (0: play until paused by hand). The server is away while the game runs.\"}}}";

/// Every tool, in the order `tools/list` gives them.
pub const all = [_]Tool{
    .{ .name = "get_status", .description = "What the editor is doing: the project folder, the open scene and whether it is saved, play (editing, playing, paused), the last build a tool asked for with the end of its output, and what Undo and Redo would do.", .input_schema = no_arguments, .run = getStatus },
    .{ .name = "get_scene", .description = "The world as a scene file's ZON: each entity's name, its parent (a place in .entities, or null) and components with their fields. Top-level entities come in the Hierarchy's order. Edit it and pass it to replace_scene.", .input_schema = no_arguments, .run = getScene },
    .{ .name = "replace_scene", .description = "Replace every entity of the world with a scene's ZON (get_scene's shape), as one undo step; save_scene writes it to the open scene's file. Components are named by .type and .owner as list_component_types shows; fields left out keep their defaults. Asset fields (a Mesh's .shape = .{ .model = \"<id>\" }, textures, scenes) take the 16-hex-digit ids list_files shows. Requires editing.", .input_schema = "{\"type\":\"object\",\"properties\":{\"scene\":{\"type\":\"string\",\"description\":\"ZON: .{ .entities = .{ .{ .name = \\\"Rock\\\", .parent = null, .components = .{ .{ .type = \\\"Transform\\\", .owner = \\\"eggy\\\", .fields = .{ .position = .{ 0, 1, 0 } } } } } } }\"}},\"required\":[\"scene\"]}", .run = replaceScene },
    .{ .name = "add_to_scene", .description = "Add a scene ZON's entities after the world's, as one undo step, optionally under an entity (its place in get_scene's .entities). Parents inside the ZON are places in its own .entities. Requires editing.", .input_schema = "{\"type\":\"object\",\"properties\":{\"scene\":{\"type\":\"string\",\"description\":\"ZON in get_scene's shape\"},\"parent\":{\"type\":\"integer\",\"description\":\"Put the new top-level entities under this place in get_scene's .entities\"}},\"required\":[\"scene\"]}", .run = addToScene },
    .{ .name = "list_component_types", .description = "Every component type a scene can hold: its .type, .owner (eggy, game, or a plugin), whether it can be added, and each field with its default value as ZON.", .input_schema = no_arguments, .run = listComponentTypes },
    .{ .name = "read_console", .description = "The editor Console's latest messages, oldest first: build output, warnings and the game's own log.", .input_schema = "{\"type\":\"object\",\"properties\":{\"max_messages\":{\"type\":\"integer\",\"description\":\"At most this many (default 50)\"}}}", .run = readConsole },
    .{ .name = "list_files", .description = "The project's files under a folder (default: all), one per line: its path and, for assets under resources/, its kind and id. A model also shows the id of its geometry, which a Mesh's .shape = .{ .model = \"<id>\" } takes. Build output and caches are left out.", .input_schema = "{\"type\":\"object\",\"properties\":{\"folder\":{\"type\":\"string\",\"description\":\"A project-relative folder, e.g. resources\"}}}", .run = listFiles },
    .{ .name = "read_file", .description = "A project file's text (scenes, UI scenes, code, eggy.zon).", .input_schema = path_argument, .run = readFile },
    .{ .name = "write_file", .description = "Write a project file's text, making the folders it needs, as one undo step. Writing the game's code (src/) needs build afterwards to take effect; writing the open scene's file doesn't change the world (use replace_scene).", .input_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"contents\":{\"type\":\"string\"}},\"required\":[\"path\",\"contents\"]}", .run = writeFile },
    .{ .name = "create_folder", .description = "Make a new, uniquely named folder under a project folder, as Assets' New Folder does. write_file makes folders by itself.", .input_schema = "{\"type\":\"object\",\"properties\":{\"parent\":{\"type\":\"string\"}},\"required\":[\"parent\"]}", .run = createFolder },
    .{ .name = "rename_file", .description = "Rename a project file or folder, keeping its asset id so references follow it.", .input_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"name\":{\"type\":\"string\",\"description\":\"The new name, without folders\"}},\"required\":[\"path\",\"name\"]}", .run = renameFile },
    .{ .name = "move_file", .description = "Move a project file or folder into another folder, keeping its asset id.", .input_schema = path_and_folder, .run = moveFile },
    .{ .name = "copy_file", .description = "Copy a project file or folder into a folder, the copy getting new asset ids.", .input_schema = path_and_folder, .run = copyFile },
    .{ .name = "duplicate_file", .description = "Copy a project file or folder beside itself under a new name.", .input_schema = path_argument, .run = duplicateFile },
    .{ .name = "delete_file", .description = "Move a project file or folder to the editor's trash; undo brings it back.", .input_schema = path_argument, .run = deleteFile },
    .{ .name = "import_file", .description = "Copy a file from anywhere on this computer (an absolute path) into a project folder, as dropping it on Assets does: models (.glb, .gltf, .fbx, .obj), images, audio, fonts.", .input_schema = "{\"type\":\"object\",\"properties\":{\"source\":{\"type\":\"string\",\"description\":\"An absolute path outside the project\"},\"folder\":{\"type\":\"string\",\"description\":\"A project-relative folder, e.g. resources/models\"}},\"required\":[\"source\",\"folder\"]}", .run = importFile },
    .{ .name = "open_scene", .description = "Open a .scene.zon (unsaved changes to the open one stay in undo). Make a new scene by writing `.{ .entities = .{} }` to a new .scene.zon with write_file, then opening it.", .input_schema = path_argument, .run = openScene },
    .{ .name = "save_scene", .description = "Save the world to the open scene's file.", .input_schema = no_arguments, .run = saveScene },
    .{ .name = "set_default_scene", .description = "Make a scene the one the game starts in.", .input_schema = path_argument, .run = setDefaultScene },
    .{ .name = "undo", .description = "Edit > Undo.", .input_schema = no_arguments, .run = undo },
    .{ .name = "redo", .description = "Edit > Redo.", .input_schema = no_arguments, .run = redo },
    .{ .name = "play", .description = "Play the game from the world as it is. It pauses by itself after `seconds` (default 5) so get_scene can see where things went; then resume or stop. Stop puts the world back as it was before Play.", .input_schema = seconds_argument, .run = play },
    .{ .name = "pause", .description = "Pause play.", .input_schema = no_arguments, .run = pause },
    .{ .name = "resume", .description = "Resume paused play, pausing again after `seconds` (default 5).", .input_schema = seconds_argument, .run = resumePlay },
    .{ .name = "stop", .description = "Stop play: the world goes back to how it was before Play.", .input_schema = no_arguments, .run = stopPlay },
    .{ .name = "build", .description = "Rebuild the game after changing its code, then load it. This call returns at once: the editor is busy until the build ends, and calls made meanwhile wait. Then get_status says whether it succeeded, with the compiler's output when it failed. When the build changed the editor itself, the rebuilt editor reopens in its place: the server is away for a moment, and get_status then shows no build.", .input_schema = no_arguments, .run = build },
};

/// `all` as `tools/list` shows them.
pub const listings = blk: {
    var out: [all.len]ToolListing = undefined;
    for (all, &out) |tool, *listing| listing.* = .{ .name = tool.name, .description = tool.description, .input_schema = tool.input_schema };
    break :blk out;
};

/// Run the tool `name`, or fail with `error.UnknownTool`.
pub fn run(name: []const u8, call: Call) ![]const u8 {
    for (all) |tool| if (std.mem.eql(u8, tool.name, name)) return tool.run(call);
    return error.UnknownTool;
}

/// Why `err` stopped a call, for an agent to act on, with the Console's latest lines, which
/// say more for most editor failures.
pub fn explainFailure(call: Call, err: anyerror) []const u8 {
    const reason = switch (err) {
        error.UnknownTool => "There is no such tool; tools/list lists them.",
        error.MissingArgument => "An argument the tool needs is missing or isn't a string.",
        error.NotEditing => "The game is playing or paused: stop it first.",
        error.EditorBusy => "The editor is busy with something else (a build, a dialog or another edit): try again shortly.",
        error.NoProject => "No project is open.",
        error.OutsideProject => "Paths are relative to the project and stay inside it.",
        error.FileNotFound => "There is no such file.",
        else => "The editor refused.",
    };
    const console = call.editor.consoleText(call.arena, 5) catch "";
    return std.fmt.allocPrint(call.arena, "{s} ({t})\nThe Console's latest messages:\n{s}", .{ reason, err, console }) catch reason;
}

fn getStatus(call: Call) ![]const u8 {
    const status = try call.editor.status(call.arena);
    return std.json.Stringify.valueAlloc(call.arena, .{
        .project_folder = try call.editor.projectFolder(call.arena),
        .open_scene = status.open_scene,
        .unsaved = status.unsaved,
        .play = status.play,
        .build = status.build,
        .build_log = status.build_log,
        .undo = status.undo,
        .redo = status.redo,
    }, .{ .whitespace = .indent_2 });
}

fn getScene(call: Call) ![]const u8 {
    return call.editor.sceneText(call.arena);
}

fn replaceScene(call: Call) ![]const u8 {
    return skippedReport(call, try call.editor.replaceScene(try call.string("scene")), "Replaced the world");
}

fn addToScene(call: Call) ![]const u8 {
    const parent = call.number("parent", -1);
    const place: ?usize = if (parent >= 0) @intFromFloat(parent) else null;
    return skippedReport(call, try call.editor.addToScene(try call.string("scene"), place), "Added the entities");
}

fn skippedReport(call: Call, skipped: usize, done: []const u8) ![]const u8 {
    if (skipped == 0) return std.fmt.allocPrint(call.arena, "{s}. save_scene keeps it.", .{done});
    return std.fmt.allocPrint(call.arena, "{s}, less {d} component(s) or field(s) it couldn't put in. The Console says why:\n{s}", .{ done, skipped, try call.editor.consoleText(call.arena, @min(skipped, 20)) });
}

fn listComponentTypes(call: Call) ![]const u8 {
    return call.editor.componentTypes(call.arena);
}

fn readConsole(call: Call) ![]const u8 {
    return call.editor.consoleText(call.arena, @intFromFloat(@max(1, call.number("max_messages", 50))));
}

/// Folders of build output, caches and history, which aren't the project's own files.
const hidden_folders = [_][]const u8{ ".git", ".zig-cache", "zig-out", "zig-pkg", ".eggy" };

fn listFiles(call: Call) ![]const u8 {
    const folder = try projectPath(call.optionalString("folder", ""));
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var project = try std.Io.Dir.cwd().openDir(io, try call.editor.projectFolder(call.arena), .{});
    defer project.close(io);
    var catalog = try eggy.assets.catalog.Snapshot.read(call.arena, io, project);
    defer catalog.deinit();

    var start = if (folder.len == 0) try project.openDir(io, ".", .{ .iterate = true }) else try project.openDir(io, folder, .{ .iterate = true });
    defer start.close(io);
    var walker = try start.walkSelectively(call.arena);
    defer walker.deinit();
    var out: std.Io.Writer.Allocating = .init(call.arena);
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            const hidden = for (hidden_folders) |name| {
                if (std.mem.eql(u8, entry.basename, name)) break true;
            } else false;
            if (!hidden) try walker.enter(io, entry);
            continue;
        }
        const path = if (folder.len == 0) entry.path else try std.fmt.allocPrint(call.arena, "{s}/{s}", .{ folder, entry.path });
        try out.writer.writeAll(path);
        if (catalog.findPath(path)) |asset| {
            var id_buffer: [eggy.assets.id.key_len]u8 = undefined;
            try out.writer.print("  kind={t} id={s}", .{ asset.kind, eggy.assets.id.key(&id_buffer, asset.id) });
            if (asset.kind == .model) try out.writer.print(" geometry_id={s}", .{eggy.assets.id.key(&id_buffer, eggy.assets.id.model(asset.id))});
        }
        try out.writer.writeByte('\n');
    }
    return out.written();
}

fn readFile(call: Call) ![]const u8 {
    const path = try projectPath(try call.string("path"));
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var project = try std.Io.Dir.cwd().openDir(io, try call.editor.projectFolder(call.arena), .{});
    defer project.close(io);
    return project.readFileAlloc(io, path, call.arena, .limited(8 << 20));
}

/// `path` checked to be relative and stay inside the project.
fn projectPath(path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return error.OutsideProject;
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return error.OutsideProject;
    return std.mem.trim(u8, path, "/");
}

fn writeFile(call: Call) ![]const u8 {
    const path = try projectPath(try call.string("path"));
    try call.editor.writeFile(path, try call.string("contents"));
    return std.fmt.allocPrint(call.arena, "Wrote {s}.", .{path});
}

fn createFolder(call: Call) ![]const u8 {
    try call.editor.createFolder(try projectPath(try call.string("parent")));
    return "Made a new folder; list_files shows its name.";
}

fn renameFile(call: Call) ![]const u8 {
    try call.editor.renameFile(try projectPath(try call.string("path")), try call.string("name"));
    return "Renamed.";
}

fn moveFile(call: Call) ![]const u8 {
    try call.editor.moveFile(try projectPath(try call.string("path")), try projectPath(try call.string("folder")));
    return "Moved.";
}

fn copyFile(call: Call) ![]const u8 {
    try call.editor.copyFile(try projectPath(try call.string("path")), try projectPath(try call.string("folder")));
    return "Copied.";
}

fn duplicateFile(call: Call) ![]const u8 {
    try call.editor.duplicateFile(try projectPath(try call.string("path")));
    return "Duplicated; list_files shows the copy's name.";
}

fn deleteFile(call: Call) ![]const u8 {
    try call.editor.deleteFile(try projectPath(try call.string("path")));
    return "Moved to the trash.";
}

fn importFile(call: Call) ![]const u8 {
    const source = try call.string("source");
    if (!std.fs.path.isAbsolute(source)) return error.SourceNotAbsolute;
    try call.editor.importFile(source, try projectPath(try call.string("folder")));
    return "Imported; list_files shows its id.";
}

fn openScene(call: Call) ![]const u8 {
    try call.editor.openScene(try projectPath(try call.string("path")));
    return "Opened.";
}

fn saveScene(call: Call) ![]const u8 {
    try call.editor.saveScene();
    return "Saved.";
}

fn setDefaultScene(call: Call) ![]const u8 {
    try call.editor.setDefaultScene(try projectPath(try call.string("path")));
    return "The game now starts in it.";
}

fn undo(call: Call) ![]const u8 {
    const status = try call.editor.status(call.arena);
    const what = status.undo orelse return "Nothing to undo.";
    try call.editor.undo();
    return std.fmt.allocPrint(call.arena, "Undid {s}.", .{what});
}

fn redo(call: Call) ![]const u8 {
    const status = try call.editor.status(call.arena);
    const what = status.redo orelse return "Nothing to redo.";
    try call.editor.redo();
    return std.fmt.allocPrint(call.arena, "Redid {s}.", .{what});
}

fn play(call: Call) ![]const u8 {
    const seconds = @max(0, call.number("seconds", 5));
    try call.editor.play(seconds);
    if (seconds == 0) return "Playing until paused in the editor; this server is away until then.";
    return std.fmt.allocPrint(call.arena, "Playing; it pauses after {d} s. Calls made meanwhile can't connect: wait, then get_status.", .{seconds});
}

fn pause(call: Call) ![]const u8 {
    try call.editor.pause();
    return "Paused.";
}

fn resumePlay(call: Call) ![]const u8 {
    const seconds = @max(0, call.number("seconds", 5));
    try call.editor.resumePlay(seconds);
    return std.fmt.allocPrint(call.arena, "Resumed; it pauses after {d} s.", .{seconds});
}

fn stopPlay(call: Call) ![]const u8 {
    try call.editor.stopPlay();
    return "Stopped; the world is as it was before Play.";
}

fn build(call: Call) ![]const u8 {
    try call.editor.requestBuild();
    return "Building. get_status says how it went once it ends.";
}

test "paths stay inside the project" {
    try std.testing.expectEqualStrings("resources/a.txt", try projectPath("resources/a.txt/"));
    try std.testing.expectError(error.OutsideProject, projectPath("../secret"));
    try std.testing.expectError(error.OutsideProject, projectPath("resources/../../x"));
    try std.testing.expectError(error.OutsideProject, projectPath("/etc/passwd"));
}
