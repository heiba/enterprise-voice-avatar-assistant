from app import rag
from app.retrieval import Hit


def hits():
    return [
        Hit(doc_id="d1", source="password-policy.md", text="Standard user passwords must be rotated every 180 days.", score=0.8, page=None),
        Hit(doc_id="d1", source="password-policy.md", text="Administrator passwords must be rotated every 90 days.", score=0.75, page=2),
    ]


def test_context_is_numbered_with_sources():
    context = rag.build_context(hits())
    assert context.startswith("[1] (source: password-policy.md)")
    assert "[2] (source: password-policy.md, page 2)" in context


def test_messages_include_history_and_voice_style():
    messages = rag.build_messages("How often?", hits(), [{"role": "user", "content": "hi"}], "voice", {"team": "IT"})
    assert messages[0]["role"] == "system"
    assert "spoken aloud" in messages[0]["content"]
    assert "team: IT" in messages[0]["content"]
    assert messages[1] == {"role": "user", "content": "hi"}
    assert messages[-1] == {"role": "user", "content": "How often?"}


def test_citation_markers_are_extracted_within_range():
    assert rag.cited_numbers("Every 90 days [2]. Also [1][7].", max_n=2) == {1, 2}


def test_retrieval_query_expands_short_followups():
    history = [{"role": "user", "content": "How often must admin passwords be rotated?"}, {"role": "assistant", "content": "90 days"}]
    assert rag.retrieval_query("And for service accounts?", history) == "How often must admin passwords be rotated? And for service accounts?"
    assert rag.retrieval_query("And for service accounts?", []) == "And for service accounts?"
    long = "What is the exact procedure for resetting a forgotten password when the portal is down?"
    assert rag.retrieval_query(long, history) == long
