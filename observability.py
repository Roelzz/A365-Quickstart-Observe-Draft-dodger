# Copyright (c) Microsoft. All rights reserved.

"""
Observability bootstrap for Draft Dodger.

Two roles:

1. Initialize Microsoft Agent 365 observability (`configure(...)`) so that
   span enrichers, exporters, and trace processors are wired up. Three
   backends are supported, picked at startup based on env vars:

   - **A365 first-party telemetry** (`Agent365ExporterOptions`) when
     `ENABLE_A365_OBSERVABILITY_EXPORTER=true`. Spans flow into A365's own
     pipeline and surface in the Microsoft 365 admin center under
     Agents → <agent> → Activity. Requires a working agentic-user token,
     which `host_agent_server.py` caches per turn via `cache_agentic_token`
     after exchanging the inbound JWT for an
     `Agent365.Observability.OtelWrite` scope token.
   - **OTLP / Spectra** (`SpectraExporterOptions`) when
     `OTEL_EXPORTER_OTLP_ENDPOINT` is set. Spans flow to a local Aspire
     Dashboard, Jaeger, or any OTel collector.
   - **Console fallback** when neither is set. The SDK still emits spans;
     they pretty-print to stdout. Useful for local dev demos.

2. Auto-instrument the OpenAI Python SDK (`OpenAIInstrumentor`) so that any
   `chat.completions` calls produce spans automatically. Note: as of
   `opentelemetry-instrumentation-openai-v2==2.4b0` this does NOT cover
   the Responses API, so the agent also wraps `responses.create` in a
   manual span (`draft_dodger.analyse`) in `agent.py`.
"""

from __future__ import annotations

import logging
import os
from typing import Optional

from microsoft_agents_a365.observability.core import (
    Agent365ExporterOptions,
    SpectraExporterOptions,
    configure,
    is_configured,
)
from opentelemetry.instrumentation.openai_v2 import OpenAIInstrumentor

from token_cache import get_cached_agentic_token

logger = logging.getLogger(__name__)

_initialized = False


async def _agentic_user_token_resolver(agent_id: str, tenant_id: str) -> Optional[str]:
    """Async token resolver for A365 first-party telemetry.

    The Microsoft Agent 365 observability SDK calls this on every export
    attempt with `(agent_id, tenant_id)`. We read the agentic-user token
    that `host_agent_server.py` caches at the start of every turn (token
    is for scope `api://9b975845-…/Agent365.Observability.OtelWrite`).

    Returns None if the cache is empty (e.g. agent has not yet handled
    a turn). The exporter retries on the next turn — no spans are lost
    permanently, the first cold-start turn just doesn't export until
    the cache is populated.
    """
    token = get_cached_agentic_token(tenant_id, agent_id)
    if not token:
        logger.debug(
            "No cached agentic-user token for agent=%s tenant=%s — "
            "first turn will populate the cache",
            agent_id,
            tenant_id,
        )
    return token


def init_observability(
    service_name: str = "draft-dodger",
    service_namespace: str = "a365.demo",
) -> bool:
    """Initialize A365 observability + OpenAI auto-instrumentation. Idempotent."""
    global _initialized
    if _initialized:
        return True

    enable_a365 = os.getenv("ENABLE_A365_OBSERVABILITY_EXPORTER", "false").lower() == "true"
    otlp_endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
    appinsights_conn = os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING")

    exporter_options = None
    backend_label = "console (stdout fallback — spans printed to terminal, no remote backend)"

    if enable_a365:
        cluster = os.getenv("AGENT365OBSERVABILITY__CLUSTERCATEGORY", "prod")
        exporter_options = Agent365ExporterOptions(
            cluster_category=cluster,
            token_resolver=_agentic_user_token_resolver,
        )
        backend_label = (
            f"A365 first-party telemetry (cluster={cluster}) — "
            "spans flow to admin.microsoft.com → Agents → <agent> → Activity"
        )
    elif otlp_endpoint:
        exporter_options = SpectraExporterOptions(
            endpoint=otlp_endpoint,
            protocol="grpc",
            insecure=otlp_endpoint.startswith("http://"),
        )
        backend_label = f"OTLP/Spectra exporter at {otlp_endpoint}"
    elif appinsights_conn:
        # azure-monitor-opentelemetry-exporter is in deps but not wired here
        # (the A365 SDK doesn't take an AppInsights option directly). If/when
        # needed, set up a separate AzureMonitorTraceExporter on the tracer
        # provider after configure(). For now we fall through to console.
        backend_label = (
            "App Insights connection string set but not wired in this build "
            "— falling back to console exporter"
        )

    logger.info("Observability backend: %s", backend_label)

    try:
        configure(
            service_name=service_name,
            service_namespace=service_namespace,
            exporter_options=exporter_options,
        )
        if is_configured():
            logger.info("A365 observability configured")
        else:
            logger.warning(
                "A365 observability configure() returned without error but is_configured()=False"
            )
    except Exception as e:
        logger.warning("A365 observability configure() failed (continuing without it): %s", e)

    try:
        OpenAIInstrumentor().instrument()
        logger.info("OpenAI SDK auto-instrumentation enabled (covers chat.completions only — Responses API uses manual span)")
    except Exception as e:
        logger.warning("OpenAI instrumentor failed: %s", e)

    _initialized = True
    return True
