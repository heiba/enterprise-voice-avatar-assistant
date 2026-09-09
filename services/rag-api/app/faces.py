"""Avatar faces a person can pick before a voice session, and the voice each face speaks with.

The catalog comes from the chart (AVATAR_FACES, a JSON list of {id, name?, gender?, voice?}).
Tavus publishes no gender for its faces, so the operator declares it once per face; the voice
follows from it (TTS_VOICE_FEMALE / TTS_VOICE_MALE) unless the face pins a voice. Names and
thumbnails missing from the catalog are filled in from the Tavus API when a key is available.
The voice agent applies the same catalog when it joins the room.
"""

from __future__ import annotations

import json
import logging
import threading
import time
from dataclasses import dataclass, replace

import httpx

from .config import settings

log = logging.getLogger("rag.faces")

TAVUS_API_URL = "https://tavusapi.com/v2"
GENDERS = ("female", "male")
FACE_ATTRIBUTE = "avatar_face"  # LiveKit participant attribute carrying the chosen face
CACHE_SECONDS = 3600.0
RETRY_SECONDS = 300.0


@dataclass(frozen=True)
class Face:
    id: str
    name: str
    gender: str | None = None
    voice: str | None = None
    thumbnail_url: str | None = None


def _text(value: object) -> str:
    return str(value).strip() if value is not None else ""


def parse(raw: str) -> list[Face]:
    try:
        items = json.loads(raw or "[]")
    except json.JSONDecodeError:
        log.warning("AVATAR_FACES is not valid JSON; no faces offered")
        return []
    faces: list[Face] = []
    for item in items if isinstance(items, list) else []:
        if not isinstance(item, dict):
            continue
        face_id = _text(item.get("id"))
        if not face_id:
            continue
        gender = _text(item.get("gender")).lower() or None
        if gender and gender not in GENDERS:
            log.warning("face %s: gender %r is not female or male; using the default voice", face_id, gender)
            gender = None
        faces.append(
            Face(
                id=face_id,
                name=_text(item.get("name")) or face_id,
                gender=gender,
                voice=_text(item.get("voice")) or None,
                thumbnail_url=_text(item.get("thumbnail_url")) or None,
            )
        )
    return faces


def catalog() -> list[Face]:
    """Declared faces (Tavus only). Without a list, the single configured face is offered by id."""
    if (settings.avatar_provider or "none").lower() != "tavus":
        return []
    faces = parse(settings.avatar_faces)
    if not faces and settings.tavus_face_id:
        faces = [Face(id=settings.tavus_face_id, name=settings.tavus_face_id)]
    return faces


def voice_for(face: Face) -> str:
    if face.voice:
        return face.voice
    if face.gender == "female":
        return settings.tts_voice_female
    if face.gender == "male":
        return settings.tts_voice_male
    return settings.tts_voice


def resolve(face_id: str | None) -> Face | None:
    if not face_id:
        return None
    return next((face for face in catalog() if face.id == face_id), None)


def default_id() -> str | None:
    faces = catalog()
    return faces[0].id if faces else None


# --- Tavus enrichment (names and thumbnails) -------------------------------------------------

_lock = threading.Lock()
_cache: dict[str, object] = {}


def _tavus_faces(face_ids: list[str], api_key: str) -> dict[str, dict]:
    """Face details from Tavus keyed by id; the list endpoint accepts a comma-separated filter."""
    with httpx.Client(timeout=httpx.Timeout(15.0, connect=5.0)) as http:
        response = http.get(
            f"{TAVUS_API_URL}/faces",
            params={"face_ids": ",".join(face_ids), "verbose": "true", "limit": max(len(face_ids), 1)},
            headers={"x-api-key": api_key},
        )
        response.raise_for_status()
        body = response.json()
    items = body.get("data", body) if isinstance(body, dict) else body
    details: dict[str, dict] = {}
    for item in items if isinstance(items, list) else []:
        if isinstance(item, dict) and item.get("face_id"):
            details[str(item["face_id"])] = item
    return details


def _merge(face: Face, detail: dict | None) -> Face:
    if not detail:
        return face
    name = face.name if face.name != face.id else (_text(detail.get("face_name")) or face.name)
    thumbnail = face.thumbnail_url or _text(detail.get("thumbnail_video_url")) or None
    return replace(face, name=name, thumbnail_url=thumbnail)


def enriched() -> list[Face]:
    """The catalog with names and thumbnails from Tavus, cached; the plain catalog if Tavus is unreachable."""
    faces = catalog()
    if not faces or not settings.tavus_api_key:
        return faces
    key = tuple(face.id for face in faces)
    now = time.monotonic()
    with _lock:
        if _cache.get("key") == key and now < float(_cache.get("expires", 0.0)):
            return list(_cache["faces"])  # type: ignore[arg-type]
        try:
            details = _tavus_faces(list(key), settings.tavus_api_key)
            result = [_merge(face, details.get(face.id)) for face in faces]
            ttl = CACHE_SECONDS
        except (httpx.HTTPError, ValueError) as exc:
            log.warning("could not read face details from Tavus: %s", exc)
            result, ttl = faces, RETRY_SECONDS
        _cache.update(key=key, faces=result, expires=now + ttl)
    return result


def reset_cache() -> None:
    with _lock:
        _cache.clear()
