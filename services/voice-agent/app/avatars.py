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
        import inspect

        from livekit.plugins import tavus

        face_id = _require(settings.tavus_face_id or settings.tavus_replica_id, "TAVUS_FACE_ID")
        pal_id = settings.tavus_pal_id or settings.tavus_persona_id
        api_key = _require(settings.tavus_api_key, "TAVUS_API_KEY")
        # Tavus renamed replicas to faces and personas to PALs; support both plugin generations.
        params = inspect.signature(tavus.AvatarSession.__init__).parameters
        if "face_id" in params:
            kwargs: dict[str, Any] = {"face_id": face_id, "api_key": api_key}
            if pal_id:
                kwargs["pal_id"] = pal_id
        else:
            kwargs = {"replica_id": face_id, "api_key": api_key}
            if pal_id:
                kwargs["persona_id"] = pal_id
        return tavus.AvatarSession(**kwargs)
    if name == "hedra":
        from livekit.plugins import hedra

        return hedra.AvatarSession(
            avatar_image=_require(settings.hedra_avatar_image, "HEDRA_AVATAR_IMAGE"),
            api_key=_require(settings.hedra_api_key, "HEDRA_API_KEY"),
        )
    return None


def start_kwargs(avatar: Any) -> dict[str, Any]:
    """Extra arguments for the provider's start(): cloud providers must join the room through the
    public LiveKit URL, not the in-cluster address this worker registers with."""
    import inspect

    kwargs: dict[str, Any] = {}
    try:
        params = inspect.signature(avatar.start).parameters
    except (TypeError, ValueError):
        return kwargs
    if "livekit_url" in params and settings.livekit_public_url:
        kwargs["livekit_url"] = settings.livekit_public_url
    return kwargs


async def start(session: Any, room: Any) -> Any | None:
    """Build and start the avatar for this room. The avatar publishes the agent's audio and its video."""
    avatar = build()
    if avatar is None:
        log.info("no avatar provider configured; publishing audio only")
        return None
    kwargs = start_kwargs(avatar)
    log.info(
        "starting avatar provider %s (livekit url for the provider: %s)",
        provider(),
        kwargs.get("livekit_url", "default"),
    )
    await avatar.start(session, room=room, **kwargs)
    log.info("avatar provider %s started", provider())
    return avatar
