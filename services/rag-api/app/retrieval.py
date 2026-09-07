"""Embed the question and search Qdrant. Returns hits with the payload written by the ingestion service."""

import logging
from dataclasses import dataclass, field

from . import clients
from .config import settings
from .schemas import Citation

log = logging.getLogger("rag.retrieval")


@dataclass
class Hit:
    doc_id: str
    source: str
    text: str
    score: float
    page: int | None = None
    chunk_index: int | None = None
    headings: list[str] = field(default_factory=list)

    def to_citation(self, n: int, used: bool = False) -> Citation:
        snippet = self.text if len(self.text) <= settings.snippet_chars else self.text[: settings.snippet_chars] + "…"
        return Citation(n=n, used=used, doc_id=self.doc_id, source=self.source, page=self.page,
                        headings=self.headings, snippet=snippet, score=round(self.score, 4))


def embed(text: str) -> list[float]:
    response = clients.embeddings().embeddings.create(model=settings.embeddings_model, input=[text])
    return response.data[0].embedding


def search(query: str, top_k: int | None = None, min_score: float | None = None) -> list[Hit]:
    client = clients.qdrant()
    if not client.collection_exists(settings.qdrant_collection):
        log.warning("collection %s does not exist yet; nothing indexed", settings.qdrant_collection)
        return []
    vector = embed(query)
    result = client.query_points(
        collection_name=settings.qdrant_collection,
        query=vector,
        limit=top_k or settings.rag_top_k,
        score_threshold=settings.rag_min_score if min_score is None else min_score,
        with_payload=True,
    )
    hits: list[Hit] = []
    for point in result.points:
        payload = point.payload or {}
        hits.append(
            Hit(
                doc_id=str(payload.get("doc_id", "")),
                source=str(payload.get("source", "")),
                text=str(payload.get("text", "")),
                score=float(point.score),
                page=payload.get("page"),
                chunk_index=payload.get("chunk_index"),
                headings=list(payload.get("headings") or []),
            )
        )
    return hits
