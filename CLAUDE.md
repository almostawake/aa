# aa

One-shot macOS bootstrapper that sets up a fresh Mac (or fresh macOS user) for the [`if`](https://github.com/almostawake/if) project template — Claude Code, VS Code, Chrome wired up for chrome-devtools MCP, Node, git, gh, jq, java. Run via `curl -fsSL https://almostawake.com/n | bash`. Update an existing install via `curl -fsSL https://almostawake.com/update | bash`.

- `n` — the installer + project provisioner (single bash script, ~2000 lines).
- `update` — refreshes per-user assets that `n` only writes on first install (CLAUDE.md, VS Code settings, etc.).
- `assets/` — files served from `almostawake.com/assets/` and fetched by `n` / `update`. Includes the user-scope `~/.claude/CLAUDE.md`, `~/.claude/settings.json`, `hook-session-namer.mjs`, `util-my-color.mjs`, the VS Code config bundle, and the welcome-modal `state.vscdb` seed.
- `n.md` — the public-facing README at almostawake.com.

The companion project this targets: **https://github.com/almostawake/if** — a Firebase/SvelteKit template for small personal automations. `n` ends by cloning it, running its `cmd-auth.mjs` for Google OAuth, provisioning a GCP/Firebase project, and deploying.

---

## Chrome launcher — read this before touching `_install_chrome` OR `if/cmd-auth.mjs`

`n` builds `~/Applications/Chrome with Claude Code.app`. It is a `.app` bundle whose `Contents/MacOS/Chrome with Claude Code` is a **plain bash script**, not a Mach-O `osacompile` applet. Don't change that.

The bash's job: ensure Chrome runs with `--remote-debugging-port=9222 --user-data-dir=$HOME/Library/Application\ Support/Google/Chrome-Claude` so chrome-devtools MCP can attach. It forwards any URL it receives in argv to Chrome via `"$@"`.

### The one rule

**`if/cmd-auth.mjs` calls `open -a APP --args URL`. The `--args` flag is load-bearing.**

```js
// cmd-auth.mjs (correct shape)
const launcherApp = path.join(
  process.env.HOME || '',
  'Applications/Chrome with Claude Code.app'
);
spawn('open', ['-a', launcherApp, '--args', url], { detached: true, stdio: 'ignore' }).unref();
```

Two things must hold at once:

1. **URL must reach the bash via argv.** `--args` does this. Without `--args`, `open -a APP URL` drops the URL on the floor (argc=0 inside the bash) and macOS quietly delivers it to the default URL handler instead — Safari on a fresh macOS user.
2. **Launch must go through LaunchServices.** `open -a` does this. Direct exec of the bash (`spawn(execPath, [url])`) also routes the URL correctly but loses LaunchServices' bundle-id stamp, so the Dock shows two icons (pinned launcher idle + a separate "Google Chrome" running) instead of one merged "Chrome with Claude Code" entry.

`open -a APP --args URL` is the only invocation that gives both. Skip the rest of this file unless you're tempted to change something.

---

## The full saga (so the next LLM doesn't go around the loop)

Pinning this here because we burned a multi-hour session re-deriving it. The launcher and `cmd-auth.mjs` have a history of "this looks wrong, let me improve it" changes that all turn out to break the working setup. Each of these is documented with what we tried and why it fails.

### Failed approach 1 — `open -a APP URL` (no `--args`)

`if` commit `d425944` (2026-05-07). The intent was right ("route the URL to a specific bundle") but the form is wrong. `open -a BUNDLE URL` on a bash-in-bundle that doesn't declare `CFBundleURLTypes` does **not** pass URL via argv. Probe inside the bash and `argc=0`. macOS LaunchServices does two things in parallel instead:

1. Launches the bundle (bash starts with empty argv, runs its kill-Chrome + spawn dance, `"$@"` is empty so Chrome opens with no URL).
2. Falls through to the **default URL handler** for the scheme and delivers the URL there via `kAEGetURL` Apple Event.

On a Mac where Chrome is already the default browser, step 2 sends the URL to Chrome, Chrome's `--user-data-dir` singleton routes it to the Chrome-Claude instance the launcher just brought up, and it all works *by accident* — not through the path the bash was designed for.

**On a fresh macOS user, the default browser is Safari.** Step 2 sends the OAuth URL to Safari. The launcher's bash also opens Chrome-Claude blank. You see Safari with the OAuth page and a blank Chrome window — the user-visible bug.

Tested directly on the fresh-VM user: `open ~/Applications/Chrome\ with\ Claude\ Code.app https://news.ycombinator.com` opened Safari with HN and Chrome with a blank tab.

The fix: add `--args` (see "The one rule" above).

### Failed approach 2 — direct exec, no `open` at all

`if` commit `5248ca3` (2026-05-12). `spawn(execPath, [url])` straight from Node, no LaunchServices in the picture.

URL routing works perfectly — the bash gets URL as `$1`, forwards to Chrome. No fall-through, no Safari, no race.

But: because we never went through `open -a`, LaunchServices never stamps the launcher's bundle id on the bash's process context. Chrome inherits an unstamped PGID. The Dock has nothing to attribute the running Chrome to except `com.google.Chrome` directly, so you get two icons in the Dock — pinned "Chrome with Claude Code" (idle) and "Google Chrome" (running). Cosmetic, not functional.

`open -a APP --args URL` fixes the cosmetic by re-introducing LaunchServices to the launch, without re-introducing the URL-drop bug (because `--args` forces argv passing).

### Failed approach 3 — rebuild the launcher as an `osacompile` applet

`aa` commit `ff66210` (reverted in `52befae`). Premise was the bash couldn't receive URLs, so an `on open location` AppleScript applet was needed. That premise was wrong — the bash *can* receive URLs, just not via `open -a` without `--args`. Don't rebuild as an applet. Adds layers, solves nothing.

### Failed approach 4 — pre-warm Chrome-Claude in `_prov_signin`

Proposed when the cold-start race looked like the culprit. The race exists but is irrelevant once `cmd-auth.mjs` uses `open -a --args` (URL goes to argv, doesn't depend on what's running). Don't add a pre-warm step.

### Failed approach 5 — declare `CFBundleURLTypes` on the launcher bundle

Would hijack URLs into the bash via Apple Event `kAEGetURL` — which a bash script can't receive (it's not an Apple-Event-aware app). URLs get dropped entirely. Strictly worse. Don't.

### Failed approach 6 — `lsregister -f` after building the launcher

Looked plausible as a "force LaunchServices to index the new bundle". Doesn't help; `open -a` works on freshly-built bundles by absolute path regardless. Harmless if added, but not necessary.

### Path gotcha

`open -a` rejects relative paths to bundles ("Unable to find application named '…'") because LaunchServices treats the argument as either a registered app *name* or an *absolute* path, never a relative file path — even if the file exists relative to cwd. Pass `path.join(process.env.HOME, 'Applications/Chrome with Claude Code.app')` (absolute) from JS. From the shell, write `~/Applications/…` so zsh expands it before `open` sees it.

---

## What's actually happening (mechanism reference)

After `cmd-auth.mjs` runs `open -a launcherApp --args url`:

1. **LaunchServices launches the bundle** with the launcher's `CFBundleIdentifier` in the new process's env. Bash starts as the bundle's `Contents/MacOS/` executable. Because `--args` was used, URL is in argv: `$1 = "https://accounts.google.com/o/oauth2/…"`. Runs in its own process group (PGID = bash's PID).
2. **Bash quits any existing Chrome** (`osascript -e 'tell application "Google Chrome" to quit'`, then poll-and-killall if needed). Idempotent — no-op if Chrome wasn't running.
3. **Bash spawns Chrome** with `--remote-debugging-port=9222 --silent-debugger-extension-api --no-first-run --user-data-dir="$HOME/Library/Application Support/Google/Chrome-Claude" "$@"`. The `&` backgrounds it; the `"$@"` expansion passes the URL through as Chrome's argv.
4. **Chrome opens URL** in the Chrome-Claude profile. Inherits bash's PGID and the launcher's bundle stamp.
5. **Bash polls** `http://localhost:9222/json/version` until Chrome's debug port is up (≤ 10 s).
6. **Bash writes `DevToolsActivePort`** to `$HOME/Library/Application Support/Google/Chrome/` so chrome-devtools MCP discovers the port.
7. **Bash exits**. Chrome continues. PPID reparents to launchd (init), but PGID stays as the bash's old PID — that's how the Dock keeps attributing the running Chrome to the launcher bundle and shows the single "Chrome with Claude Code" icon.

### Verification — run these on the VM to confirm the launcher works

```sh
# Quit anything Chrome-related first to test cold start:
osascript -e 'tell application "Google Chrome" to quit' 2>/dev/null
pkill -9 -f "Google Chrome" 2>/dev/null

# Same invocation cmd-auth.mjs uses:
open -a ~/Applications/Chrome\ with\ Claude\ Code.app --args "https://news.ycombinator.com"

# Should open HN in Chrome with --user-data-dir=Chrome-Claude, AND show a
# single Dock icon labeled "Chrome with Claude Code" (not two icons or one
# labeled "Google Chrome"). Verify the URL landed:
curl -s http://localhost:9222/json | python3 -c "import sys,json; print('\n'.join(t.get('url','') for t in json.load(sys.stdin)))"
# Output should include https://news.ycombinator.com/
```

If both hold, the launcher's contract is intact. If only the URL part holds (one icon → two icons), you're likely on the direct-exec form (`5248ca3`) — switch back to `open -a --args`. If neither holds (no URL in tabs), check whether `open -a` is rejecting the path; the bundle path must be absolute, never relative.

### What's safe to change

- The bash's body (kill-Chrome dance, polling logic, DevToolsActivePort path) — those are mechanics, not contract. The contract is "executable at `Contents/MacOS/Chrome with Claude Code` accepts a URL as `$1` (when invoked via `open -a APP --args URL`) and ensures Chrome-Claude opens with it".
- `Info.plist` fields that don't introduce URL types — bundle id, name, version, icon.
- Dock pinning in `_configure_workspace`/`_configure_dock`.

### What's NOT safe to change

- The `--args` flag in `if/cmd-auth.mjs`'s `open -a APP --args URL` call. Drop it and you re-introduce the d425944 bug.
- Replacing `open -a --args` with direct exec — works for URL routing but loses Dock attribution (`5248ca3`).
- Adding `CFBundleURLTypes` to the launcher bundle.
- Replacing the bash with an `osacompile` applet.
- The bash's `"$@"` in the Chrome command line.
- The Chrome `--user-data-dir` value (`$HOME/Library/Application Support/Google/Chrome-Claude`) — chrome-devtools MCP and `if`'s deploy step both assume this path.
