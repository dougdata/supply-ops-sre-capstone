from __future__ import annotations

from prometheus_client import Counter, Histogram, Gauge

SERVICE = "supply-worker"

EVENTS_PROCESSED = Counter(
    "events_processed_total",
    "Events processed by worker",
    ["service", "event_type", "result"],  # result: success|failed
)

PROCESSING_TIME = Histogram(
    "event_processing_seconds",
    "Time to process a single event",
    ["service", "event_type"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.5, 1.0, 2.0),
)

WORKER_BACKLOG = Gauge(
    "supply_worker_backlog",
    "Number of pending events in queue",
    ["service"],
)

WORKER_LAG_P95 = Gauge(
    "supply_worker_lag_p95_seconds",
    "Approx p95 lag (now - occurred_at) for pending items, seconds",
    ["service"],
)