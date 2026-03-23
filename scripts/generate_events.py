#!/usr/bin/env python3
"""
generate_events.py — Synthetic supply chain event generator for demo/testing.

Inserts realistic Chick-fil-A supply chain events into the database so the
worker has something to process and Grafana shows live data.

Usage:
    # Normal steady flow (good for showing healthy system)
    python generate_events.py --rate 2 --duration 300

    # Burst mode (good for showing backlog building, lag spike)
    python generate_events.py --rate 20 --duration 60

    # Stress mode (good for showing SLO breach)
    python generate_events.py --rate 50 --duration 30 --no-worker

    # One-shot: insert N events and exit
    python generate_events.py --count 100

Requirements:
    pip install psycopg sqlalchemy
"""

from __future__ import annotations

import argparse
import os
import random
import time
import uuid
from datetime import datetime, timezone, timedelta

from sqlalchemy import create_engine, text

# -------------------------------------------------------
# Event catalog — realistic CFA supply chain events
# -------------------------------------------------------
EVENT_CATALOG = [
    # Distribution center events
    {"event_type": "order.received",       "entity_type": "order",    "source": "dc-atlanta"},
    {"event_type": "order.picked",         "entity_type": "order",    "source": "dc-atlanta"},
    {"event_type": "order.packed",         "entity_type": "order",    "source": "dc-atlanta"},
    {"event_type": "order.dispatched",     "entity_type": "order",    "source": "dc-atlanta"},
    {"event_type": "order.delivered",      "entity_type": "order",    "source": "dc-dallas"},
    # Inventory events
    {"event_type": "inventory.adjusted",   "entity_type": "sku",      "source": "wms-primary"},
    {"event_type": "inventory.replenished","entity_type": "sku",      "source": "wms-primary"},
    {"event_type": "inventory.low",        "entity_type": "sku",      "source": "wms-primary"},
    {"event_type": "inventory.counted",    "entity_type": "sku",      "source": "wms-primary"},
    # Shipment events
    {"event_type": "shipment.created",     "entity_type": "shipment", "source": "tms-primary"},
    {"event_type": "shipment.in_transit",  "entity_type": "shipment", "source": "tms-primary"},
    {"event_type": "shipment.delayed",     "entity_type": "shipment", "source": "tms-primary"},
    {"event_type": "shipment.delivered",   "entity_type": "shipment", "source": "tms-primary"},
    # Production events (Bay Center Foods)
    {"event_type": "production.started",   "entity_type": "batch",    "source": "bcf-plant-1"},
    {"event_type": "production.completed", "entity_type": "batch",    "source": "bcf-plant-1"},
    {"event_type": "production.qc_passed", "entity_type": "batch",    "source": "bcf-plant-1"},
    # Restaurant fulfillment events
    {"event_type": "fulfillment.requested","entity_type": "restaurant","source": "restaurant-ops"},
    {"event_type": "fulfillment.scheduled","entity_type": "restaurant","source": "restaurant-ops"},
    {"event_type": "fulfillment.completed","entity_type": "restaurant","source": "restaurant-ops"},
]

# Entity ID pools — realistic-looking IDs
RESTAURANT_IDS = [f"CFA-{n:05d}" for n in random.sample(range(1000, 9999), 50)]
SKU_IDS        = [f"SKU-{s}" for s in ["BREAST-FZ", "NUGGETS-FZ", "SANDWICH-BUN", "WAFFLE-FRY",
                                         "SAUCE-POLY", "SAUCE-BBQ", "LEMONADE-MIX", "SWEET-TEA"]]
ORDER_IDS      = None   # generated fresh per event
BATCH_IDS      = [f"BATCH-{uuid.uuid4().hex[:8].upper()}" for _ in range(20)]
SHIPMENT_IDS   = [f"SHIP-{uuid.uuid4().hex[:8].upper()}" for _ in range(30)]


def _make_entity_id(entity_type: str) -> str:
    if entity_type == "restaurant":
        return random.choice(RESTAURANT_IDS)
    if entity_type == "sku":
        return random.choice(SKU_IDS)
    if entity_type == "batch":
        return random.choice(BATCH_IDS)
    if entity_type == "shipment":
        return random.choice(SHIPMENT_IDS)
    # order — always unique
    return f"ORD-{uuid.uuid4().hex[:10].upper()}"


def _make_payload(event_type: str, entity_type: str, entity_id: str) -> dict:
    """Generate realistic JSONB payload per event type."""
    base = {"entity_id": entity_id, "generated_by": "event-generator"}
    if entity_type == "order":
        base["restaurant_id"] = random.choice(RESTAURANT_IDS)
        base["line_items"]    = random.randint(1, 12)
        base["weight_lbs"]    = round(random.uniform(10, 500), 1)
    elif entity_type == "sku":
        base["sku_id"]        = entity_id
        base["quantity"]      = random.randint(1, 5000)
        base["unit"]          = random.choice(["cases", "lbs", "each"])
    elif entity_type == "shipment":
        base["carrier"]       = random.choice(["CFA-Fleet", "FedEx-Freight", "UPS-Supply"])
        base["origin_dc"]     = random.choice(["ATL-DC1", "DAL-DC2", "CLT-DC3"])
        base["dest_restaurant"]= random.choice(RESTAURANT_IDS)
    elif entity_type == "batch":
        base["product"]       = random.choice(["Chicken Breast", "Nuggets", "Strips"])
        base["yield_lbs"]     = round(random.uniform(500, 5000), 1)
        base["facility"]      = "BCF-Plant-1"
    return base


def insert_event(conn, lag_seconds: int = 0) -> str:
    """Insert one raw_event + queue entry. Returns event_id."""
    template = random.choice(EVENT_CATALOG)
    event_id  = str(uuid.uuid4())
    entity_id = _make_entity_id(template["entity_type"])

    # Optionally backdate occurred_at to simulate lag
    occurred_at = datetime.now(timezone.utc) - timedelta(seconds=lag_seconds)

    import json
    payload = json.dumps(_make_payload(template["event_type"],
                                        template["entity_type"], entity_id))

    conn.execute(text("""
        INSERT INTO raw_events
            (event_id, event_type, entity_type, entity_id,
             occurred_at, source, payload, received_at)
        VALUES
            (:event_id, :event_type, :entity_type, :entity_id,
             :occurred_at, :source, :payload::jsonb, now())
    """), {
        "event_id":    event_id,
        "event_type":  template["event_type"],
        "entity_type": template["entity_type"],
        "entity_id":   entity_id,
        "occurred_at": occurred_at,
        "source":      template["source"],
        "payload":     payload,
    })

    conn.execute(text("""
        INSERT INTO event_queue (event_id, status, available_at)
        VALUES (:event_id, 'PENDING', now())
    """), {"event_id": event_id})

    return event_id


def run(args):
    db_url = args.db_url or os.environ.get("DATABASE_URL")
    if not db_url:
        raise SystemExit(
            "ERROR: set --db-url or DATABASE_URL env var\n"
            "Example: postgresql+psycopg://supplyadmin:PASSWORD@RDS_ENDPOINT:5432/supply"
        )

    engine = create_engine(db_url, pool_pre_ping=True)
    print(f"Connected to database.")

    inserted   = 0
    start_time = time.time()
    target     = args.count if args.count else None
    duration   = args.duration if not args.count else None

    print(f"Mode: {'count=' + str(target) if target else 'rate=' + str(args.rate) + '/s for ' + str(duration) + 's'}")
    print(f"Lag simulation: {args.lag}s per event" if args.lag else "No lag simulation")
    print("Press Ctrl+C to stop early.\n")

    try:
        while True:
            batch_start = time.time()

            with engine.begin() as conn:
                # Insert one batch per tick
                batch_size = max(1, args.rate)
                for _ in range(batch_size):
                    insert_event(conn, lag_seconds=args.lag)
                    inserted += 1
                    if target and inserted >= target:
                        break

            elapsed = time.time() - start_time
            rate_actual = inserted / elapsed if elapsed > 0 else 0
            pending_msg = ""

            print(f"\r  inserted={inserted:,}  elapsed={elapsed:.0f}s  "
                  f"rate={rate_actual:.1f}/s", end="", flush=True)

            # Exit conditions
            if target and inserted >= target:
                break
            if duration and elapsed >= duration:
                break

            # Sleep to hit target rate (1 batch per second)
            batch_elapsed = time.time() - batch_start
            sleep_time = max(0, 1.0 - batch_elapsed)
            time.sleep(sleep_time)

    except KeyboardInterrupt:
        print("\nStopped by user.")

    print(f"\n\nDone. Inserted {inserted:,} events in {time.time()-start_time:.1f}s")
    print("Grafana should update within 30s (next Prometheus scrape).")


def main():
    parser = argparse.ArgumentParser(
        description="Generate synthetic supply chain events for demo/testing"
    )
    parser.add_argument(
        "--db-url", default=None,
        help="PostgreSQL connection URL (or set DATABASE_URL env var)"
    )
    parser.add_argument(
        "--rate", type=int, default=2,
        help="Events per second in continuous mode (default: 2)"
    )
    parser.add_argument(
        "--duration", type=int, default=300,
        help="How many seconds to run in continuous mode (default: 300)"
    )
    parser.add_argument(
        "--count", type=int, default=None,
        help="Insert exactly N events then exit (overrides --rate/--duration)"
    )
    parser.add_argument(
        "--lag", type=int, default=0,
        help="Backdate occurred_at by N seconds to simulate processing lag"
    )
    args = parser.parse_args()
    run(args)


if __name__ == "__main__":
    main()
