#!/bin/bash
#
# almostawake.com/new.sh — bootstrap for if-new
#
# Pulls latest if (assumes install.sh already cloned it) and hands off
# to scripts/if-new.sh, which provisions the user's GCP project.
#
set -e

C_RED=$'\033[31m'; C_RST=$'\033[0m'

if [ ! -d "$HOME/.if/staging" ]; then
  echo ""
  echo "${C_RED}no staged copy of if found.${C_RST}"
  echo "run the install first:"
  echo "  curl https://almostawake.com/install.sh | bash"
  echo ""
  exit 1
fi

# Pull latest changes — non-fatal if offline
git -C "$HOME/.if/staging" pull --quiet 2>/dev/null || true

exec bash "$HOME/.if/staging/scripts/if-new.sh"
