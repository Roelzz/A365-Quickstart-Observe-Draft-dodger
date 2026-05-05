# Draft Dodger

> Email risk advisor. Analyses draft emails before you send them, scores them on passive aggression / emotional temperature / formality match, flags risky phrases with rewrites, and returns a verdict — **SEND**, **TONE DOWN**, or **DELETE AND WALK AWAY** — with a confidence score.

A Microsoft Agent 365 demo agent. Python, Microsoft Agents SDK, Azure AI Foundry (gpt-5.4-nano on the Responses API).

---

## What it does

Send the agent a draft email. It returns:

- **Three scores (1–10):** Passive Aggression, Emotional Temperature, Formality Match.
- **Flagged phrases**, each with a one-line "why this is risky" + a per-phrase rewrite.
- **A verdict:**
  - **SEND** — fine as-is, agent stays out of your way.
  - **TONE DOWN** — salvageable; agent shows rewrites.
  - **DELETE AND WALK AWAY** — career-risk territory; agent recommends a cooling-off period.
- **A confidence percentage.**
- Optionally, a full clean rewrite of the email.

Tone of the agent itself: direct, dry, on the user's side. Never moralizes, never lectures.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Teams / aiohttp /api/messages POST                             │
│              │                                                  │
│              ▼                                                  │
│  host_agent_server.py  ── CloudAdapter + AgentApplication       │
│              │                                                  │
│              ▼                                                  │
│  agent.py:DraftDodgerAgent.process_user_message(...)            │
│              │                                                  │
│              ▼                                                  │
│  AsyncOpenAI.responses.create(                                  │
│      model=gpt-5.4-nano,                                        │
│      instructions=AGENT_PROMPT,                                 │
│      input=draft_email)                                         │
│              │                                                  │
│              ▼                                                  │
│  https://a365-demo.services.ai.azure.com/api/projects/a365/     │
│      openai/v1/responses        (Foundry projects endpoint)     │
└─────────────────────────────────────────────────────────────────┘
```

**No MCP tools.** The agent is reactive only — it analyses what the user sends. No mailbox/calendar/knowledge integrations.

**No notifications.** The agent doesn't auto-trigger on inbound mail. Chat-only.

---

## Why we bypass `agent_framework.ChatAgent`

The Foundry projects endpoint (`/openai/v1/responses`) is an OpenAI-compatible Responses API path, not classic Azure OpenAI. The `agent_framework` SDK (build `1.0.0b260130`) currently has two issues against this endpoint:

1. `AzureOpenAIResponsesClient` hardcodes the `?api-version=preview` query parameter. The `/v1/` Foundry path rejects this with `"api-version query parameter is not allowed when using /v1 path"`.
2. `OpenAIResponsesClient` (the generic one) sends a malformed second item in the `input` array — empty `type` field — which the endpoint rejects with `"Invalid value: ''. Supported values are: 'message', 'reasoning', ..."`.

Workaround: call `openai.AsyncOpenAI.responses.create(...)` directly. We lose `ChatAgent`'s middleware/tool plumbing, but we picked no MCP servers anyway, so nothing of value is lost. The `AgentInterface` contract (`process_user_message`, `cleanup`, `initialize`) is unchanged, so `host_agent_server.py` doesn't notice.

If/when the framework fixes either issue, swap back to the framework client by reverting commit `f2028c9` and updating the URL+api_version handling.

---

## Authentication

Two paths, picked at runtime:

1. **API key** — set `AZURE_OPENAI_API_KEY` in `.env`. Used as a literal API key.
2. **Azure CLI bearer token** (default when `AZURE_OPENAI_API_KEY` is empty). Uses `AzureCliCredential` to fetch a token for audience `https://ai.azure.com/.default`, passed as the OpenAI client's `api_key` via an async callable. The OpenAI SDK refreshes it on every request.

Run `az login` before starting the agent. The Azure CLI's currently signed-in user must have access to the Foundry project.

---

## Quick start (local)

```bash
# 1. Install deps
uv sync

# 2. Configure
cp .env.example .env
#   then edit .env — at minimum set AZURE_OPENAI_BASE_URL and AZURE_OPENAI_DEPLOYMENT

# 3. Auth
az login

# 4. Run the agent
uv run python start_with_generic_host.py

# 5. Health check (in another terminal)
curl http://localhost:3978/api/health
```

For local-only testing (no Teams, no A365), use the standalone draft runner:
```bash
uv run python tests/run_drafts.py
```
This sends 5 sample drafts (nuclear resignation, passive-aggressive chase, clean status update, awkwardly over-formal, and borderline frustrated) and prints the agent's verdicts.

For unit tests:
```bash
uv run pytest tests/ -v
```

---

## Environment variables

| Variable | Required | Default | Notes |
|---|---|---|---|
| `AZURE_OPENAI_BASE_URL` | yes | — | Must end in `/openai/v1/`. Foundry projects URL. |
| `AZURE_OPENAI_DEPLOYMENT` | yes | — | Deployment name in the Foundry project (e.g. `gpt-5.4-nano`). |
| `AZURE_OPENAI_API_KEY` | no | empty | If set, used directly. Otherwise we fall back to `az` CLI bearer token. |
| `AZURE_OPENAI_API_VERSION` | no | `preview` | Currently unused (raw `AsyncOpenAI` ignores this — kept for compatibility). |
| `PORT` | no | `3978` | aiohttp server bind port. |
| `LOG_LEVEL` | no | `INFO` | loguru level. |
| `AUTH_HANDLER_NAME` | no | empty | Empty = anonymous local mode. Set to `AGENTIC` after A365 setup. |
| `CLIENT_ID` / `CLIENT_SECRET` / `TENANT_ID` | for A365 | — | Filled in after `a365 setup all`. Required for JWT validation of inbound Teams traffic. |
| `CONNECTIONS__SERVICE_CONNECTION__SETTINGS__*` | for A365 | — | Set of variables for the Microsoft Agents SDK service connection. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | no | empty | Phase 2B observability — point at Aspire Dashboard or local OTLP collector. |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | no | empty | Phase 2B observability — Azure Monitor / App Insights. |

`.env` is gitignored. `.env.example` shows the full set of expected keys.

---

## Project layout

```
A365_Draft_Dodger/
├── agent.py                           # DraftDodgerAgent — system prompt + Responses API call
├── start_with_generic_host.py         # Entry point — passes DraftDodgerAgent into the host
├── host_agent_server.py               # Generic aiohttp host (CloudAdapter + Authorization)
├── agent_interface.py                 # Abstract base class
├── local_authentication_options.py    # Bearer-token / client-credentials helper
├── token_cache.py                     # In-memory cache for agentic auth tokens
├── agent.json                         # A365 agent metadata (name, port, devTunnelId)
├── ToolingManifest.json               # MCP server manifest — empty []
├── pyproject.toml                     # uv project + Python deps
├── requirements.txt                   # Frozen deps for Docker
├── Dockerfile                         # Container image
├── .env.example                       # Template for .env
├── .dockerignore / .gitignore
├── tests/
│   ├── test_main.py                   # pytest unit tests (token_cache, agent_interface)
│   └── run_drafts.py                  # Live integration runner — 5 demo drafts
├── plans/                             # Implementation plans (per phase)
│   ├── phase-1-scaffold.md
│   └── phase-2-registration-and-observability.md
└── deployment script/                 # A365 + Teams deployment artefacts
    ├── deploy.ps1                     # ACA deployment (skipped if running via DevTunnel)
    ├── initialize_a365_config.ps1     # Generates a365.config.json
    ├── get_mos_token.py               # Fetches the MOS auth token for a365 publish
    ├── demo-tenant.config.json.example
    ├── manifest/
    │   ├── manifest.json              # Teams agentic manifest (devPreview)
    │   ├── agenticUserTemplateManifest.json
    │   ├── color.png
    │   └── outline.png
    └── appPackage/
        └── manifest.json              # Teams app package manifest (v1.17)
```

---

## Phase 2 — A365 registration via DevTunnel (no Azure deploy)

The agent runs locally on `:3978`, exposed via a persistent Microsoft DevTunnel. A365 registers the tunnel URL as the agent's messaging endpoint instead of an Azure Container App URL.

Full step-by-step plan: see [`plans/phase-2-registration-and-observability.md`](plans/phase-2-registration-and-observability.md).

### Tunnel basics

```bash
# One-time
devtunnel login
devtunnel create a365-draft-dodger -a              # -a = allow anonymous (Teams needs this)
devtunnel port create a365-draft-dodger -p 3978
devtunnel show a365-draft-dodger                   # capture the persistent URL

# Every session
devtunnel host a365-draft-dodger                   # keep this running for the demo
```

The tunnel **ID and URL are persistent** — they survive reboots, sleeps, network changes. The **host process is not** — it must be running for traffic to flow. Use a dedicated terminal tab or `tmux`/`screen`.

### Demo-day runbook

1. **Terminal 1** — keep alive: `devtunnel host a365-draft-dodger`
2. **Terminal 2** — keep alive: `uv run python start_with_generic_host.py`
3. **Terminal 3** (optional) — `caffeinate -dimsu` to prevent sleep
4. Open Teams, search for "Draft Dodger", paste a draft email, watch the verdict come back.

If a verdict doesn't appear within ~5 seconds:
- Check Terminal 2 for stack traces.
- Hit `curl http://localhost:3978/api/health` from Terminal 3.
- Confirm the DevTunnel URL still resolves: `curl https://<tunnel-id>-3978.<region>.devtunnels.ms/api/health`.
- If the agent restarted, the tunnel host doesn't need restarting — just verify it's still up.

---

## Observability

Wired up in `observability.py` and called from `agent.py` at import time. Each call to `process_user_message` emits a single OpenTelemetry span named `draft_dodger.analyse` with `gen_ai.*` semantic attributes:

| Attribute | Value |
|---|---|
| `service.name` | `draft-dodger` |
| `service.namespace` | `a365.demo` |
| `gen_ai.system` | `azure_openai` |
| `gen_ai.operation.name` | `responses` |
| `gen_ai.request.model` | the deployment name (e.g. `gpt-5.4-nano`) |
| `gen_ai.request.input.length` | character count of the user draft |
| `gen_ai.usage.input_tokens` | from the Responses API response |
| `gen_ai.usage.output_tokens` | from the Responses API response |
| `gen_ai.response.output.length` | character count of the agent reply |

### Where the spans go

By default (no OTLP endpoint, no App Insights connection string) the Microsoft Agent 365 SDK falls back to a **console exporter** — spans are pretty-printed to stdout. Useful for local dev.

To export elsewhere, set one of:

```bash
# Local OTLP collector (Aspire Dashboard, Jaeger, otelcol, etc.)
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317

# Cloud (Azure Monitor / App Insights)
APPLICATIONINSIGHTS_CONNECTION_STRING=InstrumentationKey=...;IngestionEndpoint=...
```

### Note on `OpenAIInstrumentor`

`opentelemetry-instrumentation-openai-v2` is installed and enabled, but as of `2.4b0` it only wraps `openai.resources.chat.completions` — not the Responses API. Once it adds Responses-API support, our manual span in `process_user_message` becomes redundant and can be deleted. Until then, the manual span is what produces traces.

### Aspire Dashboard (local)

If you want a UI, run an Aspire Dashboard with Docker:

```bash
docker run --rm -it -p 18888:18888 -p 4317:18889 \
  mcr.microsoft.com/dotnet/aspire-dashboard:latest
```

Then add `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317` to `.env` and open http://localhost:18888.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Missing credentials. Please pass an api_key, workload_identity, ...` | Foundry endpoint accepts `base_url` but the `openai` SDK requires *something* in `api_key`. | Already handled — `agent.py` passes an async callable that returns the bearer token. |
| `401 Unauthorized — audience is incorrect (https://ai.azure.com)` | Token requested for the wrong scope (e.g. `cognitiveservices.azure.com`). | Already handled — scope is `https://ai.azure.com/.default`. |
| `400 — api-version query parameter is not allowed when using /v1 path` | Using `AzureOpenAIResponsesClient` which appends `?api-version=...`. | Already handled — we use raw `AsyncOpenAI` with `base_url`. |
| `400 — Invalid value: ''. Supported values are: 'message', 'reasoning', ...` | Using `OpenAIResponsesClient` from the framework — bug in input formatting. | Already handled — bypassed via direct `AsyncOpenAI.responses.create`. |
| `AzureCliCredential.get_token failed` | `az` CLI not signed in or signed into the wrong tenant. | `az login --tenant <tenantId>`; verify with `az account show`. |
| Teams says "couldn't reach the bot" but agent logs are clean | DevTunnel host process isn't running. | Restart `devtunnel host a365-draft-dodger`. URL stays the same. |
| `a365 publish` fails with "manifest version already published" | You changed the agent without bumping the manifest version. | Bump `version` in `deployment script/manifest/manifest.json` and `appPackage/manifest.json`. |
| `WARNING: Microsoft Agent 365 (or your telemetry config) is not initialized` | Observability isn't wired up (Phase 2B). | Harmless for local runs. See observability section. |

---

## What's intentionally not here

- **Azure Container Apps deployment** — deferred. The `deploy.ps1` script is staged but unused. If the demo grows beyond a laptop, run it.
- **MCP tools** (Mail/Calendar/Knowledge/Me) — declined during the interview. Adding them would require re-introducing `ChatAgent` (which means hitting the framework's Responses API bug again) or wiring tool-calling manually into `responses.create`.
- **Notifications** — declined. Agent is reactive only.
- **Multi-turn conversation memory** — each turn is independent. The Responses API supports thread state via `previous_response_id` if needed later.
- **Rate limiting / cost guards** — none. Each draft costs one Responses API call.

---

## Versioning & dependencies

- Python 3.12 (see `.python-version`).
- `uv` for env management. `uv.lock` is committed.
- Pinned: `agent-framework-core==1.0.0b260130` (kept in deps even though we don't use ChatAgent — `host_agent_server.py` and other framework infrastructure still uses it).
- Model: `gpt-5.4-nano` on Foundry. Reasoning model — uses Responses API, not Chat Completions. Do not swap to Chat Completions models without also swapping the SDK call shape.

---

## Commits so far

- `7761d65` — scaffold project, framework files, deployment scripts, manifest templates, tests.
- `f2028c9` — wire `agent.py` to the Foundry Responses API for gpt-5.4-nano.
- `609293e` — add live draft runner with 5 spectrum cases.
