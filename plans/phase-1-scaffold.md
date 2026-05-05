# Plan: Draft Dodger — A365 Email Risk Advisor Agent

## Context

Build a new Microsoft Agent 365 agent called **Draft Dodger** that analyses draft emails before they are sent and scores them on passive aggression, emotional temperature, and formality match — flagging risky phrases, suggesting rewrites, and returning a final verdict (SEND / TONE DOWN / DELETE AND WALK AWAY) with a confidence score.

The agent is for a demo. The user wants it running locally first, with deployment + tenant registration deferred to a follow-up phase.

The user referenced `https://github.com/bap-microsoft/a365-demo-tenant-automation` as a source repo, but that repo is gated behind Microsoft EMU SSO and not accessible via WebFetch. The local **`/Users/roelschenk/Downloads/Projects/A365_Hello_World/`** project is the canonical reference and matches the `a365-agent-builder` skill exactly — the same framework files (`agent_interface.py`, `host_agent_server.py`, `start_with_generic_host.py`, `local_authentication_options.py`, `token_cache.py`), the same `deployment script/` folder with `deploy.ps1` / `initialize_a365_config.ps1` / `get_mos_token.py` / manifest templates / Teams app package. So the plan uses Hello World as the template; if the GitHub repo has anything extra needed for tenant registration, we can pull it in during Phase 2.

## Decisions (locked in via interview)

| Variable | Value |
|---|---|
| `agent_name` | `draft-dodger` |
| `agent_display_name` | `Draft Dodger` |
| `agent_class_name` | `DraftDodgerAgent` |
| `agent_short_description` | `Email risk advisor that protects you from professional regret` |
| `agent_full_description` | `Analyses draft emails before you send them. Scores passive aggression, emotional temperature, and formality match; flags risky phrases with rewrites; gives a verdict — SEND, TONE DOWN, or DELETE AND WALK AWAY — with a confidence score.` |
| `project_dir` | `/Users/roelschenk/Downloads/Projects/A365_Draft_Dodger` (already exists, empty) |
| `mcp_servers` | **None** — chat-only, no Mail/Calendar/Knowledge/Me. `ToolingManifest.json` ships with an empty `mcpServers: []` array. |
| `notifications` | **None** — agent only responds to chat messages. Omit `NotificationTypes` import and the `handle_agent_notification_activity` method from `agent.py`. |
| `azure_openai_model` | `gpt-5.4-nano` (user-specified — interpreted from "Gpt 55.4 nano"). ⚠️ **Risk**: the skill explicitly lists gpt-5.4-pro as unsupported (reasoning model, uses Responses API not Chat Completions). gpt-5.4-nano may be in the same family and fail at runtime with `"Model does not support Chat Completions"`. If that happens, fall back to `gpt-4.1`. The deployment name in `.env` is whatever the user has provisioned in their Azure OpenAI account. |
| `azure_region` | `westeurope` (default) |
| `dev_tunnel_id` | `a365-draft-dodger` |
| `scope` | **Phase 1 only** — scaffold + local verification. Deploy + Teams publish deferred. |

## Approach

Execute the `a365-agent-builder` skill's **Phase 1** end-to-end, customised with the values above. The skill is canonical — every step is already mapped to a concrete command or file template. No deviation needed.

The agent's system prompt is the user-supplied Draft Dodger spec, wrapped with the skill's standard prompt-injection guardrails (rules 1–8) appended underneath. The user's prompt has its own "never moralize, never lecture, be on the user's side" rules — those stay in the user-facing block; the security rules are appended verbatim from the skill template so the agent can't be talked into ignoring its tone-analysis role.

## Critical files to create

All paths under `/Users/roelschenk/Downloads/Projects/A365_Draft_Dodger/`:

**Copied verbatim from `A365_Hello_World/`:**
- `agent_interface.py`
- `host_agent_server.py`
- `start_with_generic_host.py` (then edit the import to `from agent import DraftDodgerAgent` and pass `DraftDodgerAgent` to `create_and_run_host`)
- `local_authentication_options.py`
- `token_cache.py`
- `.env.example`
- `Dockerfile`
- `.dockerignore`
- `deployment script/deploy.ps1`
- `deployment script/initialize_a365_config.ps1`
- `deployment script/get_mos_token.py`
- `deployment script/demo-tenant.config.json.example`
- `deployment script/manifest/color.png`
- `deployment script/manifest/outline.png`

**Generated from skill templates with Draft Dodger values:**
- `agent.py` — class `DraftDodgerAgent(AgentInterface)`. `AGENT_PROMPT` = user's Draft Dodger spec + skill's 8 security rules. **No `NotificationTypes` import. No `handle_agent_notification_activity` method.**
- `pyproject.toml` — name `draft-dodger`, full description as above, dependency list verbatim from skill Step 4.
- `agent.json` — `name: "Draft Dodger"`, `devTunnelId: "a365-draft-dodger"`.
- `ToolingManifest.json` — `{ "mcpServers": [] }` (no MCP tools selected).
- `.gitignore` — verbatim from skill Step 5.
- `tests/test_main.py` — verbatim from skill Step 8 (token_cache + agent_interface tests).
- `README.md` — skill Step 9 template with Draft Dodger name + description.
- `deployment script/manifest/manifest.json` — Teams agentic manifest with `<BLUEPRINT_ID>` and `<AGENTIC_TEMPLATE_ID>` placeholders (filled in Phase 2).
- `deployment script/manifest/agenticUserTemplateManifest.json` — same.
- `deployment script/appPackage/manifest.json` — Teams v1.17 manifest with Draft Dodger name + description.

## Execution steps

1. Reuse the existing empty `A365_Draft_Dodger/` directory (no `mkdir` needed; it's already there).
2. `cd` in, `git init`, `uv init --name draft-dodger --no-readme`, delete the auto-generated `hello.py`.
3. Copy the 5 framework Python files + `.env.example` + `Dockerfile` + `.dockerignore` from Hello World.
4. Write `agent.py` with the Draft Dodger prompt (skill template, **notifications=neither** branch, no NotificationTypes import, no notification handler method).
5. Patch `start_with_generic_host.py` to import and pass `DraftDodgerAgent`.
6. Write `pyproject.toml`, `agent.json`, `ToolingManifest.json` (empty mcpServers), `.gitignore`, `README.md`.
7. Create `deployment script/` tree, copy ps1/py/json/png files, write the three manifest JSON files with placeholders.
8. Create `tests/test_main.py`.
9. `uv sync`, then `uv export --no-hashes 2>/dev/null > requirements.txt`.
10. `uv run pytest tests/ -v` — all tests pass.
11. Initial commit: `feat: scaffold Draft Dodger agent project`.

## Verification (end-to-end, Phase 1)

After scaffold:

```bash
cd /Users/roelschenk/Downloads/Projects/A365_Draft_Dodger
cp .env.example .env
# user fills in AZURE_OPENAI_ENDPOINT and AZURE_OPENAI_DEPLOYMENT (= "gpt-5.4-nano" or whatever the deployment name is)
uv run python start_with_generic_host.py
```

Then in a second terminal:
```bash
curl http://localhost:3978/api/health   # expect 200 OK
```

Send a real test draft via the host's `/api/messages` endpoint (or via the dev tunnel + Teams Toolkit if the user has it wired up). Expected: agent returns a structured response with three numeric scores, flagged phrases with rewrites, a verdict, and a confidence %.

If the agent errors with `"Model does not support Chat Completions"`, switch the `AZURE_OPENAI_DEPLOYMENT` value to a `gpt-4.1` deployment and retry — this is the documented fallback for reasoning-family models.

`uv run pytest tests/ -v` should pass all 8 tests (token cache CRUD + agent inheritance checks).

## Deferred to Phase 2 (not in this plan)

- Azure Container Apps deployment (`deploy.ps1`)
- A365 config init (`initialize_a365_config.ps1`)
- `a365 setup all` (device-code auth, blueprint creation)
- `a365 publish` to Teams (device-code auth)
- Developer Portal + Admin Center activation
- End-to-end test in Teams

User will confirm before Phase 2 starts. All the deployment scripts and manifest templates are already scaffolded by Phase 1, so Phase 2 is purely orchestration + tenant config (`tenantId`, `subscriptionId`, admin UPN, `customClientAppId`).
