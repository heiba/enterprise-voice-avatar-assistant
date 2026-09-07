-- Outcome notices pushed back into a conversation, for example the decision on a
-- service request. Written when a ticket changes state; read by whichever client is
-- live for the session (the voice agent speaks them, the frontend shows them).
CREATE TABLE IF NOT EXISTS session_notifications (
  id           BIGSERIAL PRIMARY KEY,
  session_id   TEXT NOT NULL,
  ticket_ref   TEXT,
  kind         TEXT NOT NULL DEFAULT 'ticket_update',
  text         TEXT NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  delivered_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS session_notifications_pending_idx
  ON session_notifications (session_id, id) WHERE delivered_at IS NULL;
