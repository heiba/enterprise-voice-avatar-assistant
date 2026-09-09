#!/usr/bin/env bash
# Lists the documents known to the ingestion service with their chunk counts (inbox files
# that were only classified show none), flags duplicate file names, and optionally runs a
# search to spot stale text after documents were rewritten.
#
# Usage: NS=<namespace> scripts/check-index.sh ["text that should not be found any more"]
set -uo pipefail
NS="${NS:-$(oc project -q)}"
QUERY="${1:-}"

echo "=== documents (indexed = chunks > 0) ==="
oc exec deploy/rag-api -n "$NS" -- .venv/bin/python -c "
import urllib.request, json, collections
d = json.load(urllib.request.urlopen('http://ingestion:8080/v1/documents'))
items = d if isinstance(d, list) else d.get('documents', d.get('items', []))
names = collections.Counter(str(x.get('source') or x.get('key')) for x in items)
for x in sorted(items, key=lambda x: str(x.get('source') or x.get('key'))):
    print(f\"  {str(x.get('source') or x.get('key')):45s} chunks={str(x.get('chunks', x.get('chunk_count'))):5s} id={str(x.get('doc_id', x.get('id')))[:8]}\")
dups = [n for n, c in names.items() if c > 1]
print('duplicate file names:', dups or 'none')
"

if [ -n "$QUERY" ]; then
  FE="https://$(oc get route frontend -n "$NS" -o jsonpath='{.spec.host}')"
  echo "=== search: $QUERY (stale text would score high) ==="
  curl -s -X POST "$FE/api/v1/search" -H 'Content-Type: application/json' \
    -d "$(python3 -c "import json,sys; print(json.dumps({'query': sys.argv[1], 'top_k': 3}))" "$QUERY")" \
    | python3 -c "import sys,json; [print(' ', round(h['score'],2), h['source'], '|', h['snippet'][:90].replace(chr(10),' ')) for h in json.load(sys.stdin)['hits']]"
fi
