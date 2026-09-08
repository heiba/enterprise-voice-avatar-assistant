from app import knowledge_gaps, memory


def test_record_skips_above_threshold(monkeypatch):
    monkeypatch.setattr("app.config.settings.gap_score_threshold", 0.45)
    calls = []
    monkeypatch.setattr(memory, "run", lambda *a, **k: calls.append(a))
    knowledge_gaps.record("s1", "what is the password policy?", 0.8, 3)
    assert calls == []


def test_record_logs_low_score(monkeypatch):
    monkeypatch.setattr("app.config.settings.gap_score_threshold", 0.45)
    calls = []
    monkeypatch.setattr(memory, "run", lambda *a, **k: calls.append(a))
    knowledge_gaps.record("s1", "how do I fly a helicopter?", 0.2, 2)
    assert len(calls) == 1
    params = calls[0][1]
    assert params[4] == "low_score"


def test_record_logs_no_hits(monkeypatch):
    monkeypatch.setattr("app.config.settings.gap_score_threshold", 0.45)
    calls = []
    monkeypatch.setattr(memory, "run", lambda *a, **k: calls.append(a))
    knowledge_gaps.record("s1", "something totally unknown", 0.0, 0)
    assert len(calls) == 1
    params = calls[0][1]
    assert params[4] == "no_hits"


def test_priority_escalation_map():
    assert knowledge_gaps._PRIORITY_ESCALATION["low"] == "normal"
    assert knowledge_gaps._PRIORITY_ESCALATION["normal"] == "high"
    assert knowledge_gaps._PRIORITY_ESCALATION["high"] == "urgent"
    assert "urgent" not in knowledge_gaps._PRIORITY_ESCALATION
