"""Service requests as tickets with a small state machine, plus LLM-based request classification."""

import json
import logging
import re
from typing import Any

import httpx

from . import clients
from .config import settings
from .schemas import RequestIntake, Ticket, TicketCreate, TicketEvent, TicketUpdate

log = logging.getLogger("rag.tickets")

STATES = ["intake", "classified", "pending_approval", "approved", "rejected", "fulfilled", "cancelled"]
TRANSITIONS: dict[str, set[str]] = {
    "intake": {"classified", "pending_approval", "cancelled"},
    "classified": {"pending_approval", "approved", "cancelled"},
    "pending_approval": {"approved", "rejected", "cancelled"},
    "approved": {"fulfilled", "cancelled"},
    "rejected": set(),
    "fulfilled": set(),
    "cancelled": set(),
}
CATEGORIES = ["access_request", "hardware", "software", "hr", "facilities", "finance", "other"]


class TicketError(Exception):
    def __init__(self, status_code: int, detail: str) -> None:
        super().__init__(detail)
        self.status_code = status_code
        self.detail = detail


def can_transition(current: str, new: str) -> bool:
    return new in TRANSITIONS.get(current, set())


def _require_db() -> None:
    if not settings.database_url:
        raise TicketError(503, "tickets need DATABASE_URL")


def _row_to_ticket(row: dict[str, Any], events: list[dict[str, Any]]) -> Ticket:
    return Ticket(**{**row, "payload": row.get("payload") or {}},
                  events=[TicketEvent(**e) for e in events])


def _load(conn, ticket_id: int) -> Ticket:
    row = conn.execute("SELECT * FROM tickets WHERE id = %s", (ticket_id,)).fetchone()
    if row is None:
        raise TicketError(404, "ticket not found")
    events = conn.execute(
        "SELECT from_status, to_status, actor, note, created_at FROM ticket_events WHERE ticket_id = %s ORDER BY id",
        (ticket_id,),
    ).fetchall()
    return _row_to_ticket(dict(row), [dict(e) for e in events])


def resolve_id(ref: str) -> int:
    if ref.isdigit():
        return int(ref)
    match = re.fullmatch(r"REQ-0*(\d+)", ref.upper())
    if match:
        return int(match.group(1))
    raise TicketError(404, "ticket not found")


def create(data: TicketCreate, actor: str | None = None) -> Ticket:
    _require_db()
    with clients.db() as conn:
        row = conn.execute(
            """INSERT INTO tickets (title, description, category, priority, requester, session_id, payload)
               VALUES (%s, %s, %s, %s, %s, %s, %s::jsonb) RETURNING id""",
            (data.title, data.description, data.category, data.priority, data.requester, data.session_id,
             json.dumps(data.payload)),
        ).fetchone()
        ticket_id = row["id"]
        conn.execute("UPDATE tickets SET ticket_ref = %s WHERE id = %s", (f"REQ-{ticket_id:06d}", ticket_id))
        conn.execute(
            "INSERT INTO ticket_events (ticket_id, from_status, to_status, actor, note) VALUES (%s, NULL, 'intake', %s, %s)",
            (ticket_id, actor or data.requester, "created"),
        )
        conn.commit()
        return _load(conn, ticket_id)


def get(ref: str) -> Ticket:
    _require_db()
    with clients.db() as conn:
        return _load(conn, resolve_id(ref))


def list_tickets(status: str | None = None, limit: int = 50) -> list[Ticket]:
    _require_db()
    with clients.db() as conn:
        if status:
            rows = conn.execute("SELECT * FROM tickets WHERE status = %s ORDER BY id DESC LIMIT %s", (status, limit)).fetchall()
        else:
            rows = conn.execute("SELECT * FROM tickets ORDER BY id DESC LIMIT %s", (limit,)).fetchall()
        return [_row_to_ticket(dict(r), []) for r in rows]


def update(ref: str, data: TicketUpdate) -> Ticket:
    _require_db()
    ticket_id = resolve_id(ref)
    with clients.db() as conn:
        current = _load(conn, ticket_id)
        if data.status and data.status != current.status:
            if data.status not in STATES:
                raise TicketError(422, f"unknown status {data.status}")
            if not can_transition(current.status, data.status):
                raise TicketError(409, f"cannot move a ticket from {current.status} to {data.status}")
            conn.execute(
                """UPDATE tickets SET status = %s, updated_at = now(),
                   approver = CASE WHEN %s IN ('approved', 'rejected') THEN COALESCE(%s, approver) ELSE approver END,
                   decision_note = CASE WHEN %s IN ('approved', 'rejected') THEN COALESCE(%s, decision_note) ELSE decision_note END
                   WHERE id = %s""",
                (data.status, data.status, data.actor, data.status, data.note, ticket_id),
            )
            conn.execute(
                "INSERT INTO ticket_events (ticket_id, from_status, to_status, actor, note) VALUES (%s, %s, %s, %s, %s)",
                (ticket_id, current.status, data.status, data.actor, data.note),
            )
        elif data.note:
            conn.execute(
                "INSERT INTO ticket_events (ticket_id, from_status, to_status, actor, note) VALUES (%s, %s, %s, %s, %s)",
                (ticket_id, current.status, current.status, data.actor, data.note),
            )
        if data.payload is not None:
            conn.execute("UPDATE tickets SET payload = payload || %s::jsonb, updated_at = now() WHERE id = %s",
                         (json.dumps(data.payload), ticket_id))
        conn.commit()
        return _load(conn, ticket_id)


def classify_request(text: str) -> dict[str, Any]:
    system = (
        "You triage IT and workplace service requests. Respond with a single JSON object and nothing else, with keys: "
        '"title" (short imperative, max 12 words), "category" (one of ' + ", ".join(CATEGORIES) + '), '
        '"priority" (low, normal, high, urgent), "summary" (one sentence), '
        '"needs_approval" (true when the request grants access, costs money, or changes permissions), '
        '"details" (object with any specific items mentioned, for example {"software": "Visual Studio Code"}).'
    )
    kwargs: dict[str, Any] = {
        "model": settings.llm_model,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": text[:6000]}],
        "temperature": 0,
        "max_tokens": 400,
    }
    try:
        completion = clients.llm().chat.completions.create(response_format={"type": "json_object"}, **kwargs)
    except Exception:  # noqa: BLE001
        completion = clients.llm().chat.completions.create(**kwargs)
    content = completion.choices[0].message.content or "{}"
    try:
        data = json.loads(content)
    except json.JSONDecodeError:
        match = re.search(r"\{.*\}", content, re.DOTALL)
        data = json.loads(match.group(0)) if match else {}
    category = str(data.get("category", "other")).lower()
    priority = str(data.get("priority", "normal")).lower()
    return {
        "title": str(data.get("title") or text[:80]),
        "category": category if category in CATEGORIES else "other",
        "priority": priority if priority in ("low", "normal", "high", "urgent") else "normal",
        "summary": str(data.get("summary", "")),
        "needs_approval": bool(data.get("needs_approval", True)),
        "details": data.get("details") if isinstance(data.get("details"), dict) else {},
    }


def notify_n8n(ticket: Ticket, classification: dict[str, Any], channel: str) -> bool:
    url = settings.n8n_url.rstrip("/") + settings.n8n_request_webhook_path
    body = {"ticket": ticket.model_dump(mode="json"), "classification": classification, "channel": channel}
    try:
        with httpx.Client(timeout=10) as http:
            response = http.post(url, json=body)
        if response.status_code >= 400:
            log.warning("n8n request webhook returned %s", response.status_code)
            return False
        return True
    except httpx.HTTPError as exc:
        log.warning("n8n request webhook unreachable: %s", exc)
        return False


def intake(request: RequestIntake) -> tuple[Ticket, dict[str, Any], bool]:
    classification = classify_request(request.text)
    ticket = create(
        TicketCreate(
            title=classification["title"],
            description=request.text,
            category=classification["category"],
            priority=classification["priority"],
            requester=request.requester or request.user_id,
            session_id=request.session_id,
            payload={"channel": request.channel, "summary": classification["summary"], **classification["details"]},
            needs_approval=classification["needs_approval"],
        ),
        actor=request.requester or request.user_id,
    )
    ticket = update(str(ticket.id), TicketUpdate(status="classified", actor="assistant", note=classification["summary"]))
    if classification["needs_approval"]:
        ticket = update(str(ticket.id), TicketUpdate(status="pending_approval", actor="assistant", note="awaiting approval"))
    notified = notify_n8n(ticket, classification, request.channel)
    return ticket, classification, notified
