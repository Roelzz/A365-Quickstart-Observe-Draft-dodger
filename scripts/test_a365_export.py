"""Standalone test of the Microsoft Agent 365 OTel exporter.

Bypasses the agent + DevTunnel + Bot Framework. Loads a real OtelWrite token
from /tmp/otelwrite_token.json (populated by `observability.py` the first
time it serves a real Copilot turn while OBSERVABILITY_DEBUG=true), wires up
`Agent365ExporterOptions` with a sync resolver that returns it, creates a
test span with the right attributes, and force-flushes.

Run iteratively without needing any Copilot turn. Token is valid until its
`exp` claim (~1h after the originating turn).

    uv run python scripts/test_a365_export.py
"""

from __future__ import annotations

import json
import logging
import os
import sys
from pathlib import Path

# Load `.env` so `ENABLE_A365_OBSERVABILITY_EXPORTER=true` reaches the SDK gate.
from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent / ".env")

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
print(f"  agent:  {AGENT_ID}")
print(f"  claims: {CLAIMS}\n")

# Wire up A365 SDK with our captured token
from microsoft_agents_a365.observability.core import (
    Agent365ExporterOptions,
    configure,
    get_tracer,
    get_tracer_provider,
)


def fixed_token_resolver(agent_id: str, tenant_id: str) -> str | None:
    """Sync resolver — returns the captured token regardless of args."""
    return TOKEN


configure(
    service_name="draft-dodger-test",
    service_namespace="a365.demo",
    exporter_options=Agent365ExporterOptions(
        cluster_category="prod",
        token_resolver=fixed_token_resolver,
    ),
)

print("=== creating test span with proper attributes ===\n")
tracer = get_tracer("draft-dodger-test")
with tracer.start_as_current_span("draft_dodger.analyse") as span:
    span.set_attribute("microsoft.tenant.id", TENANT_ID)
    span.set_attribute("gen_ai.agent.id", AGENT_ID)
    span.set_attribute("gen_ai.system", "azure_openai")
    span.set_attribute("gen_ai.operation.name", "chat")
    span.set_attribute("gen_ai.request.model", "gpt-5.4-nano")
    span.set_attribute("gen_ai.request.input.length", 100)
    span.set_attribute("gen_ai.usage.input_tokens", 42)
    span.set_attribute("gen_ai.usage.output_tokens", 21)
    span.set_attribute("gen_ai.response.output.length", 200)

print("\n=== force-flushing tracer provider ===\n")
provider = get_tracer_provider()
flushed = provider.force_flush(timeout_millis=15000)
print(f"\nforce_flush returned: {flushed}")
print(
    "If you saw `HTTP 200 success` above, the export landed at A365.\n"
    "If you saw `HTTP 4xx non-retryable error`, read the response body — that's the next bug."
)
