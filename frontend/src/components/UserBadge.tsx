import { useEffect, useRef, useState } from "react";

interface Props {
  name: string;
  onChange: (name: string) => void;
}

function initials(name: string): string {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return "";
  const first = parts[0][0] ?? "";
  const last = parts.length > 1 ? parts[parts.length - 1][0] ?? "" : "";
  return (first + last).toUpperCase();
}

const HINT = "Your name is used to remember facts about you across conversations";

export function UserBadge({ name, onChange }: Props) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(name);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (editing) {
      inputRef.current?.focus();
      inputRef.current?.select();
    }
  }, [editing]);

  const startEdit = () => {
    setDraft(name);
    setEditing(true);
  };

  const save = () => {
    onChange(draft.trim());
    setEditing(false);
  };

  const cancel = () => {
    setDraft(name);
    setEditing(false);
  };

  const shown = name.trim();
  const letters = initials(shown);

  if (editing) {
    return (
      <form
        className="user-badge editing"
        onSubmit={(e) => {
          e.preventDefault();
          save();
        }}
        title={HINT}
      >
        <span className={`user-avatar${initials(draft) ? "" : " guest"}`} aria-hidden="true">
          {initials(draft) || <PersonIcon />}
        </span>
        <input
          ref={inputRef}
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Escape") {
              e.preventDefault();
              cancel();
            }
          }}
          placeholder="Your name"
          maxLength={60}
          aria-label="Your name, used to remember facts about you"
        />
        <button type="submit" className="icon save" title="Save (Enter)" aria-label="Save name">
          <CheckIcon />
        </button>
        <button type="button" className="icon" onClick={cancel} title="Cancel (Esc)" aria-label="Cancel">
          <CloseIcon />
        </button>
      </form>
    );
  }

  return (
    <div className="user-badge" title={HINT}>
      <span className={`user-avatar${shown ? "" : " guest"}`} aria-hidden="true">
        {letters || <PersonIcon />}
      </span>
      <span className="who">
        <small>Talking as</small>
        <strong>{shown || "Guest"}</strong>
      </span>
      <button
        type="button"
        className="icon"
        onClick={startEdit}
        title={shown ? "Change your name" : "Set your name so the assistant can remember you"}
        aria-label={shown ? "Change your name" : "Set your name"}
      >
        <PencilIcon />
      </button>
    </div>
  );
}

function PencilIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M12 20h9" />
      <path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z" />
    </svg>
  );
}

function CheckIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M20 6 9 17l-5-5" />
    </svg>
  );
}

function CloseIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M18 6 6 18" />
      <path d="m6 6 12 12" />
    </svg>
  );
}

function PersonIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M20 21a8 8 0 0 0-16 0" />
      <circle cx="12" cy="8" r="4" />
    </svg>
  );
}
