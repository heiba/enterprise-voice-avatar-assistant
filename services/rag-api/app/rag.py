"""The grounded chat: guardrails, retrieval, prompt assembly, generation, citations, memory."""

import logging
import re
import uuid

from . import clients, guardrails, memory, retrieval
from .config import VOICE_STYLE, settings
from .retrieval import Hit
from .schemas import ChatRequest, ChatResponse, Citation, GuardrailInfo

log = logging.getLogger("rag.chat")
MARKER_RE = re.compile(r"\[(\d{1,2})\]")


def build_context(hits: list[Hit]) -> str:
    parts: list[str] = []
    total = 0
    for n, hit in enumerate(hits, start=1):
        where = f"source: {hit.source}" + (f", page {hit.page}" if hit.page else "")
        block = f"[{n}] ({where})\n{hit.text.strip()}"
        if total + len(block) > settings.max_context_chars:
            break
        parts.append(block)
        total += len(block)
    return "\n\n".join(parts)


def build_messages(question: str, hits: list[Hit], history: list[dict[str, str]], mode: str,
                   user_memory: dict[str, str] | None = None) -> list[dict[str, str]]:
    system = settings.system_prompt.format(assistant_name=settings.assistant_name)
    if mode == "voice":
        system += VOICE_STYLE
    if user_memory:
        facts = "\n".join(f"- {k}: {v}" for k, v in user_memory.items())
        system += f"\n\nWhat you remember about this user:\n{facts}"
    context = build_context(hits) if hits else "(no relevant company documents were found)"
    system += f"\n\nContext:\n{context}"
    return [{"role": "system", "content": system}, *history, {"role": "user", "content": question}]


def cited_numbers(answer: str, max_n: int) -> set[int]:
    return {int(m) for m in MARKER_RE.findall(answer or "") if 1 <= int(m) <= max_n}


def retrieval_query(message: str, history: list[dict[str, str]]) -> str:
    """Short follow-ups carry little meaning alone; prepend the previous user question for retrieval only."""
    if len(message.split()) <= settings.followup_max_words:
        previous = [m["content"] for m in history if m.get("role") == "user"]
        if previous:
            return f"{previous[-1]} {message}"
    return message


def answer(request: ChatRequest) -> ChatResponse:
    session_id = request.session_id or uuid.uuid4().hex
    memory.ensure_conversation(session_id, request.user_id, request.mode)
    info = GuardrailInfo(provider=settings.guardrails_provider)

    verdict = guardrails.check_input(request.message)
    if not verdict.allowed:
        info.input_flagged, info.category = True, verdict.category
        memory.append(session_id, "user", request.message, blocked=True)
        memory.append(session_id, "assistant", settings.blocked_message, blocked=True)
        return ChatResponse(session_id=session_id, answer=settings.blocked_message, citations=[], blocked=True,
                            guardrail=info, model=settings.llm_model)

    history = memory.history(session_id, settings.history_turns * 2)
    hits = retrieval.search(retrieval_query(request.message, history), top_k=request.top_k)
    user_memory = memory.get_user_memory(request.user_id) if request.user_id else {}
    messages = build_messages(request.message, hits, history, request.mode, user_memory)

    completion = clients.llm().chat.completions.create(
        model=settings.llm_model,
        messages=messages,
        temperature=settings.llm_temperature,
        max_tokens=settings.voice_max_tokens if request.mode == "voice" else settings.answer_max_tokens,
    )
    text = (completion.choices[0].message.content or "").strip()

    blocked = False
    out = guardrails.check_output(request.message, text)
    if not out.allowed:
        info.output_flagged, info.category = True, out.category
        text, blocked = settings.blocked_message, True

    used = cited_numbers(text, len(hits))
    citations: list[Citation] = [hit.to_citation(n, used=n in used) for n, hit in enumerate(hits, start=1)]

    memory.append(session_id, "user", request.message)
    memory.append(session_id, "assistant", text, citations=citations, blocked=blocked)
    log.info("session=%s hits=%d cited=%s blocked=%s", session_id, len(hits), sorted(used), blocked)
    return ChatResponse(session_id=session_id, answer=text, citations=citations, blocked=blocked, guardrail=info,
                        model=settings.llm_model)
