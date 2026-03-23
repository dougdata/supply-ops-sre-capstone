from __future__ import annotations

import os

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor


def setup_otel(app, engine=None) -> None:
    """
    Minimal OTEL setup via OTLP/HTTP exporter.
    Set OTEL_EXPORTER_OTLP_ENDPOINT to your collector endpoint, e.g. http://otel-collector:4318
    """
    service_name = os.getenv("SERVICE_NAME", "supply-api")
    endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
    if not endpoint:
        # Telemetry optional for local dev; skip if not configured
        return

    resource = Resource.create({"service.name": service_name})
    provider = TracerProvider(resource=resource)
    processor = BatchSpanProcessor(OTLPSpanExporter(endpoint=endpoint))
    provider.add_span_processor(processor)
    trace.set_tracer_provider(provider)

    FastAPIInstrumentor.instrument_app(app)

    if engine is not None:
        SQLAlchemyInstrumentor().instrument(engine=engine)