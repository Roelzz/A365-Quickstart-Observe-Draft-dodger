#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# A365 Agent Re-registration Demo
# ─────────────────────────────────────────────────────────────────────────────
#
# Menu-driven walk-through of the five re-registration scenarios documented
# in RE-REGISTRATION.md. Values sourced from .env + a365 config files.
#
# SCENARIOS
#   A — Endpoint Swap          Dev-tunnel URL changed. Update the blueprint's
#                              messagingEndpoint. Nothing else changes.
#   B — Manifest Re-publish    Display name, description, or icon changed.
#                              Re-generate and re-upload the Teams manifest.
#   C — Permissions Re-grant   Graph scope added or consent expired. Re-run
#                              admin consent for MCP + Bot permissions.
#   D — Full Cleanup → Re-setup (DESTRUCTIVE) Wrong --m365, --aiteammate,
#                              or auth mode. Delete everything, start over.
#   E — Side-by-side Parallel  Register a second blueprint alongside the live
#                              one. Both coexist in the tenant. Non-destructive.
#
# REQUIRED TOOLS
#   bash, jq, a365 CLI ≥ 1.1.174, az CLI, pwsh (PowerShell), curl
#   Install a365:  dotnet tool install -g Microsoft.Agents.A365.DevTools.Cli
#   Install pwsh:  brew install powershell/tap/powershell
#
# REQUIRED AUTH (per Microsoft Learn — see docs/demo-reregister.md §Minimum roles)
#   Most steps:     Agent ID Developer + Application Administrator
#   S2S/Both class: + Privileged Role Administrator (Graph app-role consent only)
#   Manifest upload + activation: + AI Administrator
#   AI Teammate licensing on the agent identity: + Agent ID Administrator + M365 Copilot licence
#   Global Administrator is a superset — works for all but exceeds the documented minimum.
#
# CONFIG FILES READ
#   .env                         — environment variables (client secret, etc.)
#   a365.config.json             — project config (endpoint, client app ID, etc.)
#   a365.generated.config.json   — live registration state (blueprint ID, etc.)
#
# IMPORTANT
#   • The CLI client app MUST be named "Agent 365 CLI" in Entra for -n mode
#     to work. The CLI looks up the client app by display name, not by ID.
#   • Scenario E backs up and restores .env + a365.generated.config.json
#     because the CLI overwrites them during -n registration.
#
# USAGE
#   bash scripts/demo-reregister.sh
#
# ─────────────────────────────────────────────────────────────────────────────
set -Euo pipefail

# ── Resolve repo root (script can be launched from anywhere) ─────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

# ── Traps ────────────────────────────────────────────────────────────────────
CURRENT_STEP=""
cleanup() {
  printf '\033[0m\n'  # reset colours
  tput cnorm 2>/dev/null || true  # restore cursor
  if [[ -n "$CURRENT_STEP" ]]; then
    echo ""
    echo -e "\033[33m⚠  Aborted at $CURRENT_STEP — no rollback attempted.\033[0m"
    echo -e "\033[2m   See RE-REGISTRATION.md §D rollback if you ran cleanup commands.\033[0m"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT

# ── Colours ──────────────────────────────────────────────────────────────────
RST='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
MAGENTA='\033[35m'
CYAN='\033[36m'
WHITE='\033[97m'
BG_BLUE='\033[44m'
BG_RED='\033[41m'

# ── Pre-flight checks ───────────────────────────────────────────────────────
if [[ ! -f ".env" ]]; then
  echo -e "${RED}✗ .env not found.${RST} Run from repo root and ensure .env exists. See .env.example."
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo -e "${RED}✗ jq not found.${RST} Install with: brew install jq"
  exit 1
fi

if ! command -v a365 &>/dev/null; then
  echo -e "${RED}✗ a365 CLI not found.${RST}"
  echo -e "  Install: ${CYAN}dotnet tool install -g Microsoft.Agents.A365.DevTools.Cli${RST}"
  echo -e "  Docs:    https://learn.microsoft.com/en-us/microsoft-agent-365/developer/reference/cli/"
  exit 1
fi

# ── Source .env ──────────────────────────────────────────────────────────────
set -a
# shellcheck disable=SC1091
source .env
set +a

# ── Extended pre-flight (non-blocking warnings) ─────────────────────────────
PREFLIGHT_AZ_OK=false
PREFLIGHT_AZ_TENANT=""
PREFLIGHT_AZ_USER=""
PREFLIGHT_CLI_VERSION=""
PREFLIGHT_CLI_OK=false
PREFLIGHT_AGENT_OK=false
PREFLIGHT_TUNNEL_OK=false

echo ""
echo -e "${BOLD}Pre-flight checks...${RST}"

# Azure CLI login
if az account show &>/dev/null; then
  PREFLIGHT_AZ_OK=true
  PREFLIGHT_AZ_TENANT=$(az account show --query tenantId -o tsv 2>/dev/null)
  PREFLIGHT_AZ_USER=$(az account show --query user.name -o tsv 2>/dev/null)
  echo -e "  ${GREEN}✔${RST} Azure CLI: logged in as ${BOLD}${PREFLIGHT_AZ_USER}${RST} (tenant ${DIM}${PREFLIGHT_AZ_TENANT}${RST})"
else
  echo -e "  ${RED}✗${RST} Azure CLI: not logged in — run ${CYAN}az login --tenant <tenantId>${RST}"
fi

# a365 CLI version (need ≥ 1.1.174)
PREFLIGHT_CLI_VERSION=$(a365 --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
if [[ "$PREFLIGHT_CLI_VERSION" != "unknown" ]]; then
  cli_major=$(echo "$PREFLIGHT_CLI_VERSION" | cut -d. -f1)
  cli_minor=$(echo "$PREFLIGHT_CLI_VERSION" | cut -d. -f2)
  cli_patch=$(echo "$PREFLIGHT_CLI_VERSION" | cut -d. -f3)
  if [[ "$cli_major" -gt 1 ]] || [[ "$cli_major" -eq 1 && "$cli_minor" -gt 1 ]] || \
     [[ "$cli_major" -eq 1 && "$cli_minor" -eq 1 && "$cli_patch" -ge 174 ]]; then
    PREFLIGHT_CLI_OK=true
    echo -e "  ${GREEN}✔${RST} a365 CLI: v${PREFLIGHT_CLI_VERSION}"
  else
    echo -e "  ${YELLOW}⚠${RST} a365 CLI: v${PREFLIGHT_CLI_VERSION} — need ≥ 1.1.174 (endpoint registration bug in older versions)"
  fi
else
  echo -e "  ${YELLOW}⚠${RST} a365 CLI: could not determine version"
fi

# Agent service on localhost:3978
if curl -sf http://localhost:3978/api/health &>/dev/null || curl -sf http://localhost:3978 &>/dev/null; then
  PREFLIGHT_AGENT_OK=true
  echo -e "  ${GREEN}✔${RST} Agent service: running on :3978"
else
  echo -e "  ${YELLOW}⚠${RST} Agent service: not responding on :3978 — run ${CYAN}uv run python start_with_generic_host.py${RST}"
fi

# Tunnel reachability
TUNNEL_ENDPOINT=$(jq -r '.messagingEndpoint // ""' a365.config.json 2>/dev/null)
if [[ -n "$TUNNEL_ENDPOINT" && "$TUNNEL_ENDPOINT" != "null" ]]; then
  TUNNEL_BASE="${TUNNEL_ENDPOINT%/api/messages}"
  if curl -sf --max-time 5 "$TUNNEL_BASE" &>/dev/null || curl -sf --max-time 5 "${TUNNEL_BASE}/api/health" &>/dev/null; then
    PREFLIGHT_TUNNEL_OK=true
    echo -e "  ${GREEN}✔${RST} Tunnel: reachable at ${DIM}${TUNNEL_BASE}${RST}"
  else
    echo -e "  ${YELLOW}⚠${RST} Tunnel: not reachable at ${DIM}${TUNNEL_BASE}${RST} — run ${CYAN}devtunnel host a365-draft-dodger${RST}"
  fi
else
  echo -e "  ${YELLOW}⚠${RST} Tunnel: no messagingEndpoint in a365.config.json"
fi

# Client app ID (needed by a365 setup commands when using -n)
PREFLIGHT_CLIENT_APP_ID=""
if [[ -f a365.config.json ]]; then
  PREFLIGHT_CLIENT_APP_ID=$(jq -r '.clientAppId // ""' a365.config.json 2>/dev/null)
fi
if [[ -n "$PREFLIGHT_CLIENT_APP_ID" && "$PREFLIGHT_CLIENT_APP_ID" != "null" ]]; then
  echo -e "  ${GREEN}✔${RST} Client app ID: ${DIM}${PREFLIGHT_CLIENT_APP_ID}${RST}"
else
  echo -e "  ${YELLOW}⚠${RST} Client app ID: not found in a365.config.json — CLI will prompt interactively"
fi

# Check client app display name matches what the CLI expects
if [[ -n "$PREFLIGHT_CLIENT_APP_ID" && "$PREFLIGHT_CLIENT_APP_ID" != "null" ]]; then
  CLIENT_APP_NAME=$(az ad app show --id "$PREFLIGHT_CLIENT_APP_ID" --query displayName -o tsv 2>/dev/null || echo "unknown")
  if [[ "$CLIENT_APP_NAME" == "Agent 365 CLI" ]]; then
    echo -e "  ${GREEN}✔${RST} Client app name: $CLIENT_APP_NAME"
  else
    echo -e "  ${YELLOW}⚠${RST} Client app name: '$CLIENT_APP_NAME' — CLI expects 'Agent 365 CLI'"
    echo -e "    Fix: ${CYAN}az ad app update --id $PREFLIGHT_CLIENT_APP_ID --display-name 'Agent 365 CLI'${RST}"
  fi
fi

# PowerShell (needed for Graph pre-auth in scenario E)
if command -v pwsh &>/dev/null; then
  echo -e "  ${GREEN}✔${RST} PowerShell (pwsh): available"
else
  echo -e "  ${YELLOW}⚠${RST} PowerShell (pwsh): not found — needed for Graph pre-auth in scenario E"
  echo -e "    Install: ${CYAN}brew install powershell/tap/powershell${RST}"
fi

echo ""
echo -e "${DIM}Press Enter to continue to menu...${RST}"
read -r

# ── Helper functions ─────────────────────────────────────────────────────────

print_banner() {
  local title="$1"
  local width=72
  echo ""
  echo -e "${BG_BLUE}${WHITE}${BOLD}$(printf '%-*s' $width " $title")${RST}"
  echo ""
}

print_step() {
  local num="$1"
  local total="$2"
  local desc="$3"
  CURRENT_STEP="Step $num/$total — $desc"
  echo -e "  ${CYAN}${BOLD}▸ Step $num/$total${RST} ${BOLD}— $desc${RST}"
}

print_explain() {
  echo -e "    ${DIM}$1${RST}"
}

print_command() {
  echo ""
  echo -e "    ${GREEN}▶ ${BOLD}$1${RST}"
  echo ""
}

print_auth() {
  echo -e "    ${YELLOW}🔑 Auth: $1${RST}"
}

print_prereq() {
  echo -e "    ${MAGENTA}📋 Prereq: $1${RST}"
}

print_warning() {
  echo -e "  ${RED}${BOLD}⚠  $1${RST}"
}

print_info() {
  echo -e "  ${BLUE}ℹ  $1${RST}"
}

print_success() {
  echo -e "  ${GREEN}✔  $1${RST}"
}

confirm() {
  local prompt="${1:-Run this command?}"
  echo -e "    ${YELLOW}${prompt}${RST} ${DIM}[Enter=yes / n=skip]${RST}"
  read -r -p "    > " answer
  case "$answer" in
    n|N|no|No) return 1 ;;
    *) return 0 ;;
  esac
}

run_or_skip() {
  local cmd="$1"
  if confirm "Run this command?"; then
    echo -e "    ${DIM}Running...${RST}"
    echo ""
    eval "$cmd"
    local rc=$?
    echo ""
    if [[ $rc -eq 0 ]]; then
      print_success "Command succeeded (exit $rc)"
    else
      print_warning "Command failed (exit $rc)"
    fi
    return $rc
  else
    echo -e "    ${DIM}Skipped.${RST}"
    return 0
  fi
}

run_or_skip_critical() {
  local cmd="$1"
  local fail_msg="${2:-Command failed — aborting scenario.}"
  if confirm "Run this command?"; then
    echo -e "    ${DIM}Running...${RST}"
    echo ""
    eval "$cmd"
    local rc=$?
    echo ""
    if [[ $rc -eq 0 ]]; then
      print_success "Command succeeded (exit $rc)"
      return 0
    else
      print_warning "$fail_msg (exit $rc)"
      echo ""
      print_info "Fix the issue and try this scenario again."
      CURRENT_STEP=""
      pause_for_menu
      return 1
    fi
  else
    echo -e "    ${DIM}Skipped — treating as abort for this scenario.${RST}"
    CURRENT_STEP=""
    pause_for_menu
    return 1
  fi
}

check_prereqs() {
  local scenario="$1"
  shift
  echo -e "  ${BOLD}Prerequisites for $scenario:${RST}"
  local all_ok=true
  while [[ $# -gt 0 ]]; do
    local check="$1"; shift
    case "$check" in
      az-login)
        if $PREFLIGHT_AZ_OK; then
          echo -e "    ${GREEN}✔${RST} Azure CLI logged in (${PREFLIGHT_AZ_USER})"
        else
          echo -e "    ${RED}✗${RST} Azure CLI — run: ${CYAN}az login --tenant <tenantId>${RST}"
          all_ok=false
        fi ;;
      tunnel)
        if $PREFLIGHT_TUNNEL_OK; then
          echo -e "    ${GREEN}✔${RST} Tunnel reachable"
        else
          echo -e "    ${YELLOW}⚠${RST} Tunnel not confirmed — ${CYAN}devtunnel host a365-draft-dodger${RST}"
        fi ;;
      agent)
        if $PREFLIGHT_AGENT_OK; then
          echo -e "    ${GREEN}✔${RST} Agent service running on :3978"
        else
          echo -e "    ${YELLOW}⚠${RST} Agent not responding — ${CYAN}uv run python start_with_generic_host.py${RST}"
        fi ;;
      cli-version)
        if $PREFLIGHT_CLI_OK; then
          echo -e "    ${GREEN}✔${RST} a365 CLI ≥ 1.1.174 (v${PREFLIGHT_CLI_VERSION})"
        else
          echo -e "    ${YELLOW}⚠${RST} a365 CLI version not confirmed (v${PREFLIGHT_CLI_VERSION})"
        fi ;;
      role-agent-dev)
        echo -e "    ${BLUE}🔑${RST} Entra role: ${BOLD}Agent ID Developer${RST} (or higher; GA works but exceeds minimum)" ;;
      role-global-admin)
        # Kept name for backwards-compatibility; the actual minimums per Microsoft Learn:
        echo -e "    ${BLUE}🔑${RST} Entra roles per step:"
        echo -e "      • ${BOLD}Agent ID Developer${RST}: blueprint creation / cleanup"
        echo -e "      • ${BOLD}Application Administrator${RST}: admin consent for delegated Graph scopes"
        echo -e "      • ${BOLD}Privileged Role Administrator${RST}: admin consent for Graph application permissions (S2S/Both classes only)"
        echo -e "      • ${BOLD}AI Administrator${RST}: manifest upload + activation in M365 admin centre"
        echo -e "      • ${BOLD}Agent ID Administrator${RST}: Copilot licence assignment to agent identity (AI Teammate)"
        echo -e "      ${DIM}Global Administrator works as a superset but is more than the documented minimum.${RST}" ;;
      generated-config)
        if [[ -f a365.generated.config.json ]]; then
          echo -e "    ${GREEN}✔${RST} a365.generated.config.json exists"
        else
          echo -e "    ${YELLOW}⚠${RST} a365.generated.config.json not found (not yet registered)"
        fi ;;
      manifest)
        if [[ -f manifest/manifest.json ]]; then
          echo -e "    ${GREEN}✔${RST} manifest/manifest.json exists"
        else
          echo -e "    ${RED}✗${RST} manifest/manifest.json not found"
          all_ok=false
        fi ;;
      pwsh)
        if command -v pwsh &>/dev/null; then
          echo -e "    ${GREEN}✔${RST} PowerShell (pwsh) available"
        else
          echo -e "    ${RED}✗${RST} PowerShell (pwsh) not found — needed for Graph pre-auth on macOS"
          all_ok=false
        fi ;;
      client-app-name)
        if [[ -n "$PREFLIGHT_CLIENT_APP_ID" && "$PREFLIGHT_CLIENT_APP_ID" != "null" ]]; then
          local app_name
          app_name=$(az ad app show --id "$PREFLIGHT_CLIENT_APP_ID" --query displayName -o tsv 2>/dev/null || echo "unknown")
          if [[ "$app_name" == "Agent 365 CLI" ]]; then
            echo -e "    ${GREEN}✔${RST} Client app display name: 'Agent 365 CLI'"
          else
            echo -e "    ${RED}✗${RST} Client app display name: '$app_name' — must be 'Agent 365 CLI'"
            echo -e "      Fix: ${CYAN}az ad app update --id $PREFLIGHT_CLIENT_APP_ID --display-name 'Agent 365 CLI'${RST}"
            all_ok=false
          fi
        else
          echo -e "    ${YELLOW}⚠${RST} Client app ID not found — CLI will prompt interactively"
        fi ;;
    esac
  done
  echo ""
  if ! $all_ok; then
    echo -e "  ${RED}Some prerequisites are not met.${RST}"
    if ! confirm "Continue anyway?"; then
      CURRENT_STEP=""
      pause_for_menu
      return 1
    fi
  fi
  return 0
}

pause_for_menu() {
  echo ""
  echo -e "  ${DIM}Press Enter to return to menu...${RST}"
  read -r
}

# ── Value loaders (lazy, from config files) ──────────────────────────────────

get_live_blueprint_id() {
  if [[ -f a365.generated.config.json ]]; then
    jq -r '.agentBlueprintId // "(not set)"' a365.generated.config.json
  else
    echo "(not yet registered)"
  fi
}

get_live_instance_id() {
  if [[ -f a365.generated.config.json ]]; then
    jq -r '.agentInstanceId // "(not set)"' a365.generated.config.json
  else
    echo "(not yet registered)"
  fi
}

get_live_bot_app_id() {
  if [[ -f a365.generated.config.json ]]; then
    jq -r '.botMsaAppId // "(not set)"' a365.generated.config.json
  else
    echo "(not yet registered)"
  fi
}

get_live_endpoint() {
  if [[ -f a365.config.json ]]; then
    jq -r '.messagingEndpoint // "(not set)"' a365.config.json
  else
    echo "(not configured)"
  fi
}

get_live_app_name() {
  if [[ -f a365.config.json ]]; then
    jq -r '(.agentBlueprintDisplayName // .agentDisplayName // .agentName // "(unnamed)")' a365.config.json
  else
    echo "(not configured)"
  fi
}

get_demo_parallel_name() {
  echo "${DEMO_PARALLEL_NAME:-"Draft Dodger Demo $(date +%Y%m%d-%H%M)"}"
}

# ── Concept primer ───────────────────────────────────────────────────────────

show_concepts() {
  print_banner "Concept Primer — what gets created, what each command destroys"

  echo -e "  ${BOLD}${CYAN}1. Blueprint${RST}"
  echo -e "  ${DIM}The multi-tenant Entra App Registration (OData type 'agent') that defines"
  echo -e "  permissions, roles, and identity patterns. Identified by agentBlueprintId."
  echo -e "  Lives forever until you run ${CYAN}a365 cleanup blueprint${DIM}.${RST}"
  echo -e "  ${DIM}Created by: ${CYAN}a365 setup blueprint${DIM}  |  Auth: Agent ID Developer role${RST}"
  echo ""

  echo -e "  ${BOLD}${CYAN}2. Service Principal (SP)${RST}"
  echo -e "  ${DIM}The per-tenant instance of the blueprint app. Carries the consent grants."
  echo -e "  Created automatically when the blueprint is registered in your tenant."
  echo -e "  Destroyed when you cleanup the blueprint.${RST}"
  echo -e "  ${DIM}Created by: auto-created with blueprint  |  Auth: no separate auth needed${RST}"
  echo ""

  echo -e "  ${BOLD}${CYAN}3. Agentic User Identity${RST}"
  echo -e "  ${DIM}An Entra user account (1:1 with Agent Identity) — UPN, mailbox, OneDrive,"
  echo -e "  Teams presence. No password — authenticates via federated credentials."
  echo -e "  Identified by agentInstanceId per user. Survives blueprint updates"
  echo -e "  except full cleanup (scenario D).${RST}"
  echo -e "  ${DIM}Created by: ${CYAN}a365 setup all${DIM} (identity SP) → ${CYAN}a365 publish --aiteammate true${DIM} + admin-centre activation (user wrapper)${RST}"
  echo -e "  ${DIM}Auth: Agent ID Developer (blueprint) + Application Administrator (consent) + Agent ID Administrator + M365 Copilot licence (user wrapper)${RST}"
  echo ""

  echo -e "  ${BOLD}${CYAN}4. Messaging Endpoint${RST}"
  echo -e "  ${DIM}The HTTPS URL the Bot Framework POSTs /api/messages to. This is the only"
  echo -e "  thing scenario A changes. Usually your dev tunnel URL."
  echo -e "  Currently: ${CYAN}$(get_live_endpoint)${RST}"
  echo -e "  ${DIM}Registered by: ${CYAN}a365 setup all --m365${DIM}  |  Auth: Agent ID Developer${RST}"
  echo ""

  echo -e "  ${BOLD}${CYAN}5. MCP Platform Link${RST}"
  echo -e "  ${DIM}How the blueprint is registered with the A365 service so it shows up in"
  echo -e "  M365 Admin Center → Agents. Created by --m365 flag during setup.${RST}"
  echo -e "  ${DIM}Auto-registered with --m365  |  Auth: Agent ID Developer${RST}"
  echo ""

  echo -e "  ${BOLD}${CYAN}6. Manifest${RST}"
  echo -e "  ${DIM}The Teams app package (manifest.zip) that admins upload. Holds the bot's"
  echo -e "  display metadata and points at the blueprint's app ID."
  echo -e "  Generated by ${CYAN}a365 publish${DIM}, then manually uploaded to Admin Center.${RST}"
  echo -e "  ${DIM}Generated by: ${CYAN}a365 publish${DIM}  |  Auth: ${BOLD}AI Administrator${DIM} (or higher) for the M365 admin-centre upload${RST}"
  echo ""

  echo -e "  ${BOLD}What each cleanup command destroys:${RST}"
  echo -e "  ┌────────────────────────────────────┬────────────────────────────────────┐"
  echo -e "  │ ${BOLD}Command${RST}                            │ ${BOLD}Destroys${RST}                           │"
  echo -e "  ├────────────────────────────────────┼────────────────────────────────────┤"
  echo -e "  │ ${RED}a365 cleanup blueprint${RST}            │ Entra app + SP + endpoint + meta   │"
  echo -e "  │ ${RED}a365 cleanup blueprint --ep-only${RST}  │ Endpoint registration only         │"
  echo -e "  │ ${RED}a365 cleanup instance${RST}             │ Agentic-user identities            │"
  echo -e "  │ ${RED}a365 cleanup azure${RST}                │ App Service + Plan (if deployed)   │"
  echo -e "  └────────────────────────────────────┴────────────────────────────────────┘"

  pause_for_menu
}

# ── Show current state ───────────────────────────────────────────────────────

show_state() {
  print_banner "Current State (live values from config files)"

  echo -e "  ${BOLD}Agent name:${RST}       $(get_live_app_name)"
  echo -e "  ${BOLD}Blueprint ID:${RST}     $(get_live_blueprint_id)"
  echo -e "  ${BOLD}Instance ID:${RST}      $(get_live_instance_id)"
  echo -e "  ${BOLD}Bot MSA App ID:${RST}   $(get_live_bot_app_id)"
  echo -e "  ${BOLD}Endpoint:${RST}         $(get_live_endpoint)"
  echo ""

  # Client app ID and display name
  if [[ -n "$PREFLIGHT_CLIENT_APP_ID" && "$PREFLIGHT_CLIENT_APP_ID" != "null" ]]; then
    local client_name
    client_name=$(az ad app show --id "$PREFLIGHT_CLIENT_APP_ID" --query displayName -o tsv 2>/dev/null || echo "unknown")
    echo -e "  ${BOLD}Client app ID:${RST}    ${PREFLIGHT_CLIENT_APP_ID}"
    echo -e "  ${BOLD}Client app name:${RST}  ${client_name}"
  else
    echo -e "  ${BOLD}Client app ID:${RST}    ${DIM}(not found in a365.config.json)${RST}"
  fi

  # PowerShell availability
  if command -v pwsh &>/dev/null; then
    echo -e "  ${BOLD}PowerShell:${RST}       ${GREEN}available${RST}"
  else
    echo -e "  ${BOLD}PowerShell:${RST}       ${YELLOW}not found${RST}"
  fi

  # Tunnel URL
  if [[ -n "$TUNNEL_ENDPOINT" && "$TUNNEL_ENDPOINT" != "null" ]]; then
    echo -e "  ${BOLD}Tunnel URL:${RST}       ${TUNNEL_BASE:-$TUNNEL_ENDPOINT}"
  else
    echo -e "  ${BOLD}Tunnel URL:${RST}       ${DIM}(not configured)${RST}"
  fi
  echo ""

  if [[ -f a365.generated.config.json ]]; then
    local last_updated
    last_updated=$(jq -r '.lastUpdated // "(unknown)"' a365.generated.config.json)
    local cli_version
    cli_version=$(jq -r '.cliVersion // "(unknown)"' a365.generated.config.json)
    local consent_count
    consent_count=$(jq '[.consentGrants // [] | .[] | select(.consentGranted == true)] | length' a365.generated.config.json 2>/dev/null || echo "0")
    local total_grants
    total_grants=$(jq '[.consentGrants // [] | .[]] | length' a365.generated.config.json 2>/dev/null || echo "0")
    echo -e "  ${DIM}Last updated:    $last_updated${RST}"
    echo -e "  ${DIM}CLI version:     $cli_version${RST}"
    echo -e "  ${DIM}Consent grants:  $consent_count/$total_grants granted${RST}"
  else
    echo -e "  ${YELLOW}a365.generated.config.json not found — agent not yet registered.${RST}"
  fi

  pause_for_menu
}

# ── Scenario A — Endpoint swap ───────────────────────────────────────────────

scenario_a() {
  print_banner "Scenario A — Endpoint Swap (non-destructive)"
  print_explain "Your dev-tunnel URL changed. You want the existing blueprint to point"
  print_explain "at a new https://…/api/messages URL. Nothing else changes — same blueprint"
  print_explain "ID, same agentic-user identities, same Teams installs."
  echo ""
  print_explain ""
  print_explain "WHY: The messaging endpoint is the HTTPS URL the Bot Framework POSTs"
  print_explain "/api/messages to. When your dev-tunnel restarts with a new URL (laptop"
  print_explain "reset, region migration, new tunnel name), the blueprint needs to know."
  print_explain ""
  print_explain "WHAT CHANGES: Only the messagingEndpoint field on the blueprint flips."
  print_explain "Blueprint ID, agentic-user identities, Teams installs — all preserved."
  print_explain ""
  print_explain "AUTH: Agent ID Developer role suffices (no higher role needed). az login required."
  print_explain "No admin consent needed — this is a metadata-only update."
  echo ""

  check_prereqs "Scenario A" az-login cli-version role-agent-dev generated-config || return

  print_step 1 2 "Confirm current endpoint"
  print_command "jq -r '.messagingEndpoint' a365.config.json"
  run_or_skip "jq -r '.messagingEndpoint' a365.config.json"
  echo ""

  print_step 2 2 "Update endpoint on the existing blueprint"
  local endpoint
  endpoint=$(get_live_endpoint)
  print_command "a365 setup blueprint --m365 --update-endpoint \"$endpoint\""
  print_explain "⚠ --m365 is REQUIRED. Without it the command silently no-ops —"
  print_explain "  the CLI prints 'Skipping...M365 agents' and does nothing."
  run_or_skip_critical "a365 setup blueprint --m365 --update-endpoint \"$endpoint\"" \
    "Endpoint update failed" || return

  echo ""
  print_info "Verification: send one Teams turn. Agent log should show"
  print_info "POST /api/messages HTTP/1.1 202."
  print_info "If you get 502s — that's the Bot Framework onboarding storm."
  print_info "It self-heals in ~2 minutes. Don't restart anything."

  CURRENT_STEP=""
  pause_for_menu
}

# ── Scenario B — Manifest re-publish ─────────────────────────────────────────

scenario_b() {
  print_banner "Scenario B — Manifest Re-publish (non-destructive)"
  print_explain "You edited the agent display name, description, icon, or accent colour"
  print_explain "and need the change to surface in M365 Admin Center."
  echo ""
  print_explain ""
  print_explain "WHY: The manifest.zip is the Teams app package that admins upload to"
  print_explain "M365 Admin Center. It contains display name, description, icon, and"
  print_explain "the blueprint's app ID. When you change any of these, you need to"
  print_explain "re-generate and re-upload the manifest."
  print_explain ""
  print_explain "QUIRK: 'a365 publish' overwrites your custom description with a generic"
  print_explain "placeholder every time. That's why step 3 re-edits the manifest after publish."
  print_explain ""
  print_explain "AUTH: Agent ID Developer for the publish step (manifest generation, local)."
  print_explain "Upload step requires AI Administrator (or higher) per M365 admin-centre role docs."
  echo ""

  check_prereqs "Scenario B" az-login cli-version role-agent-dev manifest || return

  print_step 1 4 "Snapshot current manifest"
  print_command "cp manifest/manifest.json manifest/manifest.json.bak"
  run_or_skip "cp manifest/manifest.json manifest/manifest.json.bak"
  echo ""

  print_step 2 4 "Re-publish manifest"
  print_command "a365 publish"
  print_explain "⚠ a365 publish overwrites your custom description with a generic"
  print_explain "  placeholder every time. That's why step 3 re-edits after publish."
  run_or_skip_critical "a365 publish" "Manifest publish failed" || return
  echo ""

  # Post-validation: check manifest.zip exists with recent timestamp
  if [[ -f manifest/manifest.zip ]]; then
    local zip_age
    zip_age=$(( $(date +%s) - $(stat -f %m manifest/manifest.zip 2>/dev/null || stat -c %Y manifest/manifest.zip 2>/dev/null) ))
    if [[ $zip_age -lt 60 ]]; then
      print_success "manifest.zip updated (${zip_age}s ago)"
    else
      print_warning "manifest.zip exists but is ${zip_age}s old — may not have been refreshed"
    fi
  fi

  print_step 3 4 "Re-edit manifest and re-zip"
  print_command "\$EDITOR manifest/manifest.json"
  print_explain "Edit description and any custom fields back to your preferred values."
  if confirm "Open manifest in editor?"; then
    ${EDITOR:-vi} manifest/manifest.json
  else
    echo -e "    ${DIM}Skipped.${RST}"
  fi
  echo ""

  print_command "cd manifest && zip -r manifest.zip manifest.json color.png outline.png agenticUserTemplateManifest.json && cd .."
  run_or_skip "cd manifest && zip -r manifest.zip manifest.json color.png outline.png agenticUserTemplateManifest.json && cd .."
  echo ""

  print_step 4 4 "Upload to M365 Admin Center"
  print_explain "Upload manifest/manifest.zip at:"
  print_explain "https://admin.microsoft.com → Agents → All agents → Upload custom agent"
  echo -e "    ${BLUE}🔑${RST} Requires: ${BOLD}AI Administrator${RST} (or higher) per the M365 admin-centre role doc"
  print_info "This step is manual — the CLI no longer auto-uploads (1.1.174+)."

  echo ""
  print_info "Verification: refresh M365 Admin Center → Agents. New description/icon"
  print_info "should appear within ~1 minute."

  CURRENT_STEP=""
  pause_for_menu
}

# ── Scenario C — Permissions re-grant ────────────────────────────────────────

scenario_c() {
  print_banner "Scenario C — Permissions Re-grant (non-destructive)"
  print_explain "You added a new Graph scope, consent expired, or you re-installed a"
  print_explain "permission via Graph PowerShell and need the CLI's record to match."
  echo ""
  print_explain ""
  print_explain "WHY: Graph permissions (Mail.ReadWrite, Chat.ReadWrite, etc.) are"
  print_explain "granted as delegated permissions on the blueprint's service principal."
  print_explain "If you added a new scope, consent expired, or you reinstalled a"
  print_explain "permission via Graph PowerShell, the CLI's record needs to match."
  print_explain ""
  print_explain "AUTH per Microsoft Learn: Application Administrator suffices for re-granting"
  print_explain "delegated permissions; Privileged Role Administrator is needed only if you're"
  print_explain "re-granting Graph application-permission consent (S2S/Both classes). If your"
  print_explain "role is insufficient, the CLI prints an admin-consent URL for the right admin"
  print_explain "to visit. Global Administrator works as a superset but exceeds the minimum."
  echo ""

  check_prereqs "Scenario C" az-login cli-version role-global-admin generated-config || return

  print_step 1 2 "Re-grant MCP permissions"
  print_command "a365 setup permissions mcp"
  print_explain "If your role lacks consent rights, the CLI prints an admin-consent URL"
  print_explain "for an Application Administrator (delegated) or Privileged Role Administrator"
  print_explain "(app-role / S2S) to visit."
  run_or_skip_critical "a365 setup permissions mcp" "MCP permissions grant failed" || return
  echo ""

  print_step 2 2 "Re-grant Bot permissions"
  print_command "a365 setup permissions bot"
  run_or_skip_critical "a365 setup permissions bot" "Bot permissions grant failed" || return

  echo ""
  print_info "Verification: trigger a Teams turn. AADSTS65001 errors should stop."
  print_info "Full consent table: a365 query-entra"

  CURRENT_STEP=""
  pause_for_menu
}

# ── Scenario D — Full cleanup → re-setup (DESTRUCTIVE) ──────────────────────

scenario_d() {
  print_banner "Scenario D — Full Cleanup → Re-setup (DESTRUCTIVE)"
  echo ""
  echo -e "  ${BG_RED}${WHITE}${BOLD}  ⚠  THIS IS DESTRUCTIVE  ⚠                                          ${RST}"
  echo ""
  print_warning "This destroys the live blueprint, service principal, agentic-user"
  print_warning "identities, and breaks existing Teams app installs."
  echo ""
  print_explain "What dies: Entra app, SP, all agentic-user identity associations,"
  print_explain "Teams app installs keyed to the old blueprint ID, audit-log continuity."
  print_explain "What survives: repo code, dev-tunnel URL, .env (except client secret)."
  echo ""
  print_explain ""
  print_explain "WHY: Some registration choices can't be changed after the fact —"
  print_explain "missing --m365 flag, wrong --aiteammate setting, wrong agent class."
  print_explain "The only fix is to delete everything and re-register from scratch."
  print_explain ""
  print_explain "AUTH per Microsoft Learn — layered, not all GA:"
  print_explain "  Step 1: snapshot (no auth needed)"
  print_explain "  Step 2: cleanup blueprint — Agent ID Developer (owner of the blueprint)"
  print_explain "  Step 3: cleanup instance — Agent ID Administrator (manages agent users)"
  print_explain "  Step 4: setup blueprint — Agent ID Developer + device-code auth to Graph"
  print_explain "  Step 5: setup permissions — Application Administrator (delegated) OR"
  print_explain "          Privileged Role Administrator (S2S/Both class app-role consent)"
  print_explain "  Step 6: publish — Agent ID Developer; AI Administrator for manual upload"
  print_explain "  Global Administrator covers all but exceeds the documented minimum."
  echo ""

  check_prereqs "Scenario D" az-login cli-version role-global-admin tunnel agent generated-config || return

  echo -e "    ${RED}${BOLD}Type 'i understand' to continue (anything else aborts):${RST}"
  read -r -p "    > " gate_answer
  if [[ "$gate_answer" != "i understand" ]]; then
    echo -e "    ${DIM}Aborted — returning to menu.${RST}"
    CURRENT_STEP=""
    pause_for_menu
    return
  fi
  echo ""

  print_step 1 6 "Snapshot current state (mandatory)"
  print_command "cp a365.generated.config.json a365.generated.config.json.bak-\$(date +%Y%m%d)"
  if [[ -f a365.generated.config.json ]]; then
    run_or_skip "cp a365.generated.config.json \"a365.generated.config.json.bak-\$(date +%Y%m%d)\""
    echo ""
    print_command "jq '{blueprintId: .agentBlueprintId, instanceId: .agentInstanceId, botMsaAppId: .botMsaAppId}' a365.generated.config.json"
    print_explain "Copy this output — you'll need these IDs for historical audit rows."
    run_or_skip "jq '{blueprintId: .agentBlueprintId, instanceId: .agentInstanceId, botMsaAppId: .botMsaAppId}' a365.generated.config.json"
  else
    print_warning "a365.generated.config.json not found — nothing to snapshot."
  fi
  echo ""

  print_step 2 6 "Destroy the existing blueprint"
  print_command "a365 cleanup blueprint -y"
  print_explain "Deletes: Entra app + service principal + endpoint + blueprint metadata."
  run_or_skip_critical "a365 cleanup blueprint -y" "Blueprint cleanup failed" || return
  echo ""

  print_step 3 6 "Remove agentic-user identities"
  print_command "a365 cleanup instance -y"
  print_explain "Each user gets a new agentic-user the first time they engage."
  run_or_skip "a365 cleanup instance -y"
  echo ""

  print_step 4 6 "Re-create blueprint"
  print_command "a365 setup blueprint --m365"
  print_explain "Use whatever flags you actually want this time (--aiteammate etc)."
  run_or_skip_critical "a365 setup blueprint --m365" "Blueprint setup failed — see RE-REGISTRATION.md §D rollback" || return
  echo ""

  # Post-validation: check new blueprint ID
  if [[ -f a365.generated.config.json ]]; then
    local new_id
    new_id=$(jq -r '.agentBlueprintId // ""' a365.generated.config.json)
    if [[ -n "$new_id" && "$new_id" != "null" ]]; then
      print_success "New blueprint ID: $new_id"
    fi
  fi

  print_step 5 6 "Re-grant permissions"
  print_command "a365 setup permissions mcp && a365 setup permissions bot"
  run_or_skip_critical "a365 setup permissions mcp && a365 setup permissions bot" \
    "Permissions grant failed" || return
  echo ""

  print_step 6 6 "Re-publish manifest"
  print_command "a365 publish"
  print_explain "Then re-edit manifest.json + re-zip (see scenario B), and upload"
  print_explain "manifest.zip via M365 Admin Center → Agents → Upload custom agent."
  print_explain "Finally: Activate for your test users."
  run_or_skip "a365 publish"

  echo ""
  print_info "Verification checklist:"
  print_info "  1. a365 query-entra             → old blueprint not found"
  print_info "  2. jq .agentBlueprintId *.json   → new GUID"
  print_info "  3. a365 query-entra             → scopes show consentGranted: true"
  print_info "  4. ls -la manifest/manifest.zip  → recent timestamp"
  print_info "  5. M365 Admin Center → Agents    → new row appears"
  print_info "  6. Teams turn                    → POST /api/messages returns 202"
  echo ""
  print_explain "For rollback: see RE-REGISTRATION.md §D rollback."

  CURRENT_STEP=""
  pause_for_menu
}

# ── Registration class picker ────────────────────────────────────────────────

explain_auth_modes() {
  echo -e "  ${BOLD}Understanding the two authentication modes:${RST}"
  echo ""
  echo -e "  ${BOLD}${CYAN}OBO (On-Behalf-Of)${RST}"
  echo -e "  ${DIM}The agent borrows the calling user's token. It can only do what that${RST}"
  echo -e "  ${DIM}user can do. Audit logs show the user as the actor. No admin consent${RST}"
  echo -e "  ${DIM}needed — the user consents on first use. Least privilege, most common.${RST}"
  echo ""
  echo -e "  ${BOLD}${CYAN}S2S (Server-to-Server)${RST}"
  echo -e "  ${DIM}The agent authenticates as itself using app permissions. It can act${RST}"
  echo -e "  ${DIM}without a user session (scheduled jobs, background processing). Audit${RST}"
  echo -e "  ${DIM}logs show the agent as the actor. Requires Privileged Role Administrator${RST}"
  echo -e "  ${DIM}(or higher) to grant the Graph app-role consent.${RST}"
  echo ""
  echo -e "  ${BOLD}Key trade-offs:${RST}"
  echo -e "  ┌──────────────────────┬──────────────────────┬──────────────────────┐"
  echo -e "  │                      │ ${BOLD}OBO${RST}                  │ ${BOLD}S2S${RST}                  │"
  echo -e "  ├──────────────────────┼──────────────────────┼──────────────────────┤"
  echo -e "  │ Auth                 │ User token exchange  │ Client credentials   │"
  echo -e "  │ Consent              │ User consents        │ ${YELLOW}Admin must consent${RST}   │"
  echo -e "  │ Runs without user?   │ No                   │ ${GREEN}Yes${RST}                  │"
  echo -e "  │ Audit trail          │ Shows user as actor  │ Shows agent as actor │"
  echo -e "  │ Blast radius         │ Limited to user perms│ ${YELLOW}Tenant-wide${RST}          │"
  echo -e "  │ Min. Entra role      │ Agent ID Developer   │ ${YELLOW}Priv. Role Admin${RST}     │"
  echo -e "  └──────────────────────┴──────────────────────┴──────────────────────┘"
  echo ""
}

guided_class_selection() {
  echo -e "  ${BOLD}Let's find the right class for your agent:${RST}"
  echo ""

  echo -e "  ${BOLD}Q1:${RST} Does your agent need its own M365 identity (mailbox, calendar, Teams presence)?"
  echo -ne "      ${DIM}[y/N]:${RST} "
  read -r q1
  echo ""

  if [[ "$q1" =~ ^[yY] ]]; then
    echo -e "  ${BOLD}Q2:${RST} Should it appear in M365 Copilot, or Teams channels only?"
    echo -ne "      ${DIM}[c=Copilot / t=Teams only]:${RST} "
    read -r q2
    echo ""
    if [[ "$q2" =~ ^[tT] ]]; then
      echo -e "  ${GREEN}→ Recommended: ${BOLD}5) AI Teammate (non-M365)${RST}"
      echo -e "    ${DIM}Teams-channel-only. Own Entra user. Needs Agent ID Developer + Application Administrator + (for activation) AI Administrator + Agent ID Administrator + M365 Copilot licence.${RST}"
      GUIDED_RECOMMENDATION=5
    else
      echo -e "  ${GREEN}→ Recommended: ${BOLD}4) AI Teammate (M365)${RST}"
      echo -e "    ${DIM}Full Copilot integration. Own mailbox + Teams presence. Needs Agent ID Developer + Application Administrator + (for activation) AI Administrator + Agent ID Administrator + M365 Copilot licence.${RST}"
      GUIDED_RECOMMENDATION=4
    fi
  else
    echo -e "  ${BOLD}Q2:${RST} When the agent runs, is there a ${BOLD}live Entra user${RST}${DIM} (a human in Teams / Copilot at the moment of invocation)${RST} whose"
    echo -e "      delegated token the agent can borrow?"
    echo -e "      ${DIM}'Autonomous' here means NO — e.g. Databricks scheduled jobs, cron, queue workers, event-triggered pipelines,${RST}"
    echo -e "      ${DIM}customer-system API calls. Notebook / pod / job-runner sessions don't count as A365 'user sessions' — the${RST}"
    echo -e "      ${DIM}question is whether an ${BOLD}Entra user JWT${DIM} is flowing in, not whether code is running 'in a session' somewhere.${RST}"
    echo -ne "      ${DIM}[y=autonomous, no Entra user / N=user is present]:${RST} "
    read -r q2b
    echo ""
    if [[ "$q2b" =~ ^[yY] ]]; then
      echo -e "  ${GREEN}→ Recommended: ${BOLD}2) Blueprint-only S2S (M365)${RST}"
      echo -e "    ${DIM}Agent authenticates as itself. Runs headless. Requires Privileged Role Administrator for Graph app-role consent.${RST}"
      GUIDED_RECOMMENDATION=2
    else
      echo -e "  ${GREEN}→ Recommended: ${BOLD}1) Blueprint-only OBO (M365)${RST}"
      echo -e "    ${DIM}Agent acts on behalf of user. Simplest setup, least privilege. Generally available; the CLI default.${RST}"
      GUIDED_RECOMMENDATION=1
    fi
  fi
  echo ""
  echo -e "  ${DIM}You can accept this recommendation or pick any class from the menu below.${RST}"
  echo ""
}

pick_registration_class() {
  explain_auth_modes
  guided_class_selection

  echo -e "  ${BOLD}All registration classes:${RST}"
  echo ""
  echo -e "  ${BOLD}${GREEN}1)${RST}  Blueprint-only with OBO (M365)     ${DIM}— CLI default, generally available, least privilege${RST}"
  echo -e "      ${DIM}Use when: the agent acts on behalf of a user (most common, simplest setup)${RST}"
  echo -e "      ${DIM}Creates:  Entra app + service principal. No agentic user.${RST}"
  echo -e "      ${DIM}Command: a365 setup all -n ... --m365${RST}"
  echo -e "      ${DIM}Role:    Agent ID Developer${RST}"
  echo ""
  echo -e "  ${BOLD}${GREEN}2)${RST}  Blueprint-only with S2S (M365)     ${DIM}— autonomous/headless agents${RST}"
  echo -e "      ${DIM}Use when: the agent runs autonomously without a user session${RST}"
  echo -e "      ${DIM}Creates:  Entra app + SP + app-permission grants (tenant-wide).${RST}"
  echo -e "      ${DIM}Trade-off: powerful but broad blast radius — every scope is tenant-wide.${RST}"
  echo -e "      ${DIM}Command: a365 setup all -n ... --m365 --authmode s2s${RST}"
  echo -e "      ${DIM}Role:    Agent ID Developer + ${YELLOW}Privileged Role Administrator${RST} ${DIM}(Graph app-role consent)${RST}"
  echo ""
  echo -e "  ${BOLD}${GREEN}3)${RST}  Blueprint-only with Both (M365)    ${DIM}— OBO + S2S hybrid${RST}"
  echo -e "      ${DIM}Use when: the agent needs both user-driven AND autonomous flows${RST}"
  echo -e "      ${DIM}Creates:  Entra app + SP + both delegated and app-permission grants.${RST}"
  echo -e "      ${DIM}Trade-off: rarely necessary. Consider two separate agents instead.${RST}"
  echo -e "      ${DIM}Command: a365 setup all -n ... --m365 --authmode both${RST}"
  echo -e "      ${DIM}Role:    Agent ID Developer + ${YELLOW}Privileged Role Administrator${RST} ${DIM}(Graph app-role consent)${RST}"
  echo ""
  echo -e "  ${BOLD}${CYAN}4)${RST}  AI Teammate (M365)                 ${DIM}— own Entra user identity${RST}"
  echo -e "      ${DIM}Use when: the agent needs its own M365 identity in Copilot${RST}"
  echo -e "      ${DIM}Creates:  Entra app + SP + agent identity SP at registration; agentic user (UPN,${RST}"
  echo -e "      ${DIM}          mailbox, Teams presence) is minted after admin centre activation.${RST}"
  echo -e "      ${DIM}Trade-off: most capable but needs M365 Copilot licence + multiple elevated roles (see Role line below). Cleanup destroys user.${RST}"
  echo -e "      ${DIM}Command: a365 setup all -n ... --m365  →  a365 publish --aiteammate true${RST}"
  echo -e "      ${DIM}Role:    Agent ID Developer + ${BOLD}Application Administrator${RST}${DIM} (consent). For user wrapper: + AI Administrator + Agent ID Administrator + M365 Copilot licence${RST}"
  echo ""
  echo -e "  ${BOLD}${CYAN}5)${RST}  AI Teammate (non-M365)             ${DIM}— Teams-only, no Copilot surface${RST}"
  echo -e "      ${DIM}Use when: same as 4 but Teams-channel-only, no M365 Copilot surface${RST}"
  echo -e "      ${DIM}Creates:  Same as 4 but endpoint registered via Teams Dev Portal, not MCP.${RST}"
  echo -e "      ${DIM}Command: a365 setup all -n ...  →  a365 publish --aiteammate true${RST}"
  echo -e "      ${DIM}Role:    Agent ID Developer + ${BOLD}Application Administrator${RST}${DIM} (consent). For user wrapper: + AI Administrator + Agent ID Administrator + M365 Copilot licence${RST}"
  echo ""
  echo -e "  ${BOLD}${MAGENTA}6)${RST}  Blueprint-based Non-DW (internal)  ${DIM}— Microsoft-internal pattern${RST}"
  echo -e "      ${DIM}Use when: Microsoft told you to use this pattern${RST}"
  echo -e "      ${DIM}Creates:  Entra app + SP + agent identity SP. Flagged as 'not a digital worker'.${RST}"
  echo -e "      ${DIM}Command: a365 setup all -n ... --m365  →  a365 publish --aiteammate false --use-blueprint${RST}"
  echo -e "      ${DIM}Role:    Agent ID Developer${RST}"
  echo ""

  echo -ne "  ${BOLD}Choose class [1-6, default=${GUIDED_RECOMMENDATION}]:${RST} "
  read -r class_choice

  case "${class_choice:-$GUIDED_RECOMMENDATION}" in
    1)
      SELECTED_CLASS_NAME="Blueprint-only OBO (M365)"
      SELECTED_CLASS_CMD="a365 setup all"
      SELECTED_CLASS_FLAGS="--m365"
      SELECTED_CLASS_ROLE="Agent ID Developer"
      SELECTED_CLASS_NEEDS_GA=false
      SELECTED_CLASS_POST_CMD=""
      ;;
    2)
      SELECTED_CLASS_NAME="Blueprint-only S2S (M365)"
      SELECTED_CLASS_CMD="a365 setup all"
      SELECTED_CLASS_FLAGS="--m365 --authmode s2s"
      SELECTED_CLASS_ROLE="Agent ID Developer + Privileged Role Administrator"
      SELECTED_CLASS_NEEDS_GA=true
      SELECTED_CLASS_POST_CMD=""
      ;;
    3)
      SELECTED_CLASS_NAME="Blueprint-only Both (M365)"
      SELECTED_CLASS_CMD="a365 setup all"
      SELECTED_CLASS_FLAGS="--m365 --authmode both"
      SELECTED_CLASS_ROLE="Agent ID Developer + Privileged Role Administrator"
      SELECTED_CLASS_NEEDS_GA=true
      SELECTED_CLASS_POST_CMD=""
      ;;
    4)
      SELECTED_CLASS_NAME="AI Teammate (M365)"
      SELECTED_CLASS_CMD="a365 setup all"
      SELECTED_CLASS_FLAGS="--m365"
      SELECTED_CLASS_ROLE="Agent ID Developer + Application Administrator (+ AI Administrator + Agent ID Administrator + M365 Copilot licence for the full user-wrapper activation)"
      SELECTED_CLASS_NEEDS_GA=true
      SELECTED_CLASS_POST_CMD="a365 publish --aiteammate true"
      ;;
    5)
      SELECTED_CLASS_NAME="AI Teammate (non-M365)"
      SELECTED_CLASS_CMD="a365 setup all"
      SELECTED_CLASS_FLAGS=""
      SELECTED_CLASS_ROLE="Agent ID Developer + Application Administrator (+ AI Administrator + Agent ID Administrator + M365 Copilot licence for the full user-wrapper activation)"
      SELECTED_CLASS_NEEDS_GA=true
      SELECTED_CLASS_POST_CMD="a365 publish --aiteammate true"
      ;;
    6)
      SELECTED_CLASS_NAME="Blueprint-based Non-DW (internal)"
      SELECTED_CLASS_CMD="a365 setup all"
      SELECTED_CLASS_FLAGS="--m365"
      SELECTED_CLASS_ROLE="Agent ID Developer"
      SELECTED_CLASS_NEEDS_GA=false
      SELECTED_CLASS_POST_CMD="a365 publish --aiteammate false --use-blueprint"
      ;;
    *)
      echo -e "  ${RED}Invalid choice — defaulting to Blueprint-only OBO (M365).${RST}"
      SELECTED_CLASS_NAME="Blueprint-only OBO (M365)"
      SELECTED_CLASS_CMD="a365 setup all"
      SELECTED_CLASS_FLAGS="--m365"
      SELECTED_CLASS_ROLE="Agent ID Developer"
      SELECTED_CLASS_NEEDS_GA=false
      SELECTED_CLASS_POST_CMD=""
      ;;
  esac

  echo ""
  echo -e "  ${GREEN}✔${RST} Selected: ${BOLD}${SELECTED_CLASS_NAME}${RST}"
  echo -e "    Command: ${CYAN}${SELECTED_CLASS_CMD} -n \"<name>\" ${SELECTED_CLASS_FLAGS}${RST}"
  if [[ -n "$SELECTED_CLASS_POST_CMD" ]]; then
    echo -e "    Then:    ${CYAN}${SELECTED_CLASS_POST_CMD}${RST}"
  fi
  echo -e "    Role:    ${SELECTED_CLASS_ROLE}"
  if $SELECTED_CLASS_NEEDS_GA; then
    echo -e "    ${YELLOW}⚠ This class needs elevated consent rights — see Role line above. Global Administrator works but exceeds the documented minimum.${RST}"
  fi
  echo ""
}

# ── Scenario E — Side-by-side parallel (DEMO DEFAULT) ────────────────────────

scenario_e() {
  print_banner "Scenario E — Side-by-side Parallel Registration (non-destructive)"
  print_explain "Registers a second blueprint alongside your live one. Both coexist"
  print_explain "in the tenant, both appear in M365 Admin Center → Agents."
  echo ""
  print_explain "WHY: You want to test a different agent class (e.g., Blueprint-only"
  print_explain "vs AI Teammate, OBO vs S2S) without touching your live registration."
  print_explain ""
  print_explain "HOW IT WORKS:"
  print_explain "  1. The CLI's -n flag bypasses a365.config.json and uses the name"
  print_explain "     you provide. It looks up the client app by display name"
  print_explain "     'Agent 365 CLI' in your tenant."
  print_explain "  2. A new Entra app registration is created for the parallel blueprint."
  print_explain "  3. The new blueprint gets its own service principal, client secret,"
  print_explain "     and (if AI Teammate) its own agentic-user identity."
  print_explain "  4. The CLI stamps .env and a365.generated.config.json with the new"
  print_explain "     blueprint's values — this script backs them up and restores after."
  print_explain ""
  print_explain "IMPORTANT:"
  print_explain "  • Each new blueprint requires its own admin consent for Graph permissions."
  print_explain "    The CLI opens a browser for this — approve when prompted."
  print_explain "  • This script pre-authenticates to Microsoft Graph via PowerShell so the"
  print_explain "    CLI can create the Entra app registration for the new blueprint."
  echo ""

  # Name prompt
  local default_name
  default_name=$(get_demo_parallel_name)
  echo -e "  ${BOLD}Name for the new parallel blueprint:${RST}"
  echo -e "  ${DIM}This name appears in Entra and M365 Admin Center. Use something${RST}"
  echo -e "  ${DIM}descriptive so you can tell it apart from your live blueprint.${RST}"
  echo -ne "  ${BOLD}Name [${default_name}]:${RST} "
  read -r custom_name
  local parallel_name="${custom_name:-$default_name}"
  echo ""
  print_success "Blueprint name: $parallel_name"
  echo ""

  # Class picker (includes OBO/S2S explainer + decision tree)
  pick_registration_class

  # Dynamic prereqs based on class selection
  if $SELECTED_CLASS_NEEDS_GA; then
    check_prereqs "Scenario E (${SELECTED_CLASS_NAME})" az-login cli-version role-global-admin tunnel agent pwsh client-app-name || return
  else
    check_prereqs "Scenario E (${SELECTED_CLASS_NAME})" az-login cli-version role-agent-dev tunnel agent pwsh client-app-name || return
  fi

  print_step 1 4 "Snapshot current state"
  print_explain "WHY: Record the current live blueprint ID so you can verify both"
  print_explain "registrations coexist after step 3."
  print_command "jq '{liveBlueprint: .agentBlueprintId}' a365.generated.config.json"
  if [[ -f a365.generated.config.json ]]; then
    run_or_skip "jq '{liveBlueprint: .agentBlueprintId}' a365.generated.config.json"
  else
    print_info "a365.generated.config.json not found — that's fine for a fresh registration."
  fi
  echo ""

  # Isolate every demo registration in script-runs/<name>/. The a365 CLI writes
  # .env, a365.generated.config.json, and manifest/* in the current working dir,
  # so running from a per-run sandbox keeps the live project files untouchable —
  # no backup/restore dance, and the published manifest.zip lands where you can
  # upload it without rerunning publish.
  local sanitized_name run_dir
  sanitized_name=$(echo "$parallel_name" | tr ' ' '-' | sed 's/[^A-Za-z0-9._-]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//')
  run_dir="script-runs/$sanitized_name"
  mkdir -p "$run_dir/manifest"
  # Seed manifest assets. `a365 publish` updates manifest.json in place
  # (it doesn't create it from scratch) and packages the zip from the icons +
  # agenticUserTemplateManifest.json. Without these seeds publish errors with
  # "Manifest not found".
  for f in manifest.json agenticUserTemplateManifest.json color.png outline.png; do
    [[ -f "manifest/$f" ]] && cp "manifest/$f" "$run_dir/manifest/$f"
  done
  print_info "Registration artifacts will live in: ${BOLD}${run_dir}/${RST}"
  print_info "${DIM}Live .env, a365.generated.config.json, and manifest/ stay untouched.${RST}"
  echo ""

  print_step 2 4 "Pre-authenticate to Microsoft Graph"
  print_explain "WHY: The a365 CLI needs to authenticate to Microsoft Graph to create"
  print_explain "the Entra app registration for the new blueprint. This step establishes"
  print_explain "a cached Graph session via PowerShell that the CLI picks up automatically."
  print_explain "Without it, the CLI attempts browser-based auth which may not be available."
  if [[ -n "$PREFLIGHT_CLIENT_APP_ID" && "$PREFLIGHT_CLIENT_APP_ID" != "null" ]]; then
    print_command "pwsh -c \"Connect-MgGraph -TenantId '$PREFLIGHT_AZ_TENANT' -ClientId '$PREFLIGHT_CLIENT_APP_ID' -Scopes 'Application.ReadWrite.All','Directory.Read.All' -NoWelcome\""
    run_or_skip_critical "pwsh -c \"Connect-MgGraph -TenantId '$PREFLIGHT_AZ_TENANT' -ClientId '$PREFLIGHT_CLIENT_APP_ID' -Scopes 'Application.ReadWrite.All','Directory.Read.All' -NoWelcome\"" \
      "Graph pre-auth failed — blueprint creation will likely fail" || return
  else
    print_command "pwsh -c \"Connect-MgGraph -TenantId '$PREFLIGHT_AZ_TENANT' -Scopes 'Application.ReadWrite.All','Directory.Read.All' -NoWelcome\""
    run_or_skip_critical "pwsh -c \"Connect-MgGraph -TenantId '$PREFLIGHT_AZ_TENANT' -Scopes 'Application.ReadWrite.All','Directory.Read.All' -NoWelcome\"" \
      "Graph pre-auth failed" || return
  fi
  echo ""

  # Subshell `cd "$run_dir" && a365 ...` keeps cwd changes scoped to the command,
  # so the CLI writes its artifacts in script-runs/<name>/ instead of repo root.
  local setup_cmd_display="${SELECTED_CLASS_CMD} -n \"$parallel_name\" $SELECTED_CLASS_FLAGS"
  local setup_cmd="(cd \"$run_dir\" && ${setup_cmd_display})"

  print_step 3 4 "Register second blueprint (${SELECTED_CLASS_NAME})"
  print_command "(in $run_dir/)  $setup_cmd_display"
  print_explain "WHY: This is the actual registration. The -n flag tells the CLI to"
  print_explain "create a standalone blueprint with the given name. Running from the"
  print_explain "isolated run dir means the CLI writes .env, a365.generated.config.json,"
  print_explain "and manifest/ inside ${run_dir}/ — your live project files are untouched."
  print_explain ""
  print_explain "WHAT HAPPENS: The CLI creates a new Entra app, service principal,"
  print_explain "client secret, and (depending on class) agent identity. It then"
  print_explain "opens a browser for admin consent on the new blueprint's Graph"
  print_explain "permissions — approve when prompted."
  run_or_skip_critical "$setup_cmd" \
    "Blueprint registration failed — check tunnel, auth, and CLI version" || return
  echo ""

  # Heads-up about the endpoint right after setup all — the CLI prints
  # "MessagingEndpoint not configured" because -n mode bypasses a365.config.json.
  # Surface the exact attach command now, with the live endpoint pre-filled,
  # so the user doesn't have to scroll back to find it after step 4.
  if [[ "$SELECTED_CLASS_FLAGS" == *"--m365"* ]]; then
    local heads_up_endpoint
    heads_up_endpoint=$(get_live_endpoint)
    if [[ -n "$heads_up_endpoint" && "$heads_up_endpoint" != "(not set)" && "$heads_up_endpoint" != "(not configured)" ]]; then
      print_info "Heads-up: the CLI skipped messaging endpoint registration ('-n' mode bypasses a365.config.json)."
      print_info "After the script finishes, attach the live dev-tunnel endpoint to this blueprint:"
      print_command "a365 setup blueprint -n \"$parallel_name\" --m365 --update-endpoint \"$heads_up_endpoint\""
      echo ""
    fi
  fi

  # Classes 4, 5, 6 need a follow-up `a365 publish` to flavour the manifest.
  # Setup all has already created the blueprint + agent identity SP at this point;
  # publish only generates the manifest with the right class flag.
  if [[ -n "$SELECTED_CLASS_POST_CMD" ]]; then
    local post_step_label="Generate class-specific manifest"
    local post_step_why="WHY: 'a365 setup all' creates a class-agnostic blueprint + agent identity SP."
    local post_step_why2="The publish step generates the manifest that admins upload to M365 Admin"
    local post_step_why3="Centre; its flags flavour the manifest for the chosen class."
    if [[ "$SELECTED_CLASS_NAME" == *"AI Teammate"* ]]; then
      post_step_label="Flag manifest as AI Teammate"
    elif [[ "$SELECTED_CLASS_NAME" == *"Non-DW"* ]]; then
      post_step_label="Flag manifest as Non-DW blueprint"
    fi
    print_step "3b" 4 "$post_step_label"
    local post_cmd_display="${SELECTED_CLASS_POST_CMD} -n \"$parallel_name\""
    local post_cmd="(cd \"$run_dir\" && ${post_cmd_display})"
    print_command "(in $run_dir/)  $post_cmd_display"
    print_explain "$post_step_why"
    print_explain "$post_step_why2"
    print_explain "$post_step_why3"
    run_or_skip_critical "$post_cmd" \
      "Publish failed" || return
    echo ""

    # CLI sets name.short to "<base name> Blueprint" which often exceeds the
    # 30-char manifest schema limit (it warns but doesn't fix it). Normalise
    # by stripping the trailing " Blueprint" suffix; truncate as last resort.
    # Re-zip so the upload-ready zip matches the corrected manifest.json.
    local mfile="$run_dir/manifest/manifest.json"
    if [[ -f "$mfile" ]] && command -v jq &>/dev/null; then
      local raw_short fixed_short
      raw_short=$(jq -r '.name.short // ""' "$mfile")
      if [[ ${#raw_short} -gt 30 ]]; then
        fixed_short="${raw_short% Blueprint}"
        if [[ ${#fixed_short} -gt 30 ]]; then fixed_short="${fixed_short:0:30}"; fi
        jq --arg sn "$fixed_short" '.name.short = $sn' "$mfile" > "$mfile.tmp" && mv "$mfile.tmp" "$mfile"
        print_info "Normalised manifest name.short: '$raw_short' (${#raw_short} chars) → '$fixed_short' (${#fixed_short} chars)"
        if command -v zip &>/dev/null; then
          ( cd "$run_dir/manifest" && rm -f manifest.zip && zip -q manifest.zip manifest.json color.png outline.png agenticUserTemplateManifest.json ) \
            && print_info "Re-zipped manifest.zip with corrected name.short."
        else
          print_warning "zip command not available — re-zip $run_dir/manifest/ manually before uploading."
        fi
      fi
    fi
  fi

  # Nothing to restore — every CLI call wrote into $run_dir, never the repo root.
  if [[ -f "$run_dir/manifest/manifest.zip" ]]; then
    print_success "Packaged manifest ready at ${BOLD}${run_dir}/manifest/manifest.zip${RST}"
  fi
  echo ""

  print_step 4 4 "Verify registration and show what was created"
  print_explain "WHY: Confirm the new blueprint exists in Entra and show you exactly"
  print_explain "what was created so you can verify in the portal."
  echo ""

  # Query Graph API for the new blueprint
  local bp_info
  bp_info=$(az ad app list --display-name "$parallel_name" --query "[0].{appId:appId, displayName:displayName, id:id}" -o json 2>/dev/null || echo "{}")

  local new_app_id
  new_app_id=$(echo "$bp_info" | jq -r '.appId // ""' 2>/dev/null)

  if [[ -n "$new_app_id" && "$new_app_id" != "null" && "$new_app_id" != "" ]]; then
    local new_object_id
    new_object_id=$(echo "$bp_info" | jq -r '.id // ""' 2>/dev/null)

    # Check if SP exists
    local sp_id
    sp_id=$(az ad sp show --id "$new_app_id" --query "id" -o tsv 2>/dev/null || echo "")

    echo -e "  ${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${RST}"
    echo -e "  ${BOLD}${GREEN}║  ✔  REGISTRATION SUCCESSFUL                                ║${RST}"
    echo -e "  ${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${RST}"
    echo ""
    echo -e "  ${BOLD}What was created in your tenant:${RST}"
    echo ""
    echo -e "    ${GREEN}✔${RST} ${BOLD}Entra App Registration${RST}"
    echo -e "      Name:    $parallel_name"
    echo -e "      App ID:  $new_app_id"
    if [[ -n "$sp_id" ]]; then
      echo -e "    ${GREEN}✔${RST} ${BOLD}Service Principal${RST}"
      echo -e "      SP ID:   $sp_id"
    fi
    # Agent identity SP (the agentIdentity directory object, type ServiceIdentity).
    # Auto-created by `a365 setup all` whenever --aiteammate is NOT passed to setup.
    # Named "<base name> Identity". Distinct from the full Entra user (UPN, mailbox)
    # which is minted later by admin centre activation + M365 license assignment.
    local identity_sp_id
    identity_sp_id=$(az rest --method GET --url "https://graph.microsoft.com/beta/servicePrincipals?\$filter=displayName eq '${parallel_name} Identity'" --query "value[0].id" -o tsv 2>/dev/null)
    if [[ -n "$identity_sp_id" && "$identity_sp_id" != "null" ]]; then
      echo -e "    ${GREEN}✔${RST} ${BOLD}Agent Identity SP${RST} ${DIM}(${parallel_name} Identity · ${identity_sp_id})${RST}"
    else
      echo -e "    ${RED}✗${RST} ${BOLD}Agent Identity SP${RST} ${RED}— '${parallel_name} Identity' was NOT created. ${RST}${DIM}This usually means --aiteammate was passed to 'setup all'; omit it so the CLI auto-creates the identity.${RST}"
    fi
    if [[ "$SELECTED_CLASS_NAME" == *"AI Teammate"* ]]; then
      echo -e "    ${BLUE}ℹ${RST} ${BOLD}Agentic user (UPN, mailbox, Teams presence)${RST} ${DIM}— minted after manifest upload + admin centre activation + M365 license assignment.${RST}"
    fi
    # MCP endpoint is only auto-registered when --aiteammate is passed to `setup all`.
    # After the fix that drops --aiteammate, no class auto-registers the endpoint;
    # surface this honestly so the user knows to attach it manually if needed.
    if [[ "$SELECTED_CLASS_FLAGS" == *"--m365"* ]]; then
      echo -e "    ${BLUE}ℹ${RST} ${BOLD}MCP Platform Endpoint${RST} ${DIM}— not auto-registered (suggested follow-up below).${RST}"
    fi
    if [[ "$SELECTED_CLASS_NAME" == *"Non-DW"* ]]; then
      echo -e "    ${GREEN}✔${RST} ${BOLD}Non-DW Flag${RST} (blueprint-based, not digital worker)"
    fi
    echo ""
    echo -e "  ${BOLD}Portal links:${RST}"
    echo -e "    Entra:       ${CYAN}https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Overview/appId/$new_app_id${RST}"
    echo -e "    Admin Center:${CYAN}https://admin.cloud.microsoft/#/agents/all?search=$(echo "$parallel_name" | sed 's/ /+/g')${RST}"
    echo ""
    echo -e "  ${BOLD}Live blueprint (unchanged):${RST}"
    echo -e "    Name:    $(get_live_app_name)"
    echo -e "    ID:      $(get_live_blueprint_id)"
  else
    print_warning "Could not verify blueprint in Entra — it may still be propagating."
    print_info "Check manually in Azure Portal → App registrations → search '$parallel_name'"
  fi

  echo ""
  # Suggested follow-up: attach the messaging endpoint so the demo blueprint
  # becomes a functional bot. The current `setup all` path (no --aiteammate)
  # doesn't auto-register the endpoint, so this step is opt-in. Endpoint comes
  # from the live a365.config.json — same dev-tunnel as the live Draft Dodger,
  # which is fine because the bot framework routes by appId.
  if [[ "$SELECTED_CLASS_FLAGS" == *"--m365"* ]]; then
    local suggested_endpoint
    suggested_endpoint=$(get_live_endpoint)
    if [[ -n "$suggested_endpoint" && "$suggested_endpoint" != "(not set)" && "$suggested_endpoint" != "(not configured)" ]]; then
      print_info "To make this demo blueprint a functional bot (attach the same dev-tunnel endpoint as the live agent), run:"
      print_command "a365 setup blueprint -n \"$parallel_name\" --m365 --update-endpoint \"$suggested_endpoint\""
      echo ""
    fi
  fi

  if [[ -f "$run_dir/manifest/manifest.zip" ]]; then
    print_info "To install this demo agent in Teams / M365 Copilot, upload its manifest zip:"
    print_command "open \"$run_dir/manifest/\"   # then upload manifest.zip at admin.microsoft.com → Agents → Upload custom agent"
    echo ""
  fi

  print_info "To clean up the test blueprint + run artifacts later, run:"
  print_command "a365 cleanup blueprint -n \"$parallel_name\" -y && rm -rf \"$run_dir\""

  CURRENT_STEP=""
  pause_for_menu
}

# ── Main menu ────────────────────────────────────────────────────────────────

show_menu() {
  clear
  echo ""
  echo -e "${BOLD}${BLUE}  ╔══════════════════════════════════════════════════════════════════╗${RST}"
  echo -e "${BOLD}${BLUE}  ║${RST}${BOLD}            A365 RE-REGISTRATION DEMO                           ${BLUE}║${RST}"
  echo -e "${BOLD}${BLUE}  ╚══════════════════════════════════════════════════════════════════╝${RST}"
  echo ""
  echo -e "  ${BOLD}${WHITE}0)${RST}  Concept primer — what gets created, what each command destroys"
  echo ""
  echo -e "  ${BOLD}${GREEN}A)${RST}  Endpoint swap            ${DIM}(non-destructive · single command · ~5s)${RST}"
  echo -e "  ${BOLD}${GREEN}B)${RST}  Manifest re-publish      ${DIM}(non-destructive · 4 steps · ~30s + manual upload)${RST}"
  echo -e "  ${BOLD}${GREEN}C)${RST}  Permissions re-grant     ${DIM}(non-destructive · 2 commands · ~10s)${RST}"
  echo -e "  ${BOLD}${RED}D)${RST}  Full cleanup → re-setup  ${DIM}(${RED}DESTRUCTIVE${RST}${DIM} · 6 steps · ~3min)${RST}"
  echo -e "  ${BOLD}${CYAN}E)${RST}  Side-by-side parallel    ${DIM}(non-destructive · 3 steps · ~30s)${RST}  ${YELLOW}← demo default${RST}"
  echo ""
  echo -e "  ${DIM}s)  Show current state (live values from configs)${RST}"
  echo -e "  ${DIM}q)  Quit${RST}"
  echo ""
  echo -e "  ${DIM}Agent: $(get_live_app_name) │ Blueprint: $(get_live_blueprint_id)${RST}"
  echo ""
}

main() {
  while true; do
    show_menu
    echo -ne "  ${BOLD}Choose [0/A/B/C/D/E/s/q]:${RST} "
    read -r choice
    case "$choice" in
      0)       show_concepts ;;
      [aA])    scenario_a ;;
      [bB])    scenario_b ;;
      [cC])    scenario_c ;;
      [dD])    scenario_d ;;
      [eE])    scenario_e ;;
      [sS])    show_state ;;
      [qQ]|"") CURRENT_STEP=""; exit 0 ;;
      *)       echo -e "  ${RED}Unknown option: $choice${RST}"; sleep 1 ;;
    esac
  done
}

main
