"""Client for the RAG API. Voice turns use mode=voice so answers come back short and spoken-style."""

import json
import logging
from collections.abc import AsyncIterator
from typing import Any

from .config import settings
from .tls import async_http_client

log = logging.getLogger("voice-agent.rag")


async def chat(
    message: str, session_id: str, user_id: str | None, user_name: str | None = None
) -> dict[str, Any]:
    payload: dict[str, Any] = {"message": message, "session_id": session_id, "mode": "voice"}
    if user_id:
        payload["user_id"] = user_id
    if user_name:
        payload["user_name"] = user_name
    async with async_http_client(settings.rag_timeout_seconds) as client:
        response = await client.post(f"{settings.rag_api_url.rstrip('/')}/v1/chat", json=payload)
        response.raise_for_status()
        return response.json()


async def chat_stream(
    message: str, session_id: str, user_id: str | None, user_name: str | None = None
) -> AsyncIterator[tuple[str, Any]]:
    """Yields ("delta", text) while the RAG API generates, then ("final", reply) with the citations."""
    payload: dict[str, Any] = {"message": message, "session_id": session_id, "mode": "voice"}
    if user_id:
        payload["user_id"] = user_id
    if user_name:
        payload["user_name"] = user_name
    async with (
        async_http_client(settings.rag_timeout_seconds) as client,
        client.stream("POST", f"{settings.rag_api_url.rstrip('/')}/v1/chat/stream", json=payload) as response,
    ):
        response.raise_for_status()
        async for line in response.aiter_lines():
            if not line.strip():
                continue
            event = json.loads(line)
            if event.get("type") == "delta":
                yield "delta", event.get("text", "")
            elif event.get("type") == "final":
                yield "final", event


async def pending_notifications(session_id: str) -> list[dict[str, Any]]:
    """Outcome notices (for example a ticket decision) not yet delivered to this session."""
    async with async_http_client(15) as client:
        response = await client.get(
            f"{settings.rag_api_url.rstrip('/')}/v1/sessions/{session_id}/notifications"
        )
        response.raise_for_status()
        return response.json()


async def ack_notifications(session_id: str, ids: list[int]) -> None:
    if not ids:
        return
    async with async_http_client(15) as client:
        response = await client.post(
            f"{settings.rag_api_url.rstrip('/')}/v1/sessions/{session_id}/notifications/ack",
            json={"ids": ids},
        )
        response.raise_for_status()
