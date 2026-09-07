import type { ChatResponse, Info, VoiceToken } from "../types";

const BASE = import.meta.env.VITE_API_BASE ?? "/api";

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${BASE}${path}`, {
    headers: { "Content-Type": "application/json" },
    ...init,
  });
  if (!response.ok) {
    let detail = `${response.status} ${response.statusText}`;
    try {
      const body = await response.json();
      if (body?.detail) detail = typeof body.detail === "string" ? body.detail : JSON.stringify(body.detail);
    } catch {
      /* no JSON body */
    }
    throw new Error(detail);
  }
  return response.json() as Promise<T>;
}

export function chat(body: { message: string; session_id?: string; user_id?: string; mode?: "text" | "voice" }) {
  return request<ChatResponse>("/v1/chat", { method: "POST", body: JSON.stringify(body) });
}

export function info() {
  return request<Info>("/v1/info");
}

export function deleteSession(sessionId: string) {
  return request<{ deleted: string }>(`/v1/sessions/${encodeURIComponent(sessionId)}`, { method: "DELETE" });
}

export function voiceToken(params: { session_id: string; identity: string; name?: string }) {
  const query = new URLSearchParams({ session_id: params.session_id, identity: params.identity });
  if (params.name) query.set("name", params.name);
  return request<VoiceToken>(`/v1/voice/token?${query.toString()}`);
}
