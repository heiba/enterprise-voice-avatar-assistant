interface Props {
  userName: string;
  onUserName: (name: string) => void;
  onReset: () => void;
  sessionId: string;
}

export function Header({ userName, onUserName, onReset, sessionId }: Props) {
  return (
    <header className="header">
      <div className="brand">
        <span className="brand-mark" aria-hidden="true" />
        <div>
          <h1>Enterprise Assistant</h1>
          <p>Answers from your company documents, on Red Hat OpenShift AI</p>
        </div>
      </div>
      <div className="header-controls">
        <label>
          Your name
          <input
            value={userName}
            onChange={(e) => onUserName(e.target.value)}
            placeholder="used for memory"
            aria-label="Your name, used to remember facts about you"
          />
        </label>
        <button type="button" className="secondary" onClick={onReset} title={`Current session ${sessionId.slice(0, 8)}`}>
          New conversation
        </button>
      </div>
    </header>
  );
}
