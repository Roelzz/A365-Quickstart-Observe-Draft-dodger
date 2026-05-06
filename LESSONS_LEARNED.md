# Lessons Learned — Draft Dodger on Agent 365

A categorized post-mortem of every non-obvious thing we hit while building this agent. Each entry: **Symptom · Root cause · Fix · Why it matters**. If you're following [`SETUP.md`](SETUP.md) and something looks broken, this is the document to skim first.

> Context: build was on macOS (Darwin 25), Azure AI Foundry project, gpt-5.4-nano deployment. Tenant + tunnel + blueprint identifiers redacted — substitute your own. SDK versions cited are the ones that bit us; newer versions may have moved.

---

## 1. Foundry Responses API endpoint quirks

### 1.1 Wrong audience → 401 Unauthorized

- **Symptom:** `401 - {"message":"Unauthorized. Access token is missing, invalid, audience is incorrect (https://ai.azure.com), or have expired."}`
- **Root cause:** Token was minted for audience `https://cognitiveservices.azure.com/.default` (the classic Azure OpenAI audience). Foundry projects endpoints use a different audience.
- **Fix:** Request the token with `https://ai.azure.com/.default` instead. In `agent.py`:
  ```python
  cred.get_token("https://ai.azure.com/.default")
  ```
- **Why it matters:** This is invisible in any docs you'll find by Googling "Azure OpenAI authentication" — those all say `cognitiveservices`. Foundry uses a different audience and the error message is the only hint.

### 1.2 `base_url` must end in `/openai/v1/`

- **Symptom:** Random 404s and routing failures when constructing the SDK client.
- **Root cause:** The SDK appends `/responses`, `/chat/completions`, etc., onto whatever `base_url` you pass. If your `base_url` doesn't end in `/openai/v1/`, the URL it builds is wrong.
- **Fix:** Set the env var precisely:
  ```
  AZURE_OPENAI_BASE_URL=https://<resource>.services.ai.azure.com/api/projects/<project>/openai/v1/
  ```
- **Why it matters:** It looks like the URL we'd write by hand, but the trailing slash and the literal `/openai/v1/` segment matter.

### 1.3 The `/v1/` path rejects `?api-version=…`

- **Symptom:** `400 - api-version query parameter is not allowed when using /v1 path`
- **Root cause:** `AzureOpenAIResponsesClient` (from `agent_framework.azure`) hardcodes `?api-version=preview` on every request. The Foundry `/v1/` path is OpenAI-compatible, not classic Azure-OpenAI, and rejects that query parameter.
- **Fix:** Don't use `AzureOpenAIResponsesClient`. Use raw `openai.AsyncOpenAI` with `base_url` instead. See lesson 2.1.
- **Why it matters:** This kills the most "obvious" SDK choice. You can spend an hour wondering why the SDK is broken before realizing the path itself is incompatible with the SDK's URL builder.

---

## 2. `agent_framework` SDK bugs we hit (build `1.0.0b260130`)

### 2.1 `OpenAIResponsesClient` sends malformed `input[1]`

- **Symptom:** `400 - {"error":{"message":"Invalid value: ''. Supported values are: 'apply_patch_call', 'message', 'reasoning', ..."}, "param":"input[1]"}`
- **Root cause:** The framework client serializes the system prompt as a separate `input[0]` and the user message as `input[1]`, but `input[1]`'s `type` field is empty in the request body. The Responses API expects every input array item to have a non-empty `type` (`"message"`, `"reasoning"`, etc.).
- **Fix:** Bypass `agent_framework.ChatAgent` entirely. Call `openai.AsyncOpenAI.responses.create(...)` directly:
  ```python
  response = await client.responses.create(
      model=deployment,
      instructions=AGENT_PROMPT,
      input=user_message,
  )
  ```
  We lose `ChatAgent`'s middleware/tool plumbing, but we explicitly chose no MCP servers, so nothing of value was lost. The `AgentInterface` contract (`process_user_message`, `cleanup`, `initialize`) didn't change, so `host_agent_server.py` doesn't notice.
- **Why it matters:** The framework's "Responses API" client is silently broken against actual Foundry endpoints. Direct SDK usage is the workaround. When the framework fixes it, swap back.

### 2.2 `AzureOpenAIResponsesClient` hardcodes `api_version=preview`

See lesson 1.3. Same root: framework code is built for the deployment-style URL pattern, not the OpenAI-compatible `/v1/` style.

---

## 3. OpenAI Python SDK 2.34.0 credential gotcha

- **Symptom:** `OpenAIError: Missing credentials. Please pass an api_key, workload_identity, admin_api_key, or set the OPENAI_API_KEY or OPENAI_ADMIN_KEY environment variable.`
- **Root cause:** When you build an `AsyncOpenAI` client with `base_url` (the OpenAI-compatible path mode), the underlying base class enforces `api_key` at constructor time, even if you also pass `azure_ad_token_provider`. The Azure-aware logic that bridges `azure_ad_token_provider` → `api_key` doesn't kick in until later.
- **Fix:** Pass an **async callable** as `api_key` that returns the bearer token. The SDK calls this on every request to refresh the token:
  ```python
  cred = AzureCliCredential()

  async def get_bearer_token() -> str:
      return cred.get_token("https://ai.azure.com/.default").token

  client = AsyncOpenAI(base_url=base_url, api_key=get_bearer_token)
  ```
  Synchronous callables fail with `TypeError: object str can't be used in 'await' expression` — the SDK awaits the result.
- **Why it matters:** This is the working pattern for Entra ID auth against the `/v1/` Foundry path. None of the obvious approaches (`workload_identity`, `azure_ad_token`, `azure_ad_token_provider` alone, dummy `api_key="x"`) will all work cleanly on every code path; the async callable is the cleanest.

---

## 4. a365 CLI 1.1.109 endpoint-registration bug

- **Symptom:** `ERROR: Failed to call create endpoint. Status: BadRequest` with `"errors":{"CallbackUri":["Callback URI is required"],"AgentIdentityBlueprintId":["Agent Identity Blueprint ID is required"]}`
- **Root cause:** The CLI's local debug logs show the values are populated (`Endpoint Name: <your-tunnel>-…`, `Agent Blueprint ID: <YOUR_BLUEPRINT_ID>`), but the JSON it sends to the A365 backend uses old field names (`AppId` instead of `AgentIdentityBlueprintId`, no `CallbackUri` at all). The server-side schema was renamed; the old client wasn't updated.
- **Fix:** Update the CLI:
  ```bash
  dotnet tool update -g Microsoft.Agents.A365.DevTools.Cli
  ```
  Verified working in 1.1.174.
- **Why it matters:** The `a365 setup all` wizard runs to "Setup completed with errors" — easy to miss. Always check the *Failed Steps* block at the end. The CLI even tells you which sub-command to retry: `a365 setup blueprint --endpoint-only`.

---

## 5. a365 CLI 1.1.174 behavioral changes

### 5.1 `--update-endpoint` requires `--m365`

- **Symptom:** `Skipping messaging endpoint update — this command only applies to M365 agents. Pass --m365 to opt in, or configure the endpoint manually in the Teams Developer Portal.`
- **Fix:** Add the flag:
  ```bash
  a365 setup blueprint --m365 --update-endpoint "https://<tunnel>-3978.<region>.devtunnels.ms/api/messages"
  ```
- **Why it matters:** Default behavior changed between 1.1.109 and 1.1.174. Without `--m365`, the command no-ops silently. Spent 5 minutes wondering why "successful" runs didn't actually register anything.

### 5.2 `a365 publish` no longer auto-uploads to Teams

- **Old behavior (≤ 1.1.109):** Pushed straight to Teams Developer Portal.
- **New behavior (1.1.174+):** Generates `manifest/manifest.zip` at the project root using the CLI's own templates, then prints `To publish: https://admin.microsoft.com → Agents → All agents → Upload custom agent`.
- **Implication:** Manual upload via the Microsoft 365 admin center is now the publish step.
- **Gotcha:** The CLI's templates **overwrite** anything you'd customized in `deployment script/manifest/manifest.json`. The new `manifest/manifest.json` (project root) ships with a generic placeholder description. Edit it and re-zip:
  ```bash
  cd manifest
  # edit manifest.json — fix description, accentColor, any other fields
  rm manifest.zip
  zip manifest.zip manifest.json agenticUserTemplateManifest.json color.png outline.png
  ```

---

## 6. Required Microsoft Graph permissions for the custom client app

The `a365 setup` requirements check fails noisily if your custom client app is missing any of these. All six are **delegated** scopes on Microsoft Graph (`00000003-0000-0000-c000-000000000000`):

| Scope | Well-known ID |
|---|---|
| `User.Read` | `e1fe6dd8-ba31-4d61-89e7-88639da4683d` |
| `Application.ReadWrite.All` | `bdfbf15f-ee85-4955-8675-146e8e5296b5` |
| `AgentIdentityBlueprint.ReadWrite.All` | `4fd490fc-1467-48eb-8a4c-421597ab0402` |
| `AgentIdentityBlueprint.UpdateAuthProperties.All` | `6f677aa9-25af-49a5-8a1d-628dc7f0d009` |
| `DelegatedPermissionGrant.ReadWrite.All` | `41ce6ca6-6826-4807-84f1-1c82854f7ee5` |
| `Directory.Read.All` | `06da0dbc-49e2-44d2-8312-53f166ab848a` |

All require **admin consent**. `deployment script/create_app_registration.ps1` does the lookup-by-name + add + admin-consent automatically, but if admin-consent fails (e.g. you're not Global Admin via CLI), grant it manually in the Entra portal.

---

## 7. Where the agent shows up in the user's UI

- **It does not appear in the Teams app catalog.**
- **It appears in Microsoft 365 Copilot → Agents.**

The agent is registered as an "AI teammate" / agent identity, which lives in the Copilot agents registry, not as a personal-scope Teams bot. URLs:

- https://m365.cloud.microsoft → Copilot icon → **Agents**
- Inside Teams: click **Copilot** in the left rail → **Agents** tab

If your test user can't find it: check the M365 admin center → Agents → your agent → **Activated for** must include them. Default may be empty (only the publishing admin has access).

---

## 8. Bot Framework 502 retry storm during onboarding

- **Symptom:** First few minutes after install in Copilot, your agent log shows ~70 inbound `POST /api/messages` requests, almost all returning 500. Eventually one returns 202 and things settle down.
- **Root cause:** Bot Framework's Skype connector returns 502 Bad Gateway on **outbound** replies during the initial `agentOnboarding` flow. The flow:
  1. Copilot → BF → POST /api/messages (your agent gets the activity)
  2. Your agent processes, calls Foundry, gets a result
  3. Your agent tries to POST the reply to `https://smba.trafficmanager.net/.../activities/...`
  4. **smba.trafficmanager.net returns 502 Bad Gateway** during onboarding
  5. Your agent's reply attempt fails → it returns 500 to BF for the original POST
  6. BF retries the same activity → loop
- **What works:** It self-heals. After ~2 minutes, BF onboarding completes and 502s stop. Subsequent turns succeed in seconds.
- **What it looks like in the wild:** From the user's POV in Copilot: "thinking…" for 1–2 minutes, maybe an error toast, then the response shows up. Resending the prompt usually gets a clean turn.
- **Why it matters:** Easy to mistake the 500-storm for a real bug in your agent. It's not — it's BF infrastructure flakiness during initial agent-identity provisioning.

---

## 9. Manifest path mismatches

### 9.1 `demo-tenant.config.json` lives at the project root, not under `deployment script/`

- The example template (`demo-tenant.config.json.example`) is in `deployment script/`, but `initialize_a365_config.ps1` reads `demo-tenant.config.json` from the **project root**.
- `create_app_registration.ps1` was originally written to write the file under `deployment script/` — fixed to write to the project root. Watch for this if you fork the script.

### 9.2 Two `manifest/` folders that mean different things

- `deployment script/manifest/` — our checked-in template, source-of-truth for description / accent color / app metadata. Edited by hand.
- `manifest/` (project root) — created by `a365 publish`. Uses the CLI's own templates. Overwrites your customizations every run. Treat as build output; you must re-edit and re-zip after each `a365 publish`.

---

## 10. DevTunnel persistence model

- **Tunnel ID + URL are persistent.** Created once with `devtunnel create <name> -a`. Survives reboots, sleeps, network changes. URL is deterministic: `https://<name>-<port>.<region>.devtunnels.ms`. Default expiration is 30 days but auto-extends on use.
- **Host process is NOT persistent.** `devtunnel host <name>` is a foreground process. Closing the terminal, putting the laptop to sleep with no charger, losing Wi-Fi → host process dies → tunnel URL still resolves but returns 502 until you re-run `devtunnel host`.
- **Anonymous access (`-a`) is required.** Bot Framework / M365 Copilot don't carry DevTunnel auth cookies; without `-a`, every request from MS gets a 401 from DevTunnel before it reaches your agent.

---

## 11. OpenAI OTel auto-instrumentation gap (Responses API)

- `opentelemetry-instrumentation-openai-v2==2.4b0` only wraps `openai.resources.chat.completions` (search the package source for `"openai.resources.chat.completions"` — that's the only patched module).
- The Responses API (`openai.resources.responses.responses.AsyncResponses.create`) is **not** patched.
- **Result:** No spans for your `client.responses.create(...)` calls — the auto-instrumentor silently does nothing.
- **Workaround:** A manual span around the call. We do this in `agent.py:process_user_message`, naming the span `draft_dodger.analyse` and setting `gen_ai.*` semantic conventions:
  ```python
  with _tracer.start_as_current_span("draft_dodger.analyse") as span:
      span.set_attribute("gen_ai.system", "azure_openai")
      span.set_attribute("gen_ai.operation.name", "responses")
      span.set_attribute("gen_ai.request.model", deployment)
      ...
      response = await client.responses.create(...)
      span.set_attribute("gen_ai.usage.input_tokens", response.usage.input_tokens)
      ...
  ```
- **Why it matters:** Without the manual span, you have no traces — even though the SDK appears instrumented. Watch the `OpenAIInstrumentor` release notes; once it adds Responses-API support the manual span becomes redundant and can be deleted.

---

## 12. Microsoft Agent 365 observability SDK API

- The `microsoft_agents_a365.observability.core` package exposes a function called `configure(...)`, **not** `setup_observability(...)` (which is what naming intuition suggests, and what some older docs imply).
- Signature roughly:
  ```python
  configure(
      service_name="draft-dodger",
      service_namespace="a365.demo",
      exporter_options=SpectraExporterOptions(endpoint=..., protocol="grpc") | Agent365ExporterOptions(...) | None,
  )
  ```
- **Without exporter options or a token resolver**, the SDK falls back to a **console exporter** that pretty-prints span JSON to stdout. Useful for local dev — you literally see every span in your agent log — but the spans go nowhere persistent.
- For real backends, three options:
  - **A365 first-party telemetry** (the native path, recommended for demos): `Agent365ExporterOptions(token_resolver=<async callable>)`. The token resolver receives `(agent_id, tenant_id)` and must return an agentic-user bearer token for scope `api://9b975845-388f-4429-889e-eab1ef63949c/Agent365.Observability.OtelWrite`. **Critical:** the token resolver must be `async`. The token itself comes from a JWT exchange that happens per turn in `host_agent_server.py:_cache_observability_token` — the exchanged token is stored in the in-memory `token_cache.py` keyed by `(tenant_id, agent_id)`. Spans surface in **admin.microsoft.com → Agents → &lt;agent&gt; → Activity tab**.
  - Local Aspire Dashboard / Jaeger / otelcol → `SpectraExporterOptions(endpoint="http://localhost:4317", protocol="grpc", insecure=True)`.
  - App Insights → not directly supported by `Agent365ExporterOptions`. Wire `AzureMonitorTraceExporter` separately on the tracer provider after `configure()`.
- **Cold-start gotcha (A365 native):** the first turn after agent startup may not export — the token cache is empty until `host_agent_server.py` exchanges and caches the token, which happens inside the turn. The SDK retries on subsequent turns; lost first-turn spans are usually acceptable for demos. If they aren't, prime the cache up front.
- **Idempotent configure:** the SDK logs `a365 observability already configured. Ignoring repeated configure() call.` if `configure()` is called twice. Benign.

---

## 13. AADSTS65001 on `Agent365.Observability.OtelWrite` despite a grant existing

- **Symptom:** With `ENABLE_A365_OBSERVABILITY_EXPORTER=true`, every Copilot turn produces this in the agent log:
  ```
  Failed to acquire agentic user token for agent_app_instance_id <agentic-user>
    and agentic_user_id <user>, {'error': 'invalid_grant',
    'error_description': "AADSTS65001: The user or administrator has not consented
    to use the application with ID '<agentic-user>' named '<agent name>'."}
  ```
  …yet `az rest GET /v1.0/oauth2PermissionGrants` shows a grant *does* exist for `clientId=<agentic-user>`, `resourceId=<A365 Observability SP>`, `scope=" Agent365.Observability.OtelWrite"`, `consentType=AllPrincipals`. So the grant is there, but the token exchange acts as if it isn't.
- **Root cause:** The grant's `scope` field has a **leading space**: `" Agent365.Observability.OtelWrite"` instead of `"Agent365.Observability.OtelWrite"`. The Microsoft Agents SDK's agentic-user authentication uses `grant_type: user_fic` (custom federated-identity-credential flow at `microsoft_agents/authentication/msal/msal_auth.py:396`), which does **strict scope matching** against the persisted grant. Entra normally tolerates whitespace in the space-separated `scope` field, but the `user_fic` flow does not — it surfaces the mismatch as a missing-consent error.
- **Where the leading space comes from:** `a365 setup blueprint` (verified on CLI 1.1.174) emits the inheritable-permission grant with a leading-space-then-scope-name when the grant has only one scope. Looks like a list-join defect.
- **Fix:** PATCH the grant to remove the leading space. One REST call:
  ```bash
  # Look up the grant ID for your tenant
  CLIENT_SP=$(az ad sp list --filter "appId eq '<your-agentic-user-app-id>'" --query '[0].id' -o tsv)
  GRANT_ID=$(az rest --method GET \
    --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?\$filter=clientId eq '$CLIENT_SP'" \
    --query 'value[?contains(scope,`Agent365.Observability.OtelWrite`)].id | [0]' -o tsv)

  az rest --method PATCH \
    --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$GRANT_ID" \
    --body '{"scope": "Agent365.Observability.OtelWrite"}' \
    --headers "Content-Type=application/json"
  ```
  Restart the agent. The next Copilot turn should log `✅ Token exchange successful` without an upstream `Failed to acquire agentic user token` line.
- **If PATCH doesn't take, delete + recreate cleanly:**
  ```bash
  az rest --method DELETE --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$GRANT_ID"
  az rest --method POST --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" \
    --body "{\"clientId\":\"$CLIENT_SP\",\"resourceId\":\"<A365-Observability-SP-id>\",\"scope\":\"Agent365.Observability.OtelWrite\",\"consentType\":\"AllPrincipals\"}" \
    --headers "Content-Type=application/json"
  ```
- **Why the obvious workarounds fail:**
  - `https://login.microsoftonline.com/<tenant>/v2.0/adminconsent?client_id=<agentic-user>&...` returns **AADSTS500113 — No reply address registered for the application** because the agentic-user app is auto-provisioned by A365 with no redirect URIs. Do not try to add one — modifying the auto-managed app is risky.
  - The M365 admin center → Agents → &lt;agent&gt; → **Permissions** tab does not surface this consent (at least not in the build we tested) — there's nothing actionable there for the OtelWrite scope.
- **Why it matters:** Without this fix, **native A365 observability silently no-ops on every Copilot turn**. Spans are created locally (the `draft_dodger.analyse` span is built fine) but never reach `https://agent365.svc.cloud.microsoft/observability/tenants/.../otlp/agents/.../traces` because the exporter has no bearer token to attach. There is no UI complaint; the Activity tab just stays empty.
- **Diagnostic flag in this repo:** Set `OBSERVABILITY_DEBUG=true` in `.env` and restart the agent. `observability.py:_enable_a365_exporter_debug_logging` will raise the log level on `microsoft_agents_a365.observability` and `microsoft_agents.authentication.msal` so the `AADSTS65001` and the per-export HTTP attempts become visible in the agent log.

---

## 14. Demo-day operations

- **The agent's stdout is your demo's best evidence.** Every M365 Copilot turn produces:
  - `INFO:aiohttp.access:127.0.0.1 [...] "POST /api/messages HTTP/1.1" 202 ...` — proves the HTTP request landed
  - A multi-line JSON span block with `gen_ai.usage.input_tokens` / `output_tokens` — proves the Foundry call happened with real token counts
  Tail your agent log in a side terminal during demos. When someone says "is this really running on your laptop?" you point at the log and watch lines appear in real time.
- **Restart procedure for the agent (preserves the tunnel):**
  ```bash
  pkill -f start_with_generic_host
  uv run python start_with_generic_host.py
  ```
  The tunnel is bound to the tunnel ID, not the local agent. A365 doesn't need any reconfiguration.
- **Restart procedure for the dev tunnel host:**
  ```bash
  pkill -f "devtunnel host"
  devtunnel host <your-tunnel-name>
  ```
  URL persists — A365 doesn't notice.
- **Prevent laptop sleep mid-demo (macOS):**
  ```bash
  caffeinate -dimsu
  ```
- **Tunnel host is the brittle bit.** Network changes, accidental Ctrl-C, or laptop suspend kills it. Always have it in its own terminal tab so you can see if it died.

---

## Quick-glance error → lesson map

| You see this | Read | TL;DR |
|---|---|---|
| `401 - audience is incorrect (https://ai.azure.com)` | §1.1 | Use scope `https://ai.azure.com/.default`, not `cognitiveservices`. |
| `400 - api-version query parameter is not allowed when using /v1 path` | §1.3, §2.2 | Don't use `AzureOpenAIResponsesClient`; use raw `openai.AsyncOpenAI`. |
| `400 - Invalid value: ''. Supported values are: 'message', 'reasoning'…` | §2.1 | Bypass `ChatAgent`; call `responses.create` directly. |
| `OpenAIError: Missing credentials` (with `base_url` + token provider set) | §3 | Pass an async callable as `api_key`. |
| `400 - "CallbackUri": ["Callback URI is required"]` | §4 | Update a365 CLI to ≥ 1.1.174. |
| `Skipping messaging endpoint update — this command only applies to M365 agents` | §5.1 | Add `--m365` to `setup blueprint --update-endpoint`. |
| Agent description shows generic placeholder text in M365 admin center | §5.2 | Edit `manifest/manifest.json` after `a365 publish`, re-zip. |
| `[CLIENT_APP_VALIDATION_FAILED] Client app is missing required API permissions` | §6 | Run `create_app_registration.ps1 -Force` (adds all six Graph perms + admin consent). |
| Agent doesn't appear in Teams app catalog | §7 | Look in M365 Copilot → Agents instead. Also check "Activated for" in admin center. |
| Lots of 500s on `POST /api/messages` right after install | §8 | BF onboarding 502 storm — self-heals in ~2 min. |
| `ERROR: demo-tenant.config.json not found` | §9.1 | The actual file lives at project root, not under `deployment script/`. |
| No spans appearing despite `OpenAIInstrumentor().instrument()` | §11 | Auto-instrumentor doesn't cover Responses API. Use a manual span. |
| `setup_observability` import fails | §12 | The function is named `configure(...)`. |
| `AADSTS65001 — user or administrator has not consented` on every Copilot turn (with `ENABLE_A365_OBSERVABILITY_EXPORTER=true`) | §13 | The `oauth2PermissionGrant` for OtelWrite has a leading space in `scope`. PATCH it to remove the space. |
| `AADSTS500113 — No reply address registered` when opening admin-consent URL | §13 | The agentic-user app has no redirect URIs and you can't safely add one. Fix the grant via Graph API instead. |
