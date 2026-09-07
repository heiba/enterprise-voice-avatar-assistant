#!/usr/bin/env bash
# Renders the demo documents in data/sample-docs from the Markdown sources in
# data/sample-docs/src. Policies stay readable as Markdown in git; the demo set
# mixes Markdown, DOCX (pandoc) and PDF (LibreOffice) so the ingestion pipeline
# exercises Docling on office formats.
#
# Requires: pandoc, soffice (LibreOffice). Usage: scripts/build-sample-docs.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/data/sample-docs/src"
OUT="$ROOT/data/sample-docs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# document name -> output format
FORMATS='
password-policy md
remote-work-policy docx
expense-reimbursement-policy pdf
it-equipment-procedure docx
new-hire-onboarding-procedure pdf
incident-response-procedure pdf
leave-policy docx
data-classification-policy pdf
software-request-procedure docx
it-service-catalog pdf
contract-northwind-supply-agreement pdf
contract-managed-services-blue-harbor docx
invoice-INV-2026-0042 pdf
invoice-SKY-2026-0817 pdf
invoice-MT-88213 md
'
while read -r name fmt; do
  [ -n "$name" ] || continue
  src="$SRC/$name.md"
  case "$fmt" in
    md)   cp "$src" "$OUT/$name.md" ;;
    docx) pandoc "$src" -o "$OUT/$name.docx" ;;
    pdf)  pandoc "$src" -o "$TMP/$name.docx"
          soffice --headless --convert-to pdf --outdir "$OUT" "$TMP/$name.docx" >/dev/null ;;
    *)    echo "unknown format $fmt for $name" >&2; exit 1 ;;
  esac
  printf '%-40s %s\n' "$name.$fmt" "$(du -h "$OUT/$name.$fmt" | cut -f1)"
done <<< "$FORMATS"
