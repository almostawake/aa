#!/bin/bash
#
# almostawake.com/install.sh — bootstrap for if (impatient futurist)
#
# Tiny gateway that installs the bare-minimum prerequisites needed to
# clone the private if repo (homebrew + gh + auth), then hands off to
# the real installer at scripts/if-install.sh inside that repo.
#
set -e

C_GRN=$'\033[32m'; C_GRAY=$'\033[90m'; C_RED=$'\033[31m'; C_RST=$'\033[0m'

echo ""
echo "${C_GRN}┌───────────────────────────────────────────────────┐${C_RST}"
echo "${C_GRN}│          welcome, impatient futurist (if)         │${C_RST}"
echo "${C_GRN}└───────────────────────────────────────────────────┘${C_RST}"
echo ""

# 1. homebrew (installs Xcode CLT under the hood, prompts for sudo)
if ! command -v brew >/dev/null 2>&1; then
  echo "installing homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
fi

# 2. gh
if ! command -v gh >/dev/null 2>&1; then
  echo "installing gh..."
  brew install gh
fi

# 3. authenticate (interactive, web flow)
if ! gh auth status >/dev/null 2>&1; then
  echo ""
  echo "${C_GRAY}sign in to github (this opens your browser).${C_RST}"
  gh auth login </dev/tty
fi

# 4. configure git to use gh as credential helper for HTTPS
gh auth setup-git

# 5. clone the if repo. private — fails clearly if not a collaborator yet.
mkdir -p "$HOME/.if"
if [ ! -d "$HOME/.if/staging" ]; then
  echo "fetching if..."
  if ! gh repo clone almostawake/if "$HOME/.if/staging" 2>/dev/null; then
    echo ""
    echo "${C_RED}couldn't clone almostawake/if.${C_RST}"
    echo "you may not have been added as a collaborator yet."
    echo "request access at https://almostawake.com — we'll email you when approved."
    exit 1
  fi
fi

echo ""

# 6. hand off to the real installer
exec bash "$HOME/.if/staging/scripts/if-install.sh"
