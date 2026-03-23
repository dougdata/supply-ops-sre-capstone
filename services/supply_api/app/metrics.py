from __future__ import annotations

from prometheus_client import Counter, Histogram, Gauge

HTTP_REQUESTS = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["service", "method", "route", "status"],
)

HTTP_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds",
    ["service", "route", "method"],
    buckets=(0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 0.8, 1.0, 2.0, 5.0),
)

EVENTS_INGESTED = Counter(
    "events_ingested_total",
    "Events ingested",
    ["service", "event_type", "result"],  # result: accepted|duplicate|rejected
)

DB_ERRORS = Counter(
    "db_errors_total",
    "Database errors",
    ["service", "operation"],
)

# Optional: can be updated by an internal job if you want
APP_INFO = Gauge("app_info", "App info", ["service", "version"])