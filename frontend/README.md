# Frontend

React chat interface for the assistant: a chat panel with clickable citation
markers, a sources panel showing the retrieved passages (cited ones first), a
persistent AI disclaimer, and a status strip that reports the active models
from the RAG API. Voice mode is present but disabled until the voice agent and
the LiveKit TURN certificate are in place.

Calls go to `/api/...`, which nginx proxies to the RAG API inside the cluster
(`RAG_API_UPSTREAM`, default `rag-api:8080`). The session id is kept in
`sessionStorage`, the optional user name in `localStorage`; both are sent with
every question so memory works across turns.

## Develop

```bash
npm install
VITE_API_PROXY=http://localhost:8080 npm run dev     # RAG API on localhost:8080, or a port-forward
npm run build
```

To point the dev server at the cluster:

```bash
oc port-forward -n voice-avatar-assistant svc/rag-api 8080:8080
```

## Container

```bash
podman build -t assistant-frontend -f Containerfile .
podman run -p 8080:8080 -e RAG_API_UPSTREAM=host.containers.internal:8080 assistant-frontend
```
