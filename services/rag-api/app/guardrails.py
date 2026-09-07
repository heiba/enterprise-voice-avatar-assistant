"""Input and output safety checks with a provider switch.

  none              always allow
  granite-guardian  Granite Guardian served by vLLM; the chat template answers <score>yes|no</score>
  llama-guard       Llama Guard served by vLLM; answers "safe" or "unsafe\\nS<n>"
  trustyai          TrustyAI Guardrails orchestrator detection API

Provider errors fail open by default (GUARDRAILS_FAIL_OPEN) so an unreachable
guard model degrades to "unchecked" instead of taking the assistant down.
"""

import logging
import re
from dataclasses import dataclass

import httpx

from . import clients
from .config import settings
from .tls import tls_context

log = logging.getLogger("rag.guardrails")
SCORE_RE = re.compile(r"<score>\s*(yes|no)\s*</score>", re.IGNORECASE)


@dataclass
class Verdict:
    allowed: bool
    provider: str
    category: str | None = None
    raw: str | None = None


def parse_granite(content: str) -> bool | None:
    """True when flagged, False when clean, None when the verdict is missing."""
    match = SCORE_RE.search(content or "")
    if not match:
        return None
    return match.group(1).lower() == "yes"


def parse_llama_guard(content: str) -> tuple[bool, str | None]:
    lines = [line.strip() for line in (content or "").strip().splitlines() if line.strip()]
    if not lines:
        return False, None
    if lines[0].lower().startswith("unsafe"):
        return True, lines[1] if len(lines) > 1 else None
    return False, None


def check_input(text: str) -> Verdict:
    return _check([{"role": "user", "content": text}], text)


def check_output(user_text: str, answer: str) -> Verdict:
    return _check([{"role": "user", "content": user_text}, {"role": "assistant", "content": answer}], answer)


def _check(messages: list[dict[str, str]], plain_text: str) -> Verdict:
    provider = settings.guardrails_provider.lower()
    if provider in ("", "none"):
        return Verdict(allowed=True, provider="none")
    try:
        if provider == "granite-guardian":
            content = _chat(messages)
            flagged = parse_granite(content)
            if flagged is None:
                log.warning("granite guardian returned no verdict: %r", content[:120])
                return Verdict(allowed=settings.guardrails_fail_open, provider=provider, raw=content)
            return Verdict(allowed=not flagged, provider=provider, category="harm" if flagged else None, raw=content)
        if provider == "llama-guard":
            content = _chat(messages)
            flagged, category = parse_llama_guard(content)
            return Verdict(allowed=not flagged, provider=provider, category=category, raw=content)
        if provider == "trustyai":
            return _trustyai(plain_text)
        log.warning("unknown guardrails provider %s; allowing", provider)
        return Verdict(allowed=True, provider=provider)
    except Exception as exc:  # noqa: BLE001
        log.warning("guardrails provider %s failed (%s); fail_open=%s", provider, exc, settings.guardrails_fail_open)
        return Verdict(allowed=settings.guardrails_fail_open, provider=provider, category="error", raw=str(exc)[:200])


def _chat(messages: list[dict[str, str]]) -> str:
    completion = clients.guardrails().chat.completions.create(
        model=settings.guardrails_model, messages=messages, max_tokens=40, temperature=0
    )
    return completion.choices[0].message.content or ""


def _trustyai(text: str) -> Verdict:
    url = settings.guardrails_base_url.rstrip("/") + "/api/v2/text/detection/content"
    with httpx.Client(verify=tls_context(), timeout=30) as http:
        response = http.post(url, json={"detectors": {settings.guardrails_detector: {}}, "content": text})
        response.raise_for_status()
        detections = response.json().get("detections") or []
    if detections:
        first = detections[0]
        return Verdict(allowed=False, provider="trustyai", category=first.get("detection_type") or first.get("detection"))
    return Verdict(allowed=True, provider="trustyai")
