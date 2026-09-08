-- Tracks questions where the RAG pipeline could not provide a confident answer,
-- so knowledge gaps can be surfaced to content owners.
CREATE TABLE IF NOT EXISTS knowledge_gaps (
  id          BIGSERIAL PRIMARY KEY,
  session_id  TEXT,
  question    TEXT NOT NULL,
  top_score   REAL NOT NULL DEFAULT 0,
  hit_count   INTEGER NOT NULL DEFAULT 0,
  reason      TEXT NOT NULL DEFAULT 'no_hits',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS knowledge_gaps_created_idx ON knowledge_gaps (created_at DESC);
