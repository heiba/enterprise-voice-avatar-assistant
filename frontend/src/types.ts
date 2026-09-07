export interface Citation {
  n: number;
  used: boolean;
  doc_id: string;
  source: string;
  page: number | null;
  headings: string[];
  snippet: string;
  score: number;
}

export interface GuardrailInfo {
  provider: string;
  input_flagged: boolean;
  output_flagged: boolean;
  category: string | null;
}

export interface ChatResponse {
  session_id: string;
  answer: string;
  citations: Citation[];
  blocked: boolean;
  guardrail: GuardrailInfo;
  model: string;
}

export interface ChatMessage {
  id: string;
  role: "user" | "assistant";
  content: string;
  citations?: Citation[];
  blocked?: boolean;
  pending?: boolean;
  error?: boolean;
}

export interface Info {
  llm: { model: string; base_url: string };
  embeddings: { model: string; base_url: string };
  guardrails: { provider: string; model: string };
  retrieval: { collection: string; top_k: number; min_score: number };
  memory: boolean;
  voice: { livekit_url: string };
}
