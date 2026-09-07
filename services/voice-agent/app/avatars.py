"""Avatar provider factory. Providers are imported lazily so unused ones cost nothing."""

import logging
from typing import Any

from .config import settings

log = logging.getLogger("voice-agent.avatar")

PROVIDERS = ("none", "simli", "tavus", "hedra")


def provider() -> str:
    name = (settings.avatar_provider or "none").strip().lower()
    if name not in PROVIDERS:
        raise RuntimeError(f"unknown avatar provider {name!r}; expected one of {PROVIDERS}")
    return name


def _require(value: str | None, name: str) -> str:
    if not value:
        raise RuntimeError(f"{name} is required for avatar provider {provider()!r}")
    return value


def build() -> Any | None:
    """Return an avatar session object for the configured provider, or None for audio only."""
    name = provider()
    if name == "none":
        return None
    if name == "simli":
        from livekit.plugins import simli

        return simli.AvatarSession(
            simli_config=simli.SimliConfig(
                api_key=_require(settings.simli_api_key, "SIMLI_API_KEY"),
                face_id=_require(settings.simli_face_id, "SIMLI_FACE_ID"),
            )
        )
    if name == "tavus":
        from livekit.plugins import tavus

        return tavus.AvatarSession(
            replica_id=_require(settings.tavus_replica_id, "TAVUS_REPLICA_ID"),
            persona_id=settings.tavus_persona_id,
            api_key=_require(settings.tavus_api_key, "TAVUS_API_KEY"),
        )
    if name == "hedra":
        from livekit.plugins import hedra

        return hedra.AvatarSession(
            avatar_image=_require(settings.hedra_avatar_image, "HEDRA_AVATAR_IMAGE"),
            api_key=_require(settings.hedra_api_key, "HEDRA_API_KEY"),
        )
    return None


async def start(session: Any, room: Any) -> Any | None:
    """Build and start the avatar for this room. The avatar publishes the agent's audio and its video."""
    avatar = build()
    if avatar is None:
        log.info("no avatar provider configured; publishing audio only")
        return None
    await avatar.start(session, room=room)
    log.info("avatar provider %s started", provider())
    return avatar
