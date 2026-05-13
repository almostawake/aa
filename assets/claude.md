# Personal instructions for Claude Code

## Writing Claude-read markdown
Applies to any md Claude is expected to read (this file, package `CLAUDE.md`, agent/skill docs).
- Concise, not minimal. Cut what Claude would do anyway from code and defaults; keep what teaches a principle or prevents a predictable failure.
- Prefer imperatives. Add a reason only when it changes edge-case judgment.

## Browser
chrome-devtools MCP is registered at user scope (`~/.claude.json` `mcpServers`) — available in every project, no per-project approval prompt.
- Default to chrome-devtools MCP. Use it for any UI verification or page-driving task.
- Starting Chrome (only if MCP says it isn't running): `open -a "Chrome with Claude Code"` — the launcher in `~/Applications/` (installed by `aa/n`) handles port 9222 and the `Chrome-Claude` profile. Never spawn `Google Chrome` by direct path with `--remote-debugging-port` or `--user-data-dir=/tmp/...`; that orphan profile loses signed-in state and MCP can't reuse it.
- New tabs with `background: true`. Never `bringToFront`, never resize. Avoid `lighthouse_audit`, `performance_*`, `emulate`, `resize_page`, `resize_window`.
- New tab per task. Reuse an existing tab only when the user identifies one to use.
- After UI changes to an app we're building, open and verify in the browser. Don't assume.
- "Open the app" defaults to the local dev server.

## Browser vs WebFetch
- Browser is default. WebFetch is fine only for stateless public docs/API lookups; never for sites we scrape or anything that needs the user's session.
- When unsure, prefer the browser. Being wrong with WebFetch (stale, blocked, JS-less) costs more than opening a tab.
