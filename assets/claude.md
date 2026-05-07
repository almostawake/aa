# Personal instructions for Claude Code

## Writing Claude-read markdown
Applies to any md Claude is expected to read (this file, package `CLAUDE.md`, agent/skill docs).
- Be terse. Only write what Claude wouldn't naturally do from code and defaults.
- Prefer imperatives. Add a reason only when it changes edge-case judgment.

## Browser access
- After any UI change to an app we're building, open it in the browser and verify. Never assume a UI change works.
- For any site we're scraping or will scrape, use the browser where possible rather than WebFetch.

## Browser vs WebFetch
- Default to the browser when available. WebFetch/WebSearch is acceptable for stateless public lookups: docs, API references, quick factual checks where no session or JS rendering matters.
- When unsure, prefer the browser. Being wrong with WebFetch (stale, blocked, JS-less) costs more than opening a tab.
