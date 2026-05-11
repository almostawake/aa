# Personal instructions for Claude Code

## Writing Claude-read markdown
Applies to any md Claude is expected to read (this file, package `CLAUDE.md`, agent/skill docs).
- Concise, not minimal. Cut what Claude would do anyway from code and defaults; keep what teaches a principle or prevents a predictable failure.
- Prefer imperatives. Add a reason only when it changes edge-case judgment.

## Browser
chrome-devtools MCP is registered at user scope (`~/.claude.json` `mcpServers`) — available in every project, no per-project approval prompt.
- Default to chrome-devtools MCP. Use it for any UI verification or page-driving task.
- New tabs with `background: true`. Never `bringToFront`, never resize. Avoid `lighthouse_audit`, `performance_*`, `emulate`, `resize_page`, `resize_window`.
- New tab per task. Reuse an existing tab only when the user identifies one to use.
- Mark every tab you touch — and make it the **first** action on the tab, before any work or further navigation. Marking late is a known LLM failure mode; don't fall into it.
- Mark = set `document.title` to `<emoji> <existing-title>`, stripping any existing pool-emoji prefix (this is also how you take over another session's tab). Emoji from `.claude/util-my-color.mjs` (project-scoped — only present inside `if`-template clones; skip marking elsewhere).
  ```js
  // run via evaluate_script; replace E with this session's emoji
  const POOL = ['🟦','🟩','🟧','🟪','🟥','🟨'], E = '🟦';
  document.title = E + ' ' + document.title.replace(new RegExp('^(' + POOL.join('|') + ')\\s*'), '');
  ```
- Marker is page state and is lost on full-page navigation. After any `navigate_page` you call, re-mark. For tabs you'll navigate often, pass the marking JS as `navigate_page`'s `initScript` so it re-applies on each new document automatically.
- After UI changes to an app we're building, open and verify in the browser. Don't assume.
- "Open the app" defaults to the local dev server.

## Browser vs WebFetch
- Browser is default. WebFetch is fine only for stateless public docs/API lookups; never for sites we scrape or anything that needs the user's session.
- When unsure, prefer the browser. Being wrong with WebFetch (stale, blocked, JS-less) costs more than opening a tab.
