export function VoicePanel({ enabled }: { enabled: boolean }) {
  return (
    <div className="voice">
      <button type="button" className="mic" disabled={!enabled} title={enabled ? "Start a voice conversation" : "Voice mode arrives with the voice agent"}>
        <span aria-hidden="true">🎙</span> Voice mode
      </button>
      {!enabled && <span className="muted">Voice and avatar are being wired up; text chat is fully functional.</span>}
    </div>
  );
}
