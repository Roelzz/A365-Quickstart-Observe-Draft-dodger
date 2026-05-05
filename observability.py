# Copyright (c) Microsoft. All rights reserved.

"""
Observability bootstrap for Draft Dodger.

Two roles:

1. Initialize Microsoft Agent 365 observability (`configure(...)`) so that
   span enrichers, exporters, and trace processors are wired up.
2. Auto-instrument the OpenAI Python SDK (`OpenAIInstrumentor`) so that the
   raw `AsyncOpenAI.responses.create` calls in `agent.py` produce spans —
   this is what `agent_framework`'s instrumentor would have given us if we
   hadn't bypassed `ChatAgent` for the Foundry Responses workaround.

Graceful no-op behaviour: if neither an OTLP endpoint nor an A365 token resolver
is wired up, the SDK still configures itself with an in-memory tracer so spans
are emitted (just not exported anywhere). Pointing `OTEL_EXPORTER_OTLP_ENDPOINT`
at an OTLP receiver (Aspire Dashboard, Jaeger, etc.) makes the spans visible.
"""

from __future__ import annotations

import logging
import os
from typing import Optional

from microsoft_agents_a365.observability.core import (
    SpectraExporterOptions,
    configure,
    is_configured,
)
from opentelemetry.instrumentation.openai_v2 import OpenAIInstrumentor

logger = logging.getLogger(__name__)

_initialized = False


def init_observability(
    service_name: str = "draft-dodger",
    service_namespace: str = "a365.demo",
) -> bool:
    """Initialize A365 observability + OpenAI auto-instrumentation. Idempotent."""
    global _initialized
    if _initialized:
        return True

    otlp_endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
    appinsights_conn = os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING")

    exporter_options: Optional[SpectraExporterOptions] = None
    if otlp_endpoint:
        exporter_options = SpectraExporterOptions(
            endpoint=otlp_endpoint,
            protocol="grpc",
            insecure=otlp_endpoint.startswith("http://"),
        )
        logger.info(f"OTLP exporter pointed at {otlp_endpoint}")
    elif appinsights_conn:
        logger.info("App Insights connection string present (cloud telemetry)")
    else:
        logger.info("No OTLP endpoint / App Insights — spans created but not exported")

    try:
        configure(
            service_name=service_name,
            service_namespace=service_namespace,
            exporter_options=exporter_options,
        )
        if is_configured():
            logger.info("A365 observability configured")
        else:
            logger.warning("A365 observability configure() returned without error but is_configured()=False")
    except Exception as e:
        logger.warning(f"A365 observability configure() failed (continuing without it): {e}")

    try:
        OpenAIInstrumentor().instrument()
        logger.info("OpenAI SDK auto-instrumentation enabled")
    except Exception as e:
        logger.warning(f"OpenAI instrumentor failed: {e}")

    _initialized = True
    return True
