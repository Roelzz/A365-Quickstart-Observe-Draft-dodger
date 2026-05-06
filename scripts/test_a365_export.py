"""Standalone test of the Microsoft Agent 365 OTel exporter.

Bypasses the agent + DevTunnel + Bot Framework. Loads a real OtelWrite token
from /tmp/otelwrite_token.json (populated by `observability.py` the first
time it serves a real Copilot turn while OBSERVABILITY_DEBUG=true), wires up
`Agent365ExporterOptions` with a sync resolver that returns it, creates a
proper `InvokeAgentScope` → `InferenceScope` → `OutputScope` triple — the
shape the admin.cloud.microsoft Activity tab actually renders — and
force-flushes.

Run iteratively without needing any Copilot turn. Token is valid until its
`exp` claim (~1h after the originating turn).

    uv run python scripts/test_a365_export.py
"""

from __future__ import annotations

import json
import logging
import os
import sys
import uuid
from pathlib import Path

from dotenv import load_dotenv

REPO_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(REPO_ROOT / ".env")
sys.path.insert(0, str(REPO_ROOT))  # so we can `import token_cache, observability`

logging.basicConfig(level=logging.DEBUG, format="%(levelname)s:%(name)s:%(message)s")

TOKEN_FILE = Path("/tmp/otelwrite_token.json")
if not TOKEN_FILE.exists():
    print(
        f"\n❌ {TOKEN_FILE} not found.\n"
        "   Send one Copilot turn to a running Draft Dodger agent (with\n"
        "   ENABLE_A365_OBSERVABILITY_EXPORTER=true and OBSERVABILITY_DEBUG=true)\n"
        "   to populate it, then re-run this script.",
        file=sys.stderr,
    )
    sys.exit(2)

data = json.loads(TOKEN_FILE.read_text())
TOKEN = data["token"]
AGENT_ID = data["agent_id"]
TENANT_ID = data["tenant_id"]
CLAIMS = data["claims"]

print(f"\n=== loaded token from {TOKEN_FILE} ===")
print(f"  tenant: {TENANT_ID}")
print(f"  agent:  {AGENT_ID}\n")

from microsoft_agents_a365.observability.core import (
    AgentDetails,
    CallerDetails,
    Channel,
    InferenceCallDetails,
    InferenceOperationType,
    InferenceScope,
    InvokeAgentScope,
    InvokeAgentScopeDetails,
    OutputScope,
    Request,
    ServiceEndpoint,
    UserDetails,
    get_tracer_provider,
)
from microsoft_agents_a365.observability.core.models.response import Response


# Override the cache so observability.py's resolver returns our captured token
# instead of looking for a fresh per-turn token (which doesn't exist offline).
import token_cache as _tc
_tc.cache_agentic_token(TENANT_ID, AGENT_ID, TOKEN)

from observability import init_observability

init_observability()

print("=== creating InvokeAgentScope → InferenceScope → OutputScope triple ===\n")

agent_details = AgentDetails(
    agent_id=AGENT_ID,
    agent_name="Draft Dodger",
    agent_description="Email risk advisor",
    agentic_user_id=AGENT_ID,
    agentic_user_email=os.getenv("AGENT365OBSERVABILITY__AGENTICUSEREMAIL")
    or f"agent-{AGENT_ID}@agent365.local",
    agent_blueprint_id=os.getenv("AGENT365OBSERVABILITY__AGENTBLUEPRINTID") or AGENT_ID,
    tenant_id=TENANT_ID,
    provider_name="azure-openai",
)
caller_details = CallerDetails(
    user_details=UserDetails(
        user_id="test-user",
        user_name="Test User",
        user_email="test-user@contoso.com",
        user_client_ip="127.0.0.1",
    ),
)
test_message = "Hi Bob, just circling back since I haven't heard anything in 6 days. Per my last email, the deadline was Friday."
request = Request(
    content=test_message,
    session_id=f"test-session-{uuid.uuid4()}",
    conversation_id=f"test-conversation-{uuid.uuid4()}",
    channel=Channel(name="msteams"),
)
scope_details = InvokeAgentScopeDetails(endpoint=ServiceEndpoint(hostname="localhost", port=3978))

with InvokeAgentScope.start(request, scope_details, agent_details, caller_details) as invoke_scope:
    inference_details = InferenceCallDetails(
        operationName=InferenceOperationType.CHAT,
        model=os.getenv("AZURE_OPENAI_DEPLOYMENT", "gpt-5.4-nano"),
        providerName="azure-openai",
        inputTokens=42,
        outputTokens=21,
        finishReasons=["stop"],
    )
    with InferenceScope.start(request, inference_details, agent_details) as inference:
        inference.record_input_messages([test_message])
        synthetic_output = "TONE DOWN — verdict 78% confidence (test span)"
        inference.record_input_tokens(42)
        inference.record_output_tokens(21)
        inference.record_output_messages([synthetic_output])

    # Required for Activity-tab rendering: `gen_ai.output.messages` must be
    # present on the InvokeAgentScope parent span.
    invoke_scope.record_response(synthetic_output)

    with OutputScope.start(request, Response(messages=synthetic_output), agent_details):
        pass

print("\n=== force-flushing tracer provider ===\n")
provider = get_tracer_provider()
flushed = provider.force_flush(timeout_millis=15000)
print(f"\nforce_flush returned: {flushed}")
print(
    "Look above for `HTTP 200 success on attempt N. Response: {\"partialSuccess\":{\"rejectedSpans\":0,...}}`\n"
    "If you see that, the InvokeAgent/Inference/Output triple landed cleanly. Refresh\n"
    "admin.cloud.microsoft → Agents → Draft Dodger → Activity in 1–3 minutes."
)
