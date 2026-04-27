#!/bin/bash
#
# almostawake.com/install.sh — bootstrap for if (impatient futurist)
#
# Installs git and gh into ~/.if/, mirroring if-install.sh's contained
# install convention (no Homebrew). Auth + repo cloning happen later.
#
set -e

# ==========================================================================
# Helpers (lifted from if-lib.sh — inlined because the bootstrap can't
# depend on the private repo before it's cloned)
# ==========================================================================

if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_GRAY=$'\033[90m'
  C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_GRAY=""; C_BLD=""; C_RST=""
fi

die() { printf "${C_RED}error:${C_RST} %s\n" "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

prompt_yn() {
  local q="$1" def="$2" hint answer
  if [ "$def" = "Y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  printf '%s %s ' "$q" "$hint"
  read -r answer </dev/tty || answer=""
  [ -z "$answer" ] && answer="$def"
  case "$answer" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

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
INSTALL_LOG="/tmp/if-install.log"
: > "$INSTALL_LOG"

# Surface log tail on abnormal exit.
trap '_rc=$?; if [ $_rc -ne 0 ]; then
  printf "\n\n--- last 40 lines of %s ---\n" "$INSTALL_LOG" >&2
  tail -n 40 "$INSTALL_LOG" >&2
  printf "\n(full log: %s)\n" "$INSTALL_LOG" >&2
fi' EXIT

detect_os_arch

MACOS_CODENAME=""
if [ "$OS" = "darwin" ]; then
  case "$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)" in
    14) MACOS_CODENAME="sonoma"  ;;
    15) MACOS_CODENAME="sequoia" ;;
    26) MACOS_CODENAME="tahoe"   ;;
  esac
fi

# ==========================================================================
# Install helpers (lifted verbatim from scripts/if-install.sh)
# ==========================================================================

# Pull a single Homebrew bottle (binary archive) from ghcr.io and extract
# it into $stage. Does NOT install Homebrew the tool — just uses its CDN.
fetch_bottle() {
  local pkg="$1" tag="$2" stage="$3"
  local json url token
  json=$(curl -fsSL "https://formulae.brew.sh/api/formula/${pkg}.json") || return 1
  url=$(printf '%s' "$json" | perl -MJSON::PP -e "
    my \$j = decode_json(join('', <STDIN>));
    my \$f = \$j->{bottle}{stable}{files}{'${tag}'};
    print \$f->{url} if \$f;") || return 1
  [ -z "$url" ] && return 1
  token=$(curl -fsSL "https://ghcr.io/token?service=ghcr.io&scope=repository:homebrew/core/${pkg}:pull" \
    | perl -MJSON::PP -e 'my $j = decode_json(join("",<STDIN>)); print $j->{token}') || return 1
  curl -fsSL -H "Authorization: Bearer $token" "$url" | tar -xz -C "$stage" || return 1
}

# git — ARM uses Homebrew bottle extraction (no CLT), Intel falls back to
# xcode-select --install (GUI dialog).
_install_git() {
  if [ "$OS" = "darwin" ] && [ "$ARCH" = "arm64" ] && [ -n "$MACOS_CODENAME" ]; then
    _install_git_bottle "arm64_${MACOS_CODENAME}" && return 0
    # Fall through to CLT on bottle failure.
  fi
  _install_git_xcode
}

_install_git_bottle() {
  local tag="$1"
  local stage; stage=$(mktemp -d)
  fetch_bottle git     "$tag" "$stage" || { rm -rf "$stage"; return 1; }
  fetch_bottle pcre2   "$tag" "$stage" || { rm -rf "$stage"; return 1; }
  fetch_bottle gettext "$tag" "$stage" || { rm -rf "$stage"; return 1; }
  local git_ver pcre2_ver gettext_ver
  git_ver=$(ls "$stage/git" | head -1)
  pcre2_ver=$(ls "$stage/pcre2" | head -1)
  gettext_ver=$(ls "$stage/gettext" | head -1)
  rm -rf "$IF_HOME/git"
  mkdir -p "$IF_HOME/git/lib"
  cp -R "$stage/git/$git_ver/." "$IF_HOME/git/"
  cp "$stage/pcre2/$pcre2_ver/lib/libpcre2-8.0.dylib" "$IF_HOME/git/lib/"
  cp "$stage/gettext/$gettext_ver/lib/libintl.8.dylib" "$IF_HOME/git/lib/"
  rm -rf "$stage"
  # The git bottle dlopens libintl.8.dylib via @@HOMEBREW_PREFIX@@ paths
  # that don't exist on this machine; we redirect to ~/.if/git/lib via
  # DYLD_FALLBACK_LIBRARY_PATH. But that env var is stripped by dyld when
  # loading any hardened-runtime binary (gh, codesign-restricted shells).
  # So when gh runs git as a subprocess, DYLD has already been wiped from
  # gh's env and git fails with "Symbol not found: _libintl_bind_*".
  # Fix: replace bin/git with a /bin/bash wrapper that exports DYLD and
  # exec's the real binary. The wrapper's exec→git is unhardened, so the
  # var survives. Wrap entry points in bin/ — internal helpers in
  # libexec/git-core/ are spawned by git itself and inherit env normally.
  mv "$IF_HOME/git/bin/git" "$IF_HOME/git/bin/git.real"
  cat > "$IF_HOME/git/bin/git" <<'WRAP'
#!/bin/bash
# DYLD_FALLBACK_LIBRARY_PATH: bottle dlopens libintl.8.dylib via an
# unsubstituted @@HOMEBREW_PREFIX@@ path that doesn't exist; we ship it
# at ~/.if/git/lib. dyld strips DYLD_* env vars when loading hardened
# binaries (gh, signed shells), so we re-set it here in the wrapper —
# the real git is unhardened, so the var survives the exec.
# GIT_EXEC_PATH: the bottle's compiled-in libexec path is also an
# unsubstituted placeholder. Without this, `git clone https://...` etc.
# fail because git can't find git-remote-https in libexec/git-core/.
export DYLD_FALLBACK_LIBRARY_PATH="$HOME/.if/git/lib${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
export GIT_EXEC_PATH="$HOME/.if/git/libexec/git-core"
exec "$HOME/.if/git/bin/git.real" "$@"
WRAP
  chmod +x "$IF_HOME/git/bin/git"
  # Smoke test BOTH a builtin (--version, exercises libintl) and a
  # libexec-dependent path (-c help.format=man help -i, no — too noisy).
  # Just --version is enough for libintl; libexec is covered structurally.
  "$IF_HOME/git/bin/git" --version >/dev/null
}

_install_git_xcode() {
  if xcode-select -p >/dev/null 2>&1; then return 0; fi
  xcode-select --install 2>/dev/null || true
  while ! xcode-select -p >/dev/null 2>&1; do sleep 10; done
}

_install_gh() {
  local arch_gh
  case "$ARCH" in
    arm64) arch_gh="arm64" ;;
    x64)   arch_gh="amd64" ;;
    *) die "gh: unsupported arch $ARCH" ;;
  esac
  local url
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
  local tmp_zip tmp_dir
  tmp_zip=$(mktemp -u).zip
  tmp_dir=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp_zip"
  unzip -q "$tmp_zip" -d "$tmp_dir"
  rm -rf "$IF_HOME/gh"
  mv "$(ls -d "$tmp_dir"/*/)" "$IF_HOME/gh"
  rm -rf "$tmp_zip" "$tmp_dir"
}

# ==========================================================================
# Detection
# ==========================================================================

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

# ==========================================================================
# Build the install list — same shape as if-new.sh's PROV_* arrays.
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
# Row UI (same shape as if-new.sh draw_prov_row / update_prov_row)
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
# Banner
# ==========================================================================

cat <<BANNER

┌───────────────────────────────────────────────────┐
│          welcome, impatient futurist (if)         │
└───────────────────────────────────────────────────┘

BANNER

# Render the full list — already-installed rows green from the start,
# the rest pending.
for i in $(seq 0 $((N - 1))); do
  if [ "${INSTALLED[$i]}" = "true" ]; then
    draw_row "$i" "done"
  else
    draw_row "$i" "pending"
  fi
done
echo ""

# Only prompt + run the install loop if there's actually something to do.
# If everything's already installed we fall straight through to auth+clone.
if [ "$N_TODO" -gt 0 ]; then
  if ! prompt_yn "Ready to get started?" "Y"; then
    say "no changes made. goodbye."
    trap - EXIT
    exit 0
  fi

  # Wipe the prompt + blank line so cursor returns to "after last row".
  printf '\033[2A\033[J'

  # Run each pending install with in-place row updates.
  for i in "${!FNS[@]}"; do
    if [ "${INSTALLED[$i]}" = "true" ]; then
      continue
    fi
    update_row "$i" "running"
    rc=0
    "${FNS[$i]}" >> "$INSTALL_LOG" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
      update_row "$i" "done"
    else
      update_row "$i" "failed"
      echo ""
      die "install of ${PENDING[$i]} failed (rc=$rc) — see $INSTALL_LOG"
    fi
  done
fi

# ==========================================================================
# Auth + clone (in this same subshell — PATH/zshrc are if-install.sh's job)
# ==========================================================================

# Make our just-installed binaries usable for the rest of this run.
export PATH="$IF_HOME/gh/bin:$IF_HOME/git/bin:$PATH"
# git on Apple Silicon is a Homebrew bottle with @@HOMEBREW_PREFIX@@ baked
# in; we ship its libs alongside in $IF_HOME/git/lib and resolve via
# DYLD_FALLBACK_LIBRARY_PATH for any git invocation in this script.
[ -d "$IF_HOME/git/lib" ] && export DYLD_FALLBACK_LIBRARY_PATH="$IF_HOME/git/lib"

echo ""

# --- gh auth ---
if gh auth status >/dev/null 2>&1; then
  printf '%b  github authenticated\n' "${C_GRN}✓${C_RST}"
else
  cat <<SIGNPOST

${C_BLD}Next: signing into github${C_RST}

  - github will prompt for:
    - where do you use github       ${C_GRAY}<- select github.com${C_RST}
    - preferred protocol            ${C_GRAY}<- select https${C_RST}
    - login method                  ${C_GRAY}<- select login with browser${C_RST}
  - copy the code github gives you in the terminal
  - then hit enter to trigger the browser
  - paste the code when prompted
  - choose authorize github
  - return here when it's done

  ${C_GRAY}press enter when you're ready${C_RST}
SIGNPOST
  read -r _ </dev/tty || true
  echo ""
  if ! gh auth login </dev/tty; then
    echo ""
    die "github sign-in didn't complete"
  fi
  echo ""
  printf '%b  github authenticated\n' "${C_GRN}✓${C_RST}"
fi

# --- git credential helper ---
# Idempotent — registers gh as the helper for github.com so plain `git`
# commands (e.g., `git pull`) authenticate via gh's stored token.
gh auth setup-git >> "$INSTALL_LOG" 2>&1

# --- clone the if repo ---
if [ -d "$IF_HOME/staging/.git" ]; then
  printf '%b  if repo present at ~/.if/staging\n' "${C_GRN}✓${C_RST}"
else
  printf '%b  cloning almostawake/if\n' "${C_GRAY}⋯${C_RST}"
  if ! gh repo clone almostawake/if "$IF_HOME/staging" >> "$INSTALL_LOG" 2>&1; then
    printf '\033[1A\r\033[K'
    printf '%b  couldn'\''t clone almostawake/if\n' "${C_RED}✗${C_RST}"
    echo ""
    echo "you may not have been added as a collaborator yet."
    echo "request access at https://almostawake.com — we'll email you when approved."
    exit 1
  fi
  printf '\033[1A\r\033[K'
  printf '%b  if repo cloned to ~/.if/staging\n' "${C_GRN}✓${C_RST}"
fi

# Clear EXIT trap on success — no need to dump the log.
trap - EXIT

echo ""
echo "next: bash ~/.if/staging/scripts/if-install.sh"
echo ""
