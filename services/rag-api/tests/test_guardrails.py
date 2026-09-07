from app.guardrails import parse_granite, parse_llama_guard


def test_granite_verdicts():
    assert parse_granite("<think>\n</think><score> yes </score>") is True
    assert parse_granite("<score>no</score>") is False
    assert parse_granite("no verdict here") is None


def test_llama_guard_verdicts():
    assert parse_llama_guard("safe") == (False, None)
    assert parse_llama_guard("unsafe\nS2") == (True, "S2")
