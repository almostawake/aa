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

**`if/cmd-auth.mjs` invokes the bash launcher via direct `spawn(execPath, [url])` — never via `open -a APP URL`.** The bash receives the URL as `$1`, forwards via `"$@"` to Chrome's command line, Chrome's process-singleton (keyed by `--user-data-dir`) routes it into the Chrome-Claude profile. End of story.

```js
// cmd-auth.mjs (correct shape)
const launcherExec = path.join(
  process.env.HOME || '',
  'Applications/Chrome with Claude Code.app/Contents/MacOS/Chrome with Claude Code'
);
spawn(launcherExec, [url], { detached: true, stdio: 'ignore' }).unref();
```

That's all there is. Skip the rest of this file unless you're tempted to change something.

---

## The full saga (so the next LLM doesn't go around the loop)

Pinning this here because we burned a multi-hour session re-deriving it. The launcher and `cmd-auth.mjs` have a history of "this looks wrong, let me improve it" changes that all turn out to break the working setup. Each of these is documented with what we tried and why it fails.

### Failed approach 1 — `open -a APP URL` from cmd-auth.mjs

Introduced in `if`'s commit `d425944` on 2026-05-07. Reverted on 2026-05-12.

The commit message claimed direct exec sometimes routed URLs to the user's regular Chrome via process-singleton hijack, and `open -a` was the "macOS-blessed" path. That premise was wrong on every line.

Empirically: `open -a BUNDLE URL` on a bash-in-bundle that doesn't declare `CFBundleURLTypes` does **not** pass URL via argv. Probe inside the bash with the invocation and `argc=0`. macOS LaunchServices does two things in parallel instead:

1. Launches the bundle (bash starts with empty argv, runs its kill-Chrome + spawn dance, ends up with `"$@"` empty so Chrome opens with no URL).
2. Falls through to the **default URL handler** for the scheme and delivers the URL there via `kAEGetURL` Apple Event.

On a Mac where Chrome is already the default browser (because the user set it, ages ago), step 2 sends the URL to Chrome, Chrome's `--user-data-dir` singleton routes it to the running Chrome-Claude instance the launcher just brought up, and it all works by accident — *not* through the path the bash launcher was designed for.

**On a fresh macOS user, the default browser is Safari.** Step 2 sends the OAuth URL to Safari. The launcher's bash also opens Chrome-Claude blank. You see Safari with the OAuth page and a blank Chrome window — the user-visible bug we chased through this whole session.

Tested directly: `open ~/Applications/Chrome\ with\ Claude\ Code.app https://news.ycombinator.com` on the fresh-VM user opened Safari with HN and Chrome with a blank tab. Two windows, two apps, neither what we want.

The fix: **don't go through `open` at all.** Direct `spawn(execPath, [url])` from cmd-auth.mjs hands the URL to the bash as argv. Bash forwards via `"$@"`. Chrome opens the URL in Chrome-Claude. Works on every macOS user regardless of default-browser setting.

### Failed approach 2 — rebuild the launcher as an `osacompile` applet

Tried in `aa` commit `ff66210` on 2026-05-12. Reverted in `52befae` same day.

The premise was that the bash-in-bundle was dropping URLs and an `on open location` AppleScript applet was needed to receive them properly via Apple Events. That premise was wrong. The bash-in-bundle never *needed* to receive URLs by Apple Event — it receives them via argv (when direct-exec'd). The applet adds an AppleScript layer and a separate helper script to solve a problem that doesn't exist.

The applet also strictly *worsens* one thing: AppleScript's `do shell script` runs a fresh shell whose env you don't fully control, which complicates the process-group attribution the Dock uses (see below).

### Failed approach 3 — pre-warm Chrome-Claude in `_prov_signin` before cmd-auth.mjs

I proposed this when the cold-start race looked like the culprit. It isn't — the cold-start race is real but irrelevant once cmd-auth.mjs direct-execs. Pre-warming would also fail to fix the default-browser-is-Safari case because the URL still goes via fall-through. **Don't add a pre-warm step.**

### Failed approach 4 — `open -a APP --args URL`

Looks like the right "have your cake and eat it too": LaunchServices launches the bundle (preserving Dock attribution) and `--args` passes the URL via argv. Untested in detail, possibly works. Not adopted because the simpler direct-exec is good enough and doesn't need `open` at all.

If you go down this path, note: `open -a` rejects relative paths to bundles ("Unable to find application named '…'"). Pass the absolute path.

### Failed approach 5 — declare `CFBundleURLTypes` on the launcher bundle

Would hijack URLs into the bash via Apple Event `kAEGetURL` — which a bash script can't receive (it's not an Apple-Event-aware app). URLs get dropped entirely. Strictly worse than today's setup. Don't.

### Failed approach 6 — `lsregister -f` after building the launcher

Looked plausible as a "force LaunchServices to index the new bundle". Doesn't help because direct exec doesn't use LaunchServices. Harmless if added, but not necessary.

---

## What's actually happening (mechanism reference)

After cmd-auth.mjs direct-execs the bash launcher with URL as argv:

1. **Bash invoked**: PID assigned, `argv = ["…/Chrome with Claude Code", "https://accounts.google.com/o/oauth2/…"]`. Runs in its own process group (PGID = bash's PID).
2. **Bash quits any existing Chrome** (`osascript -e 'tell application "Google Chrome" to quit'`, then poll-and-killall if needed). Idempotent — no-op if Chrome wasn't running.
3. **Bash spawns Chrome** with `--remote-debugging-port=9222 --silent-debugger-extension-api --no-first-run --user-data-dir="$HOME/Library/Application Support/Google/Chrome-Claude" "$@"`. The `&` backgrounds it; the `"$@"` expansion passes the URL through as Chrome's argv.
4. **Chrome opens URL** in the Chrome-Claude profile. Inherits bash's PGID.
5. **Bash polls** `http://localhost:9222/json/version` until Chrome's debug port is up (≤ 10 s).
6. **Bash writes `DevToolsActivePort`** to `$HOME/Library/Application Support/Google/Chrome/` so chrome-devtools MCP discovers the port.
7. **Bash exits**. Chrome continues. Chrome's PPID gets reparented to launchd (init), but PGID stays as the bash's old PID.

The Dock attribution to "Chrome with Claude Code" — macOS Dock walks PGID, finds the (now-exited) bash launcher PID, looks up the bundle. With direct exec (no LaunchServices), this attribution may not always be preserved; you may see Chrome as its own Dock entry alongside the pinned launcher. That's cosmetic. The OAuth flow works either way.

### Verification — run these on the VM to confirm the launcher works

```sh
# Quit anything Chrome-related first to test cold start:
osascript -e 'tell application "Google Chrome" to quit' 2>/dev/null
pkill -9 -f "Google Chrome" 2>/dev/null

# Direct exec — what cmd-auth.mjs now does:
~/Applications/Chrome\ with\ Claude\ Code.app/Contents/MacOS/Chrome\ with\ Claude\ Code "https://news.ycombinator.com"

# Should open HN in Chrome with --user-data-dir=Chrome-Claude. Verify:
curl -s http://localhost:9222/json | python3 -c "import sys,json; print('\n'.join(t.get('url','') for t in json.load(sys.stdin)))"
# Output should include https://news.ycombinator.com/
```

If those work, the launcher's contract is intact. If anything else looks "off" (single Dock icon vs two, etc.), it's cosmetic, not a contract violation.

### What's safe to change

- The bash's body (kill-Chrome dance, polling logic, DevToolsActivePort path) — those are mechanics, not contract. The contract is "executable at `Contents/MacOS/Chrome with Claude Code` accepts a URL as `$1` and ensures Chrome-Claude opens with it".
- `Info.plist` fields that don't introduce URL types — bundle id, name, version, icon.
- Dock pinning in `_configure_workspace`/`_configure_dock`.

### What's NOT safe to change

- Switching `if/cmd-auth.mjs` to anything other than direct exec of the bash with URL as argv. We've now learned this twice.
- Adding `CFBundleURLTypes` to the launcher bundle.
- Replacing the bash with an `osacompile` applet.
- The bash's `"$@"` in the Chrome command line.
- The Chrome `--user-data-dir` value (`$HOME/Library/Application Support/Google/Chrome-Claude`) — chrome-devtools MCP and `if`'s deploy step both assume this path.
