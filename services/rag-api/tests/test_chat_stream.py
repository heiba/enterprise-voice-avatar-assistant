import json
from types import SimpleNamespace

from fastapi.testclient import TestClient

from app import guardrails, intent, rag, retrieval
from app.guardrails import Verdict
from app.main import app
from app.retrieval import Hit

PIECES = ["Administrator passwords ", "are rotated every 90 days", " [1]."]


def _question(monkeypatch):
    monkeypatch.setattr(
        retrieval,
        "search",
        lambda q, top_k=None, min_score=None: [
            Hit(doc_id="d1", source="password-policy.md", text="Rotated every 90 days.", score=0.8)
        ],
    )
    monkeypatch.setattr(guardrails, "check_input", lambda text: Verdict(True, "none"))
    monkeypatch.setattr(guardrails, "check_output", lambda user, answer: Verdict(True, "none"))
    monkeypatch.setattr(intent, "detect", lambda text: "question")

    class FakeLLM:
        class chat:
            class completions:
                @staticmethod
                def create(**kwargs):
                    assert kwargs.get("stream") is True and kwargs["max_tokens"] == 120
                    return iter(
                        SimpleNamespace(choices=[SimpleNamespace(delta=SimpleNamespace(content=p))])
                        for p in PIECES
                    )

    monkeypatch.setattr(rag.clients, "llm", lambda: FakeLLM())


def test_stream_yields_deltas_then_the_final_reply(monkeypatch):
    _question(monkeypatch)
    with (
        TestClient(app) as client,
        client.stream("POST", "/v1/chat/stream", json={"message": "How often?", "mode": "voice"}) as response,
    ):
        assert response.status_code == 200
        assert response.headers["content-type"].startswith("application/x-ndjson")
        events = [json.loads(line) for line in response.iter_lines() if line]
    deltas = [e["text"] for e in events if e["type"] == "delta"]
    assert "".join(deltas) == "".join(PIECES)
    final = events[-1]
    assert final["type"] == "final" and final["answer"] == "".join(PIECES).strip()
    assert final["citations"][0]["used"] is True and final["blocked"] is False


def test_stream_of_a_blocked_message_is_only_the_final(monkeypatch):
    monkeypatch.setattr(guardrails, "check_input", lambda text: Verdict(False, "harm"))
    with (
        TestClient(app) as client,
        client.stream("POST", "/v1/chat/stream", json={"message": "bad"}) as response,
    ):
        events = [json.loads(line) for line in response.iter_lines() if line]
    assert len(events) == 1 and events[0]["type"] == "final" and events[0]["blocked"] is True
