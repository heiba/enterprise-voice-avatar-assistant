"""Embeddings through any OpenAI-compatible endpoint (vLLM in the chart)."""

import httpx
from openai import OpenAI

from .config import settings
from .tls import tls_context

_client: OpenAI | None = None


def client() -> OpenAI:
    global _client
    if _client is None:
        _client = OpenAI(
            base_url=settings.embeddings_base_url,
            api_key=settings.embeddings_api_key or "none",
            http_client=httpx.Client(verify=tls_context(), timeout=httpx.Timeout(120.0, connect=10.0)),
            max_retries=2,
        )
    return _client


def embed(texts: list[str]) -> list[list[float]]:
    vectors: list[list[float]] = []
    size = max(1, settings.embed_batch_size)
    for start in range(0, len(texts), size):
        batch = texts[start : start + size]
        response = client().embeddings.create(model=settings.embeddings_model, input=batch)
        ordered = sorted(response.data, key=lambda d: d.index)
        vectors.extend(item.embedding for item in ordered)
    return vectors
