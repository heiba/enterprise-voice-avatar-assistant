import type { Info } from "../types";

export function StatusStrip({ info }: { info: Info | null }) {
  if (!info) {
    return <footer className="status">Connecting to the assistant API…</footer>;
  }
  return (
    <footer className="status">
      <span><b>LLM</b> {info.llm.model}</span>
      <span><b>Embeddings</b> {info.embeddings.model}</span>
      <span><b>Guardrails</b> {info.guardrails.provider === "none" ? "off" : `${info.guardrails.provider} (${info.guardrails.model})`}</span>
      <span><b>Memory</b> {info.memory ? "on" : "off"}</span>
      <span><b>Workflows</b> n8n</span>
      <span><b>Collection</b> {info.retrieval.collection} · top {info.retrieval.top_k}</span>
    </footer>
  );
}
