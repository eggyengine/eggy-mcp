# MCP

Let coding agents drive the Eggy editor through the [Model Context Protocol](https://modelcontextprotocol.io).

> [!WARNING]
> Early days: the MCP menu writes each agent's configuration, but the server it points them
> at isn't there yet, so agents can't connect.

## Install

In the editor, open **Edit > Plugins...** and add:

```
https://raw.githubusercontent.com/eggyengine/eggy-mcp/main/eggy.zon
```

It is a dev plugin: the editor runs it, and exported games leave it out.

## Use

The **MCP** menu on the editor's top bar writes the file each agent reads to find the editor,
into your project's folder:

| Menu row | File |
| --- | --- |
| Generate Claude Code files | `.mcp.json` |
| Generate Cursor files | `.cursor/mcp.json` |
| Generate VS Code files | `.vscode/mcp.json` |
| Generate Gemini CLI files | `.gemini/settings.json` |
| Generate Codex files | `.codex/config.toml` |

If the file is already there, only its `eggy` server is added or replaced; everything else
in it stays. Edit > Undo takes the change back.

The files point agents at `http://127.0.0.1:7755/mcp`, on your computer only. To use another
port, change **Port** in the plugin's preferences, then generate the files again.

## Requirements

- Eggy, with Zig 0.17.0 or later
