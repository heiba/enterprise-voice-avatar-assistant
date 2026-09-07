#!/usr/bin/env bash
# Uploads the demo document set into the MinIO buckets of a deployed release, so
# the ingestion (documents/) and classification (inbox/) workflows run on it.
# Policies and procedures go to `documents`, invoices and contracts to `inbox`.
#
# Runs from anywhere with `oc` logged in; the upload happens from a short-lived
# pod with the MinIO client, using the credentials in the assistant-minio secret.
#
# Usage: NS=<namespace> scripts/load-sample-docs.sh [file ...]
#   NS         target namespace (default: current project)
#   MC_IMAGE   MinIO client image (default: the chart's minio.mcImage)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="${NS:-$(oc project -q)}"
MC_IMAGE="${MC_IMAGE:-$(sed -n 's/^  mcImage: *//p' "$ROOT/chart/values.yaml")}"
POD="sample-docs-upload"
cd "$ROOT/data/sample-docs"
FILES=("$@"); [ ${#FILES[@]} -gt 0 ] || FILES=( *.md *.docx *.pdf )

oc apply -n "$NS" -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $POD
spec:
  enableServiceLinks: false
  restartPolicy: Never
  containers:
    - name: mc
      image: $MC_IMAGE
      command: ["sleep", "900"]
      envFrom:
        - secretRef:
            name: assistant-minio
      env:
        - name: MC_CONFIG_DIR
          value: /tmp/.mc
      securityContext:
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        capabilities:
          drop: ["ALL"]
        seccompProfile:
          type: RuntimeDefault
YAML
trap 'oc delete pod "$POD" -n "$NS" --wait=false >/dev/null 2>&1 || true' EXIT
oc wait -n "$NS" --for=condition=Ready "pod/$POD" --timeout=120s >/dev/null
oc exec -n "$NS" "$POD" -- sh -c 'mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null'

for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "skip $f (not a file)"; continue; }
  case "$f" in
    invoice-*|contract-*) bucket=inbox ;;
    *)                    bucket=documents ;;
  esac
  oc exec -i -n "$NS" "$POD" -- sh -c "cat > '/tmp/$f'" < "$f"
  oc exec -n "$NS" "$POD" -- mc cp -q "/tmp/$f" "local/$bucket/$f" >/dev/null
  printf '%-45s -> %s\n' "$f" "$bucket"
done
echo
echo "Uploaded. Watch the n8n executions (WF2 ingestion, WF3 classification) and the Slack channels."
