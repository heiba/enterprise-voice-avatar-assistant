#!/usr/bin/env bash
# Shows recent n8n executions with the last node reached and any node errors, optionally
# waiting until a number of new executions have finished. Needs an n8n API key
# (Settings > n8n API) in N8N_API_KEY.
#
# Usage: NS=<namespace> N8N_API_KEY=... scripts/n8n-executions.sh [--since ID] [--expect N] [--limit N]
#   --since ID   only executions with an id above ID (default: show the latest ones)
#   --expect N   poll (up to 12 min) until N executions above ID have finished
set -uo pipefail
NS="${NS:-$(oc project -q)}"
: "${N8N_API_KEY:?set N8N_API_KEY (Settings > n8n API)}"
SINCE=0; EXPECT=0; LIMIT=15
while [ $# -gt 0 ]; do case "$1" in --since) SINCE="$2"; shift 2;; --expect) EXPECT="$2"; shift 2;; --limit) LIMIT="$2"; shift 2;; *) echo "unknown argument $1"; exit 1;; esac; done
N8N="https://$(oc get route n8n -n "$NS" -o jsonpath='{.spec.host}')"
python3 - "$N8N" "$N8N_API_KEY" "$SINCE" "$EXPECT" "$LIMIT" <<'PY'
import sys, json, time, urllib.request
from collections import Counter
base, key, since, expect, limit = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
def get(p):
    r = urllib.request.Request(base + '/api/v1' + p, headers={'X-N8N-API-KEY': key})
    return json.load(urllib.request.urlopen(r, timeout=30))
names = {w['id']: w['name'] for w in get('/workflows?limit=100')['data']}
for _ in range(144 if expect else 1):
    ex = [e for e in get(f'/executions?limit={max(limit, expect + 5)}')['data'] if int(e['id']) > since]
    done = [e for e in ex if e['status'] not in ('running', 'waiting', 'new')]
    if not expect or (len(done) >= expect and len(done) == len(ex)):
        break
    time.sleep(5)
if expect:
    print(Counter(f"{names.get(e['workflowId'], '?')[:3]} {e['status']}" for e in ex))
for e in sorted(ex, key=lambda e: int(e['id']))[-limit:]:
    d = get(f"/executions/{e['id']}?includeData=true").get('data', {}).get('resultData', {})
    errs = [f"{n}: {str(r['error'].get('message', ''))[:100]}" for n, runs in d.get('runData', {}).items() for r in runs if r.get('error')]
    print(f"{e['id']:>5} {names.get(e['workflowId'], '?')[:34]:34s} {e['status']:8s} {(e.get('startedAt') or '')[:19]} last={d.get('lastNodeExecuted')}" + (f"  errors={errs}" if errs else ''))
PY
