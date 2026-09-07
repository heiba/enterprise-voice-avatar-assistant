import pytest

from app import avatars
from app.config import settings


def test_none_provider_builds_nothing(monkeypatch):
    monkeypatch.setattr(settings, "avatar_provider", "none")
    assert avatars.build() is None


def test_unknown_provider_is_rejected(monkeypatch):
    monkeypatch.setattr(settings, "avatar_provider", "hologram")
    with pytest.raises(RuntimeError):
        avatars.provider()


def test_simli_requires_credentials(monkeypatch):
    monkeypatch.setattr(settings, "avatar_provider", "simli")
    monkeypatch.setattr(settings, "simli_api_key", None)
    with pytest.raises(RuntimeError, match="SIMLI_API_KEY"):
        avatars.build()
