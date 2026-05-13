# Demo Re-registration Script

> Interactive CLI teaching tool for A365 agent re-registration. Step-through every scenario with explanations, prerequisites, and verification.

## What is this?

`scripts/demo-reregister.sh` is a menu-driven bash script that walks you through the five re-registration scenarios documented in [RE-REGISTRATION.md](../RE-REGISTRATION.md). It's designed as a **teaching tool** — every step explains what the CLI command does, why you're running it, what changes in your Entra tenant, and what auth is required. You can use it for live demos, training sessions, or just to learn the A365 CLI without copy-pasting from markdown.

## Who is it for?

- **Developers** demoing A365 CLI capabilities to their team or stakeholders
- **IT admins** learning how agent registration works before doing it in production
- **Trainers** teaching A365 agent identity, auth modes, and the registration lifecycle

## Prerequisites

### Tools

| Tool | Required | Install |
|------|----------|---------|
| bash | ✔ | Built-in on macOS/Linux |
| jq | ✔ | `brew install jq` |
| a365 CLI ≥ 1.1.174 | ✔ | `dotnet tool install -g Microsoft.Agents.A365.DevTools.Cli` |
| Azure CLI (az) | ✔ | `brew install azure-cli` |
| PowerShell (pwsh) | ✔ for Scenario E | `brew install powershell/tap/powershell` |
| curl | ✔ | Built-in on macOS/Linux |

### Auth & roles

| Scenario | Minimum Entra role |
|----------|-------------------|
| A (endpoint swap) | Agent ID Developer |
| B (manifest re-publish) | Agent ID Developer |
| C (permissions re-grant) | Global Administrator |
| D (full cleanup → re-setup) | Global Administrator |
| E (side-by-side parallel) | Depends on class — Blueprint-only OBO needs Agent ID Developer; all others need Global Admin. See [Registration classes](#registration-classes) |

You must be logged in: `az login --tenant <tenantId>`

### Running services

The script checks these at startup (non-blocking warnings):

1. **Agent service** on `localhost:3978` — `uv run python start_with_generic_host.py`
2. **Dev tunnel** — `devtunnel host a365-draft-dodger`

### Config files

| File | Purpose | Tracked? |
|------|---------|----------|
| `.env` | Environment variables (secrets, connection settings) | No (gitignored) |
| `a365.config.json` | Project config (endpoint, client app ID, tenant) | No (gitignored) |
| `a365.generated.config.json` | Live registration state (blueprint ID, SP, consents) | No (gitignored) |

### Client app name

The A365 CLI looks up the client app by display name when using `-n` mode. Your Entra app registration must be named **"Agent 365 CLI"** — not a custom name. See [LESSONS_LEARNED.md §25](../LESSONS_LEARNED.md).

Fix if needed:
```bash
az ad app update --id <your-client-app-id> --display-name "Agent 365 CLI"
```

## Quick start

```bash
bash scripts/demo-reregister.sh
```

The script runs pre-flight checks (az login, CLI version, agent health, tunnel, pwsh, client app name), then shows the main menu. All checks are non-blocking — you can still explore the menu even if the tunnel isn't running.

## Menu options

| Key | Option | What it does |
|-----|--------|-------------|
| `0` | Concept primer | Explains the 6 A365 concepts: blueprint, SP, agentic user, endpoint, MCP link, manifest |
| `A` | Endpoint swap | Update the blueprint's messaging endpoint URL (non-destructive) |
| `B` | Manifest re-publish | Re-generate and re-upload the Teams manifest (non-destructive) |
| `C` | Permissions re-grant | Re-run admin consent for MCP + Bot permissions (non-destructive) |
| `D` | Full cleanup → re-setup | Delete everything and re-register from scratch (**destructive** — safety gate) |
| `E` | Side-by-side parallel | Register a second blueprint alongside the live one (**demo default**) |
| `s` | Show current state | Print live values from config files (blueprint ID, endpoint, etc.) |
| `q` | Quit | Exit cleanly |

## Scenario E — the primary demo flow

This is the scenario designed for live demos. The flow:

### 1. Name prompt

You're asked for a name for the parallel blueprint. Press Enter for the timestamped default (`Draft Dodger Demo YYYYMMDD-HHMM`) or type a custom name.

### 2. OBO vs S2S explainer

A comparison table is shown explaining the two authentication modes — how they differ in auth flow, consent requirements, blast radius, and minimum Entra role.

### 3. Decision tree

Two guided questions ("Does your agent need its own identity?" → "Does it need to run autonomously?") lead to a recommended registration class.

### 4. Class picker

All 6 classes are listed with:
- **Use when** — one-liner on the use case
- **Creates** — what Entra objects get created (app, SP, agentic user)
- **Trade-off** — what you're giving up or gaining
- **Command** — exact CLI command that will run
- **Role** — minimum Entra role required

### 5. Pre-flight checks

Scenario-specific prerequisites are verified (az login, CLI version, role, tunnel, agent, pwsh, client app name) with live ✔/✗ status.

### 6. Graph pre-auth

PowerShell `Connect-MgGraph` establishes a cached Graph session. The A365 CLI picks this up for blueprint creation.

### 7. Registration

`a365 setup all -n "<name>" --m365` runs with step-through confirmation. The script backs up `.env` and `a365.generated.config.json` before this step and restores them after — the CLI overwrites both.

### 8. Verification

After registration, the script queries the Graph API (`az ad app list`) and shows:
- ✔ What was created (app registration, service principal, agentic user if applicable, MCP endpoint)
- Portal links — clickable URLs for Entra and M365 Admin Center
- Live blueprint confirmed unchanged

## Registration classes

The A365 registration model is a 2×3 grid: **own identity** (AI Teammate vs Blueprint-only) × **auth mode** (OBO / S2S / Both). See [docs/a365-concepts.html](a365-concepts.html) for the interactive version with animated token flows.

| Cell | Class | CLI flags | Status | Auth mode | Creates in Entra | Min. role |
|------|-------|-----------|--------|-----------|-----------------|-----------|
| Top-left | AI Teammate (M365) | `--m365 --aiteammate true` | Frontier | OBO (delegated) | App + SP + agentic user (mailbox, Teams, org chart) | Global Admin + M365 license |
| Top-mid | AI Teammate + S2S | `--m365 --aiteammate true --authmode s2s` | Frontier | S2S (app perms) | App + SP + agentic user + app-permission grants | Global Admin + M365 license |
| Top-right | AI Teammate + Both | `--m365 --aiteammate true --authmode both` | Frontier | Both | App + SP + agentic user + both grant types | Global Admin + M365 license |
| Bottom-left | Blueprint-only OBO | `--m365` (default) | **GA** | OBO (delegated) | App + SP | Agent ID Developer |
| Bottom-mid | Blueprint-only S2S | `--m365 --authmode s2s` | Infra GA | S2S (app perms) | App + SP + app-permission grants (tenant-wide) | Global Admin |
| Bottom-right | Blueprint-only Both | `--m365 --authmode both` | Infra GA | Both | App + SP + both grant types | Global Admin |

> **GA** = generally available, production-ready. **Infra GA** = infrastructure is GA, full experience maturing. **Frontier** = private preview — requires enrolment.

The script's class picker offers these 6 cells plus a 7th option (Blueprint-based Non-DW) which is a Microsoft-internal variant outside the grid.

## Cleanup

After a demo, remove the test blueprint:

```bash
a365 cleanup blueprint -n "Draft Dodger Demo 20260512-2246" -y
```

Replace the name with whatever you used during the demo. Your live blueprint is never touched.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `App "Agent 365 CLI" was not found in tenant` | Rename your client app: `az ad app update --id <id> --display-name "Agent 365 CLI"` |
| `Browser authentication is not supported on this platform` | The script's Graph pre-auth step (PowerShell) handles this. If it fails, run `pwsh -c "Connect-MgGraph -TenantId '<tenantId>' -Scopes 'Application.ReadWrite.All'"` manually |
| Live agent broke after demo | Config restore failed. Check `.env` and `a365.generated.config.json` still point to your original blueprint ID |
| Agent not visible in M365 Admin Center | The CLI must use `setup all --m365` (not `setup blueprint --m365`) — the script handles this |
| `AADSTS65001 — user or administrator has not consented` | Approve the admin consent prompt the CLI opens in the browser during registration |

## Related docs

| Doc | What |
|-----|------|
| [RE-REGISTRATION.md](../RE-REGISTRATION.md) | Reference for all 5 re-registration scenarios (the source the script is based on) |
| [SETUP.md](../SETUP.md) | Fresh-tenant runbook for first-time registration |
| [LESSONS_LEARNED.md](../LESSONS_LEARNED.md) | Every error we hit + the fix. §25-27 are directly relevant to this script |
| [docs/a365-concepts.html](a365-concepts.html) | Interactive conceptual model — 85 concepts, decision tree, OBO vs S2S comparison, animated token flows |
