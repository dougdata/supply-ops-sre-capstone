from __future__ import annotations

import os
import time
from typing import List

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from prometheus_client import generate_latest, CONTENT_TYPE_LATEST
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .models import EventIn, IngestResponse, EntityStatusOut, EntityHistoryItem
from .metrics import HTTP_REQUESTS, HTTP_LATENCY, EVENTS_INGESTED, DB_ERRORS
from .db import db_healthcheck


router = APIRouter()

SERVICE = os.getenv("SERVICE_NAME", "supply-api")


def get_db(request: Request) -> Session:
    return request.app.state.SessionLocal()


@router.get("/health")
def health() -> dict:
    return {"status": "ok"}


@router.get("/ready")
def ready(db: Session = Depends(get_db)) -> dict:
    try:
        db_healthcheck(db)
        return {"status": "ready"}
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@router.get("/metrics")
def metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@router.post("/events", response_model=IngestResponse)
def ingest_event(event: EventIn, request: Request, db: Session = Depends(get_db)) -> IngestResponse:
    start = time.time()
    route = "/events"
    method = "POST"

    try:
        # Insert into raw_events (idempotency on event_id)
        db.execute(
            text("""
                INSERT INTO raw_events(event_id, event_type, entity_type, entity_id, occurred_at, source, payload)
                VALUES (:event_id, :event_type, :entity_type, :entity_id, :occurred_at, :source, :payload::jsonb)
            """),
            {
                "event_id": str(event.event_id),
                "event_type": event.event_type.value,
                "entity_type": event.entity_type.value,
                "entity_id": event.entity_id,
                "occurred_at": event.occurred_at,
                "source": event.source,
                "payload": __import__("json").dumps(event.payload),
            },
        )

        # Enqueue (even if raw event is new)
        db.execute(
            text("""
                INSERT INTO event_queue(event_id, status)
                VALUES (:event_id, 'PENDING')
            """),
            {"event_id": str(event.event_id)},
        )
        db.commit()

        EVENTS_INGESTED.labels(SERVICE, event.event_type.value, "accepted").inc()
        status_code = 202
        return IngestResponse(
            accepted=True,
            duplicate=False,
            queued=True,
            message="accepted and queued",
            event_id=event.event_id,
        )

    except IntegrityError:
        db.rollback()
        # Duplicate event_id in raw_events. Treat as idempotent success.
        EVENTS_INGESTED.labels(SERVICE, event.event_type.value, "duplicate").inc()
        status_code = 200
        return IngestResponse(
            accepted=True,
            duplicate=True,
            queued=False,
            message="duplicate event_id; treated as idempotent",
            event_id=event.event_id,
        )

    except Exception:
        db.rollback()
        DB_ERRORS.labels(SERVICE, "ingest_event").inc()
        EVENTS_INGESTED.labels(SERVICE, event.event_type.value, "rejected").inc()
        status_code = 500
        raise

    finally:
        elapsed = time.time() - start
        HTTP_LATENCY.labels(SERVICE, route, method).observe(elapsed)
        HTTP_REQUESTS.labels(SERVICE, method, route, str(status_code)).inc()


@router.get("/entities/{entity_type}/{entity_id}", response_model=EntityStatusOut)
def get_entity_status(entity_type: str, entity_id: str, db: Session = Depends(get_db)) -> EntityStatusOut:
    row = db.execute(
        text("""
            SELECT entity_type, entity_id, last_event_id, last_event_type,
                   last_occurred_at, last_updated_at, exception_count, last_exception_reason
            FROM entity_status
            WHERE entity_type = :entity_type AND entity_id = :entity_id
        """),
        {"entity_type": entity_type, "entity_id": entity_id},
    ).mappings().first()

    if not row:
        raise HTTPException(status_code=404, detail="entity not found")
    return EntityStatusOut(**row)


@router.get("/entities/{entity_type}/{entity_id}/history", response_model=List[EntityHistoryItem])
def get_entity_history(entity_type: str, entity_id: str, limit: int = 50, db: Session = Depends(get_db)):
    limit = max(1, min(limit, 200))
    rows = db.execute(
        text("""
            SELECT event_id, event_type, occurred_at, recorded_at
            FROM entity_status_history
            WHERE entity_type = :entity_type AND entity_id = :entity_id
            ORDER BY occurred_at DESC
            LIMIT :limit
        """),
        {"entity_type": entity_type, "entity_id": entity_id, "limit": limit},
    ).mappings().all()

    return [EntityHistoryItem(**r) for r in rows]


@router.post("/simulate/latency")
def simulate_latency(ms: int = 0) -> dict:
    """
    Demo helper: inject server-side latency.
    """
    ms = max(0, min(ms, 5000))
    time.sleep(ms / 1000.0)
    return {"slept_ms": ms}