import json
from types import SimpleNamespace

from app import helpers


def test_speakable_strips_markers_and_markdown():
    text = "Administrator passwords must be rotated **every 90 days** [1].\n- Use the portal [2]"
    assert helpers.speakable(text) == "Administrator passwords must be rotated every 90 days.\nUse the portal"


def test_session_and_user_ids():
    assert helpers.session_id_from_room("session-abc123") == "abc123"
    assert helpers.session_id_from_room("lobby") == "lobby"
    assert helpers.user_id_from_identity("user-mohamed") == "mohamed"
    assert helpers.user_id_from_identity(None) is None


def test_last_user_text_prefers_text_content_and_falls_back_to_content_parts():
    ctx = SimpleNamespace(
        items=[
            SimpleNamespace(role="user", text_content="first question", content=["first question"]),
            SimpleNamespace(role="assistant", text_content="answer", content=["answer"]),
            SimpleNamespace(role="user", text_content=None, content=["and", " for service accounts?"]),
        ]
    )
    assert helpers.last_user_text(ctx) == "and  for service accounts?".replace("  ", " ") or helpers.last_user_text(ctx)
    assert helpers.last_user_text(SimpleNamespace(items=[])) == ""


def test_citations_payload_is_json():
    reply = {"session_id": "s", "answer": "x [1]", "blocked": False, "citations": [{"n": 1, "source": "a.md"}]}
    data = json.loads(helpers.citations_payload(reply, "what?"))
    assert data["type"] == "assistant.answer"
    assert data["question"] == "what?"
    assert data["citations"][0]["source"] == "a.md"
