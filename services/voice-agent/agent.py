"""LiveKit Agents worker.

Pipeline per user turn: Silero VAD detects the end of speech, Whisper transcribes,
the RAG API answers (grounded, with memory and guardrails, in voice mode), the
answer is published to the room for the UI and spoken through TTS. With an avatar
provider configured, the provider publishes the audio and a lip-synced video track.

Run:  python agent.py start        (worker registers with LiveKit and joins new rooms)
      python agent.py download-files
"""

import logging

import openai as openai_sdk
from livekit import rtc
from livekit.agents import Agent, AgentSession, JobContext, JobProcess, RoomOutputOptions, WorkerOptions, cli
from livekit.plugins import openai, silero

from app import avatars, helpers, rag_client
from app.config import settings
from app.tls import async_http_client

log = logging.getLogger("voice-agent")


def build_stt():
    client = openai_sdk.AsyncClient(
        base_url=settings.stt_base_url, api_key=settings.stt_api_key or "none", http_client=async_http_client(60)
    )
    return openai.STT(model=settings.stt_model, language=settings.stt_language, client=client)


def build_tts():
    if settings.tts_provider.lower() == "elevenlabs":
        from livekit.plugins import elevenlabs

        return elevenlabs.TTS(
            voice_id=settings.elevenlabs_voice_id, model=settings.elevenlabs_model, api_key=settings.elevenlabs_api_key
        )
    client = openai_sdk.AsyncClient(
        base_url=settings.tts_base_url, api_key=settings.tts_api_key or "none", http_client=async_http_client(60)
    )
    return openai.TTS(model=settings.tts_model, voice=settings.tts_voice, speed=settings.tts_speed, client=client)


def build_llm():
    """Direct LLM, only used by the framework if a turn bypasses llm_node."""
    return openai.LLM(model=settings.llm_model, base_url=settings.llm_base_url, api_key=settings.llm_api_key or "none")


class Assistant(Agent):
    def __init__(self, room: rtc.Room, session_id: str, user_id: str | None) -> None:
        super().__init__(instructions=settings.instructions)
        self._room = room
        self._session_id = session_id
        self._user_id = user_id

    async def llm_node(self, chat_ctx, tools, model_settings):
        """Replace the LLM step with a call to the RAG API so voice and text share one answer path."""
        text = helpers.last_user_text(chat_ctx)
        if not text:
            return
        try:
            reply = await rag_client.chat(text, self._session_id, self._user_id)
        except Exception:
            log.exception("RAG API call failed for session %s", self._session_id)
            yield "Sorry, I could not reach the knowledge base just now. Please try again in a moment."
            return
        await self._publish(reply, text)
        answer = helpers.speakable(reply.get("answer", ""))
        log.info("session=%s blocked=%s answer=%r", self._session_id, reply.get("blocked"), answer[:80])
        yield answer

    async def _publish(self, reply: dict, question: str) -> None:
        try:
            await self._room.local_participant.publish_data(
                helpers.citations_payload(reply, question), reliable=True, topic="assistant"
            )
        except Exception as exc:  # noqa: BLE001
            log.warning("could not publish citations to the room: %s", exc)


def prewarm(proc: JobProcess) -> None:
    proc.userdata["vad"] = silero.VAD.load()


async def entrypoint(ctx: JobContext) -> None:
    await ctx.connect()
    participant = await ctx.wait_for_participant()
    session_id = helpers.session_id_from_room(ctx.room.name)
    user_id = helpers.user_id_from_identity(participant.identity if participant else None)
    log.info("joined room %s (session %s) for participant %s", ctx.room.name, session_id, user_id)

    session = AgentSession(
        vad=ctx.proc.userdata["vad"],
        stt=build_stt(),
        tts=build_tts(),
        llm=build_llm(),
        allow_interruptions=True,
        min_endpointing_delay=settings.min_endpointing_delay,
    )
    avatar = await avatars.start(session, ctx.room)
    await session.start(
        agent=Assistant(ctx.room, session_id, user_id),
        room=ctx.room,
        room_output_options=RoomOutputOptions(audio_enabled=avatar is None),
    )
    if settings.greeting:
        await session.say(settings.greeting, allow_interruptions=True)


if __name__ == "__main__":
    logging.basicConfig(level=settings.log_level.upper(), format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    cli.run_app(
        WorkerOptions(
            entrypoint_fnc=entrypoint,
            prewarm_fnc=prewarm,
            ws_url=settings.livekit_url,
            api_key=settings.livekit_api_key,
            api_secret=settings.livekit_api_secret,
            port=settings.agent_port,
        )
    )
