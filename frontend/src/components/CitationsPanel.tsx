import { useEffect, useRef } from "react";
import type { Citation } from "../types";

interface Props {
  citations: Citation[];
  selected: number | null;
  onSelect: (n: number) => void;
}

export function CitationsPanel({ citations, selected, onSelect }: Props) {
  const refs = useRef<Record<number, HTMLElement | null>>({});

  useEffect(() => {
    if (selected != null) refs.current[selected]?.scrollIntoView({ behavior: "smooth", block: "nearest" });
  }, [selected]);

  const ordered = [...citations].sort((a, b) => Number(b.used) - Number(a.used) || a.n - b.n);

  return (
    <div className="citations">
      <h2>Sources</h2>
      {citations.length === 0 ? (
        <p className="muted">The passages the assistant used will appear here.</p>
      ) : (
        <ul>
          {ordered.map((c) => (
            <li
              key={c.n}
              ref={(el) => {
                refs.current[c.n] = el;
              }}
              className={`citation ${c.used ? "used" : ""} ${selected === c.n ? "selected" : ""}`}
              onClick={() => onSelect(c.n)}
            >
              <header>
                <span className="n">{c.n}</span>
                <span className="source" title={c.doc_id}>{c.source}</span>
                {c.page != null && <span className="page">page {c.page}</span>}
                <span className="score" title="similarity score">{c.score.toFixed(2)}</span>
              </header>
              {c.headings.length > 0 && <div className="headings">{c.headings.join(" › ")}</div>}
              <p>{c.snippet}</p>
              {!c.used && <footer className="muted">retrieved, not cited</footer>}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
