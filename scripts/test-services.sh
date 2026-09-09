#!/usr/bin/env bash
# Runs the chart's connectivity test pod against a deployed release and prints its
# results. `helm test` does the same when the release was installed with Helm; this
# script also works for Argo CD deployments, where no Helm release exists: it renders
# the test pod from the chart, applies it, waits, prints the log, and deletes it.
#
# Usage: NS=<namespace> scripts/test-services.sh [-f values.yaml] [--set key=value ...]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="${NS:-$(oc project -q)}"
RELEASE="${RELEASE:-assistant}"
POD="${RELEASE}-test-services"
command -v helm >/dev/null || { echo "helm is required (https://helm.sh/docs/intro/install/)"; exit 1; }
trap 'oc delete pod "$POD" -n "$NS" --wait=false >/dev/null 2>&1 || true' EXIT
oc delete pod "$POD" -n "$NS" --wait=true >/dev/null 2>&1 || true
helm template "$RELEASE" "$ROOT/chart" --namespace "$NS" "$@" --show-only templates/test-model-access.yaml | oc apply -n "$NS" -f -
oc wait -n "$NS" --for=jsonpath='{.status.phase}'=Succeeded "pod/$POD" --timeout=240s >/dev/null 2>&1 || true
oc logs -n "$NS" "$POD"
phase=$(oc get pod "$POD" -n "$NS" -o jsonpath='{.status.phase}')
[ "$phase" = "Succeeded" ] || { echo "test pod ended in phase $phase"; exit 1; }
