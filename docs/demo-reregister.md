# Demo Re-registration Script

> Interactive CLI teaching tool for A365 agent re-registration. Step-through every scenario with explanations, prerequisites, and verification.

## What is this?

`scripts/demo-reregister.sh` is a menu-driven bash script that walks you through the five re-registration scenarios documented in [RE-REGISTRATION.md](../RE-REGISTRATION.md). It's a **teaching tool** — every step explains what the CLI command does, why you're running it, what changes in your Entra tenant, and what auth is required. Use it for live demos, training sessions, or to learn the A365 CLI without copy-pasting from markdown.

Scenario E (side-by-side parallel) is the demo default. Each parallel registration runs inside its own isolated `script-runs/<sanitized-name>/` sandbox so your live project files (`.env`, `a365.generated.config.json`, `manifest/`) are never touched.

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
| zip | ✔ for scenario E | Built-in on macOS/Linux |
| a365 CLI ≥ 1.1.174 | ✔ | `dotnet tool install -g Microsoft.Agents.A365.DevTools.Cli` |
| Azure CLI (`az`) | ✔ | `brew install azure-cli` |
| PowerShell (`pwsh`) | ✔ for scenario E | `brew install powershell/tap/powershell` |
| curl | ✔ | Built-in on macOS/Linux |

### Auth & roles

These are documented minimums per Microsoft Learn — not "Global Administrator everywhere", which is what the original script assumed. See [Minimum roles per Microsoft Learn](#minimum-roles-per-microsoft-learn) below for the full matrix and source links.

| Scenario | Minimum Entra role |
|----------|-------------------|
| A (endpoint swap) | **Agent ID Developer** |
| B (manifest re-publish) | **Agent ID Developer** for `a365 publish`; **AI Administrator** (or GA) for the manual manifest upload at admin.microsoft.com |
| C (permissions re-grant) | **Application Administrator** for delegated regrants; **Privileged Role Administrator** if you're re-granting Graph app-role permissions (S2S/Both classes) |
| D (full cleanup → re-setup) | **Agent ID Developer** for cleanup + setup; **Application Administrator** for the admin-consent step; **Privileged Role Administrator** if you're re-registering an S2S class |
| E (side-by-side parallel) | Class-dependent — see [Registration classes](#registration-classes). The most expensive class (S2S/Both) needs **Privileged Role Administrator**, not Global Administrator. |

You must be signed in: `az login --tenant <tenantId>`.

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
| `manifest/manifest.json` + `manifest.zip` + assets | Live agent's Teams manifest package | No (gitignored) |
| `script-runs/<sanitized-name>/` | Per-demo sandbox dir created by scenario E. Holds the CLI's `.env`, `a365.generated.config.json`, and `manifest/*` artefacts for *that* registration only. | No (gitignored) |

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
| `E` | Side-by-side parallel | Register a second blueprint alongside the live one inside `script-runs/<name>/` (**demo default**) |
| `s` | Show current state | Print live values from config files (blueprint ID, endpoint, etc.) |
| `q` | Quit | Exit cleanly |

## Scenario E — the primary demo flow

This is the scenario designed for live demos. The flow:

### 1. Name prompt

You're asked for a name for the parallel blueprint. Press Enter for the timestamped default (`Draft Dodger Demo YYYYMMDD-HHMM`) or type a custom name like `Draft Dodger Demo Test1`.

The script sanitises the name into a folder-safe form (spaces → hyphens, special chars stripped) and creates `script-runs/<sanitized-name>/` as the working dir for this registration.

### 2. OBO vs S2S explainer

A comparison table is shown explaining the two authentication modes — how they differ in auth flow, consent requirements, blast radius, and minimum Entra role.

### 3. Decision tree

Two guided questions ("Does your agent need its own identity?" → "Does it need to run autonomously?") lead to a recommended registration class.

### 4. Class picker

All 6 classes are listed with: **Use when**, **Creates**, **Trade-off**, **Command** (the actual setup + publish chain), and **Role** (minimum Entra role required). See [Registration classes](#registration-classes) below for the full grid.

### 5. Scenario-specific pre-flight

Prerequisites are verified (az login, CLI version, role, tunnel, agent, pwsh, client app name) with live ✔/✗ status. If any are red, you can `Continue anyway` or abort.

### 6. Sandbox setup

The script creates `script-runs/<sanitized-name>/manifest/` and seeds it with the four manifest assets (`manifest.json`, `agenticUserTemplateManifest.json`, `color.png`, `outline.png`) copied from your live `manifest/` folder. These are the templates `a365 publish` will update in place. Without this seed step `a365 publish` errors with `Manifest not found`.

The script prints:
```
ℹ  Registration artifacts will live in: script-runs/<sanitized-name>/
ℹ  Live .env, a365.generated.config.json, and manifest/ stay untouched.
```

### 7. Step 1/4 — Snapshot current state

`jq '{liveBlueprint: .agentBlueprintId}' a365.generated.config.json` — prints the live blueprint id so you can compare before/after. Read-only.

### 8. Step 2/4 — Graph pre-auth (PowerShell)

`pwsh -c "Connect-MgGraph -TenantId '<tid>' -ClientId '<Agent 365 CLI app id>' -Scopes 'Application.ReadWrite.All','Directory.Read.All' -NoWelcome"` establishes a cached Graph session. The A365 CLI picks this up so its own blueprint-creation step skips the macOS-broken browser auth. See [LESSONS_LEARNED.md §27](../LESSONS_LEARNED.md).

### 9. Step 3/4 — Register second blueprint

`(cd "script-runs/<sanitized-name>/" && a365 setup all -n "<name>" <class-flags>)` — runs the CLI in a subshell whose cwd is the sandbox dir. The CLI writes `.env`, `a365.generated.config.json`, and updates `manifest/*` inside that sandbox; your repo-root files never change.

For most classes this also creates the **agent identity SP** (`<name> Identity`, type `microsoft.graph.agentIdentity` / `servicePrincipalType: ServiceIdentity`) automatically — but only if `--aiteammate` is **not** passed to `setup all`. The fix that made identity creation work in this script was to drop `--aiteammate true` from `setup all` and move it to the follow-up `a365 publish` step (see [Registration classes](#registration-classes)).

After this step the script prints a heads-up:

> ℹ Heads-up: the CLI skipped messaging endpoint registration (`-n` mode bypasses `a365.config.json`).
> ℹ After the script finishes, attach the live dev-tunnel endpoint to this blueprint:
>
>     a365 setup blueprint -n "<name>" --m365 --update-endpoint "<live-endpoint>"

The endpoint URL is read from your live `a365.config.json`. Same dev-tunnel as the live agent; the Bot Framework routes by `appId`, so multiple demo bots can share the tunnel.

### 10. Step 3b/4 — Flag manifest as AI Teammate / Non-DW (classes 4, 5, 6 only)

`(cd "script-runs/<sanitized-name>/" && a365 publish <class-publish-flags> -n "<name>")` — generates the manifest package flavoured for the chosen class. The CLI writes `manifest/manifest.json` and packages `manifest/manifest.zip` inside the sandbox.

**Auto-normalisation:** `a365 publish` sets `name.short` to `"<base name> Blueprint"`, which often exceeds the 30-character schema limit (`Draft Dodger Demo Test5 Blueprint` is 33 chars). The script detects this, strips the trailing ` Blueprint` suffix, truncates to 30 if still too long, and re-zips the manifest. Look for:

```
ℹ  Normalised manifest name.short: 'Draft Dodger Demo Test5 Blueprint' (33 chars) → 'Draft Dodger Demo Test5' (23 chars)
ℹ  Re-zipped manifest.zip with corrected name.short.
```

Without this, the M365 Admin Centre upload fails with `Manifest is not valid: String '<name>' exceeds maximum length of 30. Path 'name.short'`.

### 11. Step 4/4 — Verify

The script queries the Graph API for the actual objects in your tenant and prints:

```
✔ Entra App Registration       (app id, displayName)
✔ Service Principal            (sp id)
✔ Agent Identity SP            (<name> Identity · object id) ← real Graph beta lookup
ℹ Agentic user (UPN, mailbox, Teams presence) — minted after manifest upload + admin centre activation + M365 license assignment
ℹ MCP Platform Endpoint — not auto-registered (suggested follow-up below)
```

If `Agent Identity SP` shows ✗ instead of ✔, the CLI silently skipped identity creation — usually because `--aiteammate` was passed to `setup all` (it should be passed to `a365 publish` instead). The script's current class definitions get this right; this would only fire if the script's class table is hand-edited incorrectly.

The verification block ends with two copy-pasteable follow-ups: the endpoint-attach command and the cleanup one-liner.

## Registration classes

The A365 registration model is a 2×3 grid: **own identity** (AI Teammate vs Blueprint-only) × **auth mode** (OBO / S2S / Both). See [docs/a365-concepts.html](a365-concepts.html) for the interactive version with animated token flows.

Each class has a **Setup step** (`a365 setup all`) and, for some classes, a **Publish step** (`a365 publish`) that flavours the manifest:

| Cell | Class | Setup step | Publish step | Status | Min. role per Microsoft Learn |
|------|-------|------------|--------------|--------|------------------------------|
| Top-left | AI Teammate (M365) | `a365 setup all -n "<n>" --m365` | `a365 publish --aiteammate true -n "<n>"` | Frontier | **Agent ID Developer** + **Application Administrator** (consent). Full agentic user later: **Agent ID Administrator** + M365 Copilot licence. |
| Top-mid | AI Teammate + S2S | `a365 setup all -n "<n>" --m365 --authmode s2s` | `a365 publish --aiteammate true -n "<n>"` | Frontier | **Agent ID Developer** + **Privileged Role Administrator** (S2S app-role consent) + M365 licence. |
| Top-right | AI Teammate + Both | `a365 setup all -n "<n>" --m365 --authmode both` | `a365 publish --aiteammate true -n "<n>"` | Frontier | **Agent ID Developer** + **Privileged Role Administrator** + M365 licence. |
| Bottom-left | Blueprint-only OBO (M365) | `a365 setup all -n "<n>" --m365` | — | **GA** | **Agent ID Developer** (no admin consent needed for OBO scopes the user can self-consent). |
| Bottom-mid | Blueprint-only S2S (M365) | `a365 setup all -n "<n>" --m365 --authmode s2s` | — | Infra GA | **Agent ID Developer** + **Privileged Role Administrator** (Graph app-role consent). |
| Bottom-right | Blueprint-only Both (M365) | `a365 setup all -n "<n>" --m365 --authmode both` | — | Infra GA | **Agent ID Developer** + **Privileged Role Administrator**. |
| (off-grid) | Blueprint-based Non-DW | `a365 setup all -n "<n>" --m365` | `a365 publish --aiteammate false --use-blueprint -n "<n>"` | Microsoft-internal | **Agent ID Developer**. |

> **Why these are lower than the original "Global Administrator" claim:** see [Minimum roles per Microsoft Learn](#minimum-roles-per-microsoft-learn) below. Microsoft's published role definitions give Application Administrator full coverage of delegated-permission admin consent; Privileged Role Administrator is the canonical "least privilege" for Graph application-permission consent. Global Administrator is a superset of both — sufficient but not necessary.

> **GA** = generally available, production-ready. **Infra GA** = infrastructure is GA, full experience maturing. **Frontier** = private preview — requires enrolment in the Frontier Preview Program at https://adoption.microsoft.com/copilot/frontier-program/.

### Why is `--aiteammate` on `publish`, not `setup all`?

The a365 CLI's `--aiteammate` flag on `setup all` controls whether the **agent identity SP** is created automatically:

- **Omitted** (or `--aiteammate false`) → setup all auto-creates `<name> Identity` SP. This is what every class above does at the setup step.
- **Passed** (`--aiteammate true`) → setup does blueprint + permissions **only**. The identity SP is *not* created. This is the wrong shape for any of the classes the script supports.

So `setup all` runs without `--aiteammate`, every class gets its identity SP, and the AI Teammate classes then run `a365 publish --aiteammate true` to flavour the manifest as AI Teammate (vs Blueprint-only). The full agentic user (UPN, mailbox, Teams presence) is provisioned later via manifest upload → M365 Admin Centre activation → M365 license assignment, not by the CLI directly.

## Minimum roles per Microsoft Learn

This is the defensible answer for a security review that asks "why does this need Global Administrator?". For every operation this script performs, the **documented** minimum role per Microsoft Learn is listed below — Global Administrator is sufficient for all of them (it's a superset), but it is not the *least-privileged* role that works.

| # | Operation | Minimum role | Source |
|---|-----------|--------------|--------|
| 1 | Create the "Agent 365 CLI" custom client app registration | Any user (default tenant policy permits self-service app registration; if your tenant has tightened this, **Application Administrator** can do it) | [Custom client app registration](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/custom-client-app-registration) |
| 2 | Grant admin consent for the delegated Graph scopes on the CLI app | **Application Administrator** (recommended) — also AI Administrator, Cloud Application Administrator, Global Administrator | [Custom client app registration § To add permissions and grant consent](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/custom-client-app-registration#to-add-permissions-and-grant-consent) — page explicitly lists App Admin as "Recommended" and GA as "Has all permissions, but not required" |
| 3 | Tenant-wide admin consent for any delegated Graph permission | **Cloud Application Administrator**, **Application Administrator**, or **AI Administrator** | [Grant tenant-wide admin consent § Prerequisites](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/grant-admin-consent#prerequisites) |
| 4 | `a365 setup all -n <name> --m365` — create blueprint + agent identity SP (`microsoft.graph.agentIdentity` / `ServiceIdentity`) | **Agent ID Developer** | [Setup agent blueprint § Prerequisites](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/registration#prerequisites) |
| 5 | OAuth2 delegated permission grants on the blueprint app's resources (Microsoft Graph, Agent 365 Tools, Messaging Bot API, Observability API, Power Platform API) | A365 docs say GA; generic Entra rule says **Application Administrator** suffices for delegated grants — *ambiguous in practice* | A365 doc: [Setup by using Agent ID Developer](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/registration#setup-by-using-agent-id-developer); generic rule: [Grant admin consent § Prerequisites](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/grant-admin-consent#prerequisites) |
| 6 | `a365 setup all --m365` (register messaging endpoint via MCP Platform) | Same as row 4 | (same as row 4) |
| 7 | `a365 setup all --authmode s2s` / `--authmode both` (Graph application-permission grants) | **Privileged Role Administrator** (not GA — PRA is the documented least-privilege role for Graph app-role consent) | [Grant admin consent § Prerequisites](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/grant-admin-consent#prerequisites) |
| 8 | `a365 publish` (manifest packaging — local CLI, no Graph call) | None | [Publish Agent](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/publish) |
| 9 | Upload custom agent manifest at admin.microsoft.com → Agents → Upload custom agent | **AI Administrator** (or GA) | [Agent management roles in M365 admin centre](https://learn.microsoft.com/en-us/microsoft-365/admin/manage/agent-roles-perms?view=o365-worldwide) |
| 10 | Activate / deploy uploaded agent for users | **AI Administrator** (or GA) | [Agent registry in M365 admin centre](https://learn.microsoft.com/en-us/microsoft-365/admin/manage/agent-registry?view=o365-worldwide) |
| 11 | Assign Microsoft 365 Copilot licence to a regular user | **License Administrator** (`microsoft.directory/users/assignLicense`) | [Entra built-in roles](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference) |
| 12 | Assign M365 Copilot licence to an **agent identity** (`agentUsers`) | **Agent ID Administrator** (`microsoft.directory/agentUsers/assignLicense`) — different role from Agent ID Developer | [Entra built-in roles § Agent ID Administrator](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference#agent-id-administrator) |

### Caveats to flag in a security review

- **Row 5 (OAuth2 delegated grants for the blueprint app):** the A365 docs page says GA, but the generic Entra "grant admin consent" page lists Application Administrator as sufficient for *all* delegated grants. The discrepancy is unresolved in Microsoft's own docs. If you need to defend the minimum-role claim, cite the generic Entra page — it's the authoritative rule. Tested-empirically would settle this, but we haven't done that yet.
- **Row 7 (S2S / Both):** PRA, not GA. App Admin and Cloud App Admin *cannot* grant Microsoft Graph application-permission consent — that's the Graph carve-out in the consent doc. This is the one operation in the whole project that genuinely escalates above App Admin.
- **Agent ID Developer vs Agent ID Administrator:** different roles. Developer can create/manage blueprints they own. Administrator can also assign licences to `agentUsers`. The CLI commands themselves all use Developer; only the licence-assignment for the agentic user identity needs Administrator.

## Installing a demo agent in Teams / M365 Copilot

After scenario E finishes:

1. Upload the sandbox's zipped manifest at https://admin.microsoft.com → Agents → All agents → Upload custom agent:
   ```bash
   open "script-runs/<sanitized-name>/manifest/"
   ```
2. Activate the agent for your test users in the same admin-centre page.
3. (M365 Copilot surface only) Assign a Microsoft 365 Copilot licence to the agent identity.
4. Attach the messaging endpoint so the agent actually responds to Teams turns:
   ```bash
   a365 setup blueprint -n "<name>" --m365 --update-endpoint "https://<your-tunnel-name>-3978.<region>.devtunnels.ms/api/messages"
   ```

## Cleanup

After a demo, remove the test blueprint **and** the sandbox dir:

```bash
a365 cleanup blueprint -n "Draft Dodger Demo Test1" -y && rm -rf "script-runs/Draft-Dodger-Demo-Test1"
```

Replace the name and folder with whatever you used during the demo. Your live blueprint is never touched.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `App "Agent 365 CLI" was not found in tenant` | Rename your client app: `az ad app update --id <id> --display-name "Agent 365 CLI"`. See [LESSONS_LEARNED.md §25](../LESSONS_LEARNED.md). |
| `Browser authentication is not supported on this platform` | The script's step 2 (PowerShell Graph pre-auth) handles this. If pwsh is missing, install with `brew install powershell/tap/powershell`. See [LESSONS_LEARNED.md §27](../LESSONS_LEARNED.md). |
| `Manifest is not valid: String '<name>' exceeds maximum length of 30. Path 'name.short'` | The script auto-normalises `name.short` after `a365 publish` and re-zips. If you bypassed the script, fix manually: `jq '.name.short = "<≤30 chars>"' manifest/manifest.json > t && mv t manifest/manifest.json` then `(cd manifest && zip -q manifest.zip manifest.json color.png outline.png agenticUserTemplateManifest.json)`. |
| `ERROR: Manifest not found: …/manifest/manifest.json` (in scenario E publish step) | Sandbox seed didn't include `manifest.json`. The script seeds it from your live `manifest/`; if your live `manifest/` is empty, run `a365 publish` once at repo root first to generate the live template, then re-run the demo. |
| New demo blueprint doesn't respond to Teams messages | MCP endpoint isn't auto-registered in `-n` mode. Attach manually with the command the script prints at the end of step 4 (`a365 setup blueprint -n "<name>" --m365 --update-endpoint "<url>"`). |
| Agent identity (`<name> Identity`) shows ✗ in step 4 verification | The CLI was called with `--aiteammate` on `setup all`, which suppresses identity creation. The script's current class table avoids this; check `scripts/demo-reregister.sh` lines 971–994 for the `SELECTED_CLASS_FLAGS` of your chosen class. |
| Live agent broke after demo | Shouldn't happen — every CLI call runs inside `script-runs/<name>/` via subshell `cd`. If it did, verify by re-running menu option `s` (show state) — `agentBlueprintId` should still equal your original live id. |
| `AADSTS65001 — user or administrator has not consented` | Approve the admin-consent prompt the CLI opens in the browser during step 3. **Application Administrator** is sufficient for the delegated grants AI Teammate classes need; **Privileged Role Administrator** is required only if you're consenting Graph application permissions (S2S/Both classes). Global Administrator works but is more than needed. |

## Related docs

| Doc | What |
|-----|------|
| [RE-REGISTRATION.md](../RE-REGISTRATION.md) | Reference for all 5 re-registration scenarios (the source the script is based on) |
| [SETUP.md](../SETUP.md) | Fresh-tenant runbook for first-time registration |
| [deployment script/README.md](../deployment%20script/README.md) | Runbook for the four PowerShell + Python scripts that bootstrap an A365 tenant from zero |
| [LESSONS_LEARNED.md](../LESSONS_LEARNED.md) | Every error we hit + the fix. §25–27 are directly relevant to this script |
| [docs/a365-concepts.html](a365-concepts.html) | Interactive conceptual model — 85 concepts, decision tree, OBO vs S2S comparison, animated token flows |
