# MCP

Let coding agents drive the Eggy editor through the [Model Context Protocol](https://modelcontextprotocol.io).

> [!WARNING]
> Early days: the plugin adds the MCP menu, but its rows don't generate files yet, and the
> server agents connect to isn't there yet.

## Install

In the editor, open **Edit > Plugins...** and add:

```
https://raw.githubusercontent.com/eggyengine/eggy-mcp/main/eggy.zon
```

It is a dev plugin: the editor runs it, and exported games leave it out.

## Use

The **MCP** menu on the editor's top bar writes the files each agent needs to find the editor,
into your project's folder:

- Generate Claude Code files
- Generate Cursor files
- Generate VS Code files
- Generate Gemini CLI files
- Generate Codex files

## Requirements

- Eggy, with Zig 0.17.0 or later
