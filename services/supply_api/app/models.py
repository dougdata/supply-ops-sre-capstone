from __future__ import annotations

from datetime import datetime
from enum import Enum
from typing import Any, Dict, Optional
from uuid import UUID

from pydantic import BaseModel, Field


class EventType(str, Enum):
    ORDER_CREATED = "ORDER_CREATED"
    PICKED = "PICKED"
    SHIPPED = "SHIPPED"
    DELIVERED = "DELIVERED"
    EXCEPTION = "EXCEPTION"


class EntityType(str, Enum):
    ORDER = "ORDER"
    SHIPMENT = "SHIPMENT"
    BATCH = "BATCH"


class EventIn(BaseModel):
    event_id: UUID
    event_type: EventType
    entity_type: EntityType
    entity_id: str = Field(min_length=1, max_length=128)
    occurred_at: datetime
    source: str = Field(min_length=1, max_length=64)
    payload: Dict[str, Any] = Field(default_factory=dict)


class IngestResponse(BaseModel):
    accepted: bool
    duplicate: bool = False
    queued: bool = False
    message: str
    event_id: UUID


class EntityStatusOut(BaseModel):
    entity_type: str
    entity_id: str
    last_event_id: UUID
    last_event_type: str
    last_occurred_at: datetime
    last_updated_at: datetime
    exception_count: int
    last_exception_reason: Optional[str] = None


class EntityHistoryItem(BaseModel):
    event_id: UUID
    event_type: str
    occurred_at: datetime
    recorded_at: datetime