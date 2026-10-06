#!/usr/bin/env bash
#
# ug-onboard.sh — point a developer's coding agents at ONE Unity Gateway workspace.
#
# For teams without MDM. An admin edits the three values in the CONFIG block below,
# shares this file, and the developer runs it once:
#
#     bash ug-onboard.sh
#
# The script verifies prerequisites, creates the Databricks profile (browser sign-in)
# if it is missing or expired, pins ug at your workspace, and verifies the result.
# On any failure it writes a redacted diagnostics file and tells the user to send it
# to the platform team. It is safe to re-run.
#
# This is the convention-level fallback. It sets the default workspace; a determined
# user can still change it. Where you have MDM, ship the managed config instead
# (see ug-managed-workspace.md).
#
# PREREQUISITES — the platform team does this ONCE, before sharing the script:
#   1. Unity Gateway is enabled on the workspace named below.
#   2. The model service the agents will use already exists (e.g. main.ai.coding_claude).
#   3. The coding-agent group has been granted, for that service:
#        - EXECUTE on the model service
#        - USE CATALOG on its catalog and USE SCHEMA on its schema
#      The service creator/owner separately holds CREATE SERVICE and EXECUTE on the
#      underlying model or provider (definer's privileges); service users never need those.
# Without those grants ug still configures cleanly, but a launch fails with a permissions
# error. Collect that error and send it to the platform team.

set -uo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG — admin edits these three values before sharing, then leave the rest.
# ─────────────────────────────────────────────────────────────────────────────
WORKSPACE_HOST="https://your-workspace.cloud.databricks.com"   # the ONE workspace
PROFILE_NAME="corp"                                            # Databricks CLI profile name
AGENTS="claude,codex"                                          # harnesses to configure
SUPPORT_CONTACT="your platform team (for example #ai-platform-support on Slack)"
# ─────────────────────────────────────────────────────────────────────────────

TS="$(date +%Y%m%d-%H%M%S)"
DIAG="$HOME/ug-onboard-diagnostics-$TS.log"

# Colors only when attached to a terminal.
if [ -t 1 ]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RST=$'\033[0m'
else
  BOLD=""; RED=""; GRN=""; YLW=""; RST=""
fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s!%s %s\n' "$YLW" "$RST" "$*"; }
step() { printf '\n%s==>%s %s\n' "$BOLD" "$RST" "$*"; }

usage() {
  cat <<EOF
${BOLD}ug-onboard.sh${RST} — point your coding agents at one Unity Gateway workspace.

Usage:
  bash ug-onboard.sh          Run onboarding (checks prereqs, signs you in, pins the workspace)
  bash ug-onboard.sh --help   Show this help

What it does, in order:
  1. Checks prerequisites: python3, uv, Databricks CLI, and ug (installs ug if missing).
  2. Creates or refreshes the Databricks profile via browser sign-in if it is missing/expired.
  3. Pins ug at the workspace so 'ug claude' and 'ug codex' skip the workspace picker.
  On any failure it writes a redacted diagnostics file and tells you who to send it to.
  Safe to re-run.

Set by your admin (the CONFIG block at the top of this file):
  workspace : $WORKSPACE_HOST
  profile   : $PROFILE_NAME
  agents    : $AGENTS
  support   : $SUPPORT_CONTACT

Prerequisite (platform team, once): the model service exists and your group has EXECUTE on it,
plus USE CATALOG and USE SCHEMA on its catalog and schema. See ug-managed-workspace.md.

After a successful run, launch one agent from your project directory:
  ug claude      # or: ug codex
EOF
}

# Redact anything token-shaped so the diagnostics file is safe to share.
redact() {
  sed -E \
    -e 's/dapi[A-Za-z0-9]+/dapi<redacted>/g' \
    -e 's/eyJ[A-Za-z0-9._-]{10,}/<redacted-jwt>/g' \
    -e 's/([Bb]earer )[A-Za-z0-9._-]+/\1<redacted>/g' \
    -e 's/(token["'"'"' :=]+)[A-Za-z0-9._-]{8,}/\1<redacted>/g'
}

diag_header() {
  {
    echo "ug-onboard diagnostics — $TS"
    echo "workspace: $WORKSPACE_HOST   profile: $PROFILE_NAME   agents: $AGENTS"
    echo "os: $(uname -a 2>/dev/null)"
    [ "$(uname)" = "Darwin" ] && echo "macos: $(sw_vers -productVersion 2>/dev/null)"
    echo "python3: $(command -v python3 >/dev/null 2>&1 && python3 --version 2>&1 || echo 'not found')"
    echo "uv: $(command -v uv >/dev/null 2>&1 && uv --version 2>&1 || echo 'not found')"
    echo "databricks: $(command -v databricks >/dev/null 2>&1 && databricks --version 2>&1 || echo 'not found')"
    echo "ug: $(command -v ug >/dev/null 2>&1 && ug --version 2>&1 || echo 'not found')"
    echo "PATH: $PATH"
    echo "────────────────────────────────────────────────────────"
  } | redact > "$DIAG"
}

fail() {
  warn "$RED$*$RST"
  say ""
  say "${BOLD}Something needs a human.${RST} A diagnostics file was written (secrets redacted):"
  say "    $DIAG"
  say "Send that file to $SUPPORT_CONTACT and they can tell you the fix."
  say "You can safely re-run this script after the fix."
  exit 1
}

# Capture a non-interactive command's output to the diagnostics log on failure.
capture() {
  local desc="$1"; shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ $rc -ne 0 ]; then
    { echo "FAILED (exit $rc): $desc"; echo "\$ $*"; printf '%s\n' "$out"; echo; } | redact >> "$DIAG"
  fi
  return $rc
}

# Read the host recorded for a profile in ~/.databrickscfg (no secrets live there for OAuth).
profile_host() {
  [ -f "$HOME/.databrickscfg" ] || return 0
  awk -v sect="[$PROFILE_NAME]" '
    $0==sect {f=1; next}
    /^\[/ {f=0}
    f && /^[[:space:]]*host[[:space:]]*=/ {
      sub(/^[[:space:]]*host[[:space:]]*=[[:space:]]*/,"",$0); print; exit
    }' "$HOME/.databrickscfg" 2>/dev/null
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "")        : ;;   # no argument: run onboarding
  *)         printf '%sUnknown option: %s%s\n\n' "$RED" "$1" "$RST" >&2; usage; exit 2 ;;
esac

diag_header
say "${BOLD}ug onboarding${RST} — pinning coding agents at $WORKSPACE_HOST (profile: $PROFILE_NAME)"

# 1 ─ Prerequisites -----------------------------------------------------------
step "Checking prerequisites"

command -v python3 >/dev/null 2>&1 || fail "python3 is not installed. Install Python 3.12+ and re-run."
command -v uv      >/dev/null 2>&1 || fail "uv is not installed. Install it from https://docs.astral.sh/uv and re-run."
ok "python3 and uv present"

if ! command -v databricks >/dev/null 2>&1; then
  fail "The Databricks CLI is not installed. Install it from https://docs.databricks.com/en/dev-tools/cli and re-run."
fi
ok "Databricks CLI present"

if ! command -v ug >/dev/null 2>&1; then
  warn "ug not found. Installing it with uv..."
  if ! uv tool install git+https://github.com/databricks/unity-gateway; then
    fail "Could not install ug. Check network access to GitHub and PyPI, then re-run."
  fi
  hash -r 2>/dev/null || true
  command -v ug >/dev/null 2>&1 || fail "ug installed but is not on PATH. Add the directory from 'uv tool dir --bin' to your PATH, open a new terminal, and re-run."
fi
ok "ug present ($(ug --version 2>&1 | head -1))"

# 2 ─ Databricks profile ------------------------------------------------------
step "Checking the Databricks profile '$PROFILE_NAME'"

existing_host="$(profile_host)"
if [ -n "$existing_host" ] && [ "$existing_host" != "$WORKSPACE_HOST" ]; then
  warn "Profile '$PROFILE_NAME' points at $existing_host, not $WORKSPACE_HOST."
  warn "Re-authenticating it at the correct workspace."
fi

if [ "$existing_host" = "$WORKSPACE_HOST" ] && capture "verify profile" databricks current-user me -p "$PROFILE_NAME"; then
  ok "Profile '$PROFILE_NAME' is valid and points at the right workspace"
else
  warn "Profile '$PROFILE_NAME' is missing or expired. Opening browser sign-in..."
  say "    Sign in as yourself. Approve the login in the browser window."
  # Interactive: let the browser flow and prompts reach the terminal directly.
  if ! databricks auth login --host "$WORKSPACE_HOST" --profile "$PROFILE_NAME"; then
    { echo "FAILED: databricks auth login --host $WORKSPACE_HOST --profile $PROFILE_NAME"; } >> "$DIAG"
    fail "Browser sign-in did not complete. Common causes: closed the browser tab, denied the request, or the login port was blocked."
  fi
  capture "re-verify profile after login" databricks current-user me -p "$PROFILE_NAME" \
    || fail "Signed in, but the profile still cannot reach the workspace. Confirm you have access to $WORKSPACE_HOST."
  ok "Profile '$PROFILE_NAME' created and verified"
fi

# 3 ─ Pin ug at the workspace -------------------------------------------------
step "Configuring ug for $AGENTS at $WORKSPACE_HOST"
say "    Follow any browser or terminal prompts. This writes each agent's config."
# Interactive: ug may run its own sign-in and discovery.
if ! ug configure --workspace "$WORKSPACE_HOST" --agents "$AGENTS"; then
  { echo "FAILED: ug configure --workspace $WORKSPACE_HOST --agents $AGENTS"; } >> "$DIAG"
  fail "ug configure did not finish. If it reported OS-managed settings overriding it, this machine already has a managed config; tell the platform team which workspace it names."
fi
ok "ug configured; $WORKSPACE_HOST is now the default workspace"

# 4 ─ Done --------------------------------------------------------------------
rm -f "$DIAG" 2>/dev/null || true   # success: no diagnostics needed
step "Done"
ok "Coding agents will route through $WORKSPACE_HOST."
say ""
say "Launch one from your project directory:"
say "    ${BOLD}ug claude${RST}     or     ${BOLD}ug codex${RST}"
say ""
say "If a launch fails, re-run this script. If it still fails, contact $SUPPORT_CONTACT."
