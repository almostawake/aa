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
  local json url token pkg_repo
  # ghcr.io scope uses slash form for versioned formulae: openssl@3 →
  # openssl/3. The formulae.brew.sh API itself accepts both. Token
  # endpoint 400s on the @ form — substitute before constructing scope.
  pkg_repo=$(printf '%s' "$pkg" | tr '@' '/')
  json=$(curl -fsSL "https://formulae.brew.sh/api/formula/${pkg}.json") || return 1
  url=$(printf '%s' "$json" | perl -MJSON::PP -e "
    my \$j = decode_json(join('', <STDIN>));
    my \$f = \$j->{bottle}{stable}{files}{'${tag}'};
    print \$f->{url} if \$f;") || return 1
  [ -z "$url" ] && return 1
  token=$(curl -fsSL "https://ghcr.io/token?service=ghcr.io&scope=repository:homebrew/core/${pkg_repo}:pull" \
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
  # The Homebrew git bottle is dynamically linked to a graph of libs we
  # have to ship alongside, because:
  #   - git itself wants libpcre2 + libintl (gettext) at @@HOMEBREW_PREFIX@@
  #     paths that don't exist on a clean machine.
  #   - git-remote-http (the HTTPS helper) is linked to /usr/lib/libcurl.4
  #     but expects newer-libcurl symbols (e.g. _curl_global_trace) that
  #     macOS Sonoma 14.0–14.3 doesn't export. We ship Homebrew's libcurl
  #     to override.
  #   - Homebrew's libcurl drags in: openssl@3 (libssl, libcrypto),
  #     libnghttp2, libnghttp3, libngtcp2 (+ libngtcp2_crypto_ossl),
  #     libssh2, brotli (libbrotlidec + libbrotlicommon), zstd.
  # Total ~8MB of dylibs. Closure is closed (verified empirically with
  # otool — no surprise transitive deps beyond stable system frameworks).
  for p in git pcre2 gettext curl openssl@3 libnghttp2 libnghttp3 libngtcp2 libssh2 brotli zstd; do
    fetch_bottle "$p" "$tag" "$stage" || { rm -rf "$stage"; return 1; }
  done
  rm -rf "$IF_HOME/git"
  mkdir -p "$IF_HOME/git/lib"
  cp -R "$stage/git/"*"/." "$IF_HOME/git/"
  # Each cp uses the leaf name dyld actually looks up via LC_LOAD_DYLIB.
  # Some are symlinks in the bottle (e.g. libnghttp3.9.dylib → ...9.6.1.dylib);
  # plain `cp` follows symlinks, so the destination is a real file.
  cp "$stage/pcre2/"*"/lib/libpcre2-8.0.dylib"               "$IF_HOME/git/lib/"
  cp "$stage/gettext/"*"/lib/libintl.8.dylib"                "$IF_HOME/git/lib/"
  cp "$stage/curl/"*"/lib/libcurl.4.dylib"                   "$IF_HOME/git/lib/"
  cp "$stage/openssl@3/"*"/lib/libssl.3.dylib"               "$IF_HOME/git/lib/"
  cp "$stage/openssl@3/"*"/lib/libcrypto.3.dylib"            "$IF_HOME/git/lib/"
  cp "$stage/libnghttp2/"*"/lib/libnghttp2.14.dylib"         "$IF_HOME/git/lib/"
  cp "$stage/libnghttp3/"*"/lib/libnghttp3.9.dylib"          "$IF_HOME/git/lib/"
  cp "$stage/libngtcp2/"*"/lib/libngtcp2.16.dylib"           "$IF_HOME/git/lib/"
  cp "$stage/libngtcp2/"*"/lib/libngtcp2_crypto_ossl.0.dylib" "$IF_HOME/git/lib/"
  cp "$stage/libssh2/"*"/lib/libssh2.1.dylib"                "$IF_HOME/git/lib/"
  cp "$stage/brotli/"*"/lib/libbrotlidec.1.dylib"            "$IF_HOME/git/lib/"
  cp "$stage/brotli/"*"/lib/libbrotlicommon.1.dylib"         "$IF_HOME/git/lib/"
  cp "$stage/zstd/"*"/lib/libzstd.1.dylib"                   "$IF_HOME/git/lib/"
  rm -rf "$stage"
  # Wrap bin/git so the right env is in scope when the real binary
  # runs. Without the wrapper, gh-spawned git inherits a stripped
  # environment (dyld drops DYLD_* vars when loading hardened binaries
  # like gh and codesigned shells) and clone/fetch fail.
  #
  # DYLD_LIBRARY_PATH (not _FALLBACK_): we need to OVERRIDE, not just
  # supplement. git-remote-http has /usr/lib/libcurl.4.dylib as an
  # embedded LC_LOAD_DYLIB; FALLBACK only fires when dyld fails to
  # resolve the embedded path, but /usr/lib/libcurl.4.dylib does
  # resolve — it just lacks the symbols git was built against.
  # DYLD_LIBRARY_PATH wins by leaf-name lookup before the embedded
  # path is even tried.
  #
  # GIT_EXEC_PATH: bottle's compiled-in libexec path is an unsubstituted
  # @@HOMEBREW_PREFIX@@ placeholder. Without this, git can't find
  # git-remote-https / git-fetch-pack / etc.
  #
  # SSL_CERT_FILE / CURL_CA_BUNDLE: Homebrew openssl baked in a path of
  # @@HOMEBREW_PREFIX@@/etc/openssl@3/cert.pem for CA roots. macOS
  # ships /etc/ssl/cert.pem (≈330KB, kept current by securityd) — point
  # at that so TLS handshake validates github.com's cert.
  mv "$IF_HOME/git/bin/git" "$IF_HOME/git/bin/git.real"
  cat > "$IF_HOME/git/bin/git" <<'WRAP'
#!/bin/bash
export DYLD_LIBRARY_PATH="$HOME/.if/git/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export GIT_EXEC_PATH="$HOME/.if/git/libexec/git-core"
export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/cert.pem}"
export CURL_CA_BUNDLE="${CURL_CA_BUNDLE:-/etc/ssl/cert.pem}"
exec "$HOME/.if/git/bin/git.real" "$@"
WRAP
  chmod +x "$IF_HOME/git/bin/git"
  # End-to-end smoke test: --version exercises libintl, ls-remote
  # exercises the entire HTTPS chain (git → git-remote-http → libcurl
  # → libssl → libcrypto → CA file). If any of these break on this
  # macOS, return non-zero and let _install_git fall through to the
  # Xcode CLT path.
  "$IF_HOME/git/bin/git" --version >/dev/null
  "$IF_HOME/git/bin/git" ls-remote https://github.com/octocat/Hello-World.git HEAD >/dev/null 2>&1
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

cat <<PLAN
Let's save you a few months of pain and suffering by installing
everything you need in a couple of minutes. When we're done you'll
be able to kick off your first project, which will be live in
another few minutes.

PLAN

if ! prompt_yn "Ready to go?" "Y"; then
  say ""
  say "no changes made. goodbye."
  trap - EXIT
  exit 0
fi

# ==========================================================================
# First: install git + gh
# ==========================================================================

echo ""
echo ""
printf '%bFirst: Installing git and github software.%b\n' "$C_BLD" "$C_RST"
echo ""
echo "Techy stuff you'll get to know later. We use it for installing stuff for you today."
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
  [ "${INSTALLED[$i]}" = "true" ] && continue
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

# Make our just-installed binaries usable for the rest of this run.
# (PATH/zshrc setup is if-install.sh's job, not ours.)
export PATH="$IF_HOME/gh/bin:$IF_HOME/git/bin:$PATH"
[ -d "$IF_HOME/git/lib" ] && export DYLD_FALLBACK_LIBRARY_PATH="$IF_HOME/git/lib"

# ==========================================================================
# Next: signing into github (signpost — only when a manual step is needed)
# ==========================================================================

if ! gh auth status >/dev/null 2>&1; then
  echo ""
  echo ""
  printf '%bNext: signing into github%b\n' "$C_BLD" "$C_RST"
  echo ""
  echo "This bit involves a manual step from you. Here's what's going to happen.."
  cat <<SIGNPOST

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
fi

# ==========================================================================
# The github bit — actual auth + clone (only renders when there's work)
# ==========================================================================

need_login=false
need_clone=false
gh auth status >/dev/null 2>&1 || need_login=true
[ -d "$IF_HOME/staging/.git" ] || need_clone=true

if [ "$need_login" = "true" ] || [ "$need_clone" = "true" ]; then
  echo ""
  printf '%bThe github bit%b\n' "$C_BLD" "$C_RST"

  if [ "$need_login" = "true" ]; then
    # Run gh auth login directly (no pipe-filter): when gh's stdout is
    # piped, gh detects the non-tty and switches to a less-interactive
    # mode that doesn't auto-launch the browser. Worth keeping the
    # one verbose `- gh config set ...` line for the working flow.
    if ! gh auth login </dev/tty; then
      echo ""
      die "github sign-in didn't complete"
    fi
  fi

  if [ "$need_clone" = "true" ]; then
    # gh's "Could not resolve" / "not found" / "404" are permission/repo
    # issues; anything else is dylib/network/etc. — keep that distinction
    # in the failure message rather than blaming permissions for everything.
    clone_err=$(gh repo clone almostawake/if "$IF_HOME/staging" 2>&1 | tee -a "$INSTALL_LOG")
    clone_rc=${PIPESTATUS[0]}
    if [ "$clone_rc" -ne 0 ]; then
      echo ""
      if printf '%s' "$clone_err" | grep -qiE '404|not found|could not resolve host|repository not found'; then
        echo "looks like a permissions issue — you may not have been added as"
        echo "a collaborator yet. request access at https://almostawake.com."
      else
        echo "clone failed — see error above and the log tail below."
      fi
      exit 1
    fi
  fi
fi

# Clear EXIT trap on success — no need to dump the log.
trap - EXIT

# Hand off to the full installer (lives in the freshly cloned repo).
# `exec` replaces this process so the user sees a clean transition;
# PATH/dev/tty/env all carry over.
echo ""
exec bash "$IF_HOME/staging/scripts/if-install.sh"
