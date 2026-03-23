from __future__ import annotations

import os
from dataclasses import dataclass

from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine
from sqlalchemy.orm import sessionmaker, Session


@dataclass(frozen=True)
class DbConfig:
    database_url: str


def load_db_config() -> DbConfig:
    url = os.getenv("DATABASE_URL")
    if not url:
        raise RuntimeError("DATABASE_URL is not set")
    return DbConfig(database_url=url)


def create_db_engine(cfg: DbConfig) -> Engine:
    # For demo: simple engine. In prod you'd tune pool size/timeouts.
    return create_engine(
        cfg.database_url,
        pool_pre_ping=True,
        pool_size=int(os.getenv("DB_POOL_SIZE", "5")),
        max_overflow=int(os.getenv("DB_MAX_OVERFLOW", "10")),
    )


def create_session_factory(engine: Engine):
    return sessionmaker(bind=engine, expire_on_commit=False, autoflush=False)


def db_healthcheck(session: Session) -> bool:
    session.execute(text("SELECT 1"))
    return True