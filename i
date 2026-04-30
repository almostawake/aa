#!/bin/bash
#
# almostawake.com/i.sh — bootstrap for if (impatient futurist)
#
# Installs git and gh into ~/.if/, mirroring
# scripts/install-dependencies's contained install convention (no
# Homebrew). Auth + repo cloning happen later.
#
set -e

# ==========================================================================
# Helpers (lifted from scripts/lib — inlined because the bootstrap can't
# depend on the private repo before it's cloned)
# ==========================================================================

if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRAY=$'\033[90m'
  # 256-colour palette indices, chosen for matched depth on a light
  # terminal. Truecolor (\033[38;2;...) was tried but Terminal.app
  # misrenders it as bright magenta, so we use 256-colour mode.
  #   blue  = idx 17 (#00005f, deep navy / midnight blue)
  #   green = idx 22 (#005f00, dark forest green — same depth as blue)
  C_BLU=$'\033[38;5;17m'
  C_GRN=$'\033[38;5;22m'
  C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_GRAY=""; C_BLU=""; C_BLD=""; C_RST=""
fi

die() { printf "${C_RED}error:${C_RST} %s\n" "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
heading() { printf "${C_BLD}${C_BLU}%s${C_RST}\n" "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"; }

prompt_yn() {
  local q="$1" def="$2" hint answer
  if [ "$def" = "Y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  printf '%s %s ' "$q" "$hint"
  read -r answer </dev/tty || answer=""
  [ -z "$answer" ] && answer="$def"
  case "$answer" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# ==========================================================================
# Welcome screen + opt-in. Nothing on disk changes before "Y".
# ==========================================================================

cat <<BANNER

┌─────────────────────────────────────────────────────────────────────┐
│                     welcome, impatient futurist                     │
└─────────────────────────────────────────────────────────────────────┘

BANNER

cat <<PLAN
Let's save you a few months of pain and suffering by installing
everything you need in a couple of minutes. When we're done you'll
be able to kick off your first project, which will be live in
another few minutes.

PLAN

if ! prompt_yn "Ready to go?" "Y"; then
  say ""
  say "no changes made. goodbye."
  exit 0
fi

detect_os_arch() {
  case "$(uname -s)" in
    Darwin) OS="darwin" ;;
    Linux)  OS="linux"  ;;
    *) die "unsupported OS: $(uname -s) — supports macOS and Linux only" ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) ARCH="arm64" ;;
    x86_64|amd64)  ARCH="x64"   ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
  export OS ARCH
}

# ==========================================================================
# Constants
# ==========================================================================

IF_HOME="$HOME/.if"
mkdir -p "$IF_HOME"
INSTALL_LOG="/tmp/if-install.log"
: > "$INSTALL_LOG"

# Timestamped marker — call freely; cheap, and the only way to tell where
# we hang when the UI just shows a spinner.
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >> "$INSTALL_LOG"; }

log "i: script start (pid=$$, user=$USER, shell=$SHELL)"
log "i: HOME=$HOME IF_HOME=$IF_HOME"

# Surface log tail on abnormal exit.
trap '_rc=$?; if [ $_rc -ne 0 ]; then
  printf "\n\n--- last 40 lines of %s ---\n" "$INSTALL_LOG" >&2
  tail -n 40 "$INSTALL_LOG" >&2
  printf "\n(full log: %s)\n" "$INSTALL_LOG" >&2
fi' EXIT

detect_os_arch
log "i: detected OS=$OS ARCH=$ARCH"

# ==========================================================================
# Install helpers
# ==========================================================================

# git — ARM downloads our pre-built bundle (git binaries + dylib closure
# + wrapper, ~27MB compressed). Intel falls back to xcode-select.
_install_git() {
  log "_install_git: enter (OS=$OS ARCH=$ARCH)"
  if [ "$OS" = "darwin" ] && [ "$ARCH" = "arm64" ]; then
    if _install_git_bundle; then
      log "_install_git: bundle path succeeded"
      return 0
    fi
    log "_install_git: bundle failed, falling through to xcode-select"
  fi
  _install_git_xcode
  log "_install_git: xcode path returned $?"
}

# Single tar.gz: bin/git (wrapper) + bin/git.real + bin/* helpers,
# libexec/git-core/* (~180 helpers), lib/*.dylib (libpcre2, libintl,
# libcurl + closure: libssl, libcrypto, libnghttp2, libnghttp3,
# libngtcp2 + libngtcp2_crypto_ossl, libssh2, libbrotli{dec,common},
# libzstd). Wrapper sets DYLD_LIBRARY_PATH (override),
# GIT_EXEC_PATH, SSL_CERT_FILE, CURL_CA_BUNDLE so that git-remote-http
# resolves dylibs and TLS roots correctly even when invoked from
# hardened parents (gh) that strip DYLD_* env vars.
#
# Built on Sonoma 14.1, arm64. tar -xz applies no quarantine xattr,
# so dyld doesn't see Gatekeeper warnings on first load. If the
# bundle's ad-hoc-signed dylibs get rejected on a stricter macOS
# (e.g. Tahoe enforces library-validation more strictly than Sonoma),
# the smoke test fails and we fall through to xcode-select.
_install_git_bundle() {
  log "_install_git_bundle: enter"
  rm -rf "$IF_HOME/git"
  # Single Sonoma bundle for now — when we ship Sequoia/Tahoe builds
  # we'll select by `sw_vers -productVersion | cut -d. -f1`.
  log "_install_git_bundle: curl|tar starting"
  # curl exit code is fatal (network failure → no point smoke-testing).
  # tar exit code is advisory: BSD tar warns "Failed to restore metadata"
  # for system-set xattrs (com.apple.provenance) on symlinks but the data
  # extracts fine. We rely on the smoke tests below to decide success.
  curl -fsSL https://almostawake.com/git-sonoma.tar.gz | tar -xz -C "$IF_HOME"
  local cs=("${PIPESTATUS[@]}")
  log "_install_git_bundle: curl|tar returned curl=${cs[0]} tar=${cs[1]}"
  if [ "${cs[0]}" -ne 0 ]; then
    log "_install_git_bundle: curl failed — aborting"
    return 1
  fi
  log "_install_git_bundle: smoke --version"
  if ! "$IF_HOME/git/bin/git" --version >>"$INSTALL_LOG" 2>&1; then
    log "_install_git_bundle: --version failed"
    return 1
  fi
  log "_install_git_bundle: smoke ls-remote"
  if ! "$IF_HOME/git/bin/git" ls-remote https://github.com/octocat/Hello-World.git HEAD >>"$INSTALL_LOG" 2>&1; then
    log "_install_git_bundle: ls-remote failed"
    return 1
  fi
  log "_install_git_bundle: success"
}

_install_git_xcode() {
  log "_install_git_xcode: enter"
  if xcode-select -p >/dev/null 2>&1; then
    log "_install_git_xcode: already installed"
    return 0
  fi
  log "_install_git_xcode: triggering xcode-select --install (will block on dialog)"
  xcode-select --install 2>/dev/null || true
  while ! xcode-select -p >/dev/null 2>&1; do sleep 10; done
  log "_install_git_xcode: xcode-select now reports installed"
}

_install_gh() {
  log "_install_gh: enter"
  local arch_gh
  case "$ARCH" in
    arm64) arch_gh="arm64" ;;
    x64)   arch_gh="amd64" ;;
    *) die "gh: unsupported arch $ARCH" ;;
  esac
  local url
  log "_install_gh: querying latest release"
  url=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest \
    | perl -MJSON::PP -e "
        my \$j = decode_json(join('', <STDIN>));
        for my \$a (@{\$j->{assets}}) {
          next unless ref(\$a) eq 'HASH';
          if ((\$a->{name} // '') =~ /^gh_.*_macOS_${arch_gh}\\.zip\$/) {
            print \$a->{browser_download_url};
            last;
          }
        }")
  [ -z "$url" ] && die "gh: couldn't find release asset"
  log "_install_gh: url=$url"
  local tmp_zip tmp_dir
  tmp_zip=$(mktemp -u).zip
  tmp_dir=$(mktemp -d)
  log "_install_gh: downloading"
  curl -fsSL "$url" -o "$tmp_zip"
  log "_install_gh: unzipping"
  unzip -q "$tmp_zip" -d "$tmp_dir"
  rm -rf "$IF_HOME/gh"
  mv "$(ls -d "$tmp_dir"/*/)" "$IF_HOME/gh"
  rm -rf "$tmp_zip" "$tmp_dir"
  log "_install_gh: done"
}

# ==========================================================================
# Detection
# ==========================================================================

log "i: starting detection"
# We install into ~/.if/ but don't touch PATH or zshrc here (that's the
# full installer's job). So `command -v` won't see what we installed last
# time. Check the install location directly first, fall back to PATH.
have_git=false
if [ -x "$IF_HOME/git/bin/git" ]; then
  # Wrapper presence (git.real) is our sentinel for a healthy install.
  # An older bottle-only install without the wrapper is broken under
  # gh/hardened callers — re-install to lay down the wrapper.
  if [ -x "$IF_HOME/git/bin/git.real" ]; then
    have_git=true
  fi
else
  git_path="$(command -v git 2>/dev/null || true)"
  if [ -n "$git_path" ]; then
    case "$git_path" in
      /usr/bin/git)
        # macOS ships /usr/bin/git as a stub that triggers the CLT install
        # dialog when invoked. Real only once Xcode CLT/app is installed.
        xcode-select -p >/dev/null 2>&1 && have_git=true
        ;;
      *) have_git=true ;;
    esac
  fi
fi

have_gh=false
if [ -x "$IF_HOME/gh/bin/gh" ]; then
  have_gh=true
elif command -v gh >/dev/null 2>&1; then
  have_gh=true
fi
log "i: detection done — have_git=$have_git have_gh=$have_gh"

# ==========================================================================
# Build the install list — same shape as scripts/setup-project's PROV_* arrays.
# Already-installed items still appear in the list (rendered green from
# the start) so the user sees the full picture, not a mystery skip.
# ==========================================================================

PENDING=()
RUNNING=()
DONE=()
FNS=()
INSTALLED=()  # parallel array of "true"/"false" — initial state per row

PENDING+=("install git");  RUNNING+=("installing git"); DONE+=("git installed"); FNS+=("_install_git"); INSTALLED+=("$have_git")
PENDING+=("install gh");   RUNNING+=("installing gh");  DONE+=("gh installed");  FNS+=("_install_gh");  INSTALLED+=("$have_gh")

N=${#FNS[@]}

# Count how many actually need work.
N_TODO=0
for x in "${INSTALLED[@]}"; do
  [ "$x" = "false" ] && N_TODO=$((N_TODO + 1))
done

# ==========================================================================
# Row UI (same shape as scripts/setup-project draw_prov_row / update_prov_row)
# ==========================================================================

draw_row() {
  local i="$1" state="$2"
  local icon color label
  case "$state" in
    done)    icon="${C_GRN}✓${C_RST}";  color="$C_GRN";  label="${DONE[$i]}"    ;;
    running) icon="${C_GRAY}⋯${C_RST}"; color="$C_GRAY"; label="${RUNNING[$i]}" ;;
    pending) icon="${C_GRAY}○${C_RST}"; color="$C_GRAY"; label="${PENDING[$i]}" ;;
    failed)  icon="${C_RED}✗${C_RST}";  color="$C_RED";  label="${RUNNING[$i]}" ;;
  esac
  printf '%b  %b%s%b\n' "$icon" "$color" "$label" "$C_RST"
}

update_row() {
  local i="$1" state="$2"
  local up=$((N - i))
  printf '\033[%dA\r\033[K' "$up"
  draw_row "$i" "$state"
  local down=$((N - i - 1))
  if [ "$down" -gt 0 ]; then
    printf '\033[%dB\r' "$down"
  fi
}

# ==========================================================================
# First: install git + gh
# ==========================================================================

echo ""
echo ""
heading "First: Installing git and github software."
echo ""
echo "Techy bits you'll get to know later. We use it for installing stuff for you today."
echo ""

# Render initial state — already-installed rows green from the start.
for i in $(seq 0 $((N - 1))); do
  if [ "${INSTALLED[$i]}" = "true" ]; then
    draw_row "$i" "done"
  else
    draw_row "$i" "pending"
  fi
done

# Run pending installs with in-place row updates.
for i in "${!FNS[@]}"; do
  [ "${INSTALLED[$i]}" = "true" ] && { log "i: row $i (${PENDING[$i]}) already installed — skip"; continue; }
  log "i: row $i — calling ${FNS[$i]}"
  update_row "$i" "running"
  rc=0
  "${FNS[$i]}" >> "$INSTALL_LOG" 2>&1 || rc=$?
  log "i: row $i — ${FNS[$i]} returned rc=$rc"
  if [ "$rc" -eq 0 ]; then
    update_row "$i" "done"
  else
    update_row "$i" "failed"
    echo ""
    die "install of ${PENDING[$i]} failed (rc=$rc) — see $INSTALL_LOG"
  fi
done
log "i: all install rows finished"

# Make our just-installed binaries usable for the rest of this run.
# (PATH/zshrc setup is scripts/install-dependencies's job, not ours.)
export PATH="$IF_HOME/gh/bin:$IF_HOME/git/bin:$PATH"
[ -d "$IF_HOME/git/lib" ] && export DYLD_FALLBACK_LIBRARY_PATH="$IF_HOME/git/lib"

# ==========================================================================
# Next: signing into github (signpost — only when a manual step is needed)
# ==========================================================================

if ! gh auth status >/dev/null 2>&1; then
  echo ""
  echo ""
  heading "instructions for the next step: signing into github"
  echo ""
  echo "This bit involves a manual step from you. Here's what's going to happen next and what you need to do .."
  cat <<SIGNPOST

  - github will prompt for:
    - where do you use github                        ${C_GRAY}<- accept github.com${C_RST}
    - preferred protocol                             ${C_GRAY}<- accept https${C_RST}
    - authenticate git with ...                      ${C_GRAY}<- accept y${C_RST}
    - login method                                   ${C_GRAY}<- accept login with browser${C_RST}

  - then log in and connect your account: 
    - copy the code github gives you in the terminal
    - then hit enter to trigger the browser
    - log into your github account
    - paste the code when prompted
    - choose authorize github
    - return here when it's done

  ${C_GRAY}press enter when you're ready${C_RST}
SIGNPOST
  read -r _ </dev/tty || true
fi

# ==========================================================================
# Now: github's doing its bit (gh auth login when needed; sync staging
# silently in either case)
# ==========================================================================

# Heading + visible gh auth login only when login is actually needed —
# the silent sync below doesn't warrant its own header.
if ! gh auth status >/dev/null 2>&1; then
  echo ""
  heading "Now: github's doing its bit.."
  echo ""
  # Direct invocation (no pipe-filter): gh isatty()-checks stdout and
  # downgrades the UI when piped — including dropping the auto browser
  # launch. Live with the one verbose `- gh config set ...` line in
  # exchange for the working flow.
  if ! gh auth login </dev/tty; then
    echo ""
    die "github sign-in didn't complete"
  fi
fi

# Sync ~/.if/staging silently. Clone if missing; --ff-only pull if
# present. Pull failures (local divergence) are non-fatal — warn and
# use the existing checkout. Clone failures ARE fatal: pattern-match
# the log tail to distinguish permission vs other (network / dylib).
if [ -d "$IF_HOME/staging/.git" ]; then
  if ! ( cd "$IF_HOME/staging" && git pull --ff-only --quiet ) >> "$INSTALL_LOG" 2>&1; then
    echo ""
    echo "warning: couldn't pull latest from origin (local changes?). using existing checkout."
  fi
else
  if ! gh repo clone almostawake/if "$IF_HOME/staging" >> "$INSTALL_LOG" 2>&1; then
    echo ""
    if tail -20 "$INSTALL_LOG" | grep -qiE '404|not found|could not resolve host|repository not found'; then
      echo "looks like a permissions issue — you may not have been added as"
      echo "a collaborator yet. request access at https://almostawake.com."
    else
      echo "clone failed — see log tail below."
    fi
    exit 1
  fi
fi

# Clear EXIT trap on success — no need to dump the log.
trap - EXIT

# Two blank lines before this heading (extra breathing room for the
# transition into the bigger install phase).
echo ""
echo ""
heading "Right, now let's install the core technologies you'll be using for your projects:"
echo ""

# Hand off to the full installer in ~/.if/staging. exec replaces this
# process so PATH / dev/tty / env carry over cleanly.
exec bash "$IF_HOME/staging/scripts/install-dependencies"
