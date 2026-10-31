"""Operator dashboard backend (FastAPI).

Imports the `iac` engine rather than reimplementing logic — the dashboard shows
the same pipeline/infra/cost state the CLI produces.
"""

from __future__ import annotations

from fastapi import FastAPI

app = FastAPI(title="aws-genai-iac dashboard", version="0.1.0")


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


# Routers (status, costs, deployments, drift) are registered here as they land:
# from iac_ui.routers import status
# app.include_router(status.router)
