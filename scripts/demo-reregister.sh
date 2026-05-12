#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# A365 Agent Re-registration Demo
# Menu-driven walk-through of the five re-registration scenarios documented
# in RE-REGISTRATION.md. Values sourced from .env + a365 config files.
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
    eval "$cmd" 2>&1 | sed 's/^/    /'
    local rc=${PIPESTATUS[0]}
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
  echo ""

  echo -e "  ${BOLD}${CYAN}2. Service Principal (SP)${RST}"
  echo -e "  ${DIM}The per-tenant instance of the blueprint app. Carries the consent grants."
  echo -e "  Created automatically when the blueprint is registered in your tenant."
  echo -e "  Destroyed when you cleanup the blueprint.${RST}"
  echo ""

  echo -e "  ${BOLD}${CYAN}3. Agentic User Identity${RST}"
  echo -e "  ${DIM}An Entra user account (1:1 with Agent Identity) — UPN, mailbox, OneDrive,"
  echo -e "  Teams presence. No password — authenticates via federated credentials."
  echo -e "  Identified by agentInstanceId per user. Survives blueprint updates"
  echo -e "  except full cleanup (scenario D).${RST}"
  echo ""

  echo -e "  ${BOLD}${CYAN}4. Messaging Endpoint${RST}"
  echo -e "  ${DIM}The HTTPS URL the Bot Framework POSTs /api/messages to. This is the only"
  echo -e "  thing scenario A changes. Usually your dev tunnel URL."
  echo -e "  Currently: ${CYAN}$(get_live_endpoint)${RST}"
  echo ""

  echo -e "  ${BOLD}${CYAN}5. MCP Platform Link${RST}"
  echo -e "  ${DIM}How the blueprint is registered with the A365 service so it shows up in"
  echo -e "  M365 Admin Center → Agents. Created by --m365 flag during setup.${RST}"
  echo ""

  echo -e "  ${BOLD}${CYAN}6. Manifest${RST}"
  echo -e "  ${DIM}The Teams app package (manifest.zip) that admins upload. Holds the bot's"
  echo -e "  display metadata and points at the blueprint's app ID."
  echo -e "  Generated by ${CYAN}a365 publish${DIM}, then manually uploaded to Admin Center.${RST}"
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

  if [[ -f a365.generated.config.json ]]; then
    local last_updated
    last_updated=$(jq -r '.lastUpdated // "(unknown)"' a365.generated.config.json)
    local cli_version
    cli_version=$(jq -r '.cliVersion // "(unknown)"' a365.generated.config.json)
    echo -e "  ${DIM}Last updated: $last_updated${RST}"
    echo -e "  ${DIM}CLI version:  $cli_version${RST}"
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

  print_step 1 2 "Confirm current endpoint"
  print_command "jq -r '.messagingEndpoint' a365.config.json"
  print_prereq "a365.config.json must exist"
  run_or_skip "jq -r '.messagingEndpoint' a365.config.json"
  echo ""

  print_step 2 2 "Update endpoint on the existing blueprint"
  local endpoint
  endpoint=$(get_live_endpoint)
  print_command "a365 setup blueprint --m365 --update-endpoint \"$endpoint\""
  print_auth "az login (interactive once per boot)"
  print_explain "⚠ --m365 is REQUIRED. Without it the command silently no-ops."
  print_explain "See LESSONS_LEARNED.md §5.1."
  run_or_skip "a365 setup blueprint --m365 --update-endpoint \"$endpoint\""

  echo ""
  print_info "Verification: send one Teams turn. Agent log should show"
  print_info "POST /api/messages HTTP/1.1 202."
  print_info "If you get 502s — Bot Framework cache. Self-heals in ~2 min."
  print_info "See LESSONS_LEARNED.md §8."

  CURRENT_STEP=""
  pause_for_menu
}

# ── Scenario B — Manifest re-publish ─────────────────────────────────────────

scenario_b() {
  print_banner "Scenario B — Manifest Re-publish (non-destructive)"
  print_explain "You edited the agent display name, description, icon, or accent colour"
  print_explain "and need the change to surface in M365 Admin Center."
  echo ""

  print_step 1 4 "Snapshot current manifest"
  print_command "cp manifest/manifest.json manifest/manifest.json.bak"
  print_prereq "manifest/manifest.json must exist"
  run_or_skip "cp manifest/manifest.json manifest/manifest.json.bak"
  echo ""

  print_step 2 4 "Re-publish manifest"
  print_command "a365 publish"
  print_auth "az login"
  print_explain "⚠ a365 publish overwrites your custom description with a placeholder."
  print_explain "See LESSONS_LEARNED.md §5.2."
  run_or_skip "a365 publish"
  echo ""

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
  print_auth "Global Admin or Agent ID Developer role"
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

  print_step 1 2 "Re-grant MCP permissions"
  print_command "a365 setup permissions mcp"
  print_auth "az login + admin consent (if non-GA role, a Global Admin must visit the printed URL)"
  run_or_skip "a365 setup permissions mcp"
  echo ""

  print_step 2 2 "Re-grant Bot permissions"
  print_command "a365 setup permissions bot"
  print_auth "az login"
  run_or_skip "a365 setup permissions bot"

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
  print_prereq "a365.generated.config.json must exist"
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
  print_auth "az login"
  print_explain "Deletes: Entra app + service principal + endpoint + blueprint metadata."
  run_or_skip "a365 cleanup blueprint -y"
  echo ""

  print_step 3 6 "Remove agentic-user identities"
  print_command "a365 cleanup instance -y"
  print_auth "az login"
  print_explain "Each user gets a new agentic-user the first time they engage."
  run_or_skip "a365 cleanup instance -y"
  echo ""

  print_step 4 6 "Re-create blueprint"
  print_command "a365 setup blueprint --m365"
  print_auth "az login + device-code prompt for permissions"
  print_prereq "Tunnel running on :3978 so the CLI can probe the endpoint"
  print_explain "Use whatever flags you actually want this time (--aiteammate etc)."
  run_or_skip "a365 setup blueprint --m365"
  echo ""

  print_step 5 6 "Re-grant permissions"
  print_command "a365 setup permissions mcp && a365 setup permissions bot"
  print_auth "az login + admin consent if non-GA"
  run_or_skip "a365 setup permissions mcp && a365 setup permissions bot"
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

# ── Scenario E — Side-by-side parallel (DEMO DEFAULT) ────────────────────────

scenario_e() {
  local parallel_name
  parallel_name=$(get_demo_parallel_name)

  print_banner "Scenario E — Side-by-side Parallel Registration (non-destructive)"
  print_explain "Registers a second blueprint with -n '$parallel_name' bypassing"
  print_explain "a365.config.json. Both blueprints coexist in your tenant —"
  print_explain "the live one keeps serving Teams, the test one shows up as a new"
  print_explain "row in M365 Admin Center → Agents."
  echo ""

  print_step 1 3 "Snapshot current state"
  print_command "jq '{liveBlueprint: .agentBlueprintId}' a365.generated.config.json"
  print_prereq "a365.generated.config.json must exist"
  if [[ -f a365.generated.config.json ]]; then
    run_or_skip "jq '{liveBlueprint: .agentBlueprintId}' a365.generated.config.json"
  else
    print_info "a365.generated.config.json not found — that's fine for a fresh registration."
  fi
  echo ""

  print_step 2 3 "Register second blueprint"
  print_command "a365 setup blueprint -n \"$parallel_name\" --m365"
  print_auth "az login + 1 device-code prompt for permissions"
  print_prereq "Tunnel running on :3978 so the CLI can probe the endpoint"
  print_explain "-n bypasses the project config, so the live blueprint is not touched."
  print_explain "The CLI will print a new GUID — note it."
  run_or_skip "a365 setup blueprint -n \"$parallel_name\" --m365"
  echo ""

  print_step 3 3 "Confirm both blueprints are visible"
  print_command "a365 query-entra | jq '.blueprints[] | {name, id}'"
  print_auth "az login"
  run_or_skip "a365 query-entra | jq '.blueprints[] | {name, id}' 2>/dev/null || a365 query-entra"

  echo ""
  print_info "Both blueprints should now be visible in M365 Admin Center → Agents."
  echo ""
  print_info "To clean up the test blueprint later, run:"
  print_command "a365 cleanup blueprint -n \"$parallel_name\" -y"

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
