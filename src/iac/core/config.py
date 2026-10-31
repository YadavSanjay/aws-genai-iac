"""Configuration loading — resolves `config/` + environment settings.

Secrets are NEVER stored here; pull them from SSM/Secrets Manager at runtime.
"""

from __future__ import annotations

from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

REPO_ROOT = Path(__file__).resolve().parents[3]
CONFIG_DIR = REPO_ROOT / "config"
INFRA_DIR = REPO_ROOT / "infra"


class Settings(BaseSettings):
    """Process-level settings, overridable via `IAC_` env vars."""

    model_config = SettingsConfigDict(env_prefix="IAC_", env_file=".env", extra="ignore")

    aws_region: str = "us-east-1"
    default_env: str = "dev"


settings = Settings()
