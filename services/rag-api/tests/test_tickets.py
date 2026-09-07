import pytest

from app import tickets


def test_state_machine():
    assert tickets.can_transition("intake", "classified")
    assert tickets.can_transition("pending_approval", "approved")
    assert tickets.can_transition("approved", "fulfilled")
    assert not tickets.can_transition("fulfilled", "approved")
    assert not tickets.can_transition("rejected", "approved")


def test_reference_resolution():
    assert tickets.resolve_id("42") == 42
    assert tickets.resolve_id("REQ-000042") == 42
    with pytest.raises(tickets.TicketError):
        tickets.resolve_id("nope")
