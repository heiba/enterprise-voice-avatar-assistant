"""Lazily constructed clients for the LLM, embeddings, guardrails, Qdrant, and PostgreSQL."""

from functools import lru_cache

import httpx
from openai import OpenAI
from qdrant_client import QdrantClient

from .config import settings
from .tls import tls_context


def _http() -> httpx.Client:
    return httpx.Client(verify=tls_context(), timeout=httpx.Timeout(120.0, connect=10.0))


@lru_cache(maxsize=1)
def llm() -> OpenAI:
    return OpenAI(
        base_url=settings.llm_base_url,
        api_key=settings.llm_api_key or "none",
        http_client=_http(),
        max_retries=2,
    )


@lru_cache(maxsize=1)
def embeddings() -> OpenAI:
    return OpenAI(
        base_url=settings.embeddings_base_url,
        api_key=settings.embeddings_api_key or "none",
        http_client=_http(),
        max_retries=2,
    )


@lru_cache(maxsize=1)
def guardrails() -> OpenAI:
    return OpenAI(
        base_url=settings.guardrails_base_url,
        api_key=settings.guardrails_api_key or "none",
        http_client=_http(),
        max_retries=1,
    )


@lru_cache(maxsize=1)
def qdrant() -> QdrantClient:
    return QdrantClient(url=settings.qdrant_url, api_key=settings.qdrant_api_key or None, timeout=30)


def db():
    """A new PostgreSQL connection with dict rows. Callers use it as a context manager."""
    import psycopg
    from psycopg.rows import dict_row

    return psycopg.connect(settings.database_url, connect_timeout=5, row_factory=dict_row)
