"""Runtime configuration, read once from environment variables set by Terraform."""
import os
from dataclasses import dataclass


def _as_bool(value, default):
    if value is None:
        return default
    return str(value).strip().lower() in ("1", "true", "yes", "on")


@dataclass(frozen=True)
class Config:
    project: str
    database: str
    orders_topic: str
    dead_letter_topic: str
    max_attempts: int
    require_api_key: bool
    api_key: str
    max_body_bytes: int = 64 * 1024


def load(env=None):
    env = os.environ if env is None else env
    return Config(
        project=env.get("GCP_PROJECT", ""),
        database=env.get("FIRESTORE_DATABASE", "(default)"),
        orders_topic=env.get("ORDERS_TOPIC", "orders"),
        dead_letter_topic=env.get("DEAD_LETTER_TOPIC", "orders-dead-letter"),
        max_attempts=int(env.get("MAX_ATTEMPTS", "5")),
        require_api_key=_as_bool(env.get("REQUIRE_API_KEY"), True),
        api_key=env.get("API_KEY", ""),
    )
