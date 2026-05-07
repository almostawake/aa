# n — operator guide

Companion to `https://almostawake.com/n`. Read this before invoking on
behalf of a user.

## What `n` does

A single bash script that, on a fresh macOS or Linux box, installs all
the tooling a non-developer needs (git, gh, node 22, java 21, Claude
Code, Chrome with debug-port profile), provisions a brand-new
GCP/Firebase project (creates project, links billing, enables ~17 APIs,
creates Firestore + Storage + web app + auth providers), clones the
[`if`](https://github.com/almostawake/if) SvelteKit template into
`$PROJECT_DIR/<project-id>`, seeds the user's email into the Firestore
allowedEmails whitelist, and deploys to Firebase Hosting.

Idempotent. Re-runs skip already-installed tooling and go straight to
"pick or create a project".

Run as:

```
curl -fsSL https://almostawake.com/n | bash
```

Once installed, the script writes an `alias n='curl -fsSL https://almostawake.com/n | bash'`
to `~/.zshrc`, so the user can just type `n` for subsequent projects.

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

The user's Google account must have:

- **An open billing account.** Free trial counts. Detected via
  `cloudbilling.googleapis.com/v1/billingAccounts`. If none, `n`
  prints a "set up billing in Firebase Console" message and exits.
- **Firebase ToS accepted.** Detected indirectly: if `:addFirebase`
  fails with a `terms.of.service` error, `n` prints a "open Firebase
  Console and start their create-a-project flow once" message and
  exits.

Both are one-time setups. If the script exits with a setup-needed
message, tell the user to do the one-time fix in Firebase Console, then
re-run `n`. Do not try to handle these flows in the agent — they
require the user's browser session and Google account interactions.

## Success signal

On success, the last lines printed are:

```
PROJECT READY

Live at: https://<project-id>.web.app
Code:    /Users/<user>/Projects/<project-id>
```

The script exits 0. Hosting is live (verify with `curl -fsI https://<project-id>.web.app`),
Firestore rules are deployed, the user's email is seeded into
`allowedEmails`.

## Where state lands

- `~/.if/` — all installed tooling (node, java, claude, git, gh,
  chrome launcher), npm cache, claude config dir.
- `~/.if/template-stage/` — staged clone of the public template repo +
  cached `.env.auth.json`. Reused across runs to avoid re-prompting
  for OAuth consent.
- `~/Applications/` — Chrome.app, Chrome with Claude Code.app, IF
  Terminal.app.
- `~/Library/Application Support/Google/Chrome-Claude/` — Chrome
  profile for the debug-port-enabled Claude browser.
- `~/Library/Services/Claude Code at Folder.workflow` — Finder
  right-click Quick Action.
- `~/.zshrc` — marker-fenced block (PATH, JAVA_HOME, NPM_CONFIG_CACHE,
  CLAUDE_CONFIG_DIR, PROJECT_DIR=~/Projects, aliases `cc`/`ccc`/`ccr`/`n`).
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
| `✗ Failed to add firebase to the project` (in row 2) | Firebase ToS not accepted for this account | Open Firebase Console → start their Create a project flow once (it bundles ToS acceptance), then re-run `n` |
| `sign-in didn't complete` | OAuth consent timed out or user dismissed the browser | Re-run `n` and complete the browser flow within 60s |
| `couldn't clone template repo` | Network blip or GitHub down | Check connectivity, re-run `n` |
| `<project-id> is taken` | Project IDs are globally unique on Google | User picks a different ID — `n` loops automatically |
| `install of <X> failed` | Network or platform-specific install bug | Inspect `/tmp/if-install.log` (last 40 lines printed automatically); pivot or report |

If the script exits non-zero, the last 40 lines of `/tmp/if-install.log`
are printed to stderr automatically. Read those before suggesting fixes.

## Re-run safety

`n` is idempotent at every level:
- Already-installed tooling: skipped (rendered green from the start).
- Already-configured workspace: re-applied (overwrites are
  intentional — restores Dock entries / Quick Actions if removed).
- Already-existing GCP project: chooser offers reuse; provisioning
  steps short-circuit on detection (Firestore exists → skip create,
  API enabled → skip enable, etc.).
- Already-existing project directory: clone is skipped (so local
  edits are preserved); deploy still runs.
- `~/.zshrc` block: stripped and rewritten on every run; previous
  version backed up as `~/.zshrc.<timestamp>.bak`.

Multiple projects on one machine: just run `n` again. The same Google
account is reused (cached in `~/.if/template-stage/.env.auth.json`).
To switch accounts, `rm -rf ~/.if/template-stage` then re-run.

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
