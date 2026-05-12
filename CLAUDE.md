# aa

One-shot macOS bootstrapper that sets up a fresh Mac (or fresh macOS user) for the [`if`](https://github.com/almostawake/if) project template — Claude Code, VS Code, Chrome wired up for chrome-devtools MCP, Node, git, gh, jq, java. Run via `curl -fsSL https://almostawake.com/n | bash`. Update an existing install via `curl -fsSL https://almostawake.com/update | bash`.

- `n` — the installer + project provisioner (single bash script, ~2000 lines).
- `update` — refreshes per-user assets that `n` only writes on first install (CLAUDE.md, VS Code settings, etc.).
- `assets/` — files served from `almostawake.com/assets/` and fetched by `n` / `update`. Includes the user-scope `~/.claude/CLAUDE.md`, `~/.claude/settings.json`, `hook-session-namer.mjs`, `util-my-color.mjs`, the VS Code config bundle, and the welcome-modal `state.vscdb` seed.
- `n.md` / forms the public-facing README at almostawake.com.

The companion project this targets: **https://github.com/almostawake/if** — a Firebase/SvelteKit template for small personal automations. `n` ends by cloning it, running its `cmd-auth.mjs` for Google OAuth, provisioning a GCP/Firebase project, and deploying.

## Chrome launcher — read this before touching `_install_chrome`

`n` builds `~/Applications/Chrome with Claude Code.app` — a `.app` bundle whose `Contents/MacOS/` executable is a **plain bash script**, not a Mach-O `osacompile` applet. This is intentional and has been working reliably for a month. Future-LLM trap: it *looks* broken at every level you'd probe, but it isn't. Resist the urge to "fix" it.

The bash script's only job: ensure Chrome is alive with `--remote-debugging-port=9222 --user-data-dir=$HOME/Library/Application\ Support/Google/Chrome-Claude` so chrome-devtools MCP can attach. The bash never receives URLs.

### Why URLs still reach Chrome even though the bash never sees them

`if`'s `cmd-auth.mjs` opens the OAuth URL via `spawn('open', ['-a', launcherApp, url])`. Probe the bash with that invocation and it logs `argc=0` — the URL never enters argv. **This is fine.** macOS LaunchServices does two things in parallel when `open -a BUNDLE URL` is called and the bundle doesn't declare `CFBundleURLTypes`:

1. Launches the bundle (bash starts, gets empty argv, runs its kill-Chrome + spawn + debug-port-poll dance).
2. Falls through to the **default URL handler** for the URL's scheme — Chrome on a setup where Chrome is the default browser — and delivers the URL there via the standard `kAEGetURL` Apple Event.

Chrome's process-singleton, keyed by `--user-data-dir`, routes the URL into the already-running Chrome-Claude profile instance the launcher just guaranteed was up. End result: the OAuth URL opens as a tab in Chrome-Claude, which is what we want.

### Why the Dock shows one icon, not two

When you click the pinned launcher (or `open -a` it), the bash process gets the launcher's `__CFBundleIdentifier` env from launchd, and that bundle id is what LaunchServices associates with the bash's PID. The bash spawns Chrome in the same process group. **Chrome's PGID equals the bash launcher's PID.** Even after the bash exits (~10–20s in), Chrome keeps that PGID, and macOS Dock walks the PGID to find the bundle association → Dock shows the launcher's icon with a running dot, labeled "Chrome with Claude Code". No separate Google Chrome dock entry appears. This is the polish the user expects.

### Things that look like improvements but break the elegance

- **Rebuilding the launcher as an `osacompile` applet** (with `on open location theURL` + `do shell script` chain): URL delivery still works but goes via a *different* path (Apple Event into the applet, then helper bash, then Chrome argv). The fall-through-to-default-browser route is bypassed. Adds AppleScript and a helper script layer. No real benefit. (We tried this — `ff66210`, reverted in `52befae`. See the revert commit message for the full reasoning.)
- **Declaring `CFBundleURLTypes` on the bundle**: hijacks URLs into the bash via Apple Event… which the bash can't catch (it's not an Apple Event-aware app), so URLs get dropped entirely. Strictly worse.
- **Switching `if`'s `cmd-auth.mjs` to `open -a APP --args URL`**: passes URL into bash argv, bypassing fall-through. URL would reach Chrome via the bash forwarding `"$@"`. But Chrome's process-singleton sometimes routes it to whichever Chrome instance grabbed the LaunchServices URL handler first — *often the user's regular Chrome, not Chrome-Claude*. The whole point of fall-through is that Chrome decides per-singleton where the URL lands, and the singleton check uses `--user-data-dir` to pick the right instance.
- **Changing `cmd-auth.mjs` back to direct exec of the bash with URL as argv**: same singleton risk as above. This was the pre-`d425944` state in `if`, which was switched away from precisely for that reason.

### What's safe to change

- The bash's contents (kill-Chrome dance, polling logic, DevToolsActivePort path) — those are mechanics, not contract.
- `Info.plist` *fields that don't introduce URL types* — bundle id, name, version, icon.
- The Dock-pinning code in `_configure_workspace`/`_configure_dock` — that just adds the bundle path to the user's Dock plist.

### Sanity check, for future-LLM

If you're about to "fix" the launcher because something seems off:
1. Confirm the bash actually runs (`pgrep -af "Chrome with Claude Code"` after `open -a`).
2. Confirm Chrome-Claude comes up with the debug port (`curl -s http://localhost:9222/json/version`).
3. Confirm a URL opens by running `open -a "/Applications/Chrome with Claude Code.app" "https://example.com"` and checking `/json` lists it as a tab.
4. Look at `ps -o pid,ppid,pgid -p $(pgrep -f remote-debugging-port | head -1)` — Chrome's PGID should be the (now-exited) bash launcher PID. That's the Dock attribution.

If all four pass, the launcher is working. If the user is complaining about something visible — fresh-VM OAuth landing on regular Chrome, dock icons not merging, URL not loading — the failure is almost certainly upstream (default browser isn't Chrome yet, Chrome-Claude not warm when URL hits, race during cold start), not in `_install_chrome` itself.
