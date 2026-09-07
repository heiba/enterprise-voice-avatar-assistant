# Sample documents

Synthetic documents for the demo. Nothing here is real company data.

| File | Purpose in the demo |
|---|---|
| `password-policy.md` | first ingestion and text question ("How often must passwords be rotated?") |
| `invoice-INV-2026-0042.md` | classification demo: drop it in the `inbox` bucket and WF3 classifies it as an invoice and extracts supplier, total and due date |

Upload a file to the `documents` bucket (MinIO console, or `mc cp`) and the
ingestion workflow indexes it. Files dropped in the `inbox` bucket are
classified and their fields extracted (WF3) for a downstream system; they are
not indexed for search. To bypass n8n during development:

```bash
curl -X POST http://ingestion:8080/v1/ingest -H 'Content-Type: application/json' \
  -d '{"bucket": "documents", "key": "password-policy.md"}'
```
