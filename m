#!/bin/bash
#
# m — temp dev variant of n. Runs install checks + install rows +
# configure (terminal/workspace/dock) + zshrc, then opens VS Code at
# $PROJECT_DIR. NO sign-in, NO GCP/Firebase plumbing, NO project
# clone/deploy. For iterating on the install path without burning the
# full provisioning flow each run.
#
# Diverges from n at end of section 9; sections 10–14 dropped.
#
# SECTIONS (search "^# ====" for jumps):
#    1. CONSTANTS + BASIC HELPERS
#    2. LOGGING + EXIT TRAP
#    3. OS / ARCH DETECTION
#    4. DETECT WHAT'S INSTALLED
#    5. WELCOME BANNER + OPT-IN
#    6. INSTALL HELPERS (git, gh, node, java, claude, chrome, vscode)
#    7. CONFIGURE HELPERS (terminal, workspace, dock)
#    8. ZSHRC MARKER BLOCK
#    9. ROW UI + INSTALL/CONFIGURE ORCHESTRATOR
#   10. OPEN VS CODE AT $PROJECT_DIR

set -e

[ -t 1 ] && clear

# =====================================================================
# 1. CONSTANTS + BASIC HELPERS
# =====================================================================
# Deliberately monochrome — no colour anywhere in the script. Some
# terminal themes render certain ANSI colours invisible; relying only
# on glyphs + uppercase + horizontal rules for emphasis avoids that.

IF_HOME="$HOME/.if"
INSTALL_LOG="/tmp/if-install.log"
HTTP_LOG="${HTTP_LOG:-/tmp/if-new.log}"
TEMPLATE_REPO="https://github.com/almostawake/if.git"
NODE_VERSION="22.11.0"
JAVA_VERSION="21"
MARKER_START="# >>> if install >>>"
MARKER_END="# <<< if install <<<"

mkdir -p "$IF_HOME"
: > "$INSTALL_LOG"

say()     { printf '%s\n' "$*"; }
die()     { printf 'error: %s\n' "$*" >&2; exit 1; }

prompt_yn() {
  local q="$1" def="$2" hint answer
  if [ "$def" = "Y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  printf '%s %s ' "$q" "$hint"
  read -r answer </dev/tty || answer=""
  [ -z "$answer" ] && answer="$def"
  case "$answer" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# Open URL via the Chrome-with-Claude-Code launcher when present (lands
# in the Claude profile so dev tooling sees it). Falls back to system
# default browser pre-install or on Linux.
chrome_open() {
  local url="$1"
  local launcher="$HOME/Applications/Chrome with Claude Code.app/Contents/MacOS/Chrome with Claude Code"
  if [ -x "$launcher" ]; then
    "$launcher" "$url" >/dev/null 2>&1 &
    disown 2>/dev/null || true
    return 0
  fi
  if command -v open >/dev/null 2>&1; then open "$url"
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$url"
  fi
}

# =====================================================================
# 2. LOGGING + EXIT TRAP
# =====================================================================

log()       { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >> "$INSTALL_LOG"; }
http_log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$HTTP_LOG"; }
log_trunc() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-1000; }

# Surface log tail on abnormal exit — the only way to tell where we hung
# when the row UI just shows a spinner.
trap '_rc=$?; if [ $_rc -ne 0 ]; then
  printf "\n\n--- last 40 lines of %s ---\n" "$INSTALL_LOG" >&2
  tail -n 40 "$INSTALL_LOG" >&2
  printf "\n(full log: %s)\n" "$INSTALL_LOG" >&2
fi' EXIT

log "n: script start (pid=$$, user=$USER, shell=$SHELL)"
log "n: HOME=$HOME IF_HOME=$IF_HOME"

# =====================================================================
# 3. OS / ARCH DETECTION
# =====================================================================

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
detect_os_arch
log "n: detected OS=$OS ARCH=$ARCH"

MACOS_CODENAME=""
if [ "$OS" = "darwin" ]; then
  case "$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)" in
    14) MACOS_CODENAME="sonoma"  ;;
    15) MACOS_CODENAME="sequoia" ;;
    26) MACOS_CODENAME="tahoe"   ;;
  esac
fi

# Keep ~/ clean: route npm cache + Claude state under ~/.if/.
mkdir -p "$IF_HOME/npm-cache" "$IF_HOME/claude-config"
export NPM_CONFIG_CACHE="$IF_HOME/npm-cache"
export CLAUDE_CONFIG_DIR="$IF_HOME/claude-config"

# =====================================================================
# 4. DETECT WHAT'S INSTALLED
# =====================================================================
# Probes the contained install path first, then PATH. We run in a
# fresh non-interactive bash (curl | bash doesn't source rc files), so
# PATH usually doesn't include $IF_HOME/{node,java,claude,git,gh}/bin
# even when those installs exist — relying on `command -v` alone made
# the script re-install on every run.

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

have_node22=false
node_bin=""
if   [ -x "$IF_HOME/node/bin/node" ]; then node_bin="$IF_HOME/node/bin/node"
elif command -v node >/dev/null 2>&1;  then node_bin="node"
fi
if [ -n "$node_bin" ]; then
  nm="$("$node_bin" -v 2>/dev/null | sed 's/v//' | cut -d. -f1)"
  [ -n "$nm" ] && [ "$nm" -ge 22 ] 2>/dev/null && have_node22=true
fi

have_java21=false
java_bin=""
# Adoptium ships .jdk-shaped trees on macOS (Contents/Home/bin/java) and
# flat trees on Linux (bin/java). Check both.
if   [ -x "$IF_HOME/java/Contents/Home/bin/java" ]; then java_bin="$IF_HOME/java/Contents/Home/bin/java"
elif [ -x "$IF_HOME/java/bin/java" ];               then java_bin="$IF_HOME/java/bin/java"
elif command -v java >/dev/null 2>&1;               then java_bin="java"
fi
if [ -n "$java_bin" ]; then
  jm="$("$java_bin" -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d. -f1)"
  [ -n "$jm" ] && [ "$jm" -ge 21 ] 2>/dev/null && have_java21=true
fi

have_claude=false
if   [ -x "$IF_HOME/claude/bin/claude" ]; then have_claude=true
elif command -v claude >/dev/null 2>&1;   then have_claude=true
fi

# Chrome row represents Chrome.app + Claude-connected launcher together —
# only "installed" when both exist.
have_chrome=false
if [ "$OS" = "darwin" ]; then
  if [ -d "$HOME/Applications/Chrome with Claude Code.app" ] && \
     { [ -d "$HOME/Applications/Google Chrome.app" ] || \
       [ -d "/Applications/Google Chrome.app" ]; }; then
    have_chrome=true
  fi
fi

have_vscode=false
if [ "$OS" = "darwin" ] && [ -d "$HOME/Applications/Visual Studio Code.app" ]; then
  have_vscode=true
fi

log "n: detection — git=$have_git gh=$have_gh node22=$have_node22 java21=$have_java21 claude=$have_claude chrome=$have_chrome vscode=$have_vscode"

# Drive welcome / install-section visibility off this. Re-runs (everything
# already installed) skip welcome + install rows + configure entirely and
# go straight to project setup.
ITEMS=("git" "gh" "node 22" "java 21" "claude code [in YOLO mode]" "chrome [connected to Claude]" "vscode")
INSTALL_FNS=("_install_git" "_install_gh" "_install_node" "_install_java" "_install_claude" "_install_chrome" "_install_vscode")
INSTALLED=("$have_git" "$have_gh" "$have_node22" "$have_java21" "$have_claude" "$have_chrome" "$have_vscode")
N=${#ITEMS[@]}

N_TODO=0
for x in "${INSTALLED[@]}"; do [ "$x" = "false" ] && N_TODO=$((N_TODO + 1)); done

# =====================================================================
# 5. WARNING + OPT-IN
# =====================================================================
# Shown on every run. The acceptance is cheap (one "yes") and the
# reminder is worth re-surfacing — the user may have habits that slip.

echo ""
echo "Let's get you set up.  but first ..."
echo ""
echo "═══════════════════════════════ WARNING ═══════════════════════════════"
echo ""
echo "read the following warning and accept only if you're comfortable:"
echo ""
echo "  1. these tools are for hobby purposes, not to be used at work"
echo "  2. don't put sensitive data here until your security skills mature"
echo "  3. use separate mac and gmail accounts — not your daily ones"
echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo ""
# Cursor dance on bad input: write the error on the line below
# (where the user's enter just landed), then jump back UP to the
# prompt line and erase it so the loop's next prompt redraws clean.
# Net effect: error stays visible underneath, prompt sits right above
# it ready for another try. On success, erase the line below in case
# a stale error sits there.
while true; do
  printf "do you understand (yes/NO) "
  read -r _ack </dev/tty || _ack=""
  if [ "$_ack" = "yes" ]; then
    printf "\r\033[K"
    break
  fi
  printf "\r\033[K✗  type 'yes' (literally) to accept the warning"
  printf "\033[1A\r\033[K"
done

# =====================================================================
# 6. INSTALL HELPERS
# =====================================================================

# git — ARM downloads our pre-built bundle (~27MB compressed); Intel
# falls back to xcode-select.
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
}

# Single tar.gz: bin/git wrapper + bin/git.real + bin/* helpers,
# libexec/git-core/* (~180 helpers), lib/*.dylib (libpcre2, libintl,
# libcurl + closure: libssl, libcrypto, libnghttp2, libnghttp3,
# libngtcp2 + libngtcp2_crypto_ossl, libssh2, libbrotli{dec,common},
# libzstd). Wrapper sets DYLD_LIBRARY_PATH (override), GIT_EXEC_PATH,
# SSL_CERT_FILE, CURL_CA_BUNDLE so git-remote-http resolves dylibs and
# TLS roots correctly even when invoked from hardened parents (gh)
# that strip DYLD_* env vars.
#
# Built on Sonoma 14.1 arm64. tar -xz applies no quarantine xattr, so
# dyld doesn't see Gatekeeper warnings on first load. If the bundle's
# ad-hoc-signed dylibs get rejected on a stricter macOS (Tahoe enforces
# library-validation more strictly than Sonoma), the smoke test fails
# and we fall through to xcode-select.
_install_git_bundle() {
  log "_install_git_bundle: enter"
  rm -rf "$IF_HOME/git"
  log "_install_git_bundle: curl|tar starting"
  # curl exit code is fatal (network failure → no point smoke-testing).
  # tar exit code is advisory: BSD tar warns "Failed to restore metadata"
  # for system-set xattrs (com.apple.provenance) on symlinks but the
  # data extracts fine. We rely on smoke tests to decide success.
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

_install_node() {
  mkdir -p "$IF_HOME/node"
  local plat ext url
  case "$OS-$ARCH" in
    darwin-arm64) plat="darwin-arm64"; ext="tar.gz" ;;
    darwin-x64)   plat="darwin-x64";   ext="tar.gz" ;;
    linux-x64)    plat="linux-x64";    ext="tar.xz" ;;
    *) die "unsupported platform for Node: $OS-$ARCH" ;;
  esac
  url="https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-$plat.$ext"
  if [ "$ext" = "tar.xz" ]; then
    curl -fsSL "$url" | tar -xJ -C "$IF_HOME/node" --strip-components=1
  else
    curl -fsSL "$url" | tar -xz -C "$IF_HOME/node" --strip-components=1
  fi
  export PATH="$IF_HOME/node/bin:$PATH"
}

_install_java() {
  mkdir -p "$IF_HOME/java"
  local jplat jurl
  case "$OS-$ARCH" in
    darwin-arm64) jplat="mac/aarch64" ;;
    darwin-x64)   jplat="mac/x64"     ;;
    linux-x64)    jplat="linux/x64"   ;;
    *) die "unsupported platform for Java: $OS-$ARCH" ;;
  esac
  jurl="https://api.adoptium.net/v3/binary/latest/$JAVA_VERSION/ga/$jplat/jre/hotspot/normal/eclipse"
  curl -fsSL "$jurl" | tar -xz -C "$IF_HOME/java" --strip-components=1
  if [ "$OS" = "darwin" ]; then
    export JAVA_HOME="$IF_HOME/java/Contents/Home"
  else
    export JAVA_HOME="$IF_HOME/java"
  fi
  export PATH="$JAVA_HOME/bin:$PATH"
}

# Merge a "trust this directory" entry into ~/.if/claude-config/.claude.json.
# Idempotent — running twice is a no-op. Preserves the rest of the file
# (numStartups, tipsHistory, all the other onboarding state Claude Code
# reads/writes constantly).
_trust_path() {
  local trust_path="$1"
  local cred="$IF_HOME/claude-config/.claude.json"
  [ -f "$cred" ] || printf '{}\n' > "$cred"
  local tmp; tmp=$(mktemp)
  PATH_TO_TRUST="$trust_path" perl -MJSON::PP -e '
    local $/;
    my $j = decode_json(<STDIN>);
    $j->{projects}{$ENV{PATH_TO_TRUST}} //= {};
    $j->{projects}{$ENV{PATH_TO_TRUST}}{hasTrustDialogAccepted} = JSON::PP::true;
    $j->{projects}{$ENV{PATH_TO_TRUST}}{hasCompletedProjectOnboarding} = JSON::PP::true;
    print JSON::PP->new->pretty->canonical->encode($j);
  ' < "$cred" > "$tmp" && mv "$tmp" "$cred"
}

# Claude Code binary + YOLO config files. Theme is auto-picked from
# the user's macOS appearance on first install only — re-runs preserve
# whatever theme the user later picked via Claude's /theme command.
_install_claude() {
  mkdir -p "$IF_HOME/claude"
  export PATH="$IF_HOME/claude/bin:$PATH"
  npm install --prefix "$IF_HOME/claude" -g @anthropic-ai/claude-code

  mkdir -p "$IF_HOME/claude-config"
  # Seed config files from the bundled assets curl'd from our website.
  # Fetched on demand (rather than baked into this script) so we can
  # update them without bumping n.
  #
  # Layout under CLAUDE_CONFIG_DIR — files sit DIRECTLY in the dir,
  # NOT in a `.claude/` subdir. Verified the hard way: when settings
  # were at `<dir>/.claude/settings.json`, Claude Code silently
  # ignored them (autoInstallIdeExtension, defaultMode, statusline,
  # all of it). The dir IS the equivalent of `~/.claude/` itself.
  local base="https://almostawake.com"
  [ -f "$IF_HOME/claude-config/CLAUDE.md" ] || \
    curl -fsSL "$base/assets/claude.md" -o "$IF_HOME/claude-config/CLAUDE.md"
  [ -f "$IF_HOME/claude-config/settings.json" ] || \
    curl -fsSL "$base/assets/claude-settings.json" -o "$IF_HOME/claude-config/settings.json"

  local claude_json="$IF_HOME/claude-config/.claude.json"
  if [ ! -f "$claude_json" ]; then
    curl -fsSL "$base/assets/claude.json" -o "$claude_json"
    if [ "$OS" = "darwin" ]; then
      local theme="light"
      defaults read -g AppleInterfaceStyle 2>/dev/null | grep -q Dark && theme="dark"
      local tmp; tmp=$(mktemp)
      THEME="$theme" perl -MJSON::PP -e '
        local $/;
        my $j = decode_json(<STDIN>);
        $j->{theme} = $ENV{THEME};
        print JSON::PP->new->pretty->canonical->encode($j);
      ' < "$claude_json" > "$tmp" && mv "$tmp" "$claude_json"
    fi
  fi

  # Pre-trust common cwds so the "Do you trust this folder?" prompt
  # doesn't fire on first launch from VS Code / IF Terminal / wherever
  # users typically open Claude.
  _trust_path "$HOME/if"
  _trust_path "${PROJECT_DIR:-$HOME/Projects}"
}

# Chrome Stable + Chrome with Claude Code.app launcher.
_install_chrome() {
  _log() { echo "[$(date +%H:%M:%S)] chrome: $*"; }
  _log "start"
  [ "$OS" = "darwin" ] || { _log "not darwin, skipping"; return 0; }

  # 1. Install Chrome.app (skip if already present anywhere)
  local chrome_app=""
  [ -d "/Applications/Google Chrome.app" ]      && chrome_app="/Applications/Google Chrome.app"
  [ -d "$HOME/Applications/Google Chrome.app" ] && chrome_app="$HOME/Applications/Google Chrome.app"
  _log "existing chrome_app = [$chrome_app]"

  if [ -z "$chrome_app" ]; then
    local dmg; dmg=$(mktemp -u).dmg
    local mountpoint
    _log "downloading Chrome DMG to $dmg (~200MB)…"
    if ! curl -fSL --progress-bar \
         "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg" \
         -o "$dmg"; then
      _log "curl failed: exit=$?"
      rm -f "$dmg"
      return 1
    fi
    _log "DMG size: $(ls -la "$dmg" | awk '{print $5}') bytes"

    _log "hdiutil attach…"
    local attach_out
    attach_out=$(hdiutil attach "$dmg" -nobrowse -noverify -noautoopen 2>&1)
    _log "hdiutil output:"
    printf '%s\n' "$attach_out" | sed 's/^/    /'
    mountpoint=$(printf '%s' "$attach_out" \
      | awk '/\/Volumes\// { for (i=3; i<=NF; i++) printf "%s ", $i; print "" }' \
      | sed 's/ *$//' | head -1)
    _log "parsed mountpoint = [$mountpoint]"

    if [ -z "$mountpoint" ] || [ ! -d "$mountpoint/Google Chrome.app" ]; then
      _log "mount FAILED — mountpoint empty or Google Chrome.app missing at [$mountpoint]"
      [ -n "$mountpoint" ] && hdiutil detach "$mountpoint" -force -quiet 2>/dev/null || true
      rm -f "$dmg"
      return 1
    fi

    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Google Chrome.app"
    _log "cp Chrome.app from $mountpoint to ~/Applications/"
    cp -R "$mountpoint/Google Chrome.app" "$HOME/Applications/"
    xattr -dr com.apple.quarantine "$HOME/Applications/Google Chrome.app" 2>/dev/null || true
    _log "detaching DMG"
    hdiutil detach "$mountpoint" -quiet 2>/dev/null \
      || hdiutil detach "$mountpoint" -force -quiet 2>/dev/null \
      || true
    rm -f "$dmg"
    chrome_app="$HOME/Applications/Google Chrome.app"
    _log "chrome_app now = $chrome_app"
  fi

  # 2. Build/rebuild the launcher (always, so flag changes take effect on re-runs).
  local launcher_app="$HOME/Applications/Chrome with Claude Code.app"
  mkdir -p "$HOME/Applications"
  rm -rf "$launcher_app"
  mkdir -p "$launcher_app/Contents/MacOS"
  mkdir -p "$launcher_app/Contents/Resources"
  cp "$chrome_app/Contents/Resources/app.icns" "$launcher_app/Contents/Resources/app.icns" 2>/dev/null || true

  cat > "$launcher_app/Contents/Info.plist" <<'CHROMEPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Chrome with Claude Code</string>
  <key>CFBundleDisplayName</key>
  <string>Chrome with Claude Code</string>
  <key>CFBundleExecutable</key>
  <string>Chrome with Claude Code</string>
  <key>CFBundleIconFile</key>
  <string>app</string>
  <key>CFBundleIconName</key>
  <string>app</string>
  <key>CFBundleIdentifier</key>
  <string>com.almostawake.if.chrome-claude-code</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>10.15</string>
  <key>LSRequiresNativeExecution</key>
  <true/>
  <key>LSArchitecturePriority</key>
  <array>
    <string>arm64</string>
  </array>
</dict>
</plist>
CHROMEPLIST

  cat > "$launcher_app/Contents/MacOS/Chrome with Claude Code" <<CHROMELAUNCH
#!/bin/bash
# No kill-Chrome dance needed: Chrome with a different --user-data-dir
# coexists fine with the user's regular Chrome. If Chrome-Claude is
# already running, Chrome's process-singleton sends activation to the
# existing instance (URL args become tabs there); the new process exits
# immediately. Debug port stays alive either way.

PROFILE="\$HOME/Library/Application Support/Google/Chrome-Claude"

"$chrome_app/Contents/MacOS/Google Chrome" \\
  --remote-debugging-port=9222 \\
  --silent-debugger-extension-api \\
  --no-first-run \\
  --user-data-dir="\$PROFILE" \\
  "\$@" &>/dev/null &

# Wait up to 10s for the debug port. Returns near-instantly if already
# running; cold start takes ~2-4s.
for i in \$(seq 1 20); do
  sleep 0.5
  curl -s http://localhost:9222/json/version >/dev/null 2>&1 && break
done

# Drop a DevToolsActivePort file where the chrome-devtools MCP server
# looks for it (mirrors Chrome's default-profile behavior so MCP
# discovery "just works").
mkdir -p "\$HOME/Library/Application Support/Google/Chrome"
wspath=\$(curl -s http://localhost:9222/json/version | \\
  perl -MJSON::PP -e 'my \$j=decode_json(join("",<STDIN>)); my \$u=\$j->{webSocketDebuggerUrl} // ""; my (\$p) = \$u =~ m{:9222(.*)}; print \$p // ""')
printf '9222\n'"\${wspath}" > "\$HOME/Library/Application Support/Google/Chrome/DevToolsActivePort"
CHROMELAUNCH
  chmod +x "$launcher_app/Contents/MacOS/Chrome with Claude Code"
  touch "$launcher_app"
}

# VS Code: official zip from update.code.visualstudio.com, dropped into
# ~/Applications/. Bundled `code` CLI symlinked into ~/.if/vscode/bin/ so
# the zshrc PATH addition matches the pattern used by node/gh/claude/git.
# Settings + keybindings seeded only if absent (preserves user edits on
# re-runs); extensions installed only if missing.
_install_vscode() {
  log "_install_vscode: enter (OS=$OS ARCH=$ARCH)"
  [ "$OS" = "darwin" ] || { log "_install_vscode: not darwin, skipping"; return 0; }

  local arch_url
  case "$ARCH" in
    arm64) arch_url="darwin-arm64" ;;
    x64)   arch_url="darwin-x64"   ;;
    *) die "vscode: unsupported arch $ARCH" ;;
  esac

  local zip; zip=$(mktemp -u).zip
  log "_install_vscode: downloading https://update.code.visualstudio.com/latest/$arch_url/stable"
  if ! curl -fSL --progress-bar \
       "https://update.code.visualstudio.com/latest/$arch_url/stable" \
       -o "$zip"; then
    log "_install_vscode: curl failed: exit=$?"
    rm -f "$zip"
    return 1
  fi
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Visual Studio Code.app"
  log "_install_vscode: unzipping into ~/Applications/"
  unzip -q "$zip" -d "$HOME/Applications/"
  rm -f "$zip"
  xattr -dr com.apple.quarantine "$HOME/Applications/Visual Studio Code.app" 2>/dev/null || true
  touch "$HOME/Applications/Visual Studio Code.app"

  mkdir -p "$IF_HOME/vscode/bin"
  ln -sfn "$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
    "$IF_HOME/vscode/bin/code"
  export PATH="$IF_HOME/vscode/bin:$PATH"

  local code_user="$HOME/Library/Application Support/Code/User"
  mkdir -p "$code_user"
  local base="https://almostawake.com"
  [ -f "$code_user/settings.json" ] || \
    curl -fsSL "$base/assets/vscode-settings.json" -o "$code_user/settings.json"
  [ -f "$code_user/keybindings.json" ] || \
    curl -fsSL "$base/assets/vscode-keybindings.json" -o "$code_user/keybindings.json"

  local installed
  installed=$("$IF_HOME/vscode/bin/code" --list-extensions 2>/dev/null || true)
  local ext
  for ext in dbaeumer.vscode-eslint esbenp.prettier-vscode mechatroner.rainbow-csv mhutchie.git-graph; do
    if ! printf '%s\n' "$installed" | grep -qix "$ext"; then
      log "_install_vscode: installing extension $ext"
      "$IF_HOME/vscode/bin/code" --install-extension "$ext" --force >>"$INSTALL_LOG" 2>&1 || true
    fi
  done
}

# =====================================================================
# 7. CONFIGURE HELPERS (terminal, workspace, dock)
# =====================================================================

# Pre-configure Terminal.app so Option-Enter inserts a newline (what
# "shift-enter" in Claude Code actually needs).
_configure_terminal() {
  [ "$OS" = "darwin" ] || return 0
  local plist="$HOME/Library/Preferences/com.apple.Terminal.plist"
  [ -f "$plist" ] || return 0
  [ -f "${plist}.bak" ] || cp "$plist" "${plist}.bak"
  local profile
  profile=$(defaults read com.apple.Terminal "Default Window Settings" 2>/dev/null || echo "Basic")
  plutil -insert  "Window Settings.${profile}.useOptionAsMetaKey" -bool YES "$plist" 2>/dev/null \
    || plutil -replace "Window Settings.${profile}.useOptionAsMetaKey" -bool YES "$plist" 2>/dev/null \
    || true
}

# Dock helper: delete any :persistent-apps entry whose _CFURLString == $1.
_dock_apps_remove_url() {
  local target="$1"
  local plist="$HOME/Library/Preferences/com.apple.dock.plist"
  [ -f "$plist" ] || return 0
  local i=0
  while /usr/libexec/PlistBuddy -c "Print :persistent-apps:$i" "$plist" >/dev/null 2>&1; do
    i=$((i+1))
  done
  i=$((i-1))
  while [ $i -ge 0 ]; do
    local u
    u=$(/usr/libexec/PlistBuddy -c "Print :persistent-apps:$i:tile-data:file-data:_CFURLString" "$plist" 2>/dev/null || true)
    if [ "$u" = "$target" ]; then
      /usr/libexec/PlistBuddy -c "Delete :persistent-apps:$i" "$plist" 2>/dev/null || true
    fi
    i=$((i-1))
  done
  return 0
}

# Dock helper: prepend a new :persistent-apps entry at slot 0 for URL $1.
# Used in reverse order so final slot assignment lines up left-to-right.
_dock_apps_insert_at_zero() {
  local url="$1"
  local plist="$HOME/Library/Preferences/com.apple.dock.plist"
  echo "_dock_apps_insert_at_zero: $url"
  /usr/libexec/PlistBuddy -c "Add :persistent-apps:0 dict" "$plist" || true
  /usr/libexec/PlistBuddy -c "Add :persistent-apps:0:tile-data dict" "$plist" || true
  /usr/libexec/PlistBuddy -c "Add :persistent-apps:0:tile-data:file-data dict" "$plist" || true
  /usr/libexec/PlistBuddy -c "Add :persistent-apps:0:tile-data:file-data:_CFURLString string ${url}" "$plist" || true
  /usr/libexec/PlistBuddy -c "Add :persistent-apps:0:tile-data:file-data:_CFURLStringType integer 15" "$plist" || true
  /usr/libexec/PlistBuddy -c "Add :persistent-apps:0:tile-type string file-tile" "$plist" || true
  return 0
}

# Create ~/if workspace, point Finder there, pin to Dock, enable
# "Claude Code at Folder" + "New Terminal at Folder" Quick Actions.
#
# Why ~/if and not ~/: running claude in ~ makes it enumerate Documents,
# Downloads, Photos Library, Reminders, etc., which fires macOS TCC
# prompts. An empty work dir avoids all of that.
_configure_workspace() {
  [ "$OS" = "darwin" ] || return 0
  mkdir -p "$HOME/if"

  # Build IF Terminal.app via osacompile — proper applet bundle whose
  # executable IS a native Mach-O binary (the system applet runtime).
  # Why not a shell-script .app: macOS probes Contents/MacOS for a
  # Mach-O header to decide whether to offer Rosetta; scripts fail that
  # probe and trigger the Rosetta prompt even with LSRequiresNativeExecution
  # + arm64-only LSArchitecturePriority. osacompile sidesteps it — the
  # applet binary is universal. The body uses `do shell script` +
  # `open -a Terminal.app` (LaunchServices, no Apple Events TCC prompt).
  local if_term="$HOME/Applications/IF Terminal.app"
  rm -rf "$if_term"
  local tmp_scpt; tmp_scpt=$(mktemp).scpt
  cat > "$tmp_scpt" <<'IFTERMSCPT'
do shell script "open -a Terminal.app ~/if"
IFTERMSCPT
  osacompile -o "$if_term" "$tmp_scpt"
  rm -f "$tmp_scpt"

  local term_icns=""
  for candidate in \
      "/System/Applications/Utilities/Terminal.app/Contents/Resources/Terminal.icns" \
      "/Applications/Utilities/Terminal.app/Contents/Resources/Terminal.icns" ; do
    if [ -f "$candidate" ]; then term_icns="$candidate"; break; fi
  done
  if [ -z "$term_icns" ]; then
    local term_app
    term_app=$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.Terminal'" 2>/dev/null | head -1)
    [ -n "$term_app" ] && [ -f "$term_app/Contents/Resources/Terminal.icns" ] \
      && term_icns="$term_app/Contents/Resources/Terminal.icns"
  fi
  [ -n "$term_icns" ] && cp "$term_icns" "$if_term/Contents/Resources/applet.icns"

  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.almostawake.if.terminal" \
    "$if_term/Contents/Info.plist" 2>/dev/null || true

  # Bumping mtime forces LaunchServices/Dock to re-register the icon.
  touch "$if_term"

  # Install "Claude Code at Folder" Finder Quick Action. The .workflow
  # bundle was built once in Automator; we unzip it into ~/Library/Services/
  # and `pbs -update` below makes it show in the Finder right-click menu.
  mkdir -p "$HOME/Library/Services"
  rm -rf "$HOME/Library/Services/Claude Code at Folder.workflow"
  local quick_action_zip
  quick_action_zip=$(mktemp -u).zip
  if curl -fsSL https://almostawake.com/assets/quick-action.zip -o "$quick_action_zip" 2>/dev/null; then
    unzip -q -o "$quick_action_zip" -d "$HOME/Library/Services/" || true
    rm -rf "$HOME/Library/Services/__MACOSX"
    rm -f "$quick_action_zip"
  fi

  # === Pass 1: defaults write (cfprefsd in-memory cache) ===

  # New Finder windows default to ~/if — covers right-click New Folder
  # + right-click New Terminal at Folder workflow.
  defaults write com.apple.finder NewWindowTarget -string "PfLo" 2>/dev/null || true
  defaults write com.apple.finder NewWindowTargetPath -string "file://$HOME/if/" 2>/dev/null || true

  # Clean Dock: kill the Recents shelf so the right side doesn't fill
  # with whatever they happen to launch.
  defaults write com.apple.dock show-recents -bool false 2>/dev/null || true

  # === Flush cfprefsd ===
  # Force cfprefsd to flush its cache to disk before PlistBuddy edits the
  # dock plist. Without this, PlistBuddy's Save overwrites the file with
  # its stale on-disk view, losing the `defaults` writes.
  killall cfprefsd 2>/dev/null || true
  sleep 0.3

  # === Pass 2: PlistBuddy edits on disk ===

  # Strip the default Dock back to Safari + System Settings before
  # adding our entries. Walk persistent-apps in reverse so deletes
  # don't shift indices. Identity by bundle-identifier (more stable
  # than _CFURLString — that varies across macOS versions).
  local DOCK_PLIST="$HOME/Library/Preferences/com.apple.dock.plist"
  if [ -f "$DOCK_PLIST" ]; then
    local i bid
    i=0
    while /usr/libexec/PlistBuddy -c "Print :persistent-apps:$i" "$DOCK_PLIST" >/dev/null 2>&1; do
      i=$((i+1))
    done
    i=$((i-1))
    while [ "$i" -ge 0 ]; do
      bid=$(/usr/libexec/PlistBuddy -c "Print :persistent-apps:$i:tile-data:bundle-identifier" "$DOCK_PLIST" 2>/dev/null || true)
      case "$bid" in
        com.apple.Safari|com.apple.systempreferences) : ;;
        *) /usr/libexec/PlistBuddy -c "Delete :persistent-apps:$i" "$DOCK_PLIST" 2>/dev/null || true ;;
      esac
      i=$((i-1))
    done

    # Nuke right-side stacks (Downloads etc.) for a clean right side.
    i=0
    while /usr/libexec/PlistBuddy -c "Print :persistent-others:$i" "$DOCK_PLIST" >/dev/null 2>&1; do
      i=$((i+1))
    done
    i=$((i-1))
    while [ "$i" -ge 0 ]; do
      /usr/libexec/PlistBuddy -c "Delete :persistent-others:$i" "$DOCK_PLIST" 2>/dev/null || true
      i=$((i-1))
    done
  fi

  # Dock left side, immediately right of Finder:
  #   slot 0 — VS Code (pre-configured + auto-runs cc on folderOpen)
  #   slot 1 — Chrome with Claude Code (debug-port-enabled launcher)
  #   slot 2 — IF Terminal (opens new Terminal in ~/if)
  # Prepend in reverse order so final L-R is [vscode, chrome, term, ...rest].
  # Also remove the legacy shell.command URL so upgrading installs
  # don't leave a stale Dock entry.
  local url_vscode="file://$HOME/Applications/Visual%20Studio%20Code.app/"
  local url_chrome="file://$HOME/Applications/Chrome%20with%20Claude%20Code.app/"
  local url_term="file://$HOME/Applications/IF%20Terminal.app/"
  local url_shell_legacy="file://$HOME/.if/bin/shell.command"
  _dock_apps_remove_url "$url_vscode"
  _dock_apps_remove_url "$url_chrome"
  _dock_apps_remove_url "$url_term"
  _dock_apps_remove_url "$url_shell_legacy"
  _dock_apps_insert_at_zero "$url_term"
  _dock_apps_insert_at_zero "$url_chrome"
  _dock_apps_insert_at_zero "$url_vscode"

  # Apply Dock changes. Don't killall Finder — relaunch steals focus
  # from Terminal, making Claude's first-run "Trust this folder" prompt
  # unreachable. Prefs apply to next Cmd-N anyway.
  killall Dock 2>/dev/null || true

  # === Services: register, then force-enable ===
  /System/Library/CoreServices/pbs -update 2>/dev/null || true
  sleep 0.5

  # Flush cfprefsd so its cache of pbs.plist is discarded.
  killall cfprefsd 2>/dev/null || true
  sleep 0.3

  # Edit pbs.plist directly on disk. The defaults-write route through
  # cfprefsd silently reverts (cfprefsd cache vs pbs writes fight).
  # Going straight to disk wins. Schema matches what macOS writes when
  # the user manually ticks the Quick Actions checkbox.
  local pbs_plist="$HOME/Library/Preferences/pbs.plist"
  if [ -f "$pbs_plist" ]; then
    local key
    for key in \
        "com.apple.Terminal - Open Terminal at Folder - openTerminal" \
        "(null) - Claude Code at Folder - runWorkflowAsService" ; do
      /usr/libexec/PlistBuddy -c "Delete :NSServicesStatus:'${key}'" "$pbs_plist" 2>/dev/null || true
      /usr/libexec/PlistBuddy -c "Add :NSServicesStatus:'${key}' dict" "$pbs_plist"
      /usr/libexec/PlistBuddy -c "Add :NSServicesStatus:'${key}':presentation_modes dict" "$pbs_plist"
      /usr/libexec/PlistBuddy -c "Add :NSServicesStatus:'${key}':presentation_modes:ContextMenu integer 1" "$pbs_plist"
      /usr/libexec/PlistBuddy -c "Add :NSServicesStatus:'${key}':presentation_modes:FinderPreview integer 1" "$pbs_plist"
      /usr/libexec/PlistBuddy -c "Add :NSServicesStatus:'${key}':presentation_modes:ServicesMenu integer 1" "$pbs_plist"
      /usr/libexec/PlistBuddy -c "Add :NSServicesStatus:'${key}':presentation_modes:TouchBar integer 0" "$pbs_plist"
    done
  fi

  killall cfprefsd 2>/dev/null || true
}

# =====================================================================
# 8. ZSHRC MARKER BLOCK
# =====================================================================
# Always run — idempotent. Strips any prior block and rewrites. Catches
# users migrating from the old `i` + `setup-project` aliases that point
# at dead `~/.if/staging/...` paths.

_write_zshrc() {
  local zshrc="$HOME/.zshrc"
  [ -e "$zshrc" ] || touch "$zshrc"
  if [ -s "$zshrc" ]; then
    local ts; ts=$(date +%Y%m%d-%H%M)
    cp "$zshrc" "${zshrc}.${ts}.bak"
  fi
  if grep -qF "$MARKER_START" "$zshrc"; then
    local tmpf; tmpf=$(mktemp)
    awk -v s="$MARKER_START" -v e="$MARKER_END" '
      $0 == s { skip=1; next }
      $0 == e { skip=0; next }
      !skip  { print }
    ' "$zshrc" > "$tmpf"
    mv "$tmpf" "$zshrc"
  fi
  local jh_value
  if [ "$OS" = "darwin" ]; then
    jh_value="\$HOME/.if/java/Contents/Home"
  else
    jh_value="\$HOME/.if/java"
  fi
  {
    [ -s "$zshrc" ] && printf '\n'
    printf '%s\n' "$MARKER_START"
    printf 'export PATH="$HOME/.if/node/bin:$PATH"\n'
    printf 'export PATH="$HOME/.if/claude/bin:$PATH"\n'
    printf 'export PATH="$HOME/.if/gh/bin:$PATH"\n'
    printf '[ -x "$HOME/.if/vscode/bin/code" ] && export PATH="$HOME/.if/vscode/bin:$PATH"\n'
    printf '[ -x "$HOME/.if/git/bin/git" ] && export PATH="$HOME/.if/git/bin:$PATH"\n'
    printf '[ -d "$HOME/.if/git/libexec/git-core" ] && export GIT_EXEC_PATH="$HOME/.if/git/libexec/git-core"\n'
    printf '[ -d "$HOME/.if/git/lib" ] && export DYLD_FALLBACK_LIBRARY_PATH="$HOME/.if/git/lib:$HOME/lib:/usr/local/lib:/usr/lib"\n'
    printf 'export JAVA_HOME="%s"\n' "$jh_value"
    printf 'export PATH="$JAVA_HOME/bin:$PATH"\n'
    printf 'export NPM_CONFIG_CACHE="$HOME/.if/npm-cache"\n'
    printf 'export CLAUDE_CONFIG_DIR="$HOME/.if/claude-config"\n'
    # Where new projects created by `n` go. Override per machine
    # (e.g. ~/_code) by editing the line in ~/.zshrc after install.
    printf 'export PROJECT_DIR="$HOME/Projects"\n'
    printf "alias cc='claude --dangerously-skip-permissions'\n"
    printf "alias ccc='claude --dangerously-skip-permissions --continue'\n"
    printf "alias ccr='claude --dangerously-skip-permissions --resume'\n"
    printf "alias n='curl -fsSL https://almostawake.com/n | bash'\n"
    printf '%s\n' "$MARKER_END"
  } >> "$zshrc"
}

# =====================================================================
# 9. ROW UI + INSTALL/CONFIGURE ORCHESTRATOR
# =====================================================================

# draw_row "$i" "$state" — installed | installing | pending | failed.
# Icon slot is always 4 cells. Running uses ---> (literal arrow, hard
# to miss); idle states use a glyph + spaces to keep column alignment.
# Format mirrors draw_prov_row / draw_dep_row — no leading indent.
draw_row() {
  local i="$1" state="$2"
  local icon
  case "$state" in
    installed)  icon="✓   " ;;
    installing) icon="--->" ;;
    pending)    icon="○   " ;;
    failed)     icon="✗   " ;;
  esac
  printf '%s  %s\n' "$icon" "${ITEMS[$i]}"
}

# update_row "$i" "$state" — move cursor up to row i, redraw, move back.
# Assumes cursor is "line after the last row" before each call.
update_row() {
  local i="$1" state="$2"
  local up=$((N - i))
  printf '\033[%dA\r\033[K' "$up"
  draw_row "$i" "$state"
  local down=$((N - i - 1))
  # Use `if ... fi` rather than `[ ... ] && ...` — under set -e the
  # latter's compound exit is non-zero when the test fails, propagating.
  if [ "$down" -gt 0 ]; then
    printf '\033[%dB\r' "$down"
  fi
}

run_install() {
  local i="$1" fn="$2"
  update_row "$i" "installing"
  log "run_install: about to exec '$fn'"
  local rc=0
  "$fn" >> "$INSTALL_LOG" 2>&1 || rc=$?
  log "run_install: '$fn' returned rc=$rc"
  if [ "$rc" -eq 0 ]; then
    update_row "$i" "installed"
  else
    update_row "$i" "failed"
    echo ""
    echo ""
    echo "✗  install of ${ITEMS[$i]} failed — see $INSTALL_LOG for details"
    echo ""
    echo ""
    trap - EXIT
    exit 1
  fi
}

# Always render the row UI — even on re-runs where everything is
# already installed, the user sees the verification pass before we
# move on. Already-installed items render green from the start (no
# spinner / no install function); missing items go pending → running
# → done as they install.
echo ""
echo "checking/installing dependencies"
echo ""

for i in $(seq 0 $((N - 1))); do
  if [ "${INSTALLED[$i]}" = "true" ]; then
    draw_row "$i" "installed"
  else
    draw_row "$i" "pending"
  fi
done

for i in "${!ITEMS[@]}"; do
  [ "${INSTALLED[$i]}" = "true" ] && continue
  run_install "$i" "${INSTALL_FNS[$i]}"
done

# Make just-installed binaries usable for the rest of this run.
export PATH="$IF_HOME/gh/bin:$IF_HOME/git/bin:$IF_HOME/node/bin:$IF_HOME/claude/bin:$IF_HOME/vscode/bin:$PATH"
[ -d "$IF_HOME/git/lib" ] && export DYLD_FALLBACK_LIBRARY_PATH="$IF_HOME/git/lib"
[ -d "$IF_HOME/java/Contents/Home" ] && export JAVA_HOME="$IF_HOME/java/Contents/Home" && export PATH="$JAVA_HOME/bin:$PATH"
[ -d "$IF_HOME/java/bin" ] && export JAVA_HOME="$IF_HOME/java" && export PATH="$JAVA_HOME/bin:$PATH"

# Silent end-steps (no row, just do the work). Idempotent.
_configure_terminal  >> "$INSTALL_LOG" 2>&1 || true
_configure_workspace >> "$INSTALL_LOG" 2>&1 || true

# Always rewrite the marker block — cheap, idempotent, catches users
# migrating from old `i` / `setup-project` aliases that now point at
# dead paths.
_write_zshrc >> "$INSTALL_LOG" 2>&1 || true

# =====================================================================
# 10. OPEN VS CODE AT $PROJECT_DIR
# =====================================================================
# m skips all GCP/Firebase plumbing and project provisioning. Instead,
# once installs + configure + zshrc are done, just open VS Code at
# $PROJECT_DIR (~/Projects by default) so the user can verify the
# install loop end-to-end without the full provisioning detour.

# Clear EXIT trap on success — no need to dump the install log.
trap - EXIT

# $PROJECT_DIR isn't exported into this script's env (it's defined in
# the freshly-written ~/.zshrc marker block, not yet sourced here).
# Mirror the default and respect any pre-existing override.
PROJECT_DIR_M="${PROJECT_DIR:-$HOME/Projects}"
mkdir -p "$PROJECT_DIR_M"

echo ""
echo "install loop done"
echo ""
printf "PROJECT_DIR: %s\n" "$PROJECT_DIR_M"
echo ""

if [ "$OS" = "darwin" ] && [ -d "$HOME/Applications/Visual Studio Code.app" ]; then
  ( "$IF_HOME/vscode/bin/code" "$PROJECT_DIR_M" >/dev/null 2>&1 & ) || true
fi
