from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, Field


class Citation(BaseModel):
    n: int = Field(description="Number used in the answer's [n] markers")
    used: bool = Field(default=False, description="True when the answer cites this passage")
    doc_id: str
    source: str
    page: int | None = None
    headings: list[str] = Field(default_factory=list)
    snippet: str
    score: float


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=8000)
    session_id: str | None = Field(
        default=None, description="Conversation id; a new one is created when omitted"
    )
    user_id: str | None = None
    mode: Literal["text", "voice"] = "text"
    top_k: int | None = Field(default=None, ge=1, le=20)


class GuardrailInfo(BaseModel):
    provider: str
    input_flagged: bool = False
    output_flagged: bool = False
    category: str | None = None


class ChatResponse(BaseModel):
    session_id: str
    answer: str
    citations: list[Citation] = Field(default_factory=list)
    blocked: bool = False
    guardrail: GuardrailInfo
    model: str
    # Set when the message was a service request and a ticket was filed instead of answering
    ticket: "Ticket | None" = None


class SearchRequest(BaseModel):
    query: str = Field(min_length=1, max_length=4000)
    top_k: int | None = Field(default=None, ge=1, le=50)
    min_score: float | None = None


class SearchResponse(BaseModel):
    hits: list[Citation]


class Message(BaseModel):
    role: str
    content: str
    citations: list[Citation] = Field(default_factory=list)
    blocked: bool = False
    created_at: datetime | None = None


class UserMemoryItem(BaseModel):
    key: str = Field(min_length=1, max_length=100)
    value: str = Field(max_length=2000)


class ClassifyRequest(BaseModel):
    text: str | None = Field(default=None, max_length=200000)
    bucket: str | None = None
    key: str | None = None
    filename: str | None = None


class ClassifyResponse(BaseModel):
    doc_id: str | None = None
    source: str | None = None
    doc_type: str
    confidence: float = 0.0
    summary: str = ""
    fields: dict[str, Any] = Field(default_factory=dict)
    model: str


class TicketCreate(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    description: str | None = None
    category: str | None = None
    priority: Literal["low", "normal", "high", "urgent"] = "normal"
    requester: str | None = None
    session_id: str | None = None
    payload: dict[str, Any] = Field(default_factory=dict)
    needs_approval: bool = True


class TicketUpdate(BaseModel):
    status: str | None = None
    note: str | None = None
    actor: str | None = None
    payload: dict[str, Any] | None = None


class TicketEvent(BaseModel):
    from_status: str | None
    to_status: str
    actor: str | None
    note: str | None
    created_at: datetime


class Ticket(BaseModel):
    id: int
    ticket_ref: str
    title: str
    description: str | None = None
    category: str | None = None
    priority: str
    status: str
    requester: str | None = None
    session_id: str | None = None
    payload: dict[str, Any] = Field(default_factory=dict)
    approver: str | None = None
    decision_note: str | None = None
    created_at: datetime
    updated_at: datetime
    events: list[TicketEvent] = Field(default_factory=list)


class RequestIntake(BaseModel):
    text: str = Field(min_length=1, max_length=8000)
    session_id: str | None = None
    user_id: str | None = None
    requester: str | None = None
    channel: Literal["chat", "voice", "form", "slack"] = "chat"


class RequestIntakeResponse(BaseModel):
    ticket: Ticket
    classification: dict[str, Any]
    notified: bool


class VoiceTokenResponse(BaseModel):
    token: str
    url: str
    room: str
    identity: str
    session_id: str


class Notification(BaseModel):
    id: int
    session_id: str
    ticket_ref: str | None = None
    kind: str = "ticket_update"
    text: str
    created_at: datetime


class NotificationAck(BaseModel):
    ids: list[int]


ChatResponse.model_rebuild()
