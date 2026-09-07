import { useCallback, useEffect, useState } from "react";
import { ChatPanel } from "./components/ChatPanel";
import { ErrorBoundary } from "./components/ErrorBoundary";
import { CitationsPanel } from "./components/CitationsPanel";
import { Header } from "./components/Header";
import { StatusStrip } from "./components/StatusStrip";
import { VoicePanel } from "./components/VoicePanel";
import * as api from "./lib/api";
import type { AssistantTurn, ChatMessage, Citation, Info } from "./types";

const SESSION_KEY = "assistant.session";
const NAME_KEY = "assistant.user";

function newId() {
  return crypto.randomUUID ? crypto.randomUUID().replace(/-/g, "") : Math.random().toString(36).slice(2);
}

export default function App() {
  const [sessionId, setSessionId] = useState<string>(() => sessionStorage.getItem(SESSION_KEY) ?? newId());
  const [userName, setUserName] = useState<string>(() => localStorage.getItem(NAME_KEY) ?? "");
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [citations, setCitations] = useState<Citation[]>([]);
  const [selected, setSelected] = useState<number | null>(null);
  const [info, setInfo] = useState<Info | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    sessionStorage.setItem(SESSION_KEY, sessionId);
  }, [sessionId]);
  useEffect(() => {
    localStorage.setItem(NAME_KEY, userName);
  }, [userName]);
  useEffect(() => {
    api.info().then(setInfo).catch(() => setInfo(null));
  }, []);

  const send = useCallback(
    async (text: string) => {
      const question = text.trim();
      if (!question || busy) return;
      const userMessage: ChatMessage = { id: newId(), role: "user", content: question };
      const pendingId = newId();
      setMessages((m) => [...m, userMessage, { id: pendingId, role: "assistant", content: "", pending: true }]);
      setBusy(true);
      try {
        const reply = await api.chat({
          message: question,
          session_id: sessionId,
          user_id: userName.trim() || undefined,
        });
        setMessages((m) =>
          m.map((msg) =>
            msg.id === pendingId
              ? { id: pendingId, role: "assistant", content: reply.answer, citations: reply.citations, blocked: reply.blocked }
              : msg,
          ),
        );
        setCitations(reply.citations);
        setSelected(reply.citations.find((c) => c.used)?.n ?? null);
      } catch (error) {
        const detail = error instanceof Error ? error.message : String(error);
        setMessages((m) =>
          m.map((msg) =>
            msg.id === pendingId
              ? { id: pendingId, role: "assistant", content: `The assistant could not answer: ${detail}`, error: true }
              : msg,
          ),
        );
      } finally {
        setBusy(false);
      }
    },
    [busy, sessionId, userName],
  );

  const reset = useCallback(async () => {
    const old = sessionId;
    setMessages([]);
    setCitations([]);
    setSelected(null);
    setSessionId(newId());
    api.deleteSession(old).catch(() => undefined);
  }, [sessionId]);

  const onAssistantTurn = useCallback((turn: AssistantTurn) => {
    const entries: ChatMessage[] = [];
    if (turn.question) entries.push({ id: newId(), role: "user", content: turn.question, voice: true });
    entries.push({ id: newId(), role: "assistant", content: turn.answer, citations: turn.citations, blocked: turn.blocked, voice: true });
    setMessages((m) => [...m, ...entries]);
    setCitations(turn.citations);
    setSelected(turn.citations.find((c) => c.used)?.n ?? null);
  }, []);

  const showCitations = (msg: ChatMessage) => {
    if (msg.citations) {
      setCitations(msg.citations);
      setSelected(msg.citations.find((c) => c.used)?.n ?? null);
    }
  };

  return (
    <ErrorBoundary>
    <div className="app">
      <Header userName={userName} onUserName={setUserName} onReset={reset} sessionId={sessionId} />
      <div className="banner" role="note">
        <strong>AI-generated answers</strong> from company documents. Verify against the cited source before acting on them.
      </div>
      <main className="layout">
        <section className="avatar-column">
          <VoicePanel sessionId={sessionId} userName={userName} onAssistantTurn={onAssistantTurn} />
        </section>
        <section className="chat-column">
          <ChatPanel messages={messages} busy={busy} onSend={send} onCite={setSelected} onSelectMessage={showCitations} />
        </section>
        <aside className="citations-column">
          <CitationsPanel citations={citations} selected={selected} onSelect={setSelected} />
        </aside>
      </main>
      <StatusStrip info={info} />
    </div>
    </ErrorBoundary>
  );
}
