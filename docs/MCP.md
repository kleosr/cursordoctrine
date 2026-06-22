# MCP setup — Biome + Semgrep in Cursor

The cursordoctrine hooks can't install MCP servers for you — that's a Cursor-level config. This doc gives you the exact entries to paste into `~/.cursor/mcp.json` (or your project's `.cursor/mcp.json`) so the agent can run Biome and Semgrep directly during a review.

After wiring them, the agent has access to the same checks the `acceptance` field in `.scope.json` asks for, and the `stop` hook's final review can name them by command.

## Semgrep MCP (official)

Semgrep ships an MCP server in the CLI itself (`semgrep mcp`). Confirmed in [Semgrep's README](https://github.com/semgrep/semgrep#semgrep-ecosystem) — integrates with Cursor, VS Code, Windsurf, Claude Desktop.

**Prerequisite**: install Semgrep CLI once.

```bash
# macOS
brew install semgrep
# Linux / WSL
python3 -m pip install semgrep
# Or run via uvx without installing:
#   uvx semgrep ...
```

**Cursor config** (`~/.cursor/mcp.json`):

```json
{
  "mcpServers": {
    "semgrep": {
      "command": "semgrep",
      "args": ["mcp"]
    }
  }
}
```

If you installed via `uvx` and don't want Semgrep globally:

```json
{
  "mcpServers": {
    "semgrep": {
      "command": "uvx",
      "args": ["semgrep", "mcp"]
    }
  }
}
```

Optional: `semgrep login` once to unlock the Pro rules (cross-file/data-flow, ~600 high-confidence rules). Free for individual use.

Semgrep also publishes a Cursor plugin at [semgrep/cursor-plugin](https://github.com/semgrep/cursor-plugin) if you prefer the marketplace path.

## Biome (CLI; community MCP)

Biome's official surface is the CLI (`@biomejs/biome`) plus the LSP / IDE extension. There is no first-party MCP server from the Biome team at time of writing — the path most teams use is the CLI as the `acceptance` check, plus the Biome VS Code / Cursor extension for inline diagnostics.

**Prerequisite**: install Biome in your project.

```bash
npm install --save-dev --save-exact @biomejs/biome
```

**Max-strictness config** (`biome.json` in the repo root):

```json
{
  "linter": {
    "enabled": true,
    "rules": {
      "recommended": false,
      "all": true
    }
  },
  "formatter": {
    "enabled": true,
    "indentStyle": "space",
    "indentWidth": 2
  },
  "javascript": {
    "formatter": { "quoteStyle": "single" }
  }
}
```

`"all": true` turns on every Biome rule. Tune down individual rules you genuinely disagree with, but the starting position is "everything on."

**Acceptance invocation** (what the agent runs as the deterministic done-check, and what goes in `.scope.json`'s `acceptance` field):

```bash
npx @biomejs/biome check --error-on-warnings
```

Exits non-zero on any error or warning. That's "Biome at max."

**Community MCP** (optional, if you want the agent to call Biome via MCP instead of Bash): search npm for `@biomejs/mcp-server` or a community equivalent — verify the package against Biome's docs before trusting it. The CLI path above is the canonical, always-available option.

## Tying it into `.scope.json`

With both wired, a real `.scope.json` for a sidebar change looks like:

```json
{
  "prompt": "make the sidebar collapsible on mobile viewports",
  "intent": "Add mobile collapse toggle to Sidebar; wire through Dashboard layout and useSidebarState hook",
  "files": [
    "src/components/Sidebar.tsx",
    "src/components/Sidebar.module.css",
    "src/layouts/Dashboard.tsx",
    "src/App.tsx",
    "src/hooks/useSidebarState.ts"
  ],
  "acceptance": "biome check --error-on-warnings exits 0; semgrep --config auto --error exits 0; npm test -- src/components/Sidebar exits 0; opening the app at <768px shows a hamburger that toggles the sidebar"
}
```

The `stop` hook reads this and the final review asks the agent to:
1. Run the acceptance commands and confirm zero findings.
2. Reconcile `files[]` against what git sees touched (declared-but-not-touched = did you miss something? touched-but-not-declared = scope creep).

## Verifying the MCPs are wired

After editing `mcp.json`, restart Cursor. In an agent chat, ask: *"What MCPs do you have access to?"* — both `semgrep` and (if you installed a Biome MCP) `biome` should appear. If not, check the Cursor logs: the MCP panel shows connection errors per server.

## What cursordoctrine does vs. what you do

| Concern | Owner |
|---|---|
| `stop` hook reads `.scope.json`, runs final review | cursordoctrine |
| Doctrine tells the agent to write `.scope.json` with `acceptance` naming the linters | cursordoctrine |
| Installing Biome / Semgrep CLIs in the project | you (project-level) |
| Adding the MCP entries to `~/.cursor/mcp.json` | you (Cursor-level) |
| Tuning Biome rules / Semgrep configs for your stack | you (project-level) |

cursordoctrine never invokes Biome or Semgrep directly. It tells the agent the bar (max strictness, zero findings) and trusts the agent to call them via MCP or Bash.
