from __future__ import annotations

import os

from fastapi import FastAPI
from .logger import configure_logging
from .db import load_db_config, create_db_engine, create_session_factory
from .telemetry import setup_otel
from .routes import router
from .metrics import APP_INFO

VERSION = os.getenv("APP_VERSION", "0.1.0")
SERVICE = os.getenv("SERVICE_NAME", "supply-api")

configure_logging()

app = FastAPI(title="SupplyOps Event Service", version=VERSION)
app.include_router(router)

# DB wiring
cfg = load_db_config()
engine = create_db_engine(cfg)
SessionLocal = create_session_factory(engine)
app.state.engine = engine
app.state.SessionLocal = SessionLocal

# Metrics: static info
APP_INFO.labels(service=SERVICE, version=VERSION).set(1)

# OTEL setup (optional if endpoint env var is set)
setup_otel(app, engine=engine)