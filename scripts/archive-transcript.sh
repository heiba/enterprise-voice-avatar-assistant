#!/usr/bin/env bash
# Triggers the transcript archival workflow (WF5) for a conversation.
# Usage: NS=<namespace> scripts/archive-transcript.sh [session_id]
# Without an argument the newest conversation in the RAG API is used.
set -euo pipefail
NS="${NS:-$(oc project -q)}"
N8N="https://$(oc get route n8n -n "$NS" -o jsonpath='{.spec.host}')"
SID="${1:-}"
if [ -z "$SID" ]; then
  SID=$(oc exec deploy/rag-api -n "$NS" -- .venv/bin/python -c "from app import memory; rows = memory.run('SELECT session_id FROM conversations ORDER BY updated_at DESC LIMIT 1', fetch=True) or []; print(rows[0]['session_id'] if rows else '')")
  [ -n "$SID" ] || { echo "no conversation found; pass a session id"; exit 1; }
  echo "newest session: $SID"
fi
curl -sf -X POST "$N8N/webhook/archive-transcript" -H 'Content-Type: application/json' -d "{\"session_id\":\"$SID\"}" >/dev/null
echo "archival requested for $SID; watch the n8n execution, the Drive folder and #assistant-ingestion"
