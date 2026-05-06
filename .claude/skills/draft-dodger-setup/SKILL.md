---
name: draft-dodger-setup
description: Use when the user has cloned this repository and wants to bootstrap Draft Dodger on their own Microsoft 365 tenant (or pick the project up after moving it to a new machine). Walks through prereq checks, app registration, dev tunnel creation, blueprint registration, manifest publish, admin upload, and Microsoft 365 Copilot activation. Handles the a365 CLI 1.1.174 endpoint-registration quirk (--m365 --update-endpoint), the OpenAI Responses API authentication callable, and the Bot Framework onboarding 502 storm. Invoke with /draft-dodger-setup.
---

# Draft Dodger Setup

Bootstrap Draft Dodger on a tenant from a fresh clone. This skill orchestrates the existing automation in `deployment script/` and walks the user through everything device-code prompts, manifest customization, and admin-center upload.

**You (Claude) drive the commands. The user provides tenant info when asked, completes interactive auth (device codes + MFA), and does the two manual web-UI steps at the end (admin.microsoft.com upload + activation).**

This skill is the orchestration layer. The deep references are:

- [`SETUP.md`](../../../SETUP.md) — long-form manual runbook for each phase
- [`LESSONS_LEARNED.md`](../../../LESSONS_LEARNED.md) — every error message → root cause → fix
- [`README.md`](../../../README.md) — architecture diagrams + auth model

If something errors mid-flow, read `LESSONS_LEARNED.md`'s quick-glance error map before debugging from scratch — most failures here are documented.

---

## Step 0 — Prereq check (REQUIRED)

Before anything else, verify the user has the right tools. Run these checks, report a green/red status table, and **stop the skill** if any required tool is missing.

```bash
python3 --version       # need 3.12.x
uv --version            # need ≥0.4
az --version            # any recent
az account show         # must succeed (signed in)
pwsh --version          # need 7.x
devtunnel --version     # any recent
dotnet --version        # need 8+ (10 fine)
a365 --version          # need ≥ 1.1.174 — older has the endpoint-reg bug
```

**Critical:** if `a365 --version` reports < 1.1.174, run:
```bash
dotnet tool update -g Microsoft.Agents.A365.DevTools.Cli
```
…before continuing. See `LESSONS_LEARNED.md` §4 for why. Do **not** proceed with an older CLI — it will fail at endpoint registration.

If any other tool is missing, install it (Mac: `brew install --cask devtunnel`, `brew install azure-cli`, `brew install --cask powershell`, `brew install --cask dotnet-sdk`, `brew install astral-sh/uv/uv`). Hand the user the install commands and stop.

---

## Step 1 — Interview the user

Use AskUserQuestion (one call, multiple questions) to collect everything you'll need. Pre-fill defaults where reasonable; auto-derive tenant + subscription from `az account show`.

Required:

| Field | Default | Notes |
|---|---|---|
| `foundry_base_url` | (none) | Must end with `/openai/v1/`. Foundry projects URL — copy from the Foundry portal. |
| `foundry_deployment` | `gpt-5.4-nano` | Deployment name in their Foundry project. Any Responses-API model. |
| `tunnel_name` | `a365-draft-dodger` | Globally-unique-ish DevTunnel name. If this is a re-bootstrap and the existing tunnel works, use the existing name. |
| `agent_display_name` | `Draft Dodger` | If they want to rebrand, ask. Many users keep this. |

Auto-derived (do not ask):

- `tenant_id` from `az account show --query tenantId -o tsv`
- `subscription_id` from `az account show --query id -o tsv`
- `admin_upn` from `az account show --query user.name -o tsv`

If the agent display name changes, the user is forking this into a different agent persona — point them at `LESSONS_LEARNED.md` §2 (Draft Dodger's prompt is tightly coupled to email tone analysis; rewriting it produces a different agent) and ask if they want to also edit `agent.py:AGENT_PROMPT`. If yes, defer that — they can do it after Phase 1 succeeds.

---

## Step 2 — Phase 1: local sanity check (no A365 yet)

Confirm the agent works standalone before wiring up A365. This catches Foundry endpoint, deployment name, and Azure CLI auth issues early.

```bash
# Install deps
uv sync

# Write .env from template
cp .env.example .env
# (then edit .env to fill in AZURE_OPENAI_BASE_URL and AZURE_OPENAI_DEPLOYMENT from interview answers)

# Auth to Azure
az login --tenant <tenant_id>           # if not already

# Start agent in background (capture PID for later restart)
uv run python start_with_generic_host.py &

# Wait ~5s, then health-check
curl http://localhost:3978/api/health    # expect 200, agent_initialized: true

# Send 5 sample drafts through Foundry
uv run python tests/run_drafts.py
```

**Success criterion:** `tests/run_drafts.py` returns 5 verdicts. If anything errors, look up the exact error in `LESSONS_LEARNED.md` — the most common Phase-1 failures are §1 (Foundry quirks), §3 (OpenAI SDK credential), §1.1 (wrong audience). Fix and retry before continuing.

When this works, **stop the agent** (`pkill -f start_with_generic_host`) — it'll be restarted later in agentic mode.

---

## Step 3 — Phase 2A: DevTunnel

```bash
devtunnel login                                          # interactive, signs in
devtunnel create <tunnel_name> -a                         # -a = anonymous (Bot Framework needs this)
devtunnel port create <tunnel_name> -p 3978
devtunnel show <tunnel_name>                              # shows the persistent URL
```

The tunnel URL is `https://<tunnel_name>-3978.<region>.devtunnels.ms` where `<region>` (e.g. `euw`) is auto-assigned. Capture it — you'll need it in step 5.

Update `agent.json` to set `devTunnelId` to `<tunnel_name>`.

---

## Step 4 — Phase 2B: App registration

Run the existing PowerShell script. It's idempotent — safe to re-run if the user already created the app:

```bash
pwsh -File "deployment script/create_app_registration.ps1"
```

What this does (from the script):
- Creates (or reuses) Entra app "A365 Draft Dodger Client".
- Adds 6 delegated Microsoft Graph permissions: User.Read, Application.ReadWrite.All, AgentIdentityBlueprint.ReadWrite.All, AgentIdentityBlueprint.UpdateAuthProperties.All, DelegatedPermissionGrant.ReadWrite.All, Directory.Read.All.
- Calls `az ad app permission admin-consent` (user must be Global Admin via CLI).
- Generates a 1-year client secret.
- Writes `demo-tenant.config.json` at the **project root** with tenant/subscription/admin-UPN auto-filled.

**Critical:** the printed `clientSecret` is shown **once**. Copy it from the script output and tell the user to save it somewhere safe — they'll paste it into `.env` in step 7. Do not lose it; rotation requires re-running with `-Force`.

If admin-consent fails (user not Global Admin via CLI), tell them to grant consent manually in the Entra portal: App registrations → A365 Draft Dodger Client → API permissions → "Grant admin consent for &lt;tenant&gt;". See `LESSONS_LEARNED.md` §6 for the full permission list.

---

## Step 5 — Phase 2C: stage `deployment.json` for the tunnel

```bash
cp "deployment script/deployment.json.example" deployment.json
# Edit deployment.json — replace <your-tunnel-name> and <region> with values from Step 3
```

The schema is just `endpoint` + `resourceGroup`. `initialize_a365_config.ps1` reads `endpoint` only; `resourceGroup` is informational.

---

## Step 6 — Phase 2D: generate `a365.config.json`

```bash
pwsh -File "deployment script/initialize_a365_config.ps1" \
  -AgentName "draftdodger" \
  -AgentDisplayName "<agent_display_name>" \
  -Force
```

Note: `-AgentName` must be lowercase / no spaces. `-AgentDisplayName` is the human-readable name (defaults are derived from folder name and are usually awkward; pass these explicitly).

Verify with `cat a365.config.json | python3 -m json.tool` — you should see `messagingEndpoint`, `clientAppId`, `tenantId`, `subscriptionId` populated.

---

## Step 7 — Phase 2E: start tunnel + agent, run `a365 setup all`

`a365 setup all` may probe the messaging endpoint. The tunnel host AND the local agent must both be running before you start the setup command.

```bash
# Terminal 1 — DevTunnel host
devtunnel host <tunnel_name> &

# Terminal 2 — Agent
uv run python start_with_generic_host.py &

# Verify both are reachable
curl http://localhost:3978/api/health
curl https://<tunnel_name>-3978.<region>.devtunnels.ms/api/health
# Both should return 200

# Then run setup
a365 setup all --skip-infrastructure --verbose
```

This will produce **up to two device-code prompts**. Each looks like:

```
To sign in, use a web browser to open the page:
    https://login.microsoft.com/device
And enter the code: <CODE>
```

**When you (Claude) see a device code in the output, surface it to the user immediately** — show the URL and the literal code. Wait for them to confirm they've signed in before proceeding.

> ⚠️ **MFA gotcha:** after entering the device code, Microsoft routes the user through MFA. The MFA page asks for an "Authenticator app code" — that's a **6-digit** rotating code from the Microsoft Authenticator app on their phone, NOT the device code. Tell them this explicitly. Past users have repeatedly entered the device code into the MFA prompt and gotten "code didn't work" errors.

After the run completes, check the output for a `Failed Steps` block at the end. If you see:

```
Failed Steps:
ERROR:   [FAILED] Messaging endpoint registration failed
```

…that's `LESSONS_LEARNED.md` §4. Run the workaround:

```bash
a365 setup blueprint --m365 --update-endpoint "https://<tunnel_name>-3978.<region>.devtunnels.ms/api/messages" --verbose
```

The `--m365` flag is required as of CLI 1.1.174 (without it the command silently no-ops — see §5.1).

This step also auto-stamps `.env` with `AGENT_ID`, `CONNECTIONS__SERVICE_CONNECTION__SETTINGS__*`, `AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__*`, etc.

---

## Step 8 — Phase 2F: enable AGENTIC auth, restart agent, publish

The CLI auto-fills most of `.env` but does NOT flip `AUTH_HANDLER_NAME` from empty to `AGENTIC`. Do that manually:

```bash
sed -i.bak 's/^AUTH_HANDLER_NAME=$/AUTH_HANDLER_NAME=AGENTIC/' .env && rm -f .env.bak
```

Also fill in the bare `CLIENT_ID`, `CLIENT_SECRET`, `TENANT_ID` placeholders in `.env` using values from Step 4 (the `clientSecret` from the app reg script + the appId + the tenant ID). The CLI sets the `CONNECTIONS__SERVICE_CONNECTION__SETTINGS__*` variants but the bare ones are still placeholders.

Restart the agent so it picks up the new env:

```bash
pkill -f start_with_generic_host
uv run python start_with_generic_host.py &
```

The agent log should now show `🔐 Using auth handler: AGENTIC` and `🔒 Using Client Credentials authentication`.

Now generate the manifest zip:

```bash
uv run python "deployment script/get_mos_token.py"   # third device code — surface to the user
a365 publish
```

`a365 publish` writes `manifest/manifest.zip` at the project root using its own template. **Critical:** it overwrites your customizations — the description in `manifest/manifest.json` becomes a generic placeholder. Edit the description back, then re-zip:

```bash
# Edit manifest/manifest.json:
#   description.short — keep "Email risk advisor that protects you from professional regret"
#   description.full  — keep the full one
#   accentColor       — change to "#2ECC71" if you want green

cd manifest
rm manifest.zip
zip manifest.zip manifest.json agenticUserTemplateManifest.json color.png outline.png
cd ..
```

Verify the zip:
```bash
unzip -p manifest/manifest.zip manifest.json | python3 -m json.tool | grep -A1 description
```

This `manifest/` folder is **gitignored** (the IDs inside are tenant-specific) — that's correct. It exists only on disk.

---

## Step 9 — Phase 2G: admin upload + activation (manual UI)

This is the only part the user must do via web UI — there's no scriptable API. Tell the user:

1. Go to **https://admin.microsoft.com → Agents → All agents → Upload custom agent**.
2. Upload `manifest/manifest.zip` from the project root.
3. After upload, click the new agent in the list.
4. Click **Update in …** (top-right). Set:
   - **Activated for**: `All users` (or specifically include the test user / a security group).
5. Save.

> Without "Activated for", the agent doesn't show up in any user's Copilot.

Wait for the user to confirm they've completed this step before moving to Phase 3.

---

## Step 10 — Phase 3: test in Microsoft 365 Copilot

The agent appears in **Microsoft 365 Copilot Agents**, NOT the Teams app catalog (it's an "AI teammate" / agent identity). See `LESSONS_LEARNED.md` §7.

Tell the user to:

1. Open **https://m365.cloud.microsoft → Copilot → Agents → &lt;your agent name&gt;** (or use the Copilot side panel inside Teams).
2. Install the agent.
3. Send a test draft email. Try this one to spike all three risk scores:
   > Hi Bob, I noticed you missed our meeting AGAIN. I guess your time is more valuable than mine. Per my last email, the deadline was Friday. I'll go ahead and do your work for you, since clearly nobody else will. Best, Carol
4. Watch your local agent log for `POST /api/messages` requests.

> ⚠️ **First turn can take 1–2 minutes.** Bot Framework runs an `agentOnboarding` flow on first connect, during which the agent's outbound replies get 502 Bad Gateway from `smba.trafficmanager.net`. The agent log will show ~70 inbound `POST /api/messages` retries with 500 status. **It self-heals.** Subsequent turns are fast (sub-10s). See `LESSONS_LEARNED.md` §8.

---

## Step 11 — Live demo: tail the agent log

Once the user has a working install, set up a side-terminal log tail so they can prove "M365 is calling my laptop" during demos:

```bash
# If the agent is running in foreground, just point at that terminal.
# If background (like in this skill), find the log:
LOG=$(ls -t /private/tmp/claude-*/tasks/*.output 2>/dev/null | head -1)

tail -f "$LOG" \
  | grep --line-buffered -E "POST /api/messages|draft_dodger\.analyse|gen_ai\.(request|usage|response)"
```

Each successful Copilot turn produces one access-log line (`"POST /api/messages HTTP/1.1" 202 ...`) and one multi-line span block with `gen_ai.usage.input_tokens` / `output_tokens`. Pure proof the agent is processing real traffic.

For a polished UI view, point an Aspire Dashboard at the OTLP endpoint — see `SETUP.md §13`.

---

## Day-2 operations

Once the bootstrap is done, the user usually just needs:

**Restart the agent** (preserves the tunnel, no A365 reconfig needed):
```bash
pkill -f start_with_generic_host
uv run python start_with_generic_host.py &
curl http://localhost:3978/api/health
```

**Restart the dev tunnel host** (URL persists):
```bash
pkill -f "devtunnel host"
devtunnel host <tunnel_name> &
```

**Prevent laptop sleep during a demo** (macOS):
```bash
caffeinate -dimsu
```

**Reset everything** (full cleanup):
```bash
a365 cleanup blueprint
devtunnel delete <tunnel_name>
az ad app delete --id <appId>
rm a365.config.json a365.generated.config.json deployment.json demo-tenant.config.json .env
rm -rf manifest/manifest.json manifest/agenticUserTemplateManifest.json manifest/manifest.zip
```

---

## When something breaks

The fastest path to a fix is **`LESSONS_LEARNED.md`** — every error message we've personally hit, with root cause and resolution. Specifically:

| Error message | Lesson |
|---|---|
| `401 - audience is incorrect (https://ai.azure.com)` | §1.1 |
| `400 - api-version query parameter is not allowed` | §1.3 + §2.2 |
| `400 - "Invalid value: ''", "param":"input[1]"` | §2.1 |
| `OpenAIError: Missing credentials` (with token provider set) | §3 |
| `400 - "CallbackUri": ["Callback URI is required"]` | §4 (upgrade CLI) |
| `Skipping messaging endpoint update — only applies to M365 agents` | §5.1 (add `--m365`) |
| `Client app is missing required API permissions` | §6 (re-run app reg script with `-Force`) |
| `demo-tenant.config.json not found` | §9.1 (must be at project root) |
| Agent appears nowhere in Copilot | §7 (check "Activated for" in admin center) |
| 70+ 500s in agent log right after install | §8 (BF onboarding storm — self-heals) |

If you (Claude) hit something not in `LESSONS_LEARNED.md`, capture the symptom + your fix and append a new entry to that file at the end of the run.

---

## Notes for Claude executing this skill

- **Auto mode is the right execution model** for this skill — long stretches of action, with surfacing-of-device-codes as the main interruption.
- Use TaskCreate to track each step (0–11) so progress is visible.
- Run the agent and tunnel as **background processes** (Bash with `run_in_background: true`) so this skill can keep moving while they're hosting.
- Use Monitor (with a tight grep filter) on the agent log file to surface device codes and 502 storms in real time without polling.
- When a device code appears in setup output, **immediately** prompt the user with the code + URL — these expire in ~15 minutes.
- After the skill finishes, summarize: list the bootstrap result (blueprint ID, tunnel URL, manifest path), the manual steps the user must complete (admin upload + activation), and the day-2 ops commands. Do not include literal secrets (client secret) in the summary — direct the user to retrieve them from `.env` themselves.
