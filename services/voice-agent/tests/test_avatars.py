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


def test_tavus_requires_face_and_key(monkeypatch):
    monkeypatch.setattr(settings, "avatar_provider", "tavus")
    for field in ("tavus_face_id", "tavus_replica_id", "tavus_api_key"):
        monkeypatch.setattr(settings, field, None)
    with pytest.raises(RuntimeError, match="TAVUS_FACE_ID"):
        avatars.build()
    monkeypatch.setattr(settings, "tavus_replica_id", "r3f4182ef554")  # old name still accepted
    with pytest.raises(RuntimeError, match="TAVUS_API_KEY"):
        avatars.build()
