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
    get_tracer_provider,
    is_configured,
)
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.openai_v2 import OpenAIInstrumentor
from opentelemetry.sdk.trace.export import (
    BatchSpanProcessor,
    ConsoleSpanExporter,
    SimpleSpanProcessor,
)

from token_cache import get_cached_agentic_token

logger = logging.getLogger(__name__)

_initialized = False


def _enable_a365_exporter_debug_logging() -> None:
    """When `OBSERVABILITY_DEBUG=true`, raise the A365 exporter's log level so
    its per-export HTTP activity (POST URL, status codes, retry attempts) is
    visible in the agent log. Useful for diagnosing token/consent issues, 401s
    from the ingest endpoint, and silent batch drops.

    The relevant logger is `microsoft_agents_a365.observability.core.exporters.agent365_exporter`.
    """
    if os.getenv("OBSERVABILITY_DEBUG", "false").lower() == "true":
        for name in (
            "microsoft_agents_a365.observability",
            "microsoft_agents.authentication.msal",
        ):
            logging.getLogger(name).setLevel(logging.DEBUG)
        # `logging.basicConfig(level=INFO)` (in agent.py) sets the *root logger*
        # AND the *root handler* threshold to INFO, both of which can drop DEBUG
        # records even when a child logger is set to DEBUG. Lower both levels so
        # DEBUG records actually reach stdout.
        logging.getLogger().setLevel(logging.DEBUG)
        for h in logging.getLogger().handlers:
            h.setLevel(logging.DEBUG)
        logger.info(
            "OBSERVABILITY_DEBUG=true — DEBUG logging enabled on A365 exporter "
            "and MSAL auth (expect verbose per-export and per-token-exchange logs)"
        )


def _attach_otlp_mirror() -> None:
    """When `OTEL_EXPORTER_OTLP_ENDPOINT` is set, attach a second
    `BatchSpanProcessor` + `OTLPSpanExporter` to the active tracer provider so
    every span is also pushed to a local OTLP receiver (Aspire Dashboard,
    Jaeger, otelcol, etc.) **in addition to** the primary A365 exporter.

    Decoupled from A365 ingest success/failure — the demo surface keeps working
    even if the native path hits a downstream issue. Independent of the
    `ConsoleSpanExporter` mirror that fires under `OBSERVABILITY_DEBUG=true`.

    Aspire Dashboard run-it-yourself one-liner:

        podman run --rm -d --name aspire-dashboard \\
          -p 18888:18888 -p 4317:18889 \\
          -e DASHBOARD__OTLP__AUTHMODE=Unsecured \\
          mcr.microsoft.com/dotnet/aspire-dashboard:latest

    Then set `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317` in `.env` and
    open http://localhost:18888.
    """
    endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
    if not endpoint:
        return
    try:
        provider = get_tracer_provider()
        if provider is None or not hasattr(provider, "add_span_processor"):
            logger.warning("Cannot attach OTLP mirror — tracer provider has no add_span_processor")
            return
        provider.add_span_processor(
            BatchSpanProcessor(
                OTLPSpanExporter(
                    endpoint=endpoint,
                    insecure=endpoint.startswith("http://"),
                )
            )
        )
        logger.info("OTLP mirror attached at %s — every span will also push to that endpoint", endpoint)
    except Exception as e:
        logger.warning("Failed to attach OTLP mirror: %s", e)


def _attach_console_span_mirror() -> None:
    """When `OBSERVABILITY_DEBUG=true`, attach an extra `SimpleSpanProcessor` +
    `ConsoleSpanExporter` to the active tracer provider so every span is also
    pretty-printed to stdout the moment its `with` block ends — independently
    of whether the configured A365 exporter succeeds or fails.

    Use only as a diagnostic. Adds noise; do not enable in production demos.
    """
    if os.getenv("OBSERVABILITY_DEBUG", "false").lower() != "true":
        return
    try:
        provider = get_tracer_provider()
        if provider is None or not hasattr(provider, "add_span_processor"):
            logger.warning("Cannot mirror spans to console — tracer provider has no add_span_processor")
            return
        provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
        logger.info("OBSERVABILITY_DEBUG mirror: ConsoleSpanExporter attached — every span will also print to stdout")
    except Exception as e:
        logger.warning("Failed to attach console span mirror: %s", e)


def _agentic_user_token_resolver(agent_id: str, tenant_id: str) -> Optional[str]:
    """Synchronous token resolver for A365 first-party telemetry.

    ⚠️ Despite `Agent365ExporterOptions.token_resolver`'s type hint claiming
    `Callable[[str, str], Awaitable[Optional[str]]]`, the SDK's actual call
    site at `microsoft_agents_a365/observability/core/exporters/agent365_exporter.py:129`
    is `token = self._token_resolver(agent_id, tenant_id)` — *without `await`*.
    Making this `async def` produces a coroutine object that gets stringified
    into the bearer header (`Authorization: Bearer <coroutine object …>`), and
    the A365 ingest endpoint then rejects every export with HTTP 400
    `EndpointInvalid: Tenant id  is invalid` (its downstream rendering of
    "your token is unparseable"). Keep this sync.

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
        logger.warning(
            "No cached agentic-user token for agent=%s tenant=%s — span will export without bearer",
            agent_id,
            tenant_id,
        )
        return None

    if os.getenv("OBSERVABILITY_DEBUG", "false").lower() == "true":
        # One-time-per-process diagnostic: decode the JWT (no signature check) to expose
        # the `tid` and `aud` claims, AND persist the token to /tmp so a standalone
        # test script can iterate the exporter without needing further Copilot turns.
        global _claims_logged
        try:
            _claims_logged
        except NameError:
            _claims_logged = False
        if not _claims_logged:
            try:
                import base64, json as _json
                payload_b64 = token.split(".")[1]
                payload_b64 += "=" * (-len(payload_b64) % 4)
                claims = _json.loads(base64.urlsafe_b64decode(payload_b64))
                interesting = {k: claims.get(k) for k in ("tid", "aud", "iss", "appid", "sub", "scp", "roles", "agent_id", "agentic_user_id", "exp")}
                logger.warning("OBSERVABILITY_DEBUG: agentic-user JWT claims = %s", interesting)
                # Persist token + identity for offline iteration
                with open("/tmp/otelwrite_token.json", "w") as f:
                    _json.dump(
                        {
                            "token": token,
                            "agent_id": agent_id,
                            "tenant_id": tenant_id,
                            "claims": interesting,
                        },
                        f,
                    )
                logger.warning("OBSERVABILITY_DEBUG: token persisted to /tmp/otelwrite_token.json (valid until exp=%s)", interesting.get("exp"))
            except Exception as e:
                logger.warning("OBSERVABILITY_DEBUG: failed to decode JWT for inspection: %s", e)
            _claims_logged = True

    return token


_claims_logged = False  # one-shot guard


def init_observability(
    service_name: str = "draft-dodger",
    service_namespace: str = "a365.demo",
) -> bool:
    """Initialize A365 observability + OpenAI auto-instrumentation. Idempotent."""
    global _initialized
    if _initialized:
        return True

    _enable_a365_exporter_debug_logging()

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

    _attach_otlp_mirror()
    _attach_console_span_mirror()

    _initialized = True
    return True
