from __future__ import annotations

import os
import socket
import time
import logging
from datetime import datetime, timezone
from typing import Optional

from prometheus_client import start_http_server
from sqlalchemy import text
from sqlalchemy.orm import Session
from opentelemetry import trace

from .logger import configure_logging
from .telemetry import setup_otel
from .db import load_db_config, create_db_engine, create_session_factory
from .metrics import EVENTS_PROCESSED, PROCESSING_TIME, WORKER_BACKLOG, WORKER_LAG_P95

log = logging.getLogger("supply-worker")

SERVICE = os.getenv("SERVICE_NAME", "supply-worker")
WORKER_ID = os.getenv("WORKER_ID", socket.gethostname())

POLL_INTERVAL_SEC = float(os.getenv("WORKER_POLL_INTERVAL_SEC", "1.0"))
LOCK_TTL_SEC = int(os.getenv("WORKER_LOCK_TTL_SEC", "60"))
MAX_ATTEMPTS = int(os.getenv("WORKER_MAX_ATTEMPTS", "5"))

METRICS_PORT = int(os.getenv("WORKER_METRICS_PORT", "9102"))


def _update_backlog_metrics(db: Session) -> None:
    pending = db.execute(
        text("SELECT COUNT(*) FROM event_queue WHERE status='PENDING' AND available_at <= now()")
    ).scalar_one()
    WORKER_BACKLOG.labels(SERVICE).set(pending)

    # Simple p95-ish lag estimate using percentile_cont on occurred_at of pending events.
    # For MVP: if no rows, set 0.
    lag_row = db.execute(
        text("""
          SELECT
            percentile_cont(0.95) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (now() - r.occurred_at))) AS p95_lag
          FROM event_queue q
          JOIN raw_events r ON r.event_id = q.event_id
          WHERE q.status='PENDING' AND q.available_at <= now()
        """)
    ).scalar_one()
    WORKER_LAG_P95.labels(SERVICE).set(float(lag_row or 0.0))


def _claim_one(db: Session) -> Optional[dict]:
    """
    Atomically claim one pending event using SKIP LOCKED.
    Returns mapping row with queue_id + event fields, or None.
    """
    row = db.execute(
        text("""
        WITH candidate AS (
          SELECT q.queue_id
          FROM event_queue q
          WHERE q.status='PENDING'
            AND q.available_at <= now()
          ORDER BY q.queue_id
          FOR UPDATE SKIP LOCKED
          LIMIT 1
        )
        UPDATE event_queue q
        SET status='PROCESSING',
            attempts = q.attempts + 1,
            locked_by = :locked_by,
            locked_at = now(),
            updated_at = now()
        FROM candidate
        WHERE q.queue_id = candidate.queue_id
        RETURNING q.queue_id, q.event_id, q.attempts
        """),
        {"locked_by": WORKER_ID},
    ).mappings().first()

    if not row:
        return None

    event = db.execute(
        text("""
          SELECT event_id, event_type, entity_type, entity_id, occurred_at, source, payload
          FROM raw_events
          WHERE event_id = :event_id
        """),
        {"event_id": str(row["event_id"])},
    ).mappings().first()

    if not event:
        return None

    return {"queue": dict(row), "event": dict(event)}


def _mark_done(db: Session, queue_id: int) -> None:
    db.execute(
        text("""
          UPDATE event_queue
          SET status='DONE', updated_at=now()
          WHERE queue_id=:queue_id
        """),
        {"queue_id": queue_id},
    )


def _mark_failed(db: Session, queue_id: int, event_id: str, error_type: str, error_msg: str) -> None:
    db.execute(
        text("""
          INSERT INTO processing_errors(event_id, error_type, error_message)
          VALUES (:event_id, :error_type, :error_message)
        """),
        {"event_id": event_id, "error_type": error_type, "error_message": error_msg[:2000]},
    )

    # Retry until MAX_ATTEMPTS; then mark FAILED permanently.
    db.execute(
        text("""
          UPDATE event_queue
          SET status = CASE WHEN attempts >= :max_attempts THEN 'FAILED' ELSE 'PENDING' END,
              available_at = CASE WHEN attempts >= :max_attempts THEN now() ELSE now() + interval '10 seconds' END,
              last_error = :last_error,
              updated_at = now()
          WHERE queue_id=:queue_id
        """),
        {"queue_id": queue_id, "max_attempts": MAX_ATTEMPTS, "last_error": error_msg[:500]},
    )


def _apply_business_rules(db: Session, event: dict) -> None:
    """
    Minimal processing:
    - update entity_status current record
    - append history
    - track EXCEPTION counts
    """
    entity_type = event["entity_type"]
    entity_id = event["entity_id"]
    event_id = str(event["event_id"])
    event_type = event["event_type"]
    occurred_at = event["occurred_at"]

    is_exception = (event_type == "EXCEPTION")
    exception_reason = None
    payload = event.get("payload") or {}
    if isinstance(payload, str):
        # depending on driver, payload might already be json; keep MVP-safe
        exception_reason = None
    else:
        exception_reason = payload.get("reason") if is_exception else None

    # Upsert current status
    db.execute(
        text("""
        INSERT INTO entity_status(
          entity_type, entity_id, last_event_id, last_event_type, last_occurred_at,
          last_updated_at, exception_count, last_exception_reason
        )
        VALUES (:entity_type, :entity_id, :event_id, :event_type, :occurred_at, now(),
                CASE WHEN :is_exception THEN 1 ELSE 0 END,
                CASE WHEN :is_exception THEN :exception_reason ELSE NULL END)
        ON CONFLICT (entity_type, entity_id) DO UPDATE
        SET last_event_id = EXCLUDED.last_event_id,
            last_event_type = EXCLUDED.last_event_type,
            last_occurred_at = EXCLUDED.last_occurred_at,
            last_updated_at = now(),
            exception_count = entity_status.exception_count + CASE WHEN :is_exception THEN 1 ELSE 0 END,
            last_exception_reason = CASE WHEN :is_exception THEN :exception_reason ELSE entity_status.last_exception_reason END
        """),
        {
            "entity_type": entity_type,
            "entity_id": entity_id,
            "event_id": event_id,
            "event_type": event_type,
            "occurred_at": occurred_at,
            "is_exception": is_exception,
            "exception_reason": exception_reason,
        },
    )

    # Append history
    db.execute(
        text("""
          INSERT INTO entity_status_history(entity_type, entity_id, event_id, event_type, occurred_at)
          VALUES (:entity_type, :entity_id, :event_id, :event_type, :occurred_at)
        """),
        {
            "entity_type": entity_type,
            "entity_id": entity_id,
            "event_id": event_id,
            "event_type": event_type,
            "occurred_at": occurred_at,
        },
    )


def main() -> None:
    configure_logging()
    setup_otel()
    tracer = trace.get_tracer(__name__)

    # Expose worker metrics
    start_http_server(METRICS_PORT)
    log.info(f"metrics server started on :{METRICS_PORT}")

    cfg = load_db_config()
    engine = create_db_engine(cfg)
    SessionLocal = create_session_factory(engine)

    while True:
        try:
            with SessionLocal() as db:
                _update_backlog_metrics(db)

                claimed = _claim_one(db)
                if not claimed:
                    db.commit()
                    time.sleep(POLL_INTERVAL_SEC)
                    continue

                queue = claimed["queue"]
                event = claimed["event"]
                db.commit()

            # Process outside of transaction, but write results in a transaction.
            event_type = str(event["event_type"])
            start = time.time()

            with tracer.start_as_current_span("process_event") as span:
                span.set_attribute("event.type", event_type)
                span.set_attribute("entity.type", str(event["entity_type"]))
                span.set_attribute("entity.id", str(event["entity_id"]))

                try:
                    with SessionLocal() as db2:
                        _apply_business_rules(db2, event)
                        _mark_done(db2, int(queue["queue_id"]))
                        db2.commit()

                    elapsed = time.time() - start
                    PROCESSING_TIME.labels(SERVICE, event_type).observe(elapsed)
                    EVENTS_PROCESSED.labels(SERVICE, event_type, "success").inc()

                except Exception as e:
                    elapsed = time.time() - start
                    PROCESSING_TIME.labels(SERVICE, event_type).observe(elapsed)
                    EVENTS_PROCESSED.labels(SERVICE, event_type, "failed").inc()
                    log.exception("event processing failed")
                    with SessionLocal() as db3:
                        _mark_failed(
                            db3,
                            int(queue["queue_id"]),
                            str(event["event_id"]),
                            type(e).__name__,
                            str(e),
                        )
                        db3.commit()

        except Exception:
            log.exception("worker loop error")
            time.sleep(2.0)


if __name__ == "__main__":
    main()