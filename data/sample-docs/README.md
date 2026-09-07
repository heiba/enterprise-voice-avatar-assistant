# Sample documents

Synthetic documents for the demo. Nothing here is real company data.

| File | Purpose in the demo |
|---|---|
| `password-policy.md` | first ingestion and text question ("How often must passwords be rotated?") |

Upload a file to the `documents` bucket (MinIO console, or `mc cp`) and the
ingestion workflow indexes it. To bypass n8n during development:

```bash
curl -X POST http://ingestion:8080/v1/ingest -H 'Content-Type: application/json' \
  -d '{"bucket": "documents", "key": "password-policy.md"}'
```
