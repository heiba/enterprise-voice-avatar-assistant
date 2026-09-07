import { useState } from "react";
import {
  BarVisualizer,
  LiveKitRoom,
  RoomAudioRenderer,
  VideoTrack,
  useConnectionState,
  useDataChannel,
  useLocalParticipant,
  useRoomContext,
  useVoiceAssistant,
} from "@livekit/components-react";
import { ConnectionState } from "livekit-client";
import * as api from "../lib/api";
import type { AssistantTurn, VoiceToken } from "../types";

interface Props {
  sessionId: string;
  userName: string;
  onAssistantTurn: (turn: AssistantTurn) => void;
}

const STATE_LABEL: Record<string, string> = {
  connecting: "Connecting…",
  initializing: "Assistant is joining…",
  listening: "Listening",
  thinking: "Thinking…",
  speaking: "Speaking",
  disconnected: "Assistant not connected",
};

function slug(name: string) {
  return name.trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
}

export function VoicePanel({ sessionId, userName, onAssistantTurn }: Props) {
  const [connection, setConnection] = useState<VoiceToken | null>(null);
  const [starting, setStarting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const start = async () => {
    setStarting(true);
    setError(null);
    try {
      const token = await api.voiceToken({
        session_id: sessionId,
        identity: `user-${slug(userName) || "guest"}`,
        name: userName.trim() || undefined,
      });
      setConnection(token);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setStarting(false);
    }
  };

  if (!connection) {
    return (
      <div className="voice-stage">
        <div className="avatar-frame avatar-idle">
          <button type="button" className="mic" onClick={start} disabled={starting}>
            <span aria-hidden="true">🎙</span> {starting ? "Starting…" : "Start voice conversation"}
          </button>
        </div>
        <span className="muted">
          Talk to the assistant. Voice and text share the same conversation, so it remembers what you asked here.
        </span>
        {error && <span className="voice-error">{error}</span>}
      </div>
    );
  }

  return (
    <LiveKitRoom
      token={connection.token}
      serverUrl={connection.url}
      connect
      audio
      video={false}
      onDisconnected={() => setConnection(null)}
      onError={(e) => setError(e.message)}
      className="voice-room"
    >
      <VoiceStage onAssistantTurn={onAssistantTurn} error={error} />
      <RoomAudioRenderer />
    </LiveKitRoom>
  );
}

function VoiceStage({ onAssistantTurn, error }: { onAssistantTurn: (turn: AssistantTurn) => void; error: string | null }) {
  const { state, audioTrack, videoTrack } = useVoiceAssistant();
  const connectionState = useConnectionState();
  const { localParticipant, isMicrophoneEnabled } = useLocalParticipant();
  const room = useRoomContext();

  useDataChannel("assistant", (message) => {
    try {
      const payload = JSON.parse(new TextDecoder().decode(message.payload)) as AssistantTurn;
      if (payload.type === "assistant.answer") onAssistantTurn(payload);
    } catch {
      /* ignore malformed messages */
    }
  });

  const label =
    connectionState !== ConnectionState.Connected ? `Room: ${connectionState}` : (STATE_LABEL[state] ?? state);

  return (
    <div className="voice-stage">
      <div className="avatar-frame">
        {videoTrack ? (
          <VideoTrack trackRef={videoTrack} className="avatar-video" />
        ) : (
          <BarVisualizer state={state} trackRef={audioTrack} barCount={7} options={{ minHeight: 12 }} className="visualizer" />
        )}
      </div>
      <div className="voice-controls">
        <span className={`voice-state state-${state}`}>{label}</span>
        <button type="button" className="secondary" onClick={() => localParticipant.setMicrophoneEnabled(!isMicrophoneEnabled)}>
          {isMicrophoneEnabled ? "Mute" : "Unmute"}
        </button>
        <button type="button" className="secondary" onClick={() => room.disconnect()}>
          End voice
        </button>
        {error && <span className="voice-error">{error}</span>}
      </div>
      <p className="ai-label">Spoken answers are AI-generated from company documents; the sources appear on the right.</p>
    </div>
  );
}
