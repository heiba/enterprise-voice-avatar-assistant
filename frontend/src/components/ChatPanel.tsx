import { useEffect, useRef, useState, type FormEvent, type KeyboardEvent } from "react";
import type { ChatMessage } from "../types";

interface Props {
  messages: ChatMessage[];
  busy: boolean;
  onSend: (text: string) => void;
  onCite: (n: number) => void;
  onSelectMessage: (message: ChatMessage) => void;
}

const SUGGESTIONS = [
  "How often must administrator passwords be rotated?",
  "What happens after ten failed sign-in attempts?",
  "Which multi-factor authentication methods are approved?",
];

const MARKER = /\[(\d{1,2})\]/g;

/** Render answer text with [n] citation markers as clickable chips. */
function AnswerText({ text, onCite }: { text: string; onCite: (n: number) => void }) {
  const parts: Array<string | number> = [];
  let last = 0;
  for (const match of text.matchAll(MARKER)) {
    parts.push(text.slice(last, match.index));
    parts.push(Number(match[1]));
    last = (match.index ?? 0) + match[0].length;
  }
  parts.push(text.slice(last));
  return (
    <p>
      {parts.map((part, i) =>
        typeof part === "number" ? (
          <button key={i} type="button" className="cite" onClick={() => onCite(part)} aria-label={`Show citation ${part}`}>
            {part}
          </button>
        ) : (
          <span key={i}>{part}</span>
        ),
      )}
    </p>
  );
}

export function ChatPanel({ messages, busy, onSend, onCite, onSelectMessage }: Props) {
  const [draft, setDraft] = useState("");
  const bottom = useRef<HTMLDivElement>(null);

  useEffect(() => {
    bottom.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  const submit = (event?: FormEvent) => {
    event?.preventDefault();
    if (!draft.trim() || busy) return;
    onSend(draft);
    setDraft("");
  };

  const onKey = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      submit();
    }
  };

  return (
    <div className="chat">
      <div className="messages" aria-live="polite">
        {messages.length === 0 && (
          <div className="empty">
            <p>Ask about a policy, a procedure, or a document that has been uploaded to the assistant.</p>
            <div className="suggestions">
              {SUGGESTIONS.map((s) => (
                <button key={s} type="button" className="chip" onClick={() => onSend(s)} disabled={busy}>
                  {s}
                </button>
              ))}
            </div>
          </div>
        )}
        {messages.map((msg) => (
          <article
            key={msg.id}
            className={`message ${msg.role} ${msg.blocked ? "blocked" : ""} ${msg.error ? "error" : ""}`}
            onClick={() => msg.role === "assistant" && onSelectMessage(msg)}
          >
            <header>
              {msg.role === "user" ? "You" : "Assistant"}
              {msg.voice && <span className="tag voice-tag">voice</span>}
              {msg.blocked && <span className="tag">blocked by guardrails</span>}
            </header>
            {msg.pending ? (
              <p className="pending">Searching documents and writing an answer…</p>
            ) : msg.role === "assistant" ? (
              <AnswerText text={msg.content} onCite={onCite} />
            ) : (
              <p>{msg.content}</p>
            )}
            {msg.role === "assistant" && !msg.pending && !msg.error && (
              <footer className="ai-label">AI-generated. Check the cited sources.</footer>
            )}
          </article>
        ))}
        <div ref={bottom} />
      </div>
      <form className="composer" onSubmit={submit}>
        <textarea
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={onKey}
          placeholder="Type a question. Enter sends, Shift+Enter adds a line."
          rows={2}
          aria-label="Your question"
        />
        <button type="submit" disabled={busy || !draft.trim()}>
          {busy ? "Thinking…" : "Send"}
        </button>
      </form>
    </div>
  );
}
