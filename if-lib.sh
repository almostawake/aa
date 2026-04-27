#!/bin/bash
#
# appsvelte shared helpers
# https://truffledog.au/if-lib.sh
#
# Loaded by other if-*.sh scripts via:
#   eval "$(curl -fsSL https://truffledog.au/if-lib.sh)"
#
# After that, every function/variable below is available in the calling
# script's shell as if it had been defined inline.
#
# CLAUDE EDIT NOTICE: When editing this file, bump ZSHRC_VERSION in
# zshrc-remote by 1. Shows in user's prompt as [v38] etc. — their signal
# that the push went live.

# --- Color helpers ---
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_GRAY=$'\033[90m'
  C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_GRAY=""; C_BLD=""; C_RST=""
fi

tick()  { printf "${C_GRN}✓${C_RST}"; }
dot()   { printf "${C_GRAY}○${C_RST}"; }
bold()  { printf "${C_BLD}%s${C_RST}" "$1"; }
gray()  { printf "${C_GRAY}%s${C_RST}" "$1"; }

say()   { printf '%s\n' "$*"; }
die()   { printf "${C_RED}error:${C_RST} %s\n" "$*" >&2; exit 1; }

# --- Y/N prompt (reads from /dev/tty for piped mode) ---
prompt_yn() {
  # $1 = question, $2 = default (Y or N)
  local q="$1" def="$2" hint answer
  if [ "$def" = "Y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  printf '%s %s ' "$q" "$hint"
  read -r answer </dev/tty || answer=""
  [ -z "$answer" ] && answer="$def"
  case "$answer" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# --- OS / arch detection ---
# Sets OS (darwin|linux) and ARCH (arm64|x64). Dies on unsupported.
detect_os_arch() {
  case "$(uname -s)" in
    Darwin) OS="darwin" ;;
    Linux)  OS="linux"  ;;
    *) die "unsupported OS: $(uname -s) — this installer supports macOS and Linux only" ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) ARCH="arm64" ;;
    x86_64|amd64)  ARCH="x64"   ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
  export OS ARCH
}

# --- Project folder name prompt + validation ---
# Sets PROJECT_NAME and PROJECT_DIR. Loops until valid.
prompt_project_name() {
  while true; do
    printf "Project folder name (letters/numbers/dashes, e.g. my-budget-tracker): "
    read -r PROJECT_NAME </dev/tty || PROJECT_NAME=""
    if [ -z "$PROJECT_NAME" ]; then
      say "  Name can't be empty."
      continue
    fi
    case "$PROJECT_NAME" in
      .*|*/*|*\ *)
        say "  Name can't start with a dot or contain slashes or spaces."
        continue
        ;;
    esac
    PROJECT_DIR="$HOME/$PROJECT_NAME"
    if [ -e "$PROJECT_DIR" ]; then
      say "  $PROJECT_DIR already exists. Choose a different name."
      continue
    fi
    break
  done
  export PROJECT_NAME PROJECT_DIR
}

# --- Diagnostic report builder ---
# Sets DIAG_REPORT (multi-line string) based on local machine state.
# Reused by if-check.sh and if-install.sh for consistent reporting.
build_diagnostic_report() {
  local short_user hostname_val os_name os_version arch
  local node_ver node_path java_ver java_home_val claude_ver
  local chrome_installed chrome_ver chrome_claude_app
  local appsvelte_home appsvelte_project chrome_profile chrome_default
  local zprofile_marker claude_md chrome_running debug_port

  short_user="$(whoami 2>/dev/null || echo unknown)"
  hostname_val="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
  os_name="$(uname -s)"
  os_version=""
  [ "$os_name" = "Darwin" ] && os_version="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
  arch="$(uname -m)"

  node_ver="$(node -v 2>/dev/null || echo 'not installed')"
  node_path="$(command -v node 2>/dev/null || echo 'not on PATH')"

  java_ver="not installed"
  if command -v java >/dev/null 2>&1; then
    java_ver="$(java -version 2>&1 | head -1 | tr -d '"' || echo 'installed but version check failed')"
  fi
  java_home_val="${JAVA_HOME:-not set}"

  claude_ver="not installed"
  command -v claude >/dev/null 2>&1 && claude_ver="$(claude --version 2>/dev/null | head -1 || echo installed)"

  chrome_installed="no"
  chrome_ver=""
  if [ -d "/Applications/Google Chrome.app" ]; then
    chrome_installed="yes"
    chrome_ver="$(/usr/bin/defaults read '/Applications/Google Chrome.app/Contents/Info' CFBundleShortVersionString 2>/dev/null || echo unknown)"
  fi

  chrome_claude_app="no"
  [ -d "/Applications/Chrome with Claude Code.app" ] && chrome_claude_app="yes"

  appsvelte_home="no"
  [ -d "$HOME/.appsvelte" ] && appsvelte_home="yes"

  appsvelte_project="no"
  [ -d "$HOME/appsvelte" ] && appsvelte_project="yes"

  chrome_profile="no"
  [ -d "$HOME/chrome-claude-profile" ] && chrome_profile="yes"

  chrome_default="no"
  [ -d "$HOME/Library/Application Support/Google/Chrome" ] && chrome_default="yes"

  zprofile_marker="no"
  if [ -f "$HOME/.zprofile" ] && grep -q "appsvelte install" "$HOME/.zprofile" 2>/dev/null; then
    zprofile_marker="yes"
  fi

  claude_md="no"
  [ -f "$HOME/.claude/CLAUDE.md" ] && claude_md="yes"

  chrome_running="no"
  pgrep -qf "Google Chrome" && chrome_running="yes"

  debug_port="no"
  curl -s --max-time 2 http://localhost:9222/json/version >/dev/null 2>&1 && debug_port="yes"

  # Export identifiers for the caller (e.g. ntfy title)
  DIAG_USER="$short_user"
  DIAG_HOST="$hostname_val"

  DIAG_REPORT=$(cat <<REPORT
SETUP CHECK — $(date '+%Y-%m-%d %H:%M:%S %Z')

From:       ${short_user}@${hostname_val}
OS:         ${os_name} ${os_version} (${arch})

— Installed tools —
  Node:          ${node_ver}  (${node_path})
  Java:          ${java_ver}
  JAVA_HOME:     ${java_home_val}
  Claude CLI:    ${claude_ver}
  Google Chrome: ${chrome_installed}${chrome_ver:+ (v${chrome_ver})}

— Appsvelte state —
  ~/.appsvelte/:                    ${appsvelte_home}
  ~/appsvelte/:                     ${appsvelte_project}
  ~/chrome-claude-profile/:         ${chrome_profile}
  Chrome default data dir:          ${chrome_default}
  Chrome with Claude Code.app:      ${chrome_claude_app}
  ~/.zprofile appsvelte marker:     ${zprofile_marker}
  ~/.claude/CLAUDE.md:              ${claude_md}

— Runtime —
  Chrome running:  ${chrome_running}
  Debug port 9222: ${debug_port}
REPORT
)

  export DIAG_REPORT DIAG_USER DIAG_HOST
}

# --- Post a diagnostic report to ntfy ---
# $1 = ntfy topic (e.g. "if-ntfy-setup-check")
# $2 = title prefix (e.g. "Setup Check")
# Requires DIAG_REPORT, DIAG_USER, DIAG_HOST to be set (via build_diagnostic_report)
post_diagnostic_to_ntfy() {
  local topic="$1" title_prefix="$2"
  curl -fsSL \
    -H "Title: ${title_prefix}: ${DIAG_USER}@${DIAG_HOST}" \
    -H "Tags: wrench,computer" \
    -H "Priority: high" \
    -d "$DIAG_REPORT" \
    "https://ntfy.sh/${topic}" >/dev/null 2>&1
}

# --- Provisioning (stub) ---
# Runs the GCP/Firebase provisioning flow for a project folder.
# $1 = project dir (absolute path)
#
# Currently a stub — the actual work happens in Node via Claude Code and
# Vite dev middleware once the user runs `claude` in the project.
#
# Future: this function grows to handle the full flow via a Node provisioner
# bundled in ~/.appsvelte/lib/ or inside the template's scripts/ folder.
# See CLAUDE-PROBE.md "Not yet documented" for the full plan.
provision_project() {
  local project_dir="$1"
  [ -d "$project_dir" ] || die "provision_project: directory not found: $project_dir"

  say ""
  say "$(bold 'Provisioning')"
  say ""
  say "GCP and Firebase setup (OAuth, project selection, API enablement,"
  say "Firestore, Gemini key, config files) happens inside the app when"
  say "you run Claude Code. To start:"
  say ""
  say "  cd $project_dir && claude"
  say "  → tell Claude:  set up my project"
  say ""
  say "Claude will walk you through it in the browser."
}
