"""Pure helpers, kept free of LiveKit imports so they are easy to test."""

import json
import re
from typing import Any

MARKER_RE = re.compile(r"\s*\[\d{1,2}\]")
MARKDOWN_RE = re.compile(r"[*_`#]+")
BULLET_RE = re.compile(r"^\s*(?:[-*]|\d+[.)])\s+", re.MULTILINE)
SPACES_RE = re.compile(r"[ \t]{2,}")
ROOM_PREFIX = "session-"
IDENTITY_PREFIX = "user-"


def speakable(text: str) -> str:
    """Strip citation markers and Markdown so the text reads naturally when spoken."""
    text = MARKER_RE.sub("", text)
    text = MARKDOWN_RE.sub("", text)
    text = BULLET_RE.sub("", text)
    text = SPACES_RE.sub(" ", text)
    text = re.sub(r"\s+([.,;:!?])", r"\1", text)
    return text.strip()


def session_id_from_room(room_name: str) -> str:
    """The frontend names rooms session-<id>; the RAG API session is the <id> part."""
    return room_name.removeprefix(ROOM_PREFIX)


def user_id_from_identity(identity: str | None) -> str | None:
    if not identity:
        return None
    return identity.removeprefix(IDENTITY_PREFIX)


def last_user_text(chat_ctx: Any) -> str:
    """Return the text of the most recent user message in a LiveKit ChatContext (or anything shaped like it)."""
    items = getattr(chat_ctx, "items", None) or getattr(chat_ctx, "messages", None) or []
    for item in reversed(list(items)):
        if getattr(item, "role", None) != "user":
            continue
        text = getattr(item, "text_content", None)
        if not text:
            content = getattr(item, "content", None)
            if isinstance(content, str):
                text = content
            elif isinstance(content, list):
                text = " ".join(part for part in content if isinstance(part, str))
        if text and text.strip():
            return text.strip()
    return ""


def citations_payload(reply: dict[str, Any], question: str | None = None) -> bytes:
    """Data-channel message for the frontend: the transcribed question, the answer, and its citations."""
    return json.dumps(
        {
            "type": "assistant.answer",
            "session_id": reply.get("session_id"),
            "question": question or "",
            "answer": reply.get("answer", ""),
            "blocked": bool(reply.get("blocked")),
            "citations": reply.get("citations", []),
            "ticket": reply.get("ticket"),
        }
    ).encode("utf-8")
