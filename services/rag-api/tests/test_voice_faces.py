import base64
import json

import httpx
from fastapi.testclient import TestClient

from app import faces
from app.config import settings
from app.main import app

CATALOG = json.dumps(
    [
        {"id": "r67d1c9cac37", "name": "Jackie", "gender": "female"},
        {"id": "r9d3aaaa1111", "gender": "male"},
        {"id": "rpinned", "name": "Pinned", "voice": "bf_emma"},
        {"id": "", "name": "ignored"},
    ]
)


def _tavus(monkeypatch, catalog=CATALOG, api_key=None):
    monkeypatch.setattr(settings, "avatar_provider", "tavus")
    monkeypatch.setattr(settings, "avatar_faces", catalog)
    monkeypatch.setattr(settings, "tavus_api_key", api_key)
    monkeypatch.setattr(settings, "tts_voice", "af_heart")
    monkeypatch.setattr(settings, "tts_voice_female", "af_bella")
    monkeypatch.setattr(settings, "tts_voice_male", "am_michael")
    faces.reset_cache()


def _claims(token: str) -> dict:
    payload = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))


def test_catalog_and_voice_selection(monkeypatch):
    _tavus(monkeypatch)
    items = faces.catalog()
    assert [f.id for f in items] == ["r67d1c9cac37", "r9d3aaaa1111", "rpinned"]
    assert [faces.voice_for(f) for f in items] == ["af_bella", "am_michael", "bf_emma"]
    assert items[1].name == "r9d3aaaa1111"  # no name declared: the id until Tavus fills it in
    assert faces.default_id() == "r67d1c9cac37"
    assert faces.resolve("rpinned").name == "Pinned"
    assert faces.resolve("nope") is None


def test_catalog_falls_back_to_the_single_face(monkeypatch):
    _tavus(monkeypatch, catalog="[]")
    monkeypatch.setattr(settings, "tavus_face_id", "rsingle")
    assert [f.id for f in faces.catalog()] == ["rsingle"]
    monkeypatch.setattr(settings, "avatar_provider", "none")
    assert faces.catalog() == []


def test_faces_endpoint_and_token_attribute(monkeypatch):
    _tavus(monkeypatch)
    with TestClient(app) as client:
        body = client.get("/v1/voice/faces").json()
        assert body["provider"] == "tavus" and body["default"] == "r67d1c9cac37"
        assert [(f["id"], f["voice"]) for f in body["faces"]] == [
            ("r67d1c9cac37", "af_bella"),
            ("r9d3aaaa1111", "am_michael"),
            ("rpinned", "bf_emma"),
        ]
        token = client.get(
            "/v1/voice/token", params={"session_id": "abc", "identity": "mo", "face_id": "r9d3aaaa1111"}
        ).json()
        assert token["face_id"] == "r9d3aaaa1111"
        assert _claims(token["token"])["attributes"] == {"avatar_face": "r9d3aaaa1111"}
        plain = client.get("/v1/voice/token", params={"session_id": "abc", "identity": "mo"}).json()
        assert plain["face_id"] is None and "attributes" not in _claims(plain["token"])
        unknown = client.get("/v1/voice/token", params={"session_id": "abc", "face_id": "rnope"})
        assert unknown.status_code == 400
        assert client.get("/v1/info").json()["voice"]["faces"] == 3


def test_enrichment_from_tavus_is_cached_and_tolerant(monkeypatch):
    _tavus(monkeypatch, api_key="k")
    calls = []

    def fake_tavus(face_ids, api_key):
        calls.append((tuple(face_ids), api_key))
        return {
            "r9d3aaaa1111": {
                "face_id": "r9d3aaaa1111",
                "face_name": "Nathan",
                "thumbnail_video_url": "https://cdn/n.mp4",
            },
            "r67d1c9cac37": {
                "face_id": "r67d1c9cac37",
                "face_name": "Jackie - Office",
                "thumbnail_video_url": "https://cdn/j.mp4",
            },
        }

    monkeypatch.setattr(faces, "_tavus_faces", fake_tavus)
    first = faces.enriched()
    assert first[0].name == "Jackie" and first[0].thumbnail_url == "https://cdn/j.mp4"  # declared name wins
    assert first[1].name == "Nathan" and first[1].thumbnail_url == "https://cdn/n.mp4"
    assert first[2].thumbnail_url is None
    faces.enriched()
    assert calls == [(("r67d1c9cac37", "r9d3aaaa1111", "rpinned"), "k")]

    faces.reset_cache()

    def failing(face_ids, api_key):
        raise httpx.ConnectError("offline")

    monkeypatch.setattr(faces, "_tavus_faces", failing)
    assert [f.name for f in faces.enriched()] == ["Jackie", "r9d3aaaa1111", "Pinned"]
