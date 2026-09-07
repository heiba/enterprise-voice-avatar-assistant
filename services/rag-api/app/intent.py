"""Tells a service request apart from a question, so chat and voice can file tickets in-conversation."""

import logging

from . import clients
from .config import settings

log = logging.getLogger("rag.intent")

SYSTEM = (
    "You classify the latest message from an employee talking to a company assistant. Answer with exactly one word.\n"
    "REQUEST: the employee asks the company to do or provide something for them: equipment, software, licences, "
    "access or permissions, a password or account reset, a booking, a purchase, a repair, an HR or facilities action; "
    "also when they describe a problem and want it fixed or replaced.\n"
    "QUESTION: anything else: asking for information or how something works, small talk, thanks, a follow-up on an "
    "answer, or asking how to request something without actually requesting it.\n"
    "Examples: 'I need a new laptop, mine no longer boots' -> REQUEST. 'Can I get access to the finance share?' -> "
    "REQUEST. 'How often must passwords be rotated?' -> QUESTION. 'How do I request a laptop?' -> QUESTION. "
    "'Thanks!' -> QUESTION."
)


def detect(message: str) -> str:
    """Return 'request' or 'question'. Any failure counts as a question so answering never breaks."""
    if not settings.request_intent_detection:
        return "question"
    try:
        completion = clients.llm().chat.completions.create(
            model=settings.llm_model,
            messages=[{"role": "system", "content": SYSTEM}, {"role": "user", "content": message[:2000]}],
            temperature=0,
            max_tokens=4,
        )
    except Exception as exc:  # noqa: BLE001
        log.warning("intent detection failed, treating as a question: %s", exc)
        return "question"
    word = (completion.choices[0].message.content or "").strip().upper()
    return "request" if word.startswith("REQUEST") else "question"
