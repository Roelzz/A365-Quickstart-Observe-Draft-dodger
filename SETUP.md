# Draft Dodger — Setup Guide (Fresh Tenant)

Reproducible runbook to take this repo, point it at **your own** Microsoft 365 tenant + Azure AI Foundry deployment, and end up with a working "Draft Dodger" agent in Microsoft 365 Copilot.

> 🚀 **Faster path with Claude Code:** open this repo in Claude Code and run **`/draft-dodger-setup`**. The bundled project-local skill ([`.claude/skills/draft-dodger-setup/SKILL.md`](.claude/skills/draft-dodger-setup/SKILL.md)) drives every step in this document interactively, surfaces device codes when needed, and applies the known workarounds (CLI 1.1.174 `--m365` flag, Bot Framework onboarding patience). The manual instructions below are the fallback or for readers who don't use Claude Code.

> If you're recovering an existing setup or just need restart procedures, skip to [§13 Operations](#13-operations--day-to-day).

## Documentation map

| File | Purpose |
|---|---|
| [`README.md`](README.md) | Project overview, architecture diagrams, demo-day operations |
| **`SETUP.md` (this file)** | Step-by-step fresh-tenant deployment |
| [`LESSONS_LEARNED.md`](LESSONS_LEARNED.md) | Every error we hit + the fix. Read this first when something breaks. |
| [`.claude/skills/draft-dodger-setup/SKILL.md`](.claude/skills/draft-dodger-setup/SKILL.md) | Claude Code skill — interactive bootstrap (recommended) |
| [`plans/phase-1-scaffold.md`](plans/phase-1-scaffold.md) | Original scaffolding decisions |
| [`plans/phase-2-registration-and-observability.md`](plans/phase-2-registration-and-observability.md) | Phase 2 design notes |

---

## 1. Prerequisites — tools

Install and verify each:

| Tool | Min version | Verify | Install |
|---|---|---|---|
| Python | 3.12 | `python3 --version` | `uv` will pin |
| `uv` | 0.4+ | `uv --version` | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| Azure CLI | any recent | `az --version` | `brew install azure-cli` |
| PowerShell | 7+ | `pwsh --version` | `brew install --cask powershell` |
| DevTunnel CLI | any | `devtunnel --version` | `brew install --cask devtunnel` |
| .NET SDK | 8+ | `dotnet --version` | `brew install --cask dotnet-sdk` |
| **a365 CLI** | **≥ 1.1.174** | `a365 --version` | `dotnet tool install -g Microsoft.Agents.A365.DevTools.Cli` |

> ⚠️ **a365 CLI version matters.** Versions ≤ 1.1.109 have a serialization bug in endpoint registration that produces mysterious `"CallbackUri is required"` errors with the values clearly populated locally. See [`LESSONS_LEARNED.md` §4](LESSONS_LEARNED.md#4-a365-cli-11109-endpoint-registration-bug).

To upgrade an existing install: `dotnet tool update -g Microsoft.Agents.A365.DevTools.Cli`

## 2. Prerequisites — tenant + Azure

You need:

- A **Microsoft 365 tenant** where you have **Global Administrator** role (needed for the admin consent on the custom app registration, the blueprint creation, and the manifest upload in the M365 admin center).
- The tenant has **Microsoft 365 Copilot** licensing (the agent will appear in Copilot, not the Teams app catalog).
- An **Azure AI Foundry** project with a deployment that supports the **Responses API**. We've tested with `gpt-5.4-nano`. Older non-reasoning models (`gpt-4.1`, `gpt-4o`) work via Chat Completions but you'd need to swap the SDK call shape in `agent.py` — see [`LESSONS_LEARNED.md` §1.3](LESSONS_LEARNED.md#13-the-v1-path-rejects-api-version).
- The Foundry project URL — copy it from the Foundry portal. You want the project base, e.g.:
  ```
  https://<resource>.services.ai.azure.com/api/projects/<project>/openai/v1/
  ```

Sign in to Azure CLI before you start:

```bash
az login --tenant <yourTenantId>
az account show          # verify the right tenant + subscription
```

## 3. Phase 0 — clone + install

```bash
git clone <fork-url>
cd A365_Draft_Dodger
uv sync
```

The `uv sync` step pulls everything from `pyproject.toml` + `uv.lock`. First run takes a couple minutes (the `microsoft_agents_a365_*` and `agent-framework-*` packages are large).

## 4. Phase 1 — local sanity check (no A365 yet)

The agent is fully runnable as a standalone process. Confirm that works **before** wiring anything up to A365.

```bash
cp .env.example .env
```

Edit `.env` and set at minimum:

```bash
AZURE_OPENAI_BASE_URL=https://<your-resource>.services.ai.azure.com/api/projects/<your-project>/openai/v1/
AZURE_OPENAI_DEPLOYMENT=gpt-5.4-nano        # or whatever you named it
AZURE_OPENAI_API_VERSION=preview
# AZURE_OPENAI_API_KEY=                     # leave empty — we use az CLI bearer token
```

Leave the `CLIENT_ID`, `CLIENT_SECRET`, `TENANT_ID`, `AUTH_HANDLER_NAME` placeholders alone for now — they get filled by `a365 setup` later.

Start the agent in the foreground:

```bash
uv run python start_with_generic_host.py
```

In another terminal, smoke-test:

```bash
curl http://localhost:3978/api/health
# expect: {"status": "ok", "agent_type": "DraftDodgerAgent", "agent_initialized": true}

uv run python tests/run_drafts.py
# expect: 5 verdict outputs, one per sample draft (NUCLEAR / PASSIVE-AGGRESSIVE / CLEAN / OVER-FORMAL / BORDERLINE)
```

If `tests/run_drafts.py` returns sensible verdicts, your local-to-Foundry path is good. Stop the agent (Ctrl-C in the first terminal) before continuing.

## 5. Phase 2A — DevTunnel

Pick a tunnel name. We used `a365-draft-dodger`; pick your own (must be globally unique-ish; the CLI will tell you if it's taken). Then:

```bash
devtunnel login                                              # interactive
devtunnel create <your-tunnel-name> -a                        # -a = anonymous (required for BF)
devtunnel port create <your-tunnel-name> -p 3978
devtunnel show <your-tunnel-name>                             # confirm it exists
```

Your public URL will be:

```
https://<your-tunnel-name>-3978.<region>.devtunnels.ms
```

(`<region>` is auto-assigned, e.g. `euw` for Europe West. Check the output of `devtunnel show`.)

Update `agent.json` so the `devTunnelId` matches:

```json
{
  "name": "Draft Dodger",
  "type": "agentic",
  "language": "python",
  "deployment": "container-apps",
  "port": 3978,
  "devTunnelId": "<your-tunnel-name>"
}
```

## 6. Phase 2B — App registration

The custom client app holds the Microsoft Graph permissions A365 needs. Run:

```bash
pwsh -File "deployment script/create_app_registration.ps1"
```

What it does:

- Creates (or reuses) an Entra app named "A365 Draft Dodger Client".
- Adds 6 delegated Microsoft Graph permissions: `User.Read`, `Application.ReadWrite.All`, `AgentIdentityBlueprint.ReadWrite.All`, `AgentIdentityBlueprint.UpdateAuthProperties.All`, `DelegatedPermissionGrant.ReadWrite.All`, `Directory.Read.All`.
- Runs `az ad app permission admin-consent` (you must be Global Admin via CLI for this).
- Generates a 1-year client secret.
- Writes `demo-tenant.config.json` at the **project root** (not under `deployment script/`) with `tenantId`, `subscriptionId`, `adminUserPrincipalName`, `customClientAppId` filled in from your `az account show`.

> ⚠️ **The client secret is shown once.** Capture it from the script's output:
> ```
> ===== APP REGISTRATION VALUES =====
> appId:        <your-app-id>
> clientSecret: <your-client-secret>      ← copy this
> tenantId:     <your-tenant-id>
> ```
> If admin-consent fails (you're not Global Admin via CLI, or there's a CLI/portal sync delay), grant it manually: Entra portal → App registrations → A365 Draft Dodger Client → API permissions → "Grant admin consent for &lt;tenant&gt;".

## 7. Phase 2C — stage `deployment.json` for the tunnel

`initialize_a365_config.ps1` wants a `deployment.json` at the project root that tells it where the messaging endpoint is. There's a template ready:

```bash
cp "deployment script/deployment.json.example" deployment.json
```

Edit `deployment.json` and replace the example tunnel URL with yours:

```json
{
  "endpoint": "https://<your-tunnel-name>-3978.<region>.devtunnels.ms/api/messages",
  "resourceGroup": "n/a-using-devtunnel"
}
```

The script reads only `endpoint` and `resourceGroup` (the rest of `deployment.json`'s schema is irrelevant for our DevTunnel-mode setup).

## 8. Phase 2D — generate `a365.config.json`

```bash
pwsh -File "deployment script/initialize_a365_config.ps1" \
  -AgentName "draftdodger" \
  -AgentDisplayName "Draft Dodger" \
  -Force
```

This produces `a365.config.json` (project root) with `needDeployment=false` (we're not deploying to Container Apps), `messagingEndpoint` set to your tunnel, and the right blueprint metadata. Verify with:

```bash
cat a365.config.json | python3 -m json.tool
```

You should see `messagingEndpoint`, `clientAppId`, `tenantId`, `subscriptionId` all set.

## 9. Phase 2E — run setup with the agent already up

`a365 setup all` may probe the messaging endpoint, so the agent + tunnel must be running **before** you run it. Open three terminals:

**Terminal 1 — DevTunnel host (keep running):**
```bash
devtunnel host <your-tunnel-name>
```

**Terminal 2 — Agent (keep running):**
```bash
uv run python start_with_generic_host.py
```

**Terminal 3 — verify both are reachable, then run setup:**
```bash
curl http://localhost:3978/api/health                                    # local
curl https://<your-tunnel-name>-3978.<region>.devtunnels.ms/api/health   # via tunnel — both should return 200

a365 setup all --skip-infrastructure --verbose
```

You'll get up to **two device-code prompts** during this run. Each looks like:

```
To sign in, use a web browser to open the page:
    https://login.microsoft.com/device
And enter the code: <CODE>
```

> 💡 Microsoft routes you through MFA after entering the device code. The MFA page will then ask for an "Authenticator app code" — that's a **6-digit** rolling code from the Microsoft Authenticator app on your phone, NOT the device code. Don't paste the device code into the MFA page.

After the run completes, check for the `Failed Steps` block at the end. If you see:

```
Failed Steps:
ERROR:   [FAILED] Messaging endpoint registration failed
```

That's the [CLI 1.1.109 bug from §4 of LESSONS_LEARNED.md](LESSONS_LEARNED.md#4-a365-cli-11109-endpoint-registration-bug). Upgrade the CLI and retry the endpoint step:

```bash
dotnet tool update -g Microsoft.Agents.A365.DevTools.Cli

a365 setup blueprint \
  --m365 \
  --update-endpoint "https://<your-tunnel-name>-3978.<region>.devtunnels.ms/api/messages" \
  --verbose
```

> ⚠️ The `--m365` flag is required as of 1.1.174 — without it the command silently no-ops. See [`LESSONS_LEARNED.md` §5.1](LESSONS_LEARNED.md#51-update-endpoint-requires-m365).

## 10. Phase 2F — restart agent + publish

`a365 setup all` (and `setup blueprint --m365`) auto-stamp your `.env` with `AGENT_ID`, the agentic auth handler config, and the `CONNECTIONS__SERVICE_CONNECTION__SETTINGS__*` triplet. But it **doesn't** flip `AUTH_HANDLER_NAME` from empty to `AGENTIC`. Do that manually:

```bash
sed -i.bak 's/^AUTH_HANDLER_NAME=$/AUTH_HANDLER_NAME=AGENTIC/' .env && rm -f .env.bak
grep AUTH_HANDLER_NAME .env
# expect: AUTH_HANDLER_NAME=AGENTIC
```

Also fill in the bare `CLIENT_ID`, `CLIENT_SECRET`, `TENANT_ID` placeholders (the CLI sets the `CONNECTIONS__*` versions; the bare ones are still placeholders). Use values from your app registration (§6).

Now restart the agent so it loads the new `.env`:

```bash
pkill -f start_with_generic_host
uv run python start_with_generic_host.py &
```

In its log you should see `🔐 Using auth handler: AGENTIC` and `🔒 Using Client Credentials authentication`.

Now generate the manifest zip:

```bash
uv run python "deployment script/get_mos_token.py"   # third device code
a365 publish
```

`a365 publish` writes `manifest/manifest.zip` at the project root. **Important: the CLI's templates overwrite your customizations** — the description in `manifest/manifest.json` will be a generic placeholder. Edit it, then re-zip:

```bash
# Edit manifest/manifest.json — fix description.short, description.full, accentColor

cd manifest
rm manifest.zip
zip manifest.zip manifest.json agenticUserTemplateManifest.json color.png outline.png
cd ..
```

Sanity-check the zip:

```bash
unzip -p manifest/manifest.zip manifest.json | python3 -m json.tool | grep -A1 description
```

## 11. Phase 2G — admin upload + activation (manual web UI)

1. Go to **https://admin.microsoft.com → Agents → All agents → Upload custom agent**.
2. Upload `manifest/manifest.zip`.
3. After upload, click your new agent in the list.
4. Click **Update in …** (top-right). Set:
   - **Activated for**: `All users` (or specifically include the test user / a security group).
5. Save.

> Without setting "Activated for", the agent doesn't show up in any user's Copilot — including yours.

## 12. Phase 3 — test in Microsoft 365 Copilot (NOT the Teams app catalog)

The agent is an "AI teammate" / agent identity, not a Teams personal-scope bot. It appears in **Microsoft 365 Copilot → Agents**, not the Teams app catalog.

Open one of:

- https://m365.cloud.microsoft → click the Copilot icon (left rail) → **Agents** → find **Draft Dodger** → install → start chatting.
- Microsoft Teams → click **Copilot** in the left rail → **Agents** tab → Draft Dodger.
- Standalone Microsoft 365 Copilot app → Agents.

Send a draft email. Try this one to spike all three risk dimensions:

> Hi Bob, I noticed you missed our meeting AGAIN. I guess your time is more valuable than mine. Per my last email, the deadline was Friday. I'll go ahead and do your work for you, since clearly nobody else will. Best, Carol

Expected: scores on three dimensions, flagged phrases with rewrites, verdict (likely TONE DOWN or DELETE AND WALK AWAY), and confidence percentage.

> ⚠️ **First turn can take 1–2 minutes** as Bot Framework completes onboarding for your agent identity. Your local agent log will show ~70 inbound `POST /api/messages` retries with mostly 500 status — Bot Framework retrying because outbound replies are getting 502 Bad Gateway during the `agentOnboarding` flow. It self-heals. Subsequent turns are fast. See [`LESSONS_LEARNED.md` §8](LESSONS_LEARNED.md#8-bot-framework-502-retry-storm-during-onboarding).

## 13. Operations — day-to-day

### Restart the agent (preserves the tunnel)

```bash
pkill -f start_with_generic_host
uv run python start_with_generic_host.py
curl http://localhost:3978/api/health
```

A365 doesn't notice — the tunnel URL is bound to the tunnel ID, not the local agent.

### Restart the dev tunnel host (URL persists)

```bash
pkill -f "devtunnel host"
devtunnel host <your-tunnel-name>
curl https://<your-tunnel-name>-3978.<region>.devtunnels.ms/api/health
```

A365 doesn't need any reconfiguration; the tunnel URL is the same.

### Watch live inbound traffic during a demo

This is the recipe for "is this *really* running on your laptop?" demos. Tail the agent's stdout/stderr; every M365 Copilot turn produces:

- One access log line: `INFO:aiohttp.access:127.0.0.1 [...] "POST /api/messages HTTP/1.1" 202 ...`
- The three A365 SDK structured spans (`invoke_agent Draft Dodger` → `Chat <model>` → `output_messages …`) wrapping the Foundry call.
- An `HTTP 200 success on attempt 1. … "partialSuccess":{"rejectedSpans":0}` line confirming Microsoft accepted them at `agent365.svc.cloud.microsoft`.

The agent writes everything to **stdout**, not a file. To both watch it in the launching terminal *and* tail-grep it from a side terminal, capture stdout with `tee` when you launch:

```bash
# Terminal 2 — launch with stdout mirrored to /tmp/draft-dodger.log
uv run python start_with_generic_host.py 2>&1 | tee /tmp/draft-dodger.log
```

```bash
# Side terminal — follow the demo-relevant lines
tail -f /tmp/draft-dodger.log \
  | grep --line-buffered -E 'POST /api/messages|Span (started|ended)|HTTP 200 success|rejectedSpans|OTLP mirror'
```

> Don't copy snippets that include literal angle-bracket placeholders like `<agent-log-file>` — `zsh` parses `<file` as a redirection operator and aborts with `parse error near '|'`. Use the literal `/tmp/draft-dodger.log` path above.

For Claude-launched background tasks the log is at `/private/tmp/claude-*` — find it with:

```bash
ls -t /private/tmp/claude-*/tasks/*.output | head -3
```

#### Pretty-print spans for a polished demo

The console mirror (enabled with `OBSERVABILITY_DEBUG=true`) prints each span as a multi-line JSON block. To collapse those to a one-line per-turn summary, pipe through Python:

```bash
tail -f /tmp/draft-dodger.log \
  | python3 -c "
import sys, json
buf = []
for line in sys.stdin:
    buf.append(line)
    if line.rstrip() == '}':
        try:
            obj = json.loads(''.join(buf))
            name = obj.get('name', '')
            a = obj.get('attributes', {})
            if name == 'Chat ' + (a.get('gen_ai.request.model') or ''):
                print(f\"📨 turn — model={a.get('gen_ai.request.model')} in={a.get('gen_ai.usage.input_tokens')}tok out={a.get('gen_ai.usage.output_tokens')}tok\")
            elif name.startswith('invoke_agent '):
                print(f\"🪝 invoke — agent={a.get('gen_ai.agent.name')} conv={a.get('gen_ai.conversation.id')}\")
        except: pass
        buf = []
"
```

#### Or use Aspire Dashboard for a UI

```bash
# Terminal 4: run an Aspire Dashboard locally (needs Docker)
docker run --rm -it -p 18888:18888 -p 4317:18889 \
  mcr.microsoft.com/dotnet/aspire-dashboard:latest

# Add to .env, then restart agent
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
```

Open http://localhost:18888 — every Copilot turn lights up as a span with full attributes.

### Prevent the laptop from sleeping mid-demo (macOS)

```bash
caffeinate -dimsu
```

Run this in a side terminal during demos. The dev tunnel host is the brittle bit; if your laptop sleeps and Wi-Fi drops, the host process can die.

## 14. Cleanup / reset

> Already-registered agent and just need to change something? See [`RE-REGISTRATION.md`](RE-REGISTRATION.md) — scenario-based runbook for endpoint swaps, manifest re-publishes, permission re-grants, and full re-registrations.

If you need to wipe everything and start over:

```bash
# A365 side
a365 cleanup blueprint --endpoint-only             # delete just the messaging endpoint
a365 cleanup blueprint                              # delete blueprint entirely

# DevTunnel
devtunnel delete <your-tunnel-name>

# Entra app registration
az ad app delete --id <appId from create_app_registration.ps1>

# Local state
rm a365.config.json a365.generated.config.json deployment.json demo-tenant.config.json .env
```

Then start over from §3 (Phase 0).

## 15. Troubleshooting

When something breaks, the right place to look is **[`LESSONS_LEARNED.md`](LESSONS_LEARNED.md)** — it has the full error-message → root-cause → fix table at the bottom. Quick map for common failures during setup:

| Failure during | Likely lesson |
|---|---|
| §4 local test (`tests/run_drafts.py` fails) | [§1 Foundry endpoint quirks](LESSONS_LEARNED.md#1-foundry-responses-api-endpoint-quirks), [§3 OpenAI SDK credential gotcha](LESSONS_LEARNED.md#3-openai-python-sdk-2340-credential-gotcha) |
| §6 app reg script (admin consent error) | [§6 required Graph permissions](LESSONS_LEARNED.md#6-required-microsoft-graph-permissions-for-the-custom-client-app) |
| §9 `a365 setup all` (CallbackUri error) | [§4 CLI 1.1.109 bug](LESSONS_LEARNED.md#4-a365-cli-11109-endpoint-registration-bug), [§5.1 --m365 required](LESSONS_LEARNED.md#51-update-endpoint-requires-m365) |
| §10 `a365 publish` (description shows generic placeholder) | [§5.2 publish overwrites manifest](LESSONS_LEARNED.md#52-a365-publish-no-longer-auto-uploads-to-teams) |
| §12 testing in Copilot (can't find agent) | [§7 it's in Copilot, not Teams catalog](LESSONS_LEARNED.md#7-where-the-agent-shows-up-in-the-users-ui), check **Activated for** in admin center |
| §12 testing (massive 500 storm in agent log) | [§8 BF onboarding 502 storm](LESSONS_LEARNED.md#8-bot-framework-502-retry-storm-during-onboarding) — wait it out |
