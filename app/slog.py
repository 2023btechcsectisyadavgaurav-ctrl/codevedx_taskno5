"""Structured logging. One JSON object per line on stdout: Cloud Logging reads `severity` and `message`
natively and exposes every other field as jsonPayload.<field>, so logs are searchable and drive metrics and alerts."""
import json
import sys


def log(severity, event, **fields):
    entry = {"severity": severity, "message": event, "event": event}
    entry.update(fields)
    sys.stdout.write(json.dumps(entry, default=str) + "\n")
    sys.stdout.flush()
