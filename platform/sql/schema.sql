-- SupplyOps Event Service schema (Postgres)

CREATE TABLE IF NOT EXISTS raw_events (
  event_id      UUID PRIMARY KEY,
  event_type    TEXT NOT NULL,
  entity_type   TEXT NOT NULL,
  entity_id     TEXT NOT NULL,
  occurred_at   TIMESTAMPTZ NOT NULL,
  source        TEXT NOT NULL,
  payload       JSONB NOT NULL DEFAULT '{}'::jsonb,
  received_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Simple queue table: API enqueues, worker dequeues.
CREATE TABLE IF NOT EXISTS event_queue (
  queue_id      BIGSERIAL PRIMARY KEY,
  event_id      UUID NOT NULL REFERENCES raw_events(event_id) ON DELETE CASCADE,
  status        TEXT NOT NULL DEFAULT 'PENDING', -- PENDING, PROCESSING, DONE, FAILED
  attempts      INT NOT NULL DEFAULT 0,
  available_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  locked_by     TEXT,
  locked_at     TIMESTAMPTZ,
  last_error    TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_event_queue_pending
  ON event_queue (status, available_at);

-- Current status per entity
CREATE TABLE IF NOT EXISTS entity_status (
  entity_type   TEXT NOT NULL,
  entity_id     TEXT NOT NULL,
  last_event_id UUID NOT NULL,
  last_event_type TEXT NOT NULL,
  last_occurred_at TIMESTAMPTZ NOT NULL,
  last_updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  exception_count  INT NOT NULL DEFAULT 0,
  last_exception_reason TEXT,
  PRIMARY KEY (entity_type, entity_id)
);

-- History of transitions (append-only)
CREATE TABLE IF NOT EXISTS entity_status_history (
  history_id    BIGSERIAL PRIMARY KEY,
  entity_type   TEXT NOT NULL,
  entity_id     TEXT NOT NULL,
  event_id      UUID NOT NULL,
  event_type    TEXT NOT NULL,
  occurred_at   TIMESTAMPTZ NOT NULL,
  recorded_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_entity_history_lookup
  ON entity_status_history(entity_type, entity_id, occurred_at DESC);

-- Dead-letter style record of processing failures
CREATE TABLE IF NOT EXISTS processing_errors (
  error_id      BIGSERIAL PRIMARY KEY,
  event_id      UUID NOT NULL,
  error_type    TEXT NOT NULL,
  error_message TEXT NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
