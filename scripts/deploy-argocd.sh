#!/usr/bin/env bash
# Deploys (or updates) the assistant through Argo CD, run on the bastion host after
# scripts/bootstrap-cluster.sh. Creates the secrets from one file, registers the Argo CD
# application with the cluster's apps domain, waits for the sync, the pods and the models,
# and prints the URLs. Safe to run again. Everything printed also goes to the log file.
#
# Usage: SECRETS_FILE=~/secrets.env scripts/deploy-argocd.sh
#   PROJECT=voice-avatar-assistant   project prepared by bootstrap-cluster.sh
#   SECRETS_FILE=<path>              KEY=value file with the API keys (see secrets.env.example)
#   VALUES_FILE=values-demo-cluster.yaml   values file in chart/ for this cluster
#                                    (cluster 2: values-demo-cluster-2.yaml)
#   REPO_URL=<git url>               fork to deploy from (default: the upstream repository)
#   TARGET_REVISION=main             branch, tag or commit
#   DOMAIN=<apps domain>             default: read from the cluster
#   WAIT=1                           0 = register the application and return
#   RUN_TESTS=0                      1 = run the connectivity test pod at the end
#   LOG_FILE=~/assistant-deploy-<timestamp>.log
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="${PROJECT:-voice-avatar-assistant}"
REPO_URL="${REPO_URL:-https://github.com/rh-ai-quickstart/enterprise-voice-avatar-assistant.git}"
TARGET_REVISION="${TARGET_REVISION:-main}"
VALUES_FILE="${VALUES_FILE:-values-demo-cluster.yaml}"
APP=voice-avatar-assistant
LOG_FILE="${LOG_FILE:-$HOME/assistant-deploy-$(date +%Y%m%d-%H%M%S).log}"
exec > >(tee -a "$LOG_FILE") 2>&1

STEP=0; FAILED=0
step() { STEP=$((STEP + 1)); printf '\n\033[1m== Step %s: %s\033[0m  (%s)\n' "$STEP" "$1" "$(date +%H:%M:%S)"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
info() { printf '  ..   %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=$((FAILED + 1)); }
debug(){ printf '  debug: %s\n' "$1"; }
run()  { printf '  $ %s\n' "$*"; "$@"; }
wait_for() {
  local timeout=$1 what=$2; shift 2
  local waited=0
  while ! "$@" >/dev/null 2>&1; do
    if [ "$waited" -ge "$timeout" ]; then return 1; fi
    sleep 15; waited=$((waited + 15))
    [ $((waited % 60)) -eq 0 ] && info "still waiting for $what (${waited}s)"
  done
  return 0
}
echo "Deploy log: $LOG_FILE"

step "Checks"
command -v oc >/dev/null || { fail "oc is not installed"; exit 1; }
command -v jq >/dev/null || { fail "jq is not installed (sudo dnf install -y jq)"; exit 1; }
if user=$(oc whoami 2>/dev/null); then ok "logged in as $user"; else fail "not logged in"; exit 1; fi
oc get namespace "$PROJECT" >/dev/null 2>&1 && ok "project $PROJECT exists" || { fail "project $PROJECT missing: run scripts/bootstrap-cluster.sh first"; exit 1; }
oc get deployment openshift-gitops-server -n openshift-gitops >/dev/null 2>&1 && ok "Argo CD present" || { fail "Argo CD not found in openshift-gitops: run scripts/bootstrap-cluster.sh"; exit 1; }
[ -f "$ROOT/chart/$VALUES_FILE" ] && ok "values file chart/$VALUES_FILE" || { fail "chart/$VALUES_FILE does not exist in this clone (VALUES_FILE)"; exit 1; }
DOMAIN="${DOMAIN:-$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')}"
[ -n "$DOMAIN" ] && ok "apps domain $DOMAIN" || { fail "could not read the apps domain; set DOMAIN="; exit 1; }
if [ -n "${SECRETS_FILE:-}" ]; then [ -r "$SECRETS_FILE" ] && ok "secrets file $SECRETS_FILE" || { fail "SECRETS_FILE $SECRETS_FILE is not readable"; exit 1; }; else warn "no SECRETS_FILE: integrations stay off unless the secrets already exist"; fi
if oc get secret livekit-turn-tls -n "$PROJECT" >/dev/null 2>&1; then ok "TURN certificate secret livekit-turn-tls present"; else warn "livekit-turn-tls missing: voice through corporate networks needs it (scripts/setup-turn-tls.sh); LiveKit waits for it"; fi

step "Secrets"
NAMESPACE="$PROJECT" SECRETS_FILE="${SECRETS_FILE:-}" "$ROOT/scripts/create-secrets.sh" | sed 's/^/  /'
for key in SLACK_BOT_TOKEN TAVUS_API_KEY GOOGLE_DOCS_FOLDER_ID; do
  if [ -n "$(oc get secret assistant-integrations -n "$PROJECT" -o jsonpath="{.data.$key}" 2>/dev/null)" ]; then ok "$key set"; else warn "$key empty (feature off)"; fi
done

step "Argo CD application"
run oc apply -f "$ROOT/deploy/argocd/appproject.yaml" >/dev/null
oc patch appproject "$APP" -n openshift-gitops --type merge -p "{\"spec\":{\"sourceRepos\":[\"$REPO_URL\"],\"destinations\":[{\"server\":\"https://kubernetes.default.svc\",\"namespace\":\"$PROJECT\"}]}}" >/dev/null && ok "AppProject allows $REPO_URL -> $PROJECT"
run oc apply -f "$ROOT/deploy/argocd/application.yaml" >/dev/null
oc patch application "$APP" -n openshift-gitops --type merge -p "{\"spec\":{\"source\":{\"repoURL\":\"$REPO_URL\",\"targetRevision\":\"$TARGET_REVISION\",\"helm\":{\"valueFiles\":[\"values.yaml\",\"$VALUES_FILE\"],\"parameters\":[{\"name\":\"global.domain\",\"value\":\"$DOMAIN\"}]}},\"destination\":{\"namespace\":\"$PROJECT\"}}}" >/dev/null \
  && ok "Application $APP: $REPO_URL@$TARGET_REVISION, values $VALUES_FILE, global.domain=$DOMAIN"
oc annotate application "$APP" -n openshift-gitops argocd.argoproj.io/refresh=normal --overwrite >/dev/null
[ "${WAIT:-1}" = "1" ] || { echo "Application registered (WAIT=0)."; exit 0; }

step "Sync"
app_status() { oc get application "$APP" -n openshift-gitops -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null; }
synced() { [ "$(app_status)" = "Synced/Healthy" ]; }
waited=0
until synced; do
  if [ "$waited" -ge 1800 ]; then break; fi
  sleep 20; waited=$((waited + 20))
  if [ $((waited % 60)) -eq 0 ]; then
    info "application $(app_status) after ${waited}s"
    oc get application "$APP" -n openshift-gitops -o json | jq -r '.status.resources[]? | select(.health.status != null and .health.status != "Healthy") | "     \(.kind)/\(.name): \(.health.status) \(.health.message // "")"' | head -8
    [ "$(oc get application "$APP" -n openshift-gitops -o jsonpath='{.status.operationState.phase}')" = "Error" ] && oc get application "$APP" -n openshift-gitops -o jsonpath='{.status.operationState.message}{"\n"}' | cut -c1-300 | sed 's/^/     /'
  fi
done
if synced; then ok "application Synced/Healthy"; else fail "application is $(app_status) after 30 min"; debug "oc describe application $APP -n openshift-gitops | tail -40; Argo CD UI: https://$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}')"; fi

step "Models"
if oc get isvc -n "$PROJECT" -o name 2>/dev/null | grep -q .; then
  models_ready() { [ "$(oc get isvc -n "$PROJECT" -o json | jq -r '[.items[] | (.status.conditions[]? | select(.type=="Ready") | .status)] | all(.=="True") and (length>0)')" = "true" ]; }
  waited=0
  until models_ready; do
    if [ "$waited" -ge 2400 ]; then break; fi
    sleep 30; waited=$((waited + 30))
    if [ $((waited % 120)) -eq 0 ]; then
      info "models after ${waited}s (weights download on first start takes 10 to 20 min):"
      oc get isvc -n "$PROJECT" -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,REASON:.status.conditions[?(@.type=="Ready")].reason' | sed 's/^/     /'
    fi
  done
  if models_ready; then ok "all InferenceServices Ready"; oc get isvc -n "$PROJECT" -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status' | sed 's/^/     /'; else
    fail "models not Ready after 40 min"; debug "oc get pods -n $PROJECT -l component=predictor; oc logs -n $PROJECT -l serving.kserve.io/inferenceservice=llama-3-1-8b-instruct --tail=50; GPU memory: oc exec -n nvidia-gpu-operator ds/nvidia-driver-daemonset -- nvidia-smi"; fi
else
  warn "no InferenceService in $PROJECT (remote model endpoints?)"
fi

step "Pods"
pods_ready() { ! oc get pods -n "$PROJECT" --no-headers 2>/dev/null | grep -v -E 'Running|Completed' | grep -q .; }
if wait_for 900 "all pods" pods_ready; then ok "all pods Running or Completed"; else
  fail "some pods are not ready:"; oc get pods -n "$PROJECT" --no-headers | grep -v -E 'Running|Completed' | sed 's/^/     /'; debug "oc describe pod <name> -n $PROJECT; oc logs <name> -n $PROJECT --previous"; fi

step "URLs"
for r in frontend n8n livekit qdrant; do
  host=$(oc get route "$r" -n "$PROJECT" -o jsonpath='{.spec.host}' 2>/dev/null) && [ -n "$host" ] && printf '  %-9s https://%s\n' "$r" "$host"
done
printf '  %-9s https://%s\n' "argocd" "$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}')"
if [ "${RUN_TESTS:-0}" = "1" ]; then
  step "Connectivity test pod"
  NS="$PROJECT" "$ROOT/scripts/test-services.sh" -f "$ROOT/chart/$VALUES_FILE" --set global.domain="$DOMAIN" || FAILED=$((FAILED + 1))
fi
echo
if [ "$FAILED" -gt 0 ]; then echo "Deployment finished with $FAILED problem(s); see the FAIL lines above and the log $LOG_FILE"; exit 1; fi
echo "Deployment complete. Next: n8n first run and the sample documents (SETUP.md)."
