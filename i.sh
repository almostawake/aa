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
  DYLD_FALLBACK_LIBRARY_PATH="$IF_HOME/git/lib" "$IF_HOME/git/bin/git" --version >/dev/null
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

have_git=false
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

have_gh=false
command -v gh >/dev/null 2>&1 && have_gh=true

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

# Short-circuit if nothing to do.
if [ "$N_TODO" -eq 0 ]; then
  trap - EXIT
  exit 0
fi

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

# Clear EXIT trap on success — no need to dump the log.
trap - EXIT

echo ""
echo "git + gh in place. (auth + clone come next.)"
echo ""
