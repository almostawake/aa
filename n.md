# n — operator guide

Companion to `https://almostawake.com/n`. Read this before invoking on
behalf of a user.

## What `n` does

A single bash script that runs in three phases on a fresh macOS box
(Sonoma / Sequoia / Tahoe), gated on a dedicated `if` user account:

- **install** — toolchain (git, gh, jq, node 22, java 21, Claude Code,
  Google Chrome, VS Code) plus the `Chrome with Claude Code.app`
  wrapper that exposes Chrome's debug port for the MCP server. The
  wrapper is force-rebuilt on every run, deleting any pre-existing
  `/Applications` or `~/Applications` variants (legacy / manual
  installs get healed automatically).
- **config** — Claude config files (`~/.claude/CLAUDE.md`, hooks +
  utils seeded if absent; `~/.claude/settings.json` merged for
  `defaultMode` / `skipDangerousModePermissionPrompt` / session-namer
  hook; `~/.claude.json` merged for the `chrome-devtools` MCP server
  and trust path), Dock pins (Chrome wrapper + VS Code at slot 0/1),
  `~/.zshrc` marker block (PATH, env, aliases).
- **project** — Google OAuth sign-in, GCP project create, ~18 API
  enables, Firebase add, web app + Firestore + Storage + Auth config,
  `roles/iam.serviceAccountTokenCreator` self-binding on the Cloud
  Functions runtime SA (lets callables mint V4 signed URLs for the
  template's private-Storage + signed-URL access pattern — see
  `if/docs/CLAUDE-STACK.md` "Storage privacy posture"), clone of the
  [`if`](https://github.com/almostawake/if) SvelteKit template into
  `$PROJECT_DIR/<project-id>`, seed the user's email into the
  Firestore users whitelist, deploy to Firebase Hosting.

Idempotent. Re-runs skip already-installed tooling, re-assert config
(no clobber of user additions), and go straight to "pick or create a
project". Drift between what's checked, what's fixed, and what's
required is the script's invariant — `--check-only` verifies the same
surface `--install-only` fixes, and `--project-only` pre-flights with
the same checks before touching the cloud.

Run as:

```
curl -fsSL https://almostawake.com/n | bash
```

Once installed, the script writes an `alias n='curl -fsSL https://almostawake.com/n | bash -s --'`
to `~/.zshrc`, so the user can just type `n` for subsequent projects.
The `-s --` lets the alias forward flags through to the script.

## Flags

All optional. Skip with no flags for the normal interactive flow.

- `--reuse-project <id>` — skip the project chooser and use the named
  (already-existing) GCP project. Fatal at the create-project row if
  the project doesn't exist or isn't accessible to the signed-in
  account. Provisioning steps short-circuit on detection (see Re-run
  safety), so re-running on a fully-provisioned project is safe.
- `--region <id>` — region for the new project's Firestore + Storage
  (and therefore its Cloud Functions, which deploy alongside the data).
  Single GCP region only, e.g. `us-central1` — multi-regions like `nam5`
  aren't supported. Defaults to `australia-southeast1`. Ignored when
  `--reuse-project` targets an existing project — its Firestore location
  is already fixed.
- `--install-only` — run install + config and stop. Skips sign-in,
  project creation, clone, deploy. Heals existing setups: force-
  rebuilds the Chrome wrapper (deleting `/Applications` and
  `~/Applications` variants first), merges required keys into
  `~/.claude.json` + `~/.claude/settings.json` without clobbering user
  additions, re-pins the Dock, rewrites the `~/.zshrc` marker block.
  Mutually exclusive with `--project-only`.
- `--project-only` — skip install + config and go straight to sign-in +
  project provisioning. Pre-flights with the same checks as
  `--check-only` and bails with a heal hint (`re-run n --install-only`)
  if anything's missing, rather than half-deploying onto a broken
  machine. For returning users spinning up another project on an
  already-set-up machine. Mutually exclusive with `--install-only`.
- `--check-only` — read-only diagnostic. Verifies every install + config
  item:
  - toolchain rows (git, gh, jq, node 22, java 21, claude, chrome,
    vscode);
  - Chrome wrapper bash markers + Info.plist bundle id + the hardcoded
    Chrome.app path actually resolves, plus the absence of a legacy
    `/Applications/Chrome with Claude Code.app`;
  - `~/.claude.json` `mcpServers.chrome-devtools` matches the shipped
    entry (command + args), `~/.claude/settings.json` has
    `defaultMode=bypassPermissions`, `skipDangerousModePermissionPrompt
    =true`, and a session-namer hook entry in `hooks.UserPromptSubmit`;
  - Dock pins Chrome wrapper (`~/Applications` variant) + VS Code, no
    legacy `/Applications` Chrome pin; `~/.zshrc` has the if-install
    marker block.
  No writes. Lists every mismatch. Exits 0 if clean, 1 otherwise.
- `--override-osx-user-check` — bypass the macOS-user guard (`n` normally
  requires the short username to be `if`). For developing `n` itself or
  diagnosing a colleague's daily-driver account.

If `n` is invoked from inside a directory that already contains a
`.env.auth.json` (e.g. spinning up a sibling project from an
already-provisioned one), that cred is copied to `~/.if/.env.auth.json`
before the sign-in row runs. `cmd-auth.mjs` reuses it silently when
still valid, or refreshes / re-prompts the browser flow when stale.

When piping (`curl ... | bash`), pass flags via `bash -s --`:

```
curl -fsSL https://almostawake.com/n | bash -s -- --reuse-project my-existing-id
```

The installed `n` alias passes flags through directly: `n --reuse-project my-existing-id`.

## When to invoke

User wants a new automation project on the if stack — typically phrased
as "make me a new project", "spin up a new app", "set me up with a new
firebase project", etc.

Do **not** invoke for:
- Adding to / modifying an existing project (cd into it and use the
  template's own `cmd-deploy.mjs` / `cmd-auth.mjs` instead).
- Re-deploying an existing project (use `node cmd-deploy.mjs` from the
  project root).
- Re-authenticating an existing project (use `node cmd-auth.mjs` from
  the project root).

## Required user interactions

`n` is interactive. The invoking agent should let the user drive these
steps in their terminal — do not try to answer the prompts on their
behalf.

1. **"Ready to go?" [Y/n]** — first run only, immediately after the
   welcome banner. User confirms before anything is installed.

2. **Xcode Command Line Tools dialog** — only triggered on Intel Macs
   without our prebuilt git bundle (rare; ARM macs use the bundle).
   Native macOS dialog. User clicks Install. Script blocks until done
   (~10min).

3. **Chrome default-browser flow** — first install only, after Chrome
   finishes installing. User makes Chrome the default in the Chrome
   welcome screen, then quits Chrome. Script blocks until Chrome is
   no longer running.

4. **Google sign-in** — every run that needs a fresh token. Browser
   opens to the OAuth consent screen. User picks the dedicated gmail
   account they want to administer projects under and grants the
   `cloud-platform` scope. Script blocks ~60s on first run, ~25s
   thereafter.

5. **Project chooser** — every run. User either picks an existing GCP
   project from the numbered list, or picks "+ create a new project"
   and types a project ID (lowercase letters/digits/dashes, 6-30 chars,
   starts with a letter). Validation errors loop until valid; "already
   taken" loops with a record of tried names.

## Required prerequisites

The user's macOS box must have:

- **A dedicated `if` account** (short username `if`). `n` refuses to
  run on any other account because its writes (`~/.zshrc`, the Dock,
  `~/Applications`, `~/.claude/`, `~/.if/`) clobber daily-driver
  config. Override with `--override-osx-user-check` if you accept the
  side effects.
- **Sonoma (14), Sequoia (15), or Tahoe (26).** Untested versions exit
  with `your operating system is not supported`.

The user's Google account must have:

- **An open billing account.** Free trial counts. Detected via
  `cloudbilling.googleapis.com/v1/billingAccounts`. If none, `n`
  prints a "set up billing in Firebase Console" message and exits.
- **Firebase ToS accepted.** Detected indirectly: if `:addFirebase`
  fails with a `terms.of.service` error, `n` prints a "open Firebase
  Console and start their create-a-project flow once" message and
  exits.

Both Google-side items are one-time setups. If the script exits with a
setup-needed message, tell the user to do the one-time fix in Firebase
Console, then re-run `n`. Do not try to handle these flows in the
agent — they require the user's browser session and Google account
interactions.

## Success signal

On success, the last line printed is:

```
your template project is live at https://<project-id>.web.app
```

The script exits 0 and opens the project in VS Code. Hosting is live
(verify with `curl -fsI https://<project-id>.web.app`), Firestore rules
are deployed,
the user's email is seeded into `users`.

## Where state lands

- `~/.if/` — all installed tooling (node, java, claude, git, gh, jq,
  vscode, chrome launcher), npm cache. During a provisioning run the
  in-flight OAuth cred briefly lives at `~/.if/.env.auth.json` before
  being moved into the new project; nothing else is cached here
  between runs.
- `~/.claude/` + `~/.claude.json` — Claude Code's own config (default
  location; we deliberately don't redirect via `CLAUDE_CONFIG_DIR`).
- `~/Applications/` — Chrome.app, Chrome with Claude Code.app, Visual
  Studio Code.app.
- `~/Library/Application Support/Google/Chrome-Claude/` — Chrome
  profile for the debug-port-enabled Claude browser.
- `~/.zshrc` — marker-fenced block (PATH, JAVA_HOME, NPM_CONFIG_CACHE,
  PROJECT_DIR=~/Projects, CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL, aliases
  `cc`/`ccc`/`ccr`/`n`).
- `${PROJECT_DIR:-~/Projects}/<project-id>/` — the user's new project
  (clone of `if` template + `.env`, `client/.env`, `.env.auth.json`).
- `/tmp/if-install.log` — install + configure trace (overwritten per
  run).
- `/tmp/if-new.log` — provisioning + deploy trace (appended).

The user's `PROJECT_DIR` defaults to `~/Projects` but can be overridden
by editing the `export PROJECT_DIR=...` line in `~/.zshrc`.

## Common failure modes

The agent should recognise these and surface to the user, not retry:

| Symptom in script output | What it means | What to tell the user |
|---|---|---|
| `✗ No billing account set up yet for <email>` | User has never set up billing on this Google account | Open Firebase Console → Create a project → accept the free trial when prompted, then re-run `n` |
| `✗  failed to add firebase — most likely Firebase ToS not accepted` | Firebase ToS not accepted for this account | Open Firebase Console → start their Create a project flow once (it bundles ToS acceptance), then re-run `n` |
| `✗  we waited 5 mins for sign-in .. re-run when you're ready` | OAuth consent timed out or user dismissed the browser | Re-run `n` and complete the browser flow promptly |
| `✗  downloading project template failed` | Network blip or GitHub down | Check connectivity, re-run `n` |
| `✗  <project-id> is taken` | Project IDs are globally unique on Google | User picks a different ID — `n` loops automatically |
| `✗  install of <X> failed` | Network or platform-specific install bug | Inspect `/tmp/if-install.log` (last 40 lines printed automatically); pivot or report |

If the script exits non-zero, the last 40 lines of `/tmp/if-install.log`
are printed to stderr automatically. Read those before suggesting fixes.

## Re-run safety

`n` is idempotent at every level:
- Already-installed tooling: skipped (rendered green from the start).
- Already-configured workspace: re-applied (overwrites are
  intentional — restores Dock entries if removed).
- Already-existing GCP project: chooser offers reuse; provisioning
  steps short-circuit on detection (Firestore exists → skip create,
  API enabled → skip enable, etc.).
- Already-existing project directory: clone is skipped (so local
  edits are preserved); deploy still runs.
- `~/.zshrc` block: stripped and rewritten on every run; previous
  version backed up as `~/.zshrc.<timestamp>.bak`.

Multiple projects on one machine: just run `n` again. To reuse the
same Google account without re-doing the OAuth flow, run `n` from
inside an existing provisioned project — its `.env.auth.json` is
copied into `~/.if/` at startup and `cmd-auth.mjs` reuses it silently
when still valid (refreshing or re-prompting when stale). To switch
accounts, run `n` from a directory without a `.env.auth.json` (e.g.
`~`); the browser sign-in flow runs normally.

## Time budget

- First run on a fresh machine: ~5–10 min (most spent on
  Chrome + Java + Node downloads + GCP API enablement, which is
  serialised by Google).
- Re-run for another project: ~2–3 min (skip installs, just
  provision + deploy).

## What `n` deliberately does NOT do

- Doesn't run `gh auth login`. The if template is public — no GitHub
  auth needed for the clone.
- Doesn't install Homebrew. Everything goes into `~/.if/<tool>/`,
  contained.
- Doesn't touch `/Applications/`, `/usr/local/`, or system PATH —
  only the user's home dir.
- Doesn't deploy on every run. Only on first project creation OR
  when re-running with an existing project where deploy hasn't
  succeeded yet.

## See also

- Source: https://almostawake.com/n (this is just bash — `curl URL | less`
  to read it).
- Template repo: https://github.com/almostawake/if
- Wipe-and-retry helper (testing only): https://almostawake.com/u
