# Deployment Scripts

> Bootstraps an Agent 365 Draft Dodger tenant from zero. Four scripts, two configs they share.

## What's here

This folder is the source-of-truth for the **per-tenant** setup of an A365 agent — Entra app registration, tenant-config bootstrapping, optional Azure Container Apps deployment, and a macOS-only token workaround.

You have two deployment paths to choose from:

- **DevTunnel path** (default, recommended for laptop demos). The Python agent runs on `localhost:3978` and is reached from M365 via a persistent dev tunnel. `deploy.ps1` is skipped; `deployment.json` is hand-edited from the example template.
- **Azure Container Apps path** (production / customer trials). `deploy.ps1` packages the agent as a container, pushes it to ACR, and stands up an Azure Container App that becomes the messaging endpoint.

Either way, `create_app_registration.ps1` and `initialize_a365_config.ps1` run identically.

## Prerequisites

| Requirement | Why | Install / check |
|---|---|---|
| `az` CLI signed into the target tenant | Every script uses `az` for Entra + ARM operations | `az login --tenant <tenantId>` |
| `pwsh` 7+ | Three of the four scripts are PowerShell | `brew install powershell/tap/powershell` (macOS) |
| `python` 3.12 + `msal` | For `get_mos_token.py` (macOS only) | `uv add msal` or `pip install msal` |
| `a365` CLI ≥ 1.1.174 | Consumes the configs these scripts produce | `dotnet tool install -g Microsoft.Agents.A365.DevTools.Cli` (LESSONS [§4](../LESSONS_LEARNED.md), [§5](../LESSONS_LEARNED.md)) |
| Tenant role: **Application Administrator** (or higher) | `create_app_registration.ps1` runs admin consent on the delegated Graph scopes the CLI needs. Per Microsoft Learn, Application Administrator is the recommended minimum; Cloud Application Administrator, AI Administrator, or Global Administrator also work. | Verify with `az ad signed-in-user show --query userPrincipalName` then look up the user's role assignments. See [Minimum roles per Microsoft Learn](#minimum-roles-per-microsoft-learn) below for sources. |
| Azure subscription role: **Contributor** | Only required for `deploy.ps1` (ACA path) | Verify with `az account show` |
| Tenant role: **Privileged Role Administrator** | Only if you'll register an S2S or "Both" auth-mode class. PRA is required for Graph application-permission consent — Application Admin cannot grant it. | See [Grant admin consent § Prerequisites](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/grant-admin-consent#prerequisites). |
| Tenant role: **Agent ID Developer** | Required by `a365` CLI commands (`setup all`, `setup blueprint`, `cleanup blueprint`) to create / manage blueprints. | See [Setup agent blueprint § Prerequisites](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/registration#prerequisites). |

## Files in this folder

| File | Type | Purpose |
|---|---|---|
| `create_app_registration.ps1` | PowerShell | Creates the "A365 Draft Dodger Client" Entra app, grants 6 Graph delegated permissions, admin-consents, generates a client secret, writes `../demo-tenant.config.json` |
| `initialize_a365_config.ps1` | PowerShell | Joins `demo-tenant.config.json` + `deployment.json` into `a365.config.json` (consumed by the `a365` CLI) |
| `deploy.ps1` | PowerShell | Builds + pushes the agent container, deploys to Azure Container Apps, writes `../deployment.json`. **Skip if using DevTunnel.** |
| `get_mos_token.py` | Python | macOS-only workaround: gets a MOS token via device-code flow and saves to `/tmp/mos_token.txt`. Use when `a365 publish` fails on Mac because WAM isn't available. |
| `demo-tenant.config.json.example` | Template | Copy to `../demo-tenant.config.json` (or let `create_app_registration.ps1` create it). |
| `deployment.json.example` | Template | Copy to `../deployment.json` and edit `endpoint` to your dev-tunnel URL (DevTunnel path only). |
| `appPackage/` | Directory | Reference Teams app package artifacts (uploaded manually after `a365 publish`). |
| `manifest/` | Directory | Reference manifest used by the appPackage examples. The live manifest lives at `../manifest/`. |

## Dependency graph

```
                          ┌─────────────────────┐
                          │ az login (you)      │
                          └──────────┬──────────┘
                                     │
                                     ▼
       ┌─────────────────────────────────────────────────────────┐
       │  create_app_registration.ps1                            │
       │  └─ writes: ../demo-tenant.config.json (tenant id,      │
       │             subscription, customClientAppId)            │
       │  └─ prints: clientSecret  (add to .env manually)        │
       └─────────────────────────────┬───────────────────────────┘
                                     │
              ┌──────────────────────┼──────────────────────┐
              │                      │                      │
              ▼                      ▼                      │
   ┌──────────────────┐   ┌──────────────────┐              │
   │ deploy.ps1 (ACA  │   │ Edit             │              │
   │ path) writes:    │   │ ../deployment.   │              │
   │ ../deployment.   │   │ json by hand     │              │
   │ json with the    │   │ from example     │              │
   │ Container App    │   │ template         │              │
   │ FQDN as endpoint │   │ (DevTunnel path) │              │
   └────────┬─────────┘   └────────┬─────────┘              │
            └────────────┬─────────┘                        │
                         ▼                                  │
       ┌──────────────────────────────────────┐             │
       │  initialize_a365_config.ps1          │             │
       │  └─ reads:  ../demo-tenant.config.   │◄────────────┘
       │            json, ../deployment.json  │
       │  └─ writes: ../a365.config.json      │
       └──────────────────┬───────────────────┘
                          │
                          ▼
                ┌───────────────────────┐
                │ a365 setup all --m365 │  ← uses a365.config.json
                └───────────────────────┘
```

`get_mos_token.py` sits to the side — invoke only if `a365 publish` fails on macOS with a token error.

## The four scripts — reference

### `create_app_registration.ps1`

**Synopsis** (from the script's own header): creates or reuses an Entra app registration named `A365 Draft Dodger Client`, adds the API permissions the Agent 365 CLI needs (6 Graph delegated scopes plus the Agent 365 service-connection scope), grants admin consent, generates a client secret, and writes the resulting values to `../demo-tenant.config.json`.

**Invocation:**
```bash
pwsh -File "deployment script/create_app_registration.ps1"
```

**Parameters:**

| Parameter | Default | Use |
|---|---|---|
| `-AppDisplayName` | `"A365 Draft Dodger Client"` | Display name for the app registration. |
| `-SecretLifetimeYears` | `1` | Client secret lifetime in years. |
| `-Force` | (switch) | Rotate the secret. A new credential is appended; old ones remain valid until they expire. Required to re-run after the first successful run. |

**Graph delegated scopes added** (verbatim from `$requiredGraphScopes`):
- `User.Read`
- `Application.ReadWrite.All`
- `AgentIdentityBlueprint.ReadWrite.All`
- `AgentIdentityBlueprint.UpdateAuthProperties.All`
- `DelegatedPermissionGrant.ReadWrite.All`
- `Directory.Read.All`

Plus the Agent 365 service-connection scope on resource `5a807f24-c9de-44ee-a3a7-329e88a00ffc`. See [LESSONS_LEARNED.md §6](../LESSONS_LEARNED.md) for why these specific six are required.

**Reads:** the current `az` CLI session, `../demo-tenant.config.json` (if it already exists).

**Writes:** `../demo-tenant.config.json` (stamps `tenantId`, `tenantName`, `adminUserPrincipalName`, `subscriptionId`, `subscriptionName`, `customClientAppId`).

**What to expect when it works:**
- Banner `===== APP REGISTRATION VALUES =====` printing the `appId`, `clientSecret`, and `tenantId`. **The secret is shown only once — copy it now.**
- Two follow-up next-step hints: add `CLIENT_SECRET=…` and `CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET=…` to `.env`.

**Common failures:**

| Symptom | Cause | Fix |
|---|---|---|
| `ERROR: az CLI not signed in.` | `az login` not run | `az login --tenant <tenantId>` then re-run. |
| `WARNING: Admin consent failed (may need tenant admin role).` | Signed-in user lacks consent rights | **Application Administrator** is the documented minimum for delegated-scope consent (also Cloud App Admin, AI Admin, GA). Sign in as one of those, or have an appropriate admin run `az ad app permission admin-consent --id <appId>` manually. See [Minimum roles per Microsoft Learn](#minimum-roles-per-microsoft-learn) below. |
| Script reuses existing app without rotating secret | Default behaviour | Pass `-Force` to rotate. |
| App display name fails the demo script's lookup | The `demo-reregister.sh` script expects `"Agent 365 CLI"`, not `"A365 Draft Dodger Client"` | Rename it: `az ad app update --id <appId> --display-name "Agent 365 CLI"`. See [LESSONS_LEARNED.md §25](../LESSONS_LEARNED.md). |

### `initialize_a365_config.ps1`

**Synopsis:** joins `../demo-tenant.config.json` (tenant identity) and `../deployment.json` (messaging endpoint) into `../a365.config.json`, which is the file the `a365` CLI reads at startup.

**Invocation:**
```bash
pwsh -File "deployment script/initialize_a365_config.ps1" -AgentName "draftdodger" -AgentDisplayName "Draft Dodger" -Force
```

**Parameters:**

| Parameter | Default | Use |
|---|---|---|
| `-AgentName` | derived from the agent folder name (lowercase, alphanum only) | Used as the base name for `a365` CLI commands. |
| `-AgentDisplayName` | derived from `-AgentName` | Friendly name shown in Teams / Copilot. |
| `-Location` | `westeurope` | A365 CLI region (not the same as the Container Apps region). |
| `-Force` | (switch) | Overwrite an existing `a365.config.json`. |

**Reads:** `../demo-tenant.config.json` (required), `../deployment.json` (optional — if missing, writes a placeholder endpoint).

**Writes:** `../a365.config.json` with: `tenantId`, `subscriptionId`, `resourceGroup`, `location`, `messagingEndpoint`, `clientAppId`, `agentIdentityDisplayName`, `agentBlueprintDisplayName`, `agentUserPrincipalName`, `agentUserDisplayName`, `managerEmail`, `agentUserUsageLocation`, `deploymentProjectPath`, `agentDescription`, plus `needDeployment: false` (signals to the A365 CLI not to spin up its own infrastructure).

**Common failures:**

| Symptom | Cause | Fix |
|---|---|---|
| `ERROR: a365.config.json already exists. Use -Force to overwrite.` | Re-running without `-Force` | Add `-Force`. |
| `ERROR: demo-tenant.config.json not found.` | `create_app_registration.ps1` hasn't run yet | Run it first. |
| `WARNING: No deployment.json found.` and placeholder endpoint | DevTunnel path needs `../deployment.json` hand-created | Copy `deployment.json.example` to `../deployment.json` and edit `endpoint` to your dev-tunnel URL. |

### `deploy.ps1`

**Synopsis:** deploys the Python agent to Azure Container Apps. Creates a resource group, an Azure Container Registry, a Container Apps Environment, and the Container App itself. Reads env vars from `../.env` and stamps them onto the Container App. Writes `../deployment.json` with the resulting FQDN endpoint.

**Skip this if you're using DevTunnel.** It's only needed when you want a public-internet-reachable agent (production, long-running customer trials).

**Invocation:**
```bash
pwsh -File "deployment script/deploy.ps1" -AgentName "draftdodger" -Location "swedencentral"
```

**Parameters:**

| Parameter | Default | Use |
|---|---|---|
| `-AgentName` | *(required)* | Lowercase, no spaces. Used for resource naming (`rg-agent365-<name>-<location>`, `cae-<name>`, `ca-<name>`, `acr<name><random>`). |
| `-Location` | `swedencentral` | Azure region. `westeurope` often hits capacity issues for new Container Apps Environments. |
| `-AgentFolder` | parent of `deployment script/` | Path to the agent project folder (contains `Dockerfile`, `.env`). |
| `-ConfigPath` | `<AgentFolder>/demo-tenant.config.json` | Where to read tenant identity from. |

**Steps it runs** (8 total):
1. Loads `demo-tenant.config.json` for `tenantId` + `subscriptionId`.
2. Verifies / acquires Azure CLI auth on the correct tenant + subscription.
3. (2.5) Registers Azure resource providers (`Microsoft.App`, `Microsoft.OperationalInsights`, `Microsoft.ContainerRegistry`) if not already.
4. Creates / reuses the Resource Group.
5. Creates / reuses the Azure Container Registry (admin-enabled, Basic SKU).
6. `az acr build` to build the Docker image from `../Dockerfile` and push it (platform: linux/amd64).
7. Creates / reuses the Container Apps Environment.
8. Creates or updates the Container App with env vars from `../.env`, `target-port 3978`, external ingress, 0.5 CPU / 1Gi memory, 1–3 replicas.
9. Health-checks `https://<fqdn>/api/health` up to 6 × 10s.
10. Writes `../deployment.json` with `{resourceGroup, containerRegistry, containerApp, endpoint, fqdn, healthUrl, healthCheckPassed, location, deployedAt}`.

**Reads:** `../demo-tenant.config.json`, `../.env` (line-by-line for env vars; lines matching `^[^#][^=]+=.*$`), `../Dockerfile`.

**Writes:** `../deployment.json`, all the Azure resources listed above.

**Env-var filtering on stamp:** the script strips/overrides specific keys before stamping the Container App:
- Removes any `PORT=…` from `.env` and force-sets `PORT=3978`
- Removes `BEARER_TOKEN=…`, `ALT_BLUEPRINT*`, `TOOLS_MODE=…`, `MOCK_MCP_SERVER_URL=…`, `AUTH_HANDLER_NAME=…`
- Force-sets `AUTH_HANDLER_NAME=AGENTIC`

If your local `.env` has any of those keys, the deployed container uses the forced values, not your local ones.

**Common failures:**

| Symptom | Cause | Fix |
|---|---|---|
| `az login` opens but wrong tenant | Tenant mismatch | The script does `az login --tenant $tenantId` only if it doesn't match — pre-set with `az account set --subscription <id>`. |
| `Failed to create Container Apps Environment` | Region capacity / transient ARM | Script auto-retries once after 10s. If still failing, change `-Location` to a different region. |
| Health check failures on first deploy | Container still starting | The 6 × 10s retry handles most cases. If still failing after 60s, run `az containerapp logs show --name ca-<name> --resource-group <rg> --follow` to see the agent's stdout. See [LESSONS_LEARNED.md §1](../LESSONS_LEARNED.md), [§4](../LESSONS_LEARNED.md). |
| Image push fails with `not logged in` | ACR token expired | The script calls `az acr login` before `az acr build`; if that token expired, run `az acr login --name <acrName>` manually and re-run. |

### `get_mos_token.py`

**Synopsis:** macOS-only workaround when `a365 publish` fails with `WAM not available` or similar token-acquisition errors. Runs an MSAL device-code flow against the first-party MOS app and saves the access token to `/tmp/mos_token.txt`.

**Invocation:**
```bash
python "deployment script/get_mos_token.py"                          # reads TENANT_ID from .env
python "deployment script/get_mos_token.py" --tenant-id <TENANT_ID>  # explicit tenant
```

**Parameters:**

| Parameter | Default | Use |
|---|---|---|
| `--tenant-id` | `$TENANT_ID` from environment (or `.env` via python-dotenv) | Azure AD tenant. |

**What happens:** prints a device-code URL and a code. Open the URL in a browser, paste the code, sign in. Token is written to `/tmp/mos_token.txt`. The `a365` CLI picks it up automatically on its next invocation.

**Hardcoded values** (from the script):
- Client id: `caef0b02-8d39-46ab-b28c-f517033d8a21` (TPS first-party app — the same client the CLI's internal `MosTokenService` uses).
- Scope: `e8be65d6-d430-4289-a665-51bf2a194bda/.default`.

**Common failures:** if `msal` isn't installed → `uv add msal`. If `TENANT_ID` isn't set → either pass `--tenant-id` or add it to `.env`.

## Runbook A — DevTunnel path (recommended for laptop demos)

This is what you do the very first time on a tenant.

```bash
# 0. Prerequisites
az login --tenant <yourTenantId>
devtunnel login            # one-time
devtunnel create a365-draft-dodger
devtunnel port create a365-draft-dodger -p 3978 --protocol https
devtunnel host a365-draft-dodger    # leave running in a separate terminal

# 1. Create the Entra app registration
pwsh -File "deployment script/create_app_registration.ps1"
#   → prints clientSecret; copy it into ../.env as:
#       CLIENT_SECRET=<value>
#       CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET=<value>
#   → renames the app to "Agent 365 CLI" (one-off):
az ad app update --id <appIdJustPrinted> --display-name "Agent 365 CLI"

# 2. Stand in for deploy.ps1 with the dev-tunnel URL
cp "deployment script/deployment.json.example" deployment.json
#   → edit deployment.json and replace <your-tunnel-name>/<region> in the endpoint URL

# 3. Synthesize a365.config.json
pwsh -File "deployment script/initialize_a365_config.ps1" \
    -AgentName "draftdodger" \
    -AgentDisplayName "Draft Dodger" \
    -Force

# 4. Register the blueprint + identity + permissions with A365
a365 setup all -n "Draft Dodger" --m365

# 5. Start the local agent
uv run python start_with_generic_host.py
#   → listens on http://localhost:3978; dev tunnel forwards M365 traffic in
```

After step 5, `a365 publish` will package the manifest for upload at `https://admin.microsoft.com → Agents → Upload custom agent`.

For parallel test registrations on the same tenant once the live agent exists, switch to [scripts/demo-reregister.sh](../scripts/demo-reregister.sh) — see [docs/demo-reregister.md](../docs/demo-reregister.md).

## Runbook B — Azure Container Apps path (production)

Same as Runbook A through step 1, then **instead of step 2's manual edit** run:

```bash
# 2'. Build + push image, deploy ACA, write deployment.json
pwsh -File "deployment script/deploy.ps1" \
    -AgentName "draftdodger" \
    -Location "swedencentral"
```

That populates `../deployment.json` with the Container App's real FQDN. Then resume at step 3 (`initialize_a365_config.ps1`).

You don't run `start_with_generic_host.py` in this path — the container is your agent host.

## macOS publish workaround

If `a365 publish` errors with a token / WAM message on macOS:

```bash
python "deployment script/get_mos_token.py"
a365 publish    # picks up /tmp/mos_token.txt automatically
```

## Cleanup

To tear down everything created above for a given agent:

```bash
# A365 blueprint + identity (always)
a365 cleanup blueprint -y
a365 cleanup instance -y    # if you provisioned an agentic user

# Azure resources (ACA path only)
az group delete --name "rg-agent365-<agentName>-<location>" --yes --no-wait

# Local artefacts
rm -f a365.config.json a365.generated.config.json deployment.json
rm -rf script-runs/    # any sandboxed parallel registrations from demo-reregister.sh
# Keep .env if you want to retain CLIENT_ID/SECRET for the next bootstrap
```

The Entra app registration created by `create_app_registration.ps1` is *not* removed automatically — delete it from `https://entra.microsoft.com → App registrations → A365 Draft Dodger Client` (or whatever you renamed it to) if you no longer need it.

## Troubleshooting

| Symptom | Where it's covered |
|---|---|
| Foundry / Responses API endpoint quirks | [LESSONS_LEARNED.md §1](../LESSONS_LEARNED.md) |
| `a365` CLI 1.1.109 endpoint-registration bug | [LESSONS_LEARNED.md §4](../LESSONS_LEARNED.md) |
| Required Microsoft Graph permissions for the custom client app | [LESSONS_LEARNED.md §6](../LESSONS_LEARNED.md) |
| Client app display name must be "Agent 365 CLI" for `-n` mode | [LESSONS_LEARNED.md §25](../LESSONS_LEARNED.md) |
| `a365 setup all -n` overwrites `.env` / `a365.generated.config.json` | [LESSONS_LEARNED.md §26](../LESSONS_LEARNED.md) — the `demo-reregister.sh` script handles this via per-run sandboxes; for these deployment scripts the writes are intentional. |
| Browser auth fails on macOS during `a365 setup blueprint` | [LESSONS_LEARNED.md §27](../LESSONS_LEARNED.md) |

## Minimum roles per Microsoft Learn

For a security review that asks "why does this need Global Administrator?" — Global Admin is *sufficient* for everything here, but it's not the *least-privileged* role that works for any operation. The documented minimums per Microsoft Learn:

| # | Operation in this folder | Minimum role | Source |
|---|--------------------------|--------------|--------|
| 1 | `create_app_registration.ps1` — create the "A365 Draft Dodger Client" Entra app | Any user (default tenant policy) — **Application Administrator** if your tenant restricts self-service app registration | [Custom client app registration](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/custom-client-app-registration) |
| 2 | `create_app_registration.ps1` — grant admin consent on the delegated Graph scopes | **Application Administrator** (recommended) — also Cloud Application Administrator, AI Administrator, Global Administrator | [Custom client app registration § To add permissions and grant consent](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/custom-client-app-registration#to-add-permissions-and-grant-consent) — page lists App Admin as "Recommended", GA as "Has all permissions, but not required" |
| 3 | `initialize_a365_config.ps1` — joins config files, writes `a365.config.json` | None (local file IO only) | n/a |
| 4 | `deploy.ps1` — create RG, ACR, Container Apps Environment + App | **Contributor** on the target subscription (Azure RBAC, not Entra). Plus tenant role from row 2 because the deployment doesn't grant any new Entra permissions. | [Azure built-in roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles) |
| 5 | Subsequent `a365 setup all -n <name> --m365` (after this folder's scripts finish) | **Agent ID Developer** | [Setup agent blueprint § Prerequisites](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/registration#prerequisites) |
| 6 | Subsequent `a365 setup all --authmode s2s` / `both` (S2S / Both classes) | **Privileged Role Administrator** (PRA — the canonical least-privilege role for Graph application-permission consent) | [Grant admin consent § Prerequisites](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/grant-admin-consent#prerequisites) |
| 7 | Subsequent `a365 publish` (manifest packaging, local) | None | [Publish Agent](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/publish) |
| 8 | Upload custom agent manifest at admin.microsoft.com → Agents → Upload custom agent | **AI Administrator** (or GA) | [Agent management roles in M365 admin centre](https://learn.microsoft.com/en-us/microsoft-365/admin/manage/agent-roles-perms?view=o365-worldwide) |
| 9 | Activate uploaded agent for users | **AI Administrator** (or GA) | [Agent registry in M365 admin centre](https://learn.microsoft.com/en-us/microsoft-365/admin/manage/agent-registry?view=o365-worldwide) |
| 10 | Assign M365 Copilot licence to an **agent identity** (`agentUsers`) | **Agent ID Administrator** (different from Agent ID *Developer*) — owns `microsoft.directory/agentUsers/assignLicense` | [Entra built-in roles § Agent ID Administrator](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference#agent-id-administrator) |

### Practical role bundles

| Bundle | Who | Why |
|---|-----|-----|
| **Smallest viable bundle** for Blueprint-only OBO + DevTunnel demo | The same human, holding **Application Administrator** + **Agent ID Developer** | Covers rows 1, 2, 5, 7 above. The OBO-class user-consent at first use covers row 6's delegated grants without admin consent at all. |
| Add **Privileged Role Administrator** | For S2S or Both classes | Required only for Graph application-permission grants. Drop after registration; the role isn't needed at runtime. |
| Add **AI Administrator** | For admin-centre upload + activation | Rows 8, 9. Can be a separate person doing the upload after a developer hands off `manifest.zip`. |
| Add **Agent ID Administrator** | For AI Teammate full experience (Copilot licence on the agent identity) | Row 10. Often the same human who runs admin-centre activation, but technically a distinct role. |
| Add **Contributor** on the Azure subscription | Only for the ACA deployment path | Row 4. Not needed for DevTunnel demos. |

### Caveats to flag in a security review

- **A365's `registration` doc says Global Administrator** for "OAuth2 delegated permission grants on the blueprint app." The generic Entra `grant-admin-consent` doc says Application Administrator suffices for all delegated grants. The two contradict; the generic Entra rule is the authoritative one. If you hit a permission failure with Application Admin only, the A365 platform may have an additional check — flag as untested.
- **Graph application-permission grants are the one place GA-or-PRA is genuinely needed**, not Application Admin. Row 6.
- **`Agent ID Administrator` and `Agent ID Developer` are different roles.** Developer can create/manage blueprints they own. Administrator can additionally license agent identities. Don't conflate.

## See also

- [../SETUP.md](../SETUP.md) — narrative first-time tenant-prep walkthrough that wraps these scripts
- [../RE-REGISTRATION.md](../RE-REGISTRATION.md) — what to do *after* setup when something needs to change
- [../docs/demo-reregister.md](../docs/demo-reregister.md) — interactive teaching tool for parallel re-registration tests
- [../LESSONS_LEARNED.md](../LESSONS_LEARNED.md) — error → fix index
- [../docs/a365-concepts.html](../docs/a365-concepts.html) — interactive concept map (blueprint, agent identity, OBO vs S2S, etc.)
