# aa

One-shot macOS bootstrapper for [`if`](https://github.com/almostawake/if). Run via `curl -fsSL https://almostawake.com/n | bash`. Diagnose drift via `curl -fsSL https://almostawake.com/n | bash -s -- --check-only`.

- `n` — installer + project provisioner + diagnostics (single bash script).
- `assets/` — `~/.claude/CLAUDE.md`, `~/.claude/settings.json`, hooks, color util, VS Code config bundle.
- `n.md` — public README at almostawake.com.

Companion: **https://github.com/almostawake/if** — Firebase/SvelteKit template `n` clones, OAuth-authenticates against, provisions, and deploys.

---

# ⚠️ Chrome launcher — STOP and read this in full before touching any of:

- `aa/n` — function `_install_chrome` (the bash-in-bundle launcher template + Info.plist).
- `if/cmd-auth.mjs` — function `openBrowser`.
- The installed bundle at `~/Applications/Chrome with Claude Code.app`.

This setup is **fragile**: every line of the invocation is load-bearing, and there are at least six plausible-looking "improvements" that silently break it in ways you won't see until a fresh macOS user runs it. We've now walked each dead end at least once. Stick to the rule below.

## The rule

`if/cmd-auth.mjs` must invoke the launcher exactly like this:

```js
const launcherApp = path.join(
  process.env.HOME || '',
  'Applications/Chrome with Claude Code.app'  // ABSOLUTE path; -a rejects relative paths
);
spawn('open', ['-a', launcherApp, '--args', url], { detached: true, stdio: 'ignore' }).unref();
```

## Why each piece is load-bearing

| Piece | Role | What breaks if removed |
|---|---|---|
| `'open'` | Routes through LaunchServices, which stamps the launcher's `CFBundleIdentifier` on the bash's process group. | Direct `spawn(execPath, [url])` works for URL routing but the running Chrome appears as a separate "Google Chrome" Dock entry alongside the pinned launcher — two icons instead of one. |
| `-a launcherApp` | Tells `open` *which* bundle to launch. | `open URL` (no `-a`) just opens the URL in the system default browser — Safari on fresh macOS users — and never touches our launcher. |
| `--args` | Forces URL into the bundle's argv. | Without `--args`, `open -a APP URL` gives the bash `argc=0`. macOS then silently falls through and delivers the URL to the default URL handler (Safari on fresh users). You see Safari with the OAuth page and Chrome-Claude opens blank. The bash's `"$@"` is empty. |
| absolute path | `open -a` treats the argument as either a registered app *name* or an *absolute* path. | "Unable to find application named '…'" — even if a relative path file exists. |

## The bash launcher itself

`~/Applications/Chrome with Claude Code.app/Contents/MacOS/Chrome with Claude Code` is a plain bash script (not an `osacompile` applet, no `CFBundleURLTypes` in the Info.plist). Its contract:

1. Receive URL as `$1` (via `--args` from the caller).
2. Quit any running Chrome (graceful then forced).
3. `exec` Chrome with `--remote-debugging-port=9222 --silent-debugger-extension-api --no-first-run --user-data-dir="$HOME/Library/Application Support/Google/Chrome-Claude" "$@"` — backgrounded.
4. Poll `http://localhost:9222/json/version` until Chrome's debug port responds.
5. Write `DevToolsActivePort` to the regular Chrome profile path so chrome-devtools MCP discovers the port.
6. Exit. Chrome continues, inheriting the bash's PGID — that's what keeps the Dock attributing it to our bundle even after the bash dies.

The `"$@"` in step 3 is the only thing that gets the URL into Chrome. The `--user-data-dir` is Chrome's process-singleton key — it's what makes Chrome route the URL to our profile instead of the user's regular Chrome.

## Verify after any change

Cold-start a Chrome-less state, then test:

```sh
osascript -e 'tell application "Google Chrome" to quit' 2>/dev/null
pkill -9 -f "Google Chrome" 2>/dev/null

open -a ~/Applications/Chrome\ with\ Claude\ Code.app --args "https://news.ycombinator.com"
```

All four must hold:

1. Hacker News opens in a Chrome window.
2. The window's profile is Chrome-Claude — verify via `curl -s http://localhost:9222/json | grep ycombinator` returning a match.
3. **Dock shows one icon** labeled "Chrome with Claude Code" with a running dot. Not two icons, not "Google Chrome".
4. No Safari window opened.

If only #1 + #2 hold (two Dock icons): you've drifted to direct exec — restore `open -a --args`.
If a Safari window appeared: you've dropped `--args` — restore it.
If "Unable to find application…": path is relative or wrong — make it absolute.

## Failed approaches — do not retry

| Attempt | Commit | What breaks |
|---|---|---|
| `open -a APP URL` (no `--args`) | `if d425944` | URL `argc=0` inside bash; macOS falls through to default URL handler → Safari on fresh user, OAuth opens in wrong app. |
| Direct exec `spawn(execPath, [url])` | `if 5248ca3` | URL routes correctly, but no LaunchServices stamp → Chrome shows as a separate "Google Chrome" Dock entry. Two icons. |
| Rebuild launcher as `osacompile` applet | `aa ff66210` (reverted `52befae`) | Solves a non-existent problem (bash already receives URL via `--args` argv). Adds AppleScript + helper-script layers. |
| Declare `CFBundleURLTypes` on the bundle | not attempted | Would hijack URLs into Apple Event `kAEGetURL` delivery — which the bash can't receive. URLs dropped entirely. Strictly worse than today. |
| Pre-warm Chrome-Claude in `_prov_signin` | not attempted | Irrelevant once `--args` is in place. Would just slow `n` down. |
| `lsregister -f` after building the launcher | not attempted | `open -a` already works on freshly-built bundles by absolute path. Harmless but pointless. |

## Why this is fragile

- `--args` isn't a common idiom. Many LLMs (and humans) read `open -a APP URL` and assume it works — and it *does* work on Macs where the developer set Chrome as the default browser years ago. The bug is invisible until a fresh macOS user (Safari-default) runs it.
- `open -a APP URL` vs `open -a APP --args URL` look almost identical in code review but mean entirely different things in macOS LaunchServices.
- The bash-in-bundle has no `CFBundleURLTypes`. Every textbook says "if your .app handles URLs, declare URL types". Following that "best practice" here is exactly wrong.
- Probes can mislead. Direct probe of the bash with `open -a APP URL` shows `argc=0` and seems to confirm "URLs don't reach the bash". You'd then "fix" by switching to an applet. The real issue is that macOS silently re-delivers the URL elsewhere.

Verify with the four-point checklist on a fresh macOS user. Don't trust intuition; macOS LaunchServices behavior for custom bundles is poorly documented and surprising.

## What IS safe to change

- The bash's body (kill-Chrome flow, polling logic, `DevToolsActivePort` path) — mechanics, not contract.
- `Info.plist` fields that don't introduce URL types — bundle id, name, version, icon path.
- Dock pinning in `_configure_workspace`.
- The Chrome flags inside the bash, *except* `--user-data-dir` (path is referenced by chrome-devtools MCP and `if`'s deploy step).
