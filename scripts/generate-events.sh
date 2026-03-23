#!/usr/bin/env bash
# generate-events.sh — Run the supply chain event generator inside the cluster.
# RDS is in a private subnet so the generator must run as a Kubernetes job.
#
# Usage:
#   bash scripts/generate-events.sh                    # default: steady mode
#   bash scripts/generate-events.sh steady             # 2 events/sec for 10 min (1200 events)
#   bash scripts/generate-events.sh burst              # 20 events/sec for 60s — shows backlog spike
#   bash scripts/generate-events.sh stress             # 50 events/sec for 30s — triggers SLO breach
#   bash scripts/generate-events.sh load               # 3 events/sec for 30 min — sustained load
#   bash scripts/generate-events.sh count 1000         # insert exactly N events then exit
#   bash scripts/generate-events.sh lag 60             # events backdated 60s — shows p95 lag spike
#
# What each mode demonstrates in the interview:
#   steady  — healthy system, backlog at 0, events processing in real time
#   burst   — backlog briefly spikes then drains, Grafana shows blip
#   stress  — p95 lag rises toward SLO target, error budget starts burning
#   load    — sustained throughput, good for showing the rate chart over time
#   count   — seed the database for a demo then stop
#   lag     — artificially aged events make p95 lag metric spike immediately

set -euo pipefail

MODE="${1:-steady}"
ARG="${2:-}"

NAMESPACE="supply"
JOB_NAME="event-generator"

# Clean up any previous run
kubectl -n "$NAMESPACE" delete pod "$JOB_NAME" \
  --ignore-not-found --wait=false 2>/dev/null

# Set rate/duration/lag based on mode
case "$MODE" in
  steady)
    RATE=2; DURATION=600; LAG=0
    echo "==> Mode: STEADY — 2 events/sec for 10 minutes (~1200 events)"
    echo "    Shows: healthy processing, backlog at 0, green SLO dashboard"
    ;;
  burst)
    RATE=20; DURATION=60; LAG=0
    echo "==> Mode: BURST — 20 events/sec for 60 seconds (~1200 events)"
    echo "    Shows: backlog spike then drain, Grafana blip recovers quickly"
    ;;
  stress)
    RATE=50; DURATION=30; LAG=0
    echo "==> Mode: STRESS — 50 events/sec for 30 seconds (~1500 events)"
    echo "    Shows: worker under pressure, p95 lag may rise toward SLO target"
    ;;
  load)
    RATE=3; DURATION=1800; LAG=0
    echo "==> Mode: LOAD — 3 events/sec for 30 minutes (~5400 events)"
    echo "    Shows: sustained throughput, good for demo event processing rate chart"
    ;;
  count)
    COUNT="${ARG:-1000}"
    RATE=10; DURATION=99999; LAG=0
    echo "==> Mode: COUNT — inserting exactly $COUNT events"
    ;;
  lag)
    LAG="${ARG:-60}"
    RATE=5; DURATION=120; LAG=$LAG
    echo "==> Mode: LAG — 5 events/sec backdated ${LAG}s for 2 minutes"
    echo "    Shows: p95 lag metric spikes immediately to ~${LAG}s"
    ;;
  *)
    echo "Unknown mode: $MODE"
    echo "Usage: $0 [steady|burst|stress|load|count <N>|lag <seconds>]"
    exit 1
    ;;
esac

echo ""

# Build the Python generator inline — runs inside the cluster where RDS is reachable
PYTHON_SCRIPT=$(cat << 'PYEOF'
import os, uuid, random, time, json
from datetime import datetime, timezone, timedelta
from sqlalchemy import create_engine, text

db_url = os.environ["DATABASE_URL"]
engine = create_engine(db_url, pool_pre_ping=True, pool_size=2)

EVENTS = [
    ("order.received",        "order",      "dc-atlanta"),
    ("order.picked",          "order",      "dc-atlanta"),
    ("order.packed",          "order",      "dc-atlanta"),
    ("order.dispatched",      "order",      "dc-dallas"),
    ("order.delivered",       "order",      "dc-dallas"),
    ("inventory.adjusted",    "sku",        "wms-primary"),
    ("inventory.replenished", "sku",        "wms-primary"),
    ("inventory.low",         "sku",        "wms-primary"),
    ("shipment.created",      "shipment",   "tms-primary"),
    ("shipment.in_transit",   "shipment",   "tms-primary"),
    ("shipment.delayed",      "shipment",   "tms-primary"),
    ("shipment.delivered",    "shipment",   "tms-primary"),
    ("production.started",    "batch",      "bcf-plant-1"),
    ("production.completed",  "batch",      "bcf-plant-1"),
    ("production.qc_passed",  "batch",      "bcf-plant-1"),
    ("fulfillment.requested", "restaurant", "restaurant-ops"),
    ("fulfillment.scheduled", "restaurant", "restaurant-ops"),
    ("fulfillment.completed", "restaurant", "restaurant-ops"),
]

RESTAURANTS = [f"CFA-{n:05d}" for n in random.sample(range(1000, 9999), 50)]
SKUS        = ["SKU-BREAST-FZ", "SKU-NUGGETS-FZ", "SKU-SANDWICH-BUN",
               "SKU-WAFFLE-FRY", "SKU-SAUCE-POLY", "SKU-LEMONADE-MIX"]
BATCHES     = [f"BATCH-{uuid.uuid4().hex[:8].upper()}" for _ in range(20)]
SHIPMENTS   = [f"SHIP-{uuid.uuid4().hex[:8].upper()}"  for _ in range(30)]

def entity_id(etype):
    if etype == "restaurant": return random.choice(RESTAURANTS)
    if etype == "sku":        return random.choice(SKUS)
    if etype == "batch":      return random.choice(BATCHES)
    if etype == "shipment":   return random.choice(SHIPMENTS)
    return f"ORD-{uuid.uuid4().hex[:10].upper()}"

def payload(etype, eid):
    if etype == "order":
        return {"restaurant_id": random.choice(RESTAURANTS),
                "line_items": random.randint(1,12),
                "weight_lbs": round(random.uniform(10,500),1)}
    if etype == "sku":
        return {"quantity": random.randint(1,5000), "unit": random.choice(["cases","lbs"])}
    if etype == "shipment":
        return {"carrier": random.choice(["CFA-Fleet","FedEx-Freight","UPS-Supply"]),
                "dest": random.choice(RESTAURANTS)}
    if etype == "batch":
        return {"product": random.choice(["Chicken Breast","Nuggets","Strips"]),
                "yield_lbs": round(random.uniform(500,5000),1)}
    return {}

rate     = int(os.environ.get("RATE", "2"))
duration = int(os.environ.get("DURATION", "600"))
lag_sec  = int(os.environ.get("LAG", "0"))
count    = int(os.environ.get("COUNT", "0"))  # 0 = use rate/duration

inserted = 0
start    = time.time()
print(f"Generator started: rate={rate}/s duration={duration}s lag={lag_sec}s count={count or 'unlimited'}")

try:
    while True:
        batch_start = time.time()
        with engine.begin() as conn:
            for _ in range(rate):
                tmpl = random.choice(EVENTS)
                eid  = str(uuid.uuid4())
                entid = entity_id(tmpl[1])
                occurred_at = datetime.now(timezone.utc) - timedelta(seconds=lag_sec)
                conn.execute(text("""
                    INSERT INTO raw_events
                      (event_id,event_type,entity_type,entity_id,occurred_at,source,payload)
                    VALUES (:eid,:et,:ent,:entid,:oat,:src,cast(:payload as jsonb))
                    ON CONFLICT (event_id) DO NOTHING
                """), {"eid":eid,"et":tmpl[0],"ent":tmpl[1],"entid":entid,
                       "oat":occurred_at,"src":tmpl[2],
                       "payload":json.dumps(payload(tmpl[1],entid))})
                conn.execute(text("""
                    INSERT INTO event_queue (event_id,status,available_at)
                    VALUES (:eid,:status,now())
                    ON CONFLICT DO NOTHING
                """), {"eid":eid,"status":"PENDING"})
                inserted += 1
                if count and inserted >= count:
                    break

        elapsed = time.time() - start
        print(f"inserted={inserted} elapsed={elapsed:.0f}s rate={inserted/elapsed:.1f}/s", flush=True)

        if count and inserted >= count:
            break
        if elapsed >= duration:
            break

        sleep = max(0, 1.0 - (time.time() - batch_start))
        time.sleep(sleep)

except KeyboardInterrupt:
    print("Stopped.")

print(f"Done. Inserted {inserted} events in {time.time()-start:.1f}s")
PYEOF
)

# Launch as a pod inside the cluster
kubectl -n "$NAMESPACE" run "$JOB_NAME" \
  --image=python:3.11-slim \
  --restart=Never \
  --env="DATABASE_URL=$(kubectl -n $NAMESPACE get secret supply-secrets \
    -o jsonpath='{.data.DATABASE_URL}' | base64 -d)" \
  --env="RATE=${RATE}" \
  --env="DURATION=${DURATION}" \
  --env="LAG=${LAG}" \
  --env="COUNT=${COUNT:-0}" \
  --command -- /bin/bash -c \
  "pip install sqlalchemy 'psycopg[binary]' -q && python3 -c '${PYTHON_SCRIPT}'"

echo "Pod launched. Following logs (Ctrl+C to detach — pod keeps running)..."
echo "To stop early: kubectl -n $NAMESPACE delete pod $JOB_NAME"
echo ""
kubectl -n "$NAMESPACE" logs -f "$JOB_NAME" 2>/dev/null || \
  kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/"$JOB_NAME" --timeout=60s && \
  kubectl -n "$NAMESPACE" logs -f "$JOB_NAME"
