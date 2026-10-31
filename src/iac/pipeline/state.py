"""Pipeline run state — the single source of truth the UI reads.

CLI commands emit these records as they run stages; the FastAPI backend serves
them to the operator dashboard so the CLI and UI never diverge.
"""

from __future__ import annotations

from datetime import datetime
from enum import StrEnum

from pydantic import BaseModel


class StageStatus(StrEnum):
    PENDING = "pending"
    RUNNING = "running"
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    SKIPPED = "skipped"


class StageRun(BaseModel):
    name: str
    status: StageStatus = StageStatus.PENDING
    started_at: datetime | None = None
    finished_at: datetime | None = None
    detail: str | None = None


class PipelineRun(BaseModel):
    run_id: str
    environment: str
    stages: list[StageRun] = []
