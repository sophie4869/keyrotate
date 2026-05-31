#!/usr/bin/env bash
#
# keyrotate installer.
#
# Symlinks bin/secret + bin/secret-helpers into ~/bin and npm-installs the
# userPassword target's node deps. Does NOT create or touch any config files —
# you bring your own at $SECRET_CONFIG_DIR (default ~/.config/keyrotate).
#
#   git clone https://github.com/sophie4869/keyrotate ~/keyrotate
#   cd ~/keyrotate && bash install.sh
#
# Idempotent: re-running is safe.
#
set -euo pipefail

KEYROTATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="${HOME:?}"
CONFIG_DEFAULT="$HOME_DIR/.config/keyrotate"

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
ok()   { printf "  ${c_ok}✓${c_off} %s\n" "$*"; }
warn() { printf "  ${c_warn}⚠${c_off}  %s\n" "$*"; }
err()  { printf "  ${c_err}✗${c_off} %s\n" "$*" >&2; }
hdr()  { printf "\n${c_dim}── %s ──${c_off}\n" "$*"; }

# ── 1. prereqs ──
hdr "prereqs"

# Required — script can't run without these
missing=()
for cmd in jq curl openssl; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd ($(command -v "$cmd"))"
  else
    err "$cmd not found"; missing+=("$cmd")
  fi
done

# Optional — each gates a specific target / strategy. Skipping is fine.
HAVE_NPM=0
for cmd in node npm; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd ($(command -v "$cmd"))"
    [ "$cmd" = "npm" ] && HAVE_NPM=1
  else
    warn "$cmd not found — needed only for the userPassword target (bcrypt + mongodb npm deps)"
  fi
done

if command -v gh >/dev/null 2>&1; then
  ok "gh ($(command -v gh))"
else
  warn "gh not found — needed only for the 'github' target (brew install gh)"
fi

if command -v gcloud >/dev/null 2>&1; then
  ok "gcloud ($(command -v gcloud))"
else
  warn "gcloud not found — needed only for the 'gcpSecretManager' and 'cloudRun' targets"
fi

if [ "${#missing[@]}" -gt 0 ]; then
  err "missing required: ${missing[*]}"
  err "install via: brew install ${missing[*]}"
  exit 1
fi

# ── 2. symlinks ──
hdr "symlinks"

link_one() {
  local src="$1" dst="$2"
  if [ -L "$dst" ]; then
    local current; current="$(readlink "$dst")"
    if [ "$current" = "$src" ]; then ok "$dst → already linked"; return; fi
    warn "$dst → points elsewhere ($current); re-linking"
    rm "$dst"
  elif [ -e "$dst" ]; then
    err "$dst exists and is NOT a symlink — refusing to clobber"
    return 1
  fi
  mkdir -p "$(dirname "$dst")"
  ln -s "$src" "$dst"
  ok "$dst → $src"
}

link_one "$KEYROTATE/bin/secret"         "$HOME_DIR/bin/secret"
link_one "$KEYROTATE/bin/secret-helpers" "$HOME_DIR/bin/secret-helpers"

# ── 3. node deps for userPassword target (optional) ──
hdr "node deps (optional, for userPassword target)"
if [ "$HAVE_NPM" = "0" ]; then
  warn "npm not present — skipping. Every target other than 'userPassword' still works."
elif [ -d "$KEYROTATE/bin/secret-helpers/node_modules" ]; then
  ok "node_modules already present"
else
  if ( cd "$KEYROTATE/bin/secret-helpers" && npm install --no-audit --no-fund ); then
    ok "installed mongodb + bcrypt"
  else
    warn "npm install failed (network? native bcrypt build?). 'userPassword' target will be unavailable; everything else still works."
  fi
fi

# ── 4. config dir ──
hdr "config dir"
if [ -d "$CONFIG_DEFAULT" ] || [ -L "$CONFIG_DEFAULT" ]; then
  ok "$CONFIG_DEFAULT exists — bring your own configs"
else
  mkdir -p "$CONFIG_DEFAULT"
  cp "$KEYROTATE/examples/example.json"  "$CONFIG_DEFAULT/example.json"
  cp "$KEYROTATE/examples/_aliases.json" "$CONFIG_DEFAULT/_aliases.json"
  ok "seeded $CONFIG_DEFAULT with examples/ (edit example.json to fit your project, or delete it)"
fi

# ── 5. next steps ──
hdr "next steps"
cat <<EOF
  ${c_ok}✓${c_off} keyrotate ready.

  Configure provider credentials in macOS Keychain (or set env vars):
    security add-generic-password -U -s atlas-api  -a public  -w '<PUBLIC>'
    security add-generic-password -U -s atlas-api  -a private -w '<PRIVATE>'
    security add-generic-password -U -s vercel-api -a token   -w '<VERCEL_TOKEN>'
    security add-generic-password -U -s koyeb-api  -a token   -w '<KOYEB_TOKEN>'

  Get going:
    secret ls                  # list configured projects
    secret notes               # show every manual-rotation playbook
    secret list <project>      # secrets in one project

  Schema reference: $KEYROTATE/SCHEMA.md
EOF
