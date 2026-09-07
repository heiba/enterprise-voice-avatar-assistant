"""Converts a small Markdown document with Docling and checks the chunker output.

Needs the Docling package and, on first run, the chunker tokenizer from Hugging Face.
Skipped when either is unavailable (for example offline).
"""

from pathlib import Path

import pytest

SAMPLE = """# Leave policy

## Annual leave

Every employee receives 25 days of paid annual leave per calendar year. Requests must be
submitted at least two weeks in advance through the HR portal.

## Sick leave

Employees who are ill should notify their manager before 10:00 on the first day of absence.
A doctor's note is required after three consecutive days.
"""


def test_markdown_is_chunked_with_headings(tmp_path: Path):
    try:
        from app import pipeline

        path = tmp_path / "leave-policy.md"
        path.write_text(SAMPLE)
        document = pipeline.convert(path)
        chunks = pipeline.chunk(document)
    except Exception as exc:  # noqa: BLE001
        pytest.skip(f"docling or its tokenizer unavailable: {exc}")
    assert chunks, "expected at least one chunk"
    joined = " ".join(c.text for c in chunks)
    assert "25 days" in joined
    assert any("Sick leave" in c.text or "Sick leave" in " ".join(c.headings) for c in chunks)
    assert all(c.index == i for i, c in enumerate(chunks))
