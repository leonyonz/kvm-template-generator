#!/usr/bin/env bash
# Start the template-generator web UI
cd "$(dirname "$0")"
export TG_TOKEN="${TG_TOKEN:-changeme}"
export TG_PORT="${TG_PORT:-8080}"
exec python3 -m uvicorn server.app:app --host 0.0.0.0 --port "$TG_PORT"
