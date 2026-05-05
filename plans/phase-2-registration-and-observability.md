# Plan: Draft Dodger Phase 2 — A365 Registration (DevTunnel) + Observability

## Context

Draft Dodger Phase 1 is complete and working: agent runs locally, hits the Foundry Responses endpoint with gpt-5.4-nano, returns structured tone-analysis verdicts. Three commits on `main`: `7761d65` → `f2028c9` → `609293e`.

Two follow-on questions from the user:
1. **Register the agent in A365 while keeping the runtime local** — yes, via Microsoft DevTunnel. No Azure Container Apps deployment needed.
2. **Observability** — currently broken: `AgentFrameworkInstrumentor` logs `"Microsoft Agent 365 (or your telemetry config) is not initialized"` on every run, and worse, since I bypassed `ChatAgent` to talk to the Foundry Responses API directly via raw `AsyncOpenAI`, the framework auto-instrumentation wouldn't trace our actual API calls even if it were configured.

This plan covers two independent phases. They can be executed in either order. Phase 2A is required for the demo. Phase 2B is nice-to-have for "look, I can see traces" credibility.

## Phase 2A — DevTunnel + A365 Registration

Goal: agent runs on `localhost:3978`, exposed via persistent DevTunnel, registered as an A365 blueprint, published to Teams. No Azure Container Apps.

### Prerequisites

| Tool | Check | Install |
|---|---|---|
| Microsoft DevTunnel CLI | `devtunnel --version` | `brew install --cask devtunnel` (or [docs](https://aka.ms/devtunnel)) |
| Azure CLI (already have) | `az account show` | already installed |
| PowerShell 7 | `pwsh --version` | `brew install powershell` |
| a365 CLI | `a365 --version` | `npm install -g @anthropic/a365-cli` |

Tenant config required (collect from user before starting):
- `tenantId`
- `tenantName`
- `adminUserPrincipalName` (admin UPN)
- `subscriptionId`
- `subscriptionName`
- `customClientAppId` (custom client App Registration's client ID — this is the app that holds the API permissions for A365)

### Steps

1. **Create persistent DevTunnel.**
   ```bash
   devtunnel login                                          # device code, sign in with admin
   devtunnel create a365-draft-dodger -a                    # -a = allow anonymous (Teams needs this)
   devtunnel port create a365-draft-dodger -p 3978
   devtunnel show a365-draft-dodger                         # capture the persistent URL
   ```
   The URL has form `https://<tunnel-id>-3978.<region>.devtunnels.ms`. Capture it as `<TUNNEL_URL>`.

2. **Fill in `deployment script/demo-tenant.config.json`** from the `.example` template with the tenant config above.

3. **Skip `deploy.ps1` entirely.** Instead, hand-create `deployment.json` at the project root so `initialize_a365_config.ps1` thinks the agent is already deployed:
   ```json
   {
     "agentName": "draft-dodger",
     "agentEndpoint": "<TUNNEL_URL>",
     "containerAppName": "local-via-devtunnel",
     "resourceGroup": "n/a",
     "imageTag": "n/a"
   }
   ```
   Verify the actual key names by reading `deploy.ps1`'s output — adjust if the real schema differs.

4. **Run A365 config init.**
   ```bash
   cd "deployment script"
   pwsh -File initialize_a365_config.ps1 -Force
   ```
   This reads `demo-tenant.config.json` + the fake `deployment.json` and writes `a365.config.json` at the project root.

5. **Run `a365 setup all`.**
   ```bash
   cd /Users/roelschenk/Downloads/Projects/A365_Draft_Dodger
   a365 setup all
   ```
   Device-code prompt — sign in with admin. This creates the blueprint, the service connection, and writes `a365.generated.config.json`.

6. **Extract blueprint ID and update `.env`.**
   ```bash
   BP=$(jq -r '.blueprint.id' a365.generated.config.json)
   ```
   Replace placeholders in `.env`:
   - `CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID`
   - `CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET`
   - `CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID`
   - `CLIENT_ID`, `CLIENT_SECRET`, `TENANT_ID`
   - Set `AUTH_HANDLER_NAME=AGENTIC` (was empty for local-anonymous mode)

7. **Update Teams manifest files** with the blueprint ID and a generated agentic template UUID:
   ```bash
   AT_ID=$(python3 -c "import uuid; print(uuid.uuid4())")
   # In deployment script/manifest/manifest.json: replace <BLUEPRINT_ID> with $BP, <AGENTIC_TEMPLATE_ID> with $AT_ID
   # In deployment script/manifest/agenticUserTemplateManifest.json: same
   ```

8. **Start the DevTunnel host and the agent in two terminals.**
   ```bash
   # Terminal 1 — keep running while demoing
   devtunnel host a365-draft-dodger

   # Terminal 2
   uv run python start_with_generic_host.py
   ```

9. **Publish to Teams.**
   ```bash
   uv run python "deployment script/get_mos_token.py"
   a365 publish
   ```
   Device-code prompt again.

10. **Developer Portal** (https://dev.teams.microsoft.com/apps): verify the bot ID matches the blueprint ID. Submit "Publish to org."

11. **Admin Center** (https://admin.teams.microsoft.com/policies/manage-apps): set status → Allowed; under Manage → Permissions, approve.

12. **End-to-end test in Teams.** Search for "Draft Dodger" in apps → install → send a draft → verify the agent responds.

### Risks for Phase 2A

- `initialize_a365_config.ps1` may expect specific keys in `deployment.json` that differ from my guess in step 3. **Verification**: read the script body before running; adjust the JSON to match.
- DevTunnel host process must stay running for the entire demo. Use `caffeinate -dimsu` and keep the host in `tmux`/`screen` so an accidental Ctrl-C doesn't kill the demo.
- `a365 publish` increments require version bumps in `manifest.json` if you re-publish. Keep version `1.0.0` for first publish.
- If the agent endpoint check in the A365 backend probes the tunnel URL and finds it down, registration may fail. **Mitigation**: have `devtunnel host` running and the local agent up *before* running `a365 setup all`.

## Phase 2B — Observability

Goal: traces from every Draft Dodger turn flow into either Aspire Dashboard (local) or Application Insights (cloud), including the actual OpenAI Responses API call latency, prompt, and token counts.

### Why this isn't already working

- `agent.py` calls `AgentFrameworkInstrumentor().instrument()` but the underlying Microsoft Agent 365 observability SDK isn't initialized → warning logged, no spans created.
- Even if it were initialized: I removed `ChatAgent` from the runtime path during the Foundry Responses workaround. The OpenAI calls now go through raw `openai.AsyncOpenAI`, which the AgentFramework instrumentor doesn't hook into.

### Steps

1. **Add OpenAI auto-instrumentation to dependencies.**
   ```bash
   uv add opentelemetry-instrumentation-openai-v2
   uv export --no-hashes 2>/dev/null > requirements.txt
   ```

2. **Initialize Microsoft Agent 365 observability** in `agent.py`. New helper module `observability.py`:
   ```python
   from microsoft_agents_a365.observability.core import setup_observability
   from opentelemetry.instrumentation.openai_v2 import OpenAIInstrumentor

   def init_observability() -> None:
       setup_observability(
           service_name="draft-dodger",
           otlp_endpoint=os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT") or None,
           azure_monitor_connection_string=os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING") or None,
       )
       OpenAIInstrumentor().instrument()
   ```
   Verify the actual function name in the installed `microsoft_agents_a365.observability.core` package — the API may have changed.

3. **Call `init_observability()` once at module import time** at the top of `agent.py`, before `OpenAI` clients are constructed. Then drop the bare `AgentFrameworkInstrumentor` call (it's misleading since we don't use the framework's runtime).

4. **Local trace verification with Aspire Dashboard.**
   ```bash
   docker run --rm -it -p 18888:18888 -p 4317:18889 \
     mcr.microsoft.com/dotnet/aspire-dashboard:latest
   ```
   Add to `.env`:
   ```
   OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
   ```
   Run a few drafts through `tests/run_drafts.py`, open http://localhost:18888, expect to see spans for `responses.create` with model, input/output token counts, and latency.

5. **Cloud trace verification with App Insights** (Phase 2A or later):
   - Provision an App Insights resource in the same subscription.
   - Set `APPLICATIONINSIGHTS_CONNECTION_STRING` in `.env`.
   - Verify traces in Application Insights → Transaction search.

6. **Sanity check**: send the nuclear resignation draft; a single trace should show one span with `gen_ai.system=openai`, `gen_ai.request.model=gpt-5.4-nano`, and the agent prompt/response (with optional content redaction depending on SDK config).

### Risks for Phase 2B

- The exact `setup_observability(...)` function signature might differ from what I wrote. **Verification**: `import microsoft_agents_a365.observability.core; help(...)` before wiring it in.
- `opentelemetry-instrumentation-openai-v2` may not yet support the OpenAI Python SDK 2.x line — the project pins `openai>=2.34.0` (transitive). If the instrumentor only hooks the v1 SDK API, traces will be empty. **Mitigation**: try it; if empty, fall back to wrapping `responses.create` in a manual span using `opentelemetry.trace.get_tracer(...)`.
- If `OTEL_EXPORTER_OTLP_ENDPOINT` is set but no collector is listening, the SDK will retry and log noise. Keep it empty when not actively collecting traces.

## Critical files

Phase 2A:
- `deployment script/demo-tenant.config.json` (to be created, gitignored)
- `deployment.json` (to be hand-created at project root, gitignored)
- `a365.config.json` (generated by `initialize_a365_config.ps1`, gitignored)
- `a365.generated.config.json` (generated by `a365 setup all`, gitignored)
- `.env` (update with blueprint ID + secrets after `a365 setup all`)
- `deployment script/manifest/manifest.json` and `agenticUserTemplateManifest.json` (replace placeholders)

Phase 2B:
- `agent.py` (init observability before client creation, drop AgentFrameworkInstrumentor)
- `observability.py` (new helper)
- `pyproject.toml` (add `opentelemetry-instrumentation-openai-v2`)
- `.env` (set `OTEL_EXPORTER_OTLP_ENDPOINT` or `APPLICATIONINSIGHTS_CONNECTION_STRING`)

## Verification

Phase 2A: end-to-end smoke test in Microsoft Teams — install the published agent, send a tone-analysis draft, confirm a structured response comes back (scores + flags + verdict).

Phase 2B: with the agent running and `tests/run_drafts.py` executed, the Aspire Dashboard at http://localhost:18888 (or App Insights Transaction search) shows ≥5 traces, one per draft. Each trace has at least one span for the OpenAI Responses call with non-zero token counts.

## Out of scope (deferred)

- Azure Container Apps deployment via `deploy.ps1` (unchanged from earlier plan).
- Re-introducing `ChatAgent` to fix the framework's `OpenAIResponsesClient.input[1]` malformation. Worth filing as an issue against `agent_framework` upstream; not blocking the demo.
- Adding MCP servers (Mail/Calendar/Knowledge/Me) — user explicitly declined.
- CI/CD or automated redeploys.
