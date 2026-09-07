-- Schema shared by the RAG API (owner) and the ingestion service (documents table).
-- Every statement is idempotent; the services run this file at startup.

CREATE TABLE IF NOT EXISTS conversations (
  session_id  TEXT PRIMARY KEY,
  user_id     TEXT,
  channel     TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS messages (
  id          BIGSERIAL PRIMARY KEY,
  session_id  TEXT NOT NULL REFERENCES conversations(session_id) ON DELETE CASCADE,
  role        TEXT NOT NULL,
  content     TEXT NOT NULL,
  citations   JSONB NOT NULL DEFAULT '[]'::jsonb,
  blocked     BOOLEAN NOT NULL DEFAULT false,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS messages_session_idx ON messages (session_id, id);

CREATE TABLE IF NOT EXISTS user_memory (
  user_id     TEXT NOT NULL,
  key         TEXT NOT NULL,
  value       TEXT NOT NULL,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, key)
);

CREATE TABLE IF NOT EXISTS documents (
  doc_id      TEXT PRIMARY KEY,
  source      TEXT NOT NULL,
  source_uri  TEXT NOT NULL,
  doc_type    TEXT,
  pages       INTEGER,
  chunks      INTEGER,
  metadata    JSONB NOT NULL DEFAULT '{}'::jsonb,
  extracted   JSONB,
  ingested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tickets (
  id            BIGSERIAL PRIMARY KEY,
  ticket_ref    TEXT UNIQUE,
  title         TEXT NOT NULL,
  description   TEXT,
  category      TEXT,
  priority      TEXT NOT NULL DEFAULT 'normal',
  status        TEXT NOT NULL DEFAULT 'intake',
  requester     TEXT,
  session_id    TEXT,
  payload       JSONB NOT NULL DEFAULT '{}'::jsonb,
  approver      TEXT,
  decision_note TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ticket_events (
  id          BIGSERIAL PRIMARY KEY,
  ticket_id   BIGINT NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
  from_status TEXT,
  to_status   TEXT NOT NULL,
  actor       TEXT,
  note        TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ticket_events_ticket_idx ON ticket_events (ticket_id, id);
