"""Client for the RAG API. Voice turns use mode=voice so answers come back short and spoken-style."""

import logging
from typing import Any

from .config import settings
from .tls import async_http_client

log = logging.getLogger("voice-agent.rag")


async def chat(message: str, session_id: str, user_id: str | None) -> dict[str, Any]:
    payload: dict[str, Any] = {"message": message, "session_id": session_id, "mode": "voice"}
    if user_id:
        payload["user_id"] = user_id
    async with async_http_client(settings.rag_timeout_seconds) as client:
        response = await client.post(f"{settings.rag_api_url.rstrip('/')}/v1/chat", json=payload)
        response.raise_for_status()
        return response.json()
