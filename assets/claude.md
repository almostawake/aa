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
- Mark every tab you touch — and make it the **first** action on the tab, before any work or further navigation. Marking late is a known LLM failure mode; don't fall into it.
- Mark = set `document.title` to `<emoji> <existing-title>`, stripping any existing pool-emoji prefix (this is also how you take over another session's tab). Emoji from `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/util-my-color.mjs` (user-scoped — works in every project).
- Apply the marker via the snippet below. It installs a `MutationObserver` on `<head>` so the mark survives any title overwrite *within* a document (static `<title>` in HTML shells, `<svelte:head>` updates, Vite HMR style swaps, etc.). The observer dies on full-document navigation though, so you have to re-install it whenever that happens.
- Apply rules — follow these every time:
  1. **After `new_page`** (which doesn't accept `initScript`): immediately `evaluate_script` the snippet on the new tab. First action, before any work.
  2. **When calling `navigate_page`**: pass the snippet as `initScript`. The MCP unregisters it after the navigation completes (it is *not* persistent — confirmed in `chrome-devtools-mcp/build/src/tools/pages.js:289–294`), so each `navigate_page` call needs `initScript` again.
  3. **After any full-document navigation you didn't drive via `navigate_page`** — page-initiated `window.location.href` (e.g. magic-link auto-follow), OAuth/SSO redirects, hard refreshes, meta-refresh — the observer is gone. Re-inject via `evaluate_script` as the *first* action on the resulting page.
  4. **Snapshot-driven recovery**: every page snapshot shows `RootWebArea "<title>"`. If the title is missing your pool-emoji prefix, you missed a re-injection — re-`evaluate_script` the snippet before doing anything else on that tab.
  ```js
  // replace E with this session's emoji
  (() => {
    const POOL = ['🟦','🟩','🟧','🟪','🟥','🟨'], E = '🟦';
    const STRIP = new RegExp('^(' + POOL.join('|') + ')\\s*');
    const apply = () => {
      const want = E + ' ' + document.title.replace(STRIP, '');
      if (document.title !== want) document.title = want;
    };
    const setup = () => {
      apply();
      new MutationObserver(apply).observe(document.head, { childList: true, subtree: true, characterData: true });
    };
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', setup, { once: true });
    else setup();
  })();
  ```
- After UI changes to an app we're building, open and verify in the browser. Don't assume.
- "Open the app" defaults to the local dev server.

## Browser vs WebFetch
- Browser is default. WebFetch is fine only for stateless public docs/API lookups; never for sites we scrape or anything that needs the user's session.
- When unsure, prefer the browser. Being wrong with WebFetch (stale, blocked, JS-less) costs more than opening a tab.
