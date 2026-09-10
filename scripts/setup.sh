#!/usr/bin/env bash
# Interactive, resumable setup of the demo on a fresh cluster. Runs on the bastion host,
# logged in to the cluster as an administrator, from a clone of this repository.
#
#   scripts/setup.sh            discover the cluster, show progress, run every remaining step in order;
#                               it only stops for values it cannot know (keys, browser work) or on failure
#   scripts/setup.sh --status   discovery and progress only, changes nothing
#   scripts/setup.sh --step N   run step N (again), then stop
#   scripts/setup.sh --yes      skip the optional prompts (n8n API key, Let's Encrypt e-mail)
#   scripts/setup.sh --reset    forget the saved progress (the cluster is not touched)
#
# Without a GPU the script stops and says what the demo needs. To use remote model endpoints
# instead, run it with PROFILE=remote and REMOTE_LLM_ENDPOINT, REMOTE_LLM_MODEL,
# REMOTE_STT_ENDPOINT, REMOTE_EMB_ENDPOINT (and the keys in ~/secrets.env).
#
# Progress and discovered facts are kept in ~/.assistant-setup/state.env. Every run is logged
# to ~/.assistant-setup/logs/setup-<timestamp>.log (the bootstrap and deploy steps add their
# own logs next to it); DEBUG=1 also writes a full command trace to <log>.trace. Every step
# checks the cluster before doing anything, so work done by hand or by an earlier run is
# recognised and not repeated.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${STATE_DIR:-$HOME/.assistant-setup}"
STATE="$STATE_DIR/state.env"
SECRETS_FILE="${SECRETS_FILE:-$HOME/secrets.env}"
PROJECT="${PROJECT:-voice-avatar-assistant}"
LLM_NAME="${LLM_NAME:-llama-32-3b-instruct}"
YES=0; MODE=next; ONLY=""
for a in "$@"; do case "$a" in --status) MODE=status;; --yes|-y) YES=1;; --reset) MODE=reset;; --step) MODE=step;; [0-9]*) ONLY="$a";; -h|--help) sed -n 2,14p "$0"; exit 0;; esac; done
mkdir -p "$STATE_DIR/logs"; touch "$STATE"; chmod 700 "$STATE_DIR"
[ "$MODE" = reset ] && { rm -f "$STATE"; touch "$STATE"; echo "progress forgotten ($STATE)"; exit 0; }
RUN_LOG="$STATE_DIR/logs/setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$RUN_LOG") 2>&1
if [ "${DEBUG:-0}" = 1 ]; then exec {BASH_XTRACEFD}>>"$RUN_LOG.trace"; export PS4='+ $(date +%H:%M:%S) ${BASH_SOURCE##*/}:${LINENO}: '; set -x; fi
printf '%s setup started by %s on %s; log %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$(id -un)" "$(hostname)" "$RUN_LOG"

# ---------------------------------------------------------------- helpers -------------------
B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
say()  { printf '%s\n' "$*"; }
ts()   { date +%H:%M:%S; }
run_step() {  # run_step N: runs stepN with a timestamped header and footer, records the duration
  local n=$1 start rc; start=$(date +%s)
  say ""; say "$(ts) ${D}---- step $n: ${STEPS[$((n-1))]} ----${N}"
  "step$n"; rc=$?
  save "STEP_${n}_LAST_RUN" "$(date +%Y-%m-%dT%H:%M) rc=$rc $(( $(date +%s) - start ))s"
  say "$(ts) ${D}---- step $n finished in $(( $(date +%s) - start ))s, exit $rc ----${N}"
  return $rc
}
ok()   { printf '  %sOK%s   %s\n' "$G" "$N" "$1"; }
warn() { printf '  %sWARN%s %s\n' "$Y" "$N" "$1"; }
bad()  { printf '  %sFAIL%s %s\n' "$R" "$N" "$1"; }
note() { printf '  %s..%s   %s\n' "$D" "$N" "$1"; }
save() { local k=$1 v=$2; { grep -v "^$k=" "$STATE" 2>/dev/null || true; } > "$STATE.tmp"; printf '%s=%q\n' "$k" "$v" >> "$STATE.tmp"; mv "$STATE.tmp" "$STATE"; export "$k=$v"; }
unsave() { { grep -v "^$1=" "$STATE" 2>/dev/null || true; } > "$STATE.tmp"; mv "$STATE.tmp" "$STATE"; unset "$1"; }
mark() { save "STEP_$1_DONE" "$(date +%Y-%m-%dT%H:%M)"; }
# ask <var> <prompt> <default>: interactive unless --yes; empty answer keeps the default
ask() { local var=$1 prompt=$2 def=${3:-}; local ans; if [ "$YES" = 1 ] && [ -n "$def" ]; then ans=$def; else read -r -p "  $prompt${def:+ [$def]}: " ans; ans=${ans:-$def}; fi; printf -v "$var" '%s' "$ans"; }
ask_secret() { local var=$1 prompt=$2; local ans=""; if [ "$YES" != 1 ]; then read -rs -p "  $prompt (typed text stays hidden, Enter to skip): " ans; echo; fi; printf -v "$var" '%s' "$ans"; }
confirm() { local ans; [ "$YES" = 1 ] && return 0; read -r -p "  $1 [Y/n]: " ans; [ -z "$ans" ] || [[ "$ans" =~ ^[Yy] ]]; }
logfile() { echo "$STATE_DIR/logs/$1-$(date +%Y%m%d-%H%M%S).log"; }
# shellcheck disable=SC1090
. "$STATE" 2>/dev/null || true

# ---------------------------------------------------------------- login ---------------------
# Logs in when the bastion is not (or its token expired): proposes the API URL it can find,
# asks for the user (kubeadmin) and the password from the provisioning e-mail, hidden.
ensure_login() {
  command -v oc >/dev/null || { bad "oc is not installed on this host (https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/)"; return 1; }
  if oc whoami >/dev/null 2>&1; then return 0; fi
  say "${B}Cluster login${N}"
  local reason; reason=$(oc whoami 2>&1 | head -1); note "oc whoami: ${reason:-no session}"
  local -a cands=(); local u host
  [ -n "${API_URL:-}" ] && cands+=("$API_URL")
  while read -r u; do [ -n "$u" ] && cands+=("$u"); done < <(oc config view -o jsonpath='{range .clusters[*]}{.cluster.server}{"\n"}{end}' 2>/dev/null)
  host=$(hostname -f 2>/dev/null || hostname); case "$host" in bastion.*) cands+=("https://api.${host#bastion.}:6443");; esac
  local -a uniq=(); for u in "${cands[@]}"; do case " ${uniq[*]:-} " in *" $u "*) ;; *) uniq+=("$u");; esac; done
  if [ "${#uniq[@]}" -gt 1 ]; then say "  API URLs found on this host:"; printf '     %s\n' "${uniq[@]}"; fi
  local api user pass
  ask api "API URL (from the provisioning e-mail, https://api.<guid>.<base domain>:6443)" "${uniq[0]:-}"
  [ -n "$api" ] || { bad "an API URL is needed"; return 1; }
  ask user "User" "${LOGIN_USER:-kubeadmin}"
  ask_secret pass "Password for $user"
  [ -n "$pass" ] || { bad "a password is needed"; return 1; }
  if oc login "$api" -u "$user" -p "$pass" >/dev/null 2>&1 || oc login "$api" -u "$user" -p "$pass" --insecure-skip-tls-verify=true >/dev/null 2>&1; then
    ok "logged in to $api as $(oc whoami)"; save API_URL "$api"; save LOGIN_USER "$user"
    oc auth can-i create namespaces >/dev/null 2>&1 && ok "cluster-admin permissions" || warn "this user cannot create cluster resources; the bootstrap needs kubeadmin or a cluster-admin"
    return 0
  fi
  bad "login failed: $(oc login "$api" -u "$user" -p "$pass" --insecure-skip-tls-verify=true 2>&1 | tail -1)"
  note "check the API URL and password in the provisioning e-mail; from the laptop the same values work with oc as well"
  return 1
}

# ---------------------------------------------------------------- discovery -----------------
discover() {
  API=""; USER_NAME=""; OCP_VERSION=""; DOMAIN="${DOMAIN:-}"; NODE_COUNT=0; INSTANCE=""; GPUS="${GPUS:-0}"; GPU_PRODUCT=""; GPU_MEMORY=""; GPU_REPLICAS=""; GPU_ALLOC=0
  RHOAI_VERSION=""; DSC=""; KSERVE=""; OP_NFD=no; OP_GPU=no; OP_CM=no; OP_GITOPS=no; LLM_NS="${LLM_NS:-}"; LLM_READY=""; LLM_SHARE=""
  PROJECT_EXISTS=no; ARGO_READY=no; TURN_SECRET=no; SECRETS_IN_CLUSTER=no; APP_STATE=""; ISVC_TOTAL=0; ISVC_READY=0; PODS_NOT_READY=1; FRONTEND_URL=""; N8N_URL=""; DOCS_INDEXED=""
  LOGGED_IN=0; command -v oc >/dev/null && oc whoami >/dev/null 2>&1 && LOGGED_IN=1
  [ "$LOGGED_IN" = 1 ] || return
  progress() { [ "${QUIET_DISCOVERY:-0}" = 1 ] || printf '  %s..%s %s\n' "$D" "$N" "$1"; }
  progress "cluster and nodes"
  API=$(oc whoami --show-server); USER_NAME=$(oc whoami)
  OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null)
  DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)
  NODE_COUNT=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  INSTANCE=$(oc get nodes -o jsonpath='{.items[0].metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null)
  GPUS=$(oc get nodes -o json 2>/dev/null | jq '[.items[].metadata.labels["nvidia.com/gpu.count"] // "0" | tonumber] | add')
  [ "${GPUS:-0}" -gt 0 ] || GPUS=$(oc get nodes -o json 2>/dev/null | jq '[.items[].status.capacity["nvidia.com/gpu"] // "0" | tonumber] | add')
  GPU_PRODUCT=$(oc get nodes -o jsonpath='{.items[0].metadata.labels.nvidia\.com/gpu\.product}' 2>/dev/null)
  GPU_MEMORY=$(oc get nodes -o jsonpath='{.items[0].metadata.labels.nvidia\.com/gpu\.memory}' 2>/dev/null)
  GPU_REPLICAS=$(oc get nodes -o jsonpath='{.items[0].metadata.labels.nvidia\.com/gpu\.replicas}' 2>/dev/null)
  GPU_ALLOC=$(oc get nodes -o json 2>/dev/null | jq '[.items[].status.allocatable["nvidia.com/gpu"] // "0" | tonumber] | add')
  progress "operators"
  # CSVs are looked up in the operator's own namespace (and openshift-operators): a cluster-wide
  # listing returns every copied CSV of every namespace and takes minutes on a busy cluster
  csv_version() {  # <prefix> <namespace...>: version of the first Succeeded CSV found
    local n=$1; shift; local ns
    for ns in "$@"; do oc get csv -n "$ns" -o json 2>/dev/null | jq -r --arg n "$n" '.items[] | select(.metadata.name | startswith($n)) | select(.status.phase=="Succeeded") | .spec.version' | head -1 | grep . && return 0; done
    return 1
  }
  RHOAI_VERSION=$(csv_version rhods-operator redhat-ods-operator openshift-operators || true)
  DSC=$(oc get datasciencecluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  KSERVE=$(oc get datasciencecluster "$DSC" -o jsonpath='{.spec.components.kserve.managementState}' 2>/dev/null)
  OP_NFD=$(csv_version nfd openshift-nfd openshift-operators >/dev/null && echo yes || echo no)
  OP_GPU=$(csv_version gpu-operator-certified nvidia-gpu-operator openshift-operators >/dev/null && echo yes || echo no)
  OP_CM=$(csv_version cert-manager-operator cert-manager-operator openshift-operators >/dev/null && echo yes || echo no)
  OP_GITOPS=$(csv_version openshift-gitops-operator openshift-gitops-operator openshift-operators >/dev/null && echo yes || echo no)
  progress "language model"
  LLM_NS=$(oc get isvc -A -o json 2>/dev/null | jq -r --arg n "$LLM_NAME" '.items[] | select(.metadata.name==$n) | .metadata.namespace' | head -1)
  LLM_READY=""; LLM_SHARE=""
  if [ -n "$LLM_NS" ]; then
    LLM_READY=$(oc get isvc "$LLM_NAME" -n "$LLM_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    LLM_SHARE=$(oc get isvc "$LLM_NAME" -n "$LLM_NS" -o json 2>/dev/null | jq -r '.spec.predictor.model.args // [] | .[] | select(startswith("--gpu-memory-utilization")) | sub("^--gpu-memory-utilization=?";"")' | head -1)
  fi
  progress "project and application"
  PROJECT_EXISTS=$(oc get namespace "$PROJECT" >/dev/null 2>&1 && echo yes || echo no)
  ARGO_READY=$([ "$(oc get deployment openshift-gitops-server -n openshift-gitops -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "1" ] && echo yes || echo no)
  TURN_SECRET=$(oc get secret livekit-turn-tls -n "$PROJECT" >/dev/null 2>&1 && echo yes || echo no)
  SECRETS_IN_CLUSTER=$(oc get secret assistant-integrations -n "$PROJECT" >/dev/null 2>&1 && echo yes || echo no)
  APP_STATE=$(oc get application voice-avatar-assistant -n openshift-gitops -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
  ISVC_TOTAL=$(oc get isvc -n "$PROJECT" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ISVC_READY=$(oc get isvc -n "$PROJECT" -o json 2>/dev/null | jq '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length')
  PODS_NOT_READY=$(oc get pods -n "$PROJECT" --no-headers 2>/dev/null | grep -v -E 'Running|Completed' | wc -l | tr -d ' ')
  FRONTEND_URL=$(oc get route frontend -n "$PROJECT" -o jsonpath='https://{.spec.host}' 2>/dev/null)
  N8N_URL=$(oc get route n8n -n "$PROJECT" -o jsonpath='https://{.spec.host}' 2>/dev/null)
  DOCS_INDEXED=""
  if [ "$PODS_NOT_READY" = 0 ] && [ -n "$FRONTEND_URL" ]; then
    DOCS_INDEXED=$(oc exec deploy/rag-api -n "$PROJECT" -- .venv/bin/python -c 'import urllib.request,json; print(len(json.load(urllib.request.urlopen("http://ingestion:8080/v1/documents", timeout=10))))' 2>/dev/null || echo "")
  fi
}

# ---------------------------------------------------------------- profile -------------------
# gpu:    every GPU on the cluster is used, each advertised 4 times through time-slicing so the
#         language model, Whisper and BGE-M3 can share a card; fixed memory shares; no guardrails
# remote: no GPU, every model is a remote OpenAI-compatible endpoint (PROFILE=remote)
suggest_profile() { if [ "${GPUS:-0}" -eq 0 ]; then echo remote; else echo gpu; fi; }
profile_slices() { case "$1" in gpu) echo 4;; *) echo 1;; esac; }
write_values_object() {  # -> $STATE_DIR/values-object.json, deep-merged over the values file by Argo CD
  local llm_deploy=true; [ -n "${LLM_NS:-}" ] && llm_deploy=false
  case "$PROFILE" in
  remote)
    jq -n --arg le "$REMOTE_LLM_ENDPOINT" --arg lm "$REMOTE_LLM_MODEL" --arg se "$REMOTE_STT_ENDPOINT" --arg sm "$REMOTE_STT_MODEL" --arg ee "$REMOTE_EMB_ENDPOINT" --arg em "$REMOTE_EMB_MODEL" \
      '{models:{llm:{deploy:false,endpoint:$le,servedModelName:$lm},stt:{deploy:false,endpoint:$se,servedModelName:$sm},embeddings:{deploy:false,endpoint:$ee,servedModelName:$em},guardrails:{provider:"none",deploy:false}}}' ;;
  *)
    jq -n --argjson d "$llm_deploy" '{models:{llm:{deploy:$d,args:["--max-model-len=8192","--gpu-memory-utilization=0.45","--max-num-seqs=8","--enforce-eager","--enable-auto-tool-choice","--tool-call-parser=llama3_json"]},stt:{deploy:true,args:["--gpu-memory-utilization=0.15","--enforce-eager"]},embeddings:{args:["--runner=pooling","--max-model-len=8192","--gpu-memory-utilization=0.12","--enforce-eager"]},guardrails:{provider:"none",deploy:false}}}' ;;
  esac > "$STATE_DIR/values-object.json"
}

# ---------------------------------------------------------------- status --------------------
STEPS=("Cluster and prerequisites" "Deployment profile" "Cluster bootstrap" "TURN certificate" "Keys and integrations" "Deploy with Argo CD" "n8n first run" "Sample documents" "Verification")
step_state() {  # prints done|todo|attention and a detail
  case "$1" in
  1) if [ "$LOGGED_IN" != 1 ]; then echo "attention|not logged in to a cluster"; elif [ -z "$RHOAI_VERSION" ]; then echo "attention|OpenShift AI not found";
     elif [[ "$RHOAI_VERSION" == 2.* ]]; then echo "attention|OpenShift AI $RHOAI_VERSION; 3.x is required"; elif [ "$KSERVE" != Managed ]; then echo "todo|KServe is ${KSERVE:-unset} (bootstrap fixes it)";
     else echo "done|OpenShift $OCP_VERSION, OpenShift AI $RHOAI_VERSION, $NODE_COUNT node(s) $INSTANCE, ${GPUS:-0} GPU(s) ${GPU_PRODUCT:+($GPU_PRODUCT)}, KServe Managed"; fi ;;
  2) if [ -n "${PROFILE:-}" ]; then echo "done|$PROFILE${LLM_NS:+; language model $LLM_NS/$LLM_NAME}"; else echo "todo|suggested: $(suggest_profile)"; fi ;;
  3) if [ "$PROJECT_EXISTS" = yes ] && [ "$ARGO_READY" = yes ] && [ -n "${STEP_3_DONE:-}" ]; then echo "done|project, Argo CD, GPU sharing (${GPU_ALLOC:-?} schedulable GPUs)";
     elif [ "$PROJECT_EXISTS" = yes ] && [ "$ARGO_READY" = yes ]; then echo "todo|project and Argo CD exist; run to verify GPU sharing and the model share"; else echo "todo|project ${PROJECT_EXISTS}, Argo CD ${ARGO_READY}"; fi ;;
  4) if [ "$TURN_SECRET" = yes ]; then echo "done|secret livekit-turn-tls present"; elif [ "$PROJECT_EXISTS" != yes ]; then echo "todo|after the bootstrap"; else echo "todo|secret missing"; fi ;;
  5) if [ "$SECRETS_IN_CLUSTER" = yes ] && [ -n "${STEP_5_DONE:-}" ]; then echo "done|$SECRETS_FILE and the cluster secrets"; elif [ "$SECRETS_IN_CLUSTER" = yes ]; then echo "todo|cluster secrets exist; run to review the keys"; elif [ -f "$SECRETS_FILE" ]; then echo "todo|$SECRETS_FILE exists, not yet applied"; else echo "todo|no $SECRETS_FILE yet"; fi ;;
  6) if [ "$APP_STATE" = "Synced/Healthy" ] && [ "${PODS_NOT_READY:-1}" = 0 ]; then echo "done|application Synced/Healthy, ${ISVC_READY:-0}/${ISVC_TOTAL:-0} models Ready"; elif [ -n "$APP_STATE" ]; then echo "attention|application $APP_STATE, ${PODS_NOT_READY} pod(s) not ready"; else echo "todo|not deployed"; fi ;;
  7) if [ -n "${STEP_7_DONE:-}" ]; then echo "done|owner, Google Docs credential, workflows published"; elif [ -n "$N8N_URL" ]; then echo "todo|$N8N_URL"; else echo "todo|after the deployment"; fi ;;
  8) if [ -n "$DOCS_INDEXED" ] && [ "$DOCS_INDEXED" -ge 10 ]; then echo "done|$DOCS_INDEXED documents indexed"; elif [ -n "$DOCS_INDEXED" ]; then echo "todo|$DOCS_INDEXED documents indexed"; else echo "todo|after the deployment"; fi ;;
  9) if [ -n "${STEP_9_DONE:-}" ]; then echo "done|preflight passed $STEP_9_DONE"; else echo "todo|preflight not run"; fi ;;
  esac
}
show_status() {
  say ""; say "${B}Enterprise voice avatar assistant: setup${N}"
  if [ "$LOGGED_IN" = 1 ]; then say "  cluster $API as $USER_NAME, apps domain $DOMAIN"; else say "  ${R}not logged in${N}: the script asks for the API URL, user and password when run"; fi
  say "  progress file $STATE; this run's log $RUN_LOG"; say ""
  NEXT=""
  for i in 1 2 3 4 5 6 7 8 9; do
    local st; st=$(step_state $i); local kind=${st%%|*} detail=${st#*|} icon="○"
    case "$kind" in done) icon="${G}✔${N}";; attention) icon="${R}!${N}";; esac
    [ -z "$NEXT" ] && [ "$kind" != done ] && NEXT=$i
    printf '  %s %s %-26s %s%s%s\n' "$icon" "$i" "${STEPS[$((i-1))]}" "$D" "$detail" "$N"
  done
  say ""
}

# ---------------------------------------------------------------- steps ---------------------
step1() {
  say "${B}Step 1: cluster and prerequisites${N}"
  [ "$LOGGED_IN" = 1 ] || { ensure_login && discover || return 1; }
  for t in oc jq git openssl curl helm python3; do command -v $t >/dev/null && ok "$t" || warn "$t missing (sudo dnf install -y $t; helm: curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash)"; done
  oc auth can-i create namespaces >/dev/null 2>&1 && ok "cluster-admin permissions" || { bad "this user cannot create cluster resources; use kubeadmin"; return 1; }
  ok "OpenShift $OCP_VERSION on $NODE_COUNT node(s), $INSTANCE"
  case "$OCP_VERSION" in 4.1[0-8].*) warn "OpenShift AI 3.x needs OpenShift 4.19.9 or later";; esac
  [ -n "$RHOAI_VERSION" ] && ok "OpenShift AI $RHOAI_VERSION" || { bad "OpenShift AI is not installed; this guide assumes an environment with OpenShift AI 3 (see the README prerequisites)"; return 1; }
  [[ "$RHOAI_VERSION" == 3.* ]] || { bad "OpenShift AI $RHOAI_VERSION found; 3.x is required"; return 1; }
  [ "$KSERVE" = Managed ] && ok "KServe Managed in DataScienceCluster $DSC" || warn "KServe is ${KSERVE:-unset}; the bootstrap sets it to Managed"
  for o in "NFD:$OP_NFD" "GPU Operator:$OP_GPU" "cert-manager:$OP_CM" "GitOps:$OP_GITOPS"; do [ "${o#*:}" = yes ] && ok "${o%%:*} installed" || warn "${o%%:*} missing; the bootstrap installs it"; done
  if [ "${GPUS:-0}" -gt 0 ]; then ok "$GPUS GPU(s) ${GPU_PRODUCT:+$GPU_PRODUCT }(schedulable now: ${GPU_ALLOC:-?})"; else warn "no GPU on this cluster; models will have to be remote endpoints"; fi
  if [ -n "$LLM_NS" ]; then ok "language model $LLM_NS/$LLM_NAME (Ready=$LLM_READY, GPU share ${LLM_SHARE:-default 0.9})"; else note "no InferenceService $LLM_NAME on the cluster; the chart can deploy Llama 3.1 8B itself (needs a GPU)"; fi
  sc=$(oc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}')
  [ -n "$sc" ] && ok "default StorageClass $sc" || { bad "no default StorageClass"; return 1; }
  save OCP_VERSION "$OCP_VERSION"; save RHOAI_VERSION "$RHOAI_VERSION"; save GPUS "${GPUS:-0}"; save DOMAIN "$DOMAIN"; save LLM_NS "${LLM_NS:-}"
  [ "$KSERVE" = Managed ]
}
step2() {
  say "${B}Step 2: deployment profile${N} (decided from the GPUs on the cluster)"
  local mem_gib=""; [ -n "$GPU_MEMORY" ] && mem_gib=$((GPU_MEMORY / 1024))
  say "  found: ${GPUS:-0} GPU(s)${GPU_PRODUCT:+ $GPU_PRODUCT}${mem_gib:+ with $mem_gib GiB each}${LLM_NS:+; language model $LLM_NS/$LLM_NAME already deployed}"
  say "  the demo needs on GPUs: the language model, Whisper large-v3-turbo and BGE-M3."
  if [ "${PROFILE:-}" = remote ]; then
    for v in REMOTE_LLM_ENDPOINT REMOTE_LLM_MODEL REMOTE_STT_ENDPOINT REMOTE_EMB_ENDPOINT; do [ -n "${!v:-}" ] || { bad "PROFILE=remote needs $v (OpenAI-compatible base URL including /v1, or the model id)"; return 1; }; save "$v" "${!v}"; done
    save REMOTE_STT_MODEL "${REMOTE_STT_MODEL:-whisper-large-v3-turbo}"; save REMOTE_EMB_MODEL "${REMOTE_EMB_MODEL:-bge-m3}"
    ok "remote profile: every model is a remote endpoint; keys LLM_API_KEY, STT_API_KEY, EMBEDDINGS_API_KEY go into $SECRETS_FILE"
  elif [ "${GPUS:-0}" -eq 0 ]; then
    bad "not enough GPUs: the demo needs at least 1 NVIDIA GPU with 24 GB (an L4), this cluster has none."
    say "     required: 1 GPU of 24 GB shared by the language model (60%), Whisper (15%) and BGE-M3 (12%)"
    say "     available: 0 GPUs (no node carries nvidia.com/gpu.count; check the instance type with: oc get nodes -L node.kubernetes.io/instance-type)"
    say "     options: add a GPU node (g6.8xlarge or larger), or run with remote model endpoints: PROFILE=remote REMOTE_LLM_ENDPOINT=... scripts/setup.sh"
    return 1
  elif [ -n "$GPU_MEMORY" ] && [ "$GPU_MEMORY" -lt 20000 ]; then
    bad "not enough GPU memory: the demo needs 22 GB or more on one GPU, this cluster's ${GPU_PRODUCT:-GPU} has $mem_gib GiB."
    say "     required: language model 60% (about 14 GB with the 3B model), Whisper 15% (3.6 GB), BGE-M3 12% (2.9 GB) on the same card"
    say "     available: $GPUS x ${GPU_PRODUCT:-GPU} with $mem_gib GiB"
    say "     options: a GPU with 24 GB (L4, A10G, or larger), or remote endpoints for the language model (PROFILE=remote)"
    return 1
  else
    PROFILE=gpu
    ok "gpu profile: all $GPUS GPU(s) used, each advertised 4 times through time-slicing"
    if [ -n "$LLM_NS" ]; then say "     language model: $LLM_NS/$LLM_NAME, its GPU memory share is lowered to 60% in step 3"; else say "     language model: Llama 3.1 8B (4-bit) deployed by the chart at 45%"; fi
    say "     Whisper 15%, BGE-M3 12%; no guardrail model in this demo"
  fi
  save PROFILE "$PROFILE"; write_values_object; ok "profile $PROFILE saved ($STATE_DIR/values-object.json)"; mark 2
}
step3() {
  say "${B}Step 3: cluster bootstrap${N} (operators, KServe, GPU sharing, model share, Argo CD, project)"
  [ -n "${PROFILE:-}" ] || { bad "choose the profile first (step 2)"; return 1; }
  local log; log=$(logfile bootstrap); local slices; slices=$(profile_slices "$PROFILE")
  local frac=0.6
  say "  running scripts/bootstrap-cluster.sh with GPU_SLICES=$slices LLM_GPU_FRACTION=$frac (log $log)"
  PROJECT="$PROJECT" GPU_SLICES="$slices" LLM_NAME="${LLM_NS:+$LLM_NAME}" LLM_GPU_FRACTION="$frac" LOG_FILE="$log" "$ROOT/scripts/bootstrap-cluster.sh" && { mark 3; return 0; }
  bad "bootstrap reported problems; see $log, fix, and run: scripts/setup.sh --step 3"; return 1
}
step4() {
  say "${B}Step 4: TURN certificate${N} (voice through corporate networks needs TURN over TLS with a trusted certificate)"
  [ "$PROJECT_EXISTS" = yes ] || { bad "project missing; run step 3 first"; return 1; }
  local host="livekit-turn-${PROJECT}.${DOMAIN}" secret=livekit-turn-tls
  local name; name=$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null); name="${name:-router-certs-default}"
  local tmp; tmp=$(mktemp -d)
  say "  \$ oc get secret $name -n openshift-ingress   (the cluster's wildcard certificate)"
  if oc get secret "$name" -n openshift-ingress -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "$tmp/tls.crt" && [ -s "$tmp/tls.crt" ] \
     && oc get secret "$name" -n openshift-ingress -o jsonpath='{.data.tls\.key}' | base64 -d > "$tmp/tls.key" \
     && openssl x509 -in "$tmp/tls.crt" -noout -ext subjectAltName 2>/dev/null | grep -q "\*\.${DOMAIN}" \
     && openssl verify -untrusted "$tmp/tls.crt" "$tmp/tls.crt" >/dev/null 2>&1; then
    note "$(openssl x509 -in "$tmp/tls.crt" -noout -issuer -enddate | tr '\n' ' ')"
    oc create secret tls "$secret" -n "$PROJECT" --cert="$tmp/tls.crt" --key="$tmp/tls.key" --dry-run=client -o yaml | oc apply -f - >/dev/null \
      && ok "secret $PROJECT/$secret created from the trusted wildcard certificate for $host"
    rm -rf "$tmp"; mark 4; return 0
  fi
  rm -rf "$tmp"
  warn "the wildcard certificate is self-signed or does not cover *.$DOMAIN; cert-manager can request one from Let's Encrypt (the apps domain must be reachable from the internet)"
  [ "$YES" = 1 ] || ask ACME_EMAIL "E-mail for Let's Encrypt (empty to skip TURN for now)" "${ACME_EMAIL:-}"
  [ -n "${ACME_EMAIL:-}" ] || { warn "TURN skipped: voice works on open networks only. Rerun later: scripts/setup.sh --step 4"; mark 4; return 0; }
  save ACME_EMAIL "$ACME_EMAIL"
  oc get crd clusterissuers.cert-manager.io >/dev/null 2>&1 || { bad "cert-manager is not installed (step 3 installs it)"; return 1; }
  oc apply -f - <<YAML >/dev/null
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-http01
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-http01-account
    solvers:
      - http01:
          ingress:
            ingressClassName: openshift-default
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${secret}
  namespace: ${PROJECT}
spec:
  secretName: ${secret}
  dnsNames:
    - ${host}
  issuerRef:
    name: letsencrypt-http01
    kind: ClusterIssuer
YAML
  ok "ClusterIssuer letsencrypt-http01 and Certificate $PROJECT/$secret applied; waiting for the ACME challenge"
  cert_ready() { [ "$(oc get certificate "$secret" -n "$PROJECT" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]; }
  local waited=0
  until cert_ready; do
    [ "$waited" -ge 600 ] && { bad "certificate not Ready after 10 min; oc describe certificate $secret -n $PROJECT; oc get order,challenge -n $PROJECT"; return 1; }
    sleep 15; waited=$((waited + 15)); [ $((waited % 60)) -eq 0 ] && note "waiting for the ACME challenge (${waited}s)"
  done
  ok "certificate Ready for $host (renews itself)"; mark 4
}
step5() {
  say "${B}Step 5: keys and integrations${N} (one file: $SECRETS_FILE)"
  local n8n_host="n8n-$PROJECT.$DOMAIN"
  if [ ! -f "$SECRETS_FILE" ]; then cp "$ROOT/secrets.env.example" "$SECRETS_FILE" && chmod 600 "$SECRETS_FILE" && ok "created $SECRETS_FILE from secrets.env.example"; fi
  # shellcheck disable=SC1090
  set -a; . "$SECRETS_FILE"; set +a
  put() { local k=$1 v=$2; { grep -v "^$k=" "$SECRETS_FILE" || true; } > "$SECRETS_FILE.tmp"; printf '%s=%s\n' "$k" "$v" >> "$SECRETS_FILE.tmp"; mv "$SECRETS_FILE.tmp" "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"; }
  say ""
  say "  ${B}Slack${N} (approval cards and notifications). On your laptop: https://api.slack.com/apps > Create New App > From a manifest;"
  say "  paste n8n/slack-app-manifest.json with N8N_HOST replaced by $n8n_host, install the app to the workspace,"
  say "  copy the Bot User OAuth Token (xoxb-…) and, under Basic Information, the Signing Secret. Create the channels"
  say "  #assistant-ingestion #assistant-documents #assistant-approvals #assistant-tickets #assistant-knowledge-gaps and invite the app to each."
  if [ -n "${SLACK_BOT_TOKEN:-}" ]; then ok "SLACK_BOT_TOKEN already in the file"; else ask_secret v "Bot User OAuth Token"; [ -n "$v" ] && put SLACK_BOT_TOKEN "$v"; fi
  if [ -n "${SLACK_SIGNING_SECRET:-}" ]; then ok "SLACK_SIGNING_SECRET already in the file"; else ask_secret v "Signing Secret"; [ -n "$v" ] && put SLACK_SIGNING_SECRET "$v"; fi
  say ""
  say "  ${B}Tavus${N} (avatar video). On your laptop: https://platform.tavus.io > developer settings > API key. Free plan: 25 minutes a month, one stream."
  if [ -n "${TAVUS_API_KEY:-}" ]; then ok "TAVUS_API_KEY already in the file"; else ask_secret v "Tavus API key"; [ -n "$v" ] && put TAVUS_API_KEY "$v"; fi
  say ""
  say "  ${B}Google Docs${N} (transcript archival). On your laptop, in Google Cloud console: a project; enable Google Docs API and Google Drive API;"
  say "  OAuth consent screen External with yourself as test user; Credentials > OAuth client ID > Web application with redirect URI"
  say "  https://$n8n_host/rest/oauth2-credential/callback  (client id and secret are entered in n8n later, step 7)."
  say "  In Google Drive create a folder for transcripts; its id is the part of the URL after /folders/."
  if [ -n "${GOOGLE_DOCS_FOLDER_ID:-}" ]; then ok "GOOGLE_DOCS_FOLDER_ID already in the file"; else ask v "Drive folder id (Enter to skip)" ""; [ -n "$v" ] && put GOOGLE_DOCS_FOLDER_ID "$v"; fi
  if [ "${PROFILE:-}" = remote ]; then
    say ""; say "  ${B}Remote model keys${N} for the endpoints of step 2."
    for k in LLM_API_KEY STT_API_KEY EMBEDDINGS_API_KEY; do if [ -n "${!k:-}" ]; then ok "$k already in the file"; else ask_secret v "$k"; [ -n "$v" ] && put "$k" "$v"; fi; done
  fi
  say ""; say "  keys present in $SECRETS_FILE:"; grep -v '^#' "$SECRETS_FILE" | grep -v '=$' | grep -v '^$' | sed 's/=.*/=<set>/' | sed 's/^/     /'
  note "edit the file at any time with: nano $SECRETS_FILE ; the deploy step (6) applies it. Changed a key later? scripts/setup.sh --step 5 then --step 6."
  if [ "$SECRETS_IN_CLUSTER" = yes ]; then
    note "rewriting the integrations and model-key secrets in the cluster from the file (passwords are kept)"
    NAMESPACE="$PROJECT" SECRETS_FILE="$SECRETS_FILE" REFRESH=assistant-integrations,assistant-models "$ROOT/scripts/create-secrets.sh" | sed 's/^/  /'
  fi
  mark 5
}
step6() {
  say "${B}Step 6: deploy with Argo CD${N}"
  [ -n "${PROFILE:-}" ] || { bad "choose the profile first (step 2)"; return 1; }
  [ -f "$STATE_DIR/values-object.json" ] || write_values_object
  local log; log=$(logfile deploy)
  say "  profile $PROFILE, values chart/values-demo-cluster.yaml plus $STATE_DIR/values-object.json, secrets from $SECRETS_FILE (log $log)"
  say "  this takes 10 to 20 minutes, mostly model downloads"
  local llm_env=()
  if [ "$PROFILE" = remote ]; then llm_env=(LLM_ENDPOINT="$REMOTE_LLM_ENDPOINT" LLM_MODEL="$REMOTE_LLM_MODEL"); elif [ -z "${LLM_NS:-}" ]; then llm_env=(LLM_ENDPOINT="http://llama-3-1-8b-instruct-predictor.$PROJECT.svc.cluster.local:8080/v1" LLM_MODEL="llama-3-1-8b-instruct"); fi
  # shellcheck disable=SC1090
  set -a; [ -f "$SECRETS_FILE" ] && . "$SECRETS_FILE"; set +a
  env PROJECT="$PROJECT" SECRETS_FILE="$SECRETS_FILE" VALUES_OBJECT_FILE="$STATE_DIR/values-object.json" LLM_NAME="$LLM_NAME" LOG_FILE="$log" RUN_TESTS=1 "${llm_env[@]}" "$ROOT/scripts/deploy-argocd.sh" && { mark 6; return 0; }
  bad "deployment reported problems; see $log, fix, and run: scripts/setup.sh --step 6"; return 1
}
step7() {
  say "${B}Step 7: n8n first run${N} (browser, on your laptop)"
  [ -n "$N8N_URL" ] || { bad "n8n route not found; run step 6 first"; return 1; }
  say "  1. Open $N8N_URL and create the owner account (keep the password with your other secrets)."
  say "  2. Credentials > Create credential > Google Docs OAuth2 API: paste the client id and secret from Google Cloud, Sign in with Google."
  say "  3. Open WF5 Transcript archival, select the Google Docs node, pick the credential, save, Publish."
  say "  4. Overview shows WF1 to WF7 as Published."
  say "  Optional but recommended: Settings > n8n API > create an API key; this script uses it to verify the workflows and keeps it in $STATE_DIR/n8n.key (never in git)."
  key=""; [ -f "$STATE_DIR/n8n.key" ] || ask_secret key "n8n API key"
  if [ -n "$key" ]; then printf '%s' "$key" > "$STATE_DIR/n8n.key"; chmod 600 "$STATE_DIR/n8n.key"; fi
  if [ -f "$STATE_DIR/n8n.key" ]; then
    local wf; wf=$(curl -s --max-time 20 -H "X-N8N-API-KEY: $(cat "$STATE_DIR/n8n.key")" "$N8N_URL/api/v1/workflows?limit=50" | jq -r '.data[]? | "\(.active) \(.name)"' 2>/dev/null)
    if [ -n "$wf" ]; then
      printf '%s\n' "$wf" | sed 's/^true /  active   /; s/^false /  INACTIVE /'
      if printf '%s\n' "$wf" | grep -q '^false'; then warn "inactive workflows above: attach the missing credential in the editor and publish, then run: scripts/setup.sh --step 7"; return 1; fi
      ok "all workflows active"; mark 7; return 0
    fi
    warn "could not list workflows with that key (wrong key, or n8n not reachable from here)"
  fi
  confirm "Owner created, Google credential attached and every workflow Published?" && mark 7
}
step8() {
  say "${B}Step 8: sample documents${N} (15 policies, procedures, an invoice and a contract)"
  [ "${PODS_NOT_READY:-1}" = 0 ] || { bad "pods not ready; run step 6 first"; return 1; }
  say "  \$ NS=$PROJECT scripts/load-sample-docs.sh"
  NS="$PROJECT" "$ROOT/scripts/load-sample-docs.sh" | sed 's/^/  /' || { bad "upload failed"; return 1; }
  say "  waiting for ingestion (Slack #assistant-ingestion reports each document)"
  local waited=0 n=0
  while [ "$waited" -lt 900 ]; do
    n=$(oc exec deploy/rag-api -n "$PROJECT" -- .venv/bin/python -c 'import urllib.request,json; print(len(json.load(urllib.request.urlopen("http://ingestion:8080/v1/documents", timeout=10))))' 2>/dev/null || echo 0)
    [ "$n" -ge 10 ] && break; sleep 20; waited=$((waited + 20)); [ $((waited % 60)) -eq 0 ] && note "$n documents indexed after ${waited}s"
  done
  [ "$n" -ge 10 ] || { bad "only $n documents indexed after 15 min; oc logs deploy/ingestion -n $PROJECT --tail=50; scripts/n8n-executions.sh"; return 1; }
  ok "$n documents indexed"; NS="$PROJECT" "$ROOT/scripts/check-index.sh" | sed 's/^/  /'; mark 8
}
step9() {
  say "${B}Step 9: verification${N}"
  local extra=(); [ -f "$STATE_DIR/values-object.json" ] && extra=(-f "$STATE_DIR/values-object.json")
  local llm_set=(); [ -f "$HOME/assistant-cluster.env" ] && { . "$HOME/assistant-cluster.env"; llm_set=(--set "models.llm.endpoint=$LLM_ENDPOINT" --set "models.llm.servedModelName=$LLM_MODEL"); }
  say "  \$ NS=$PROJECT scripts/demo-preflight.sh -f chart/values-demo-cluster.yaml ${extra[*]:-} --set global.domain=$DOMAIN ${llm_set[*]:-}"
  if NS="$PROJECT" "$ROOT/scripts/demo-preflight.sh" -f "$ROOT/chart/values-demo-cluster.yaml" "${extra[@]}" --set "global.domain=$DOMAIN" "${llm_set[@]}"; then
    mark 9; say ""; say "  ${G}Ready for the demo.${N}"; say "  frontend $FRONTEND_URL"; say "  n8n      $N8N_URL"
    say "  Walk through docs/demo-script.md: a cited text answer, a voice session (the browser asks for the microphone), a request by voice with its Slack card, the archive button."
    say "  Next cluster: clone, scripts/setup.sh; update the Slack request URL and the Google redirect URI with the new domain (they contain it)."
  else bad "preflight reported problems (docs/troubleshooting.md); fix and run: scripts/setup.sh --step 9"; return 1; fi
}

# ---------------------------------------------------------------- main ----------------------
command -v jq >/dev/null || { echo "jq is required: sudo dnf install -y jq"; exit 1; }
[ "$MODE" = status ] || ensure_login || { discover; show_status; exit 1; }
say "$(ts) discovering the cluster (a few seconds)"
discover; show_status
case "$MODE" in
status) exit 0 ;;
step) [ -n "$ONLY" ] || { echo "usage: scripts/setup.sh --step N"; exit 1; }; run_step "$ONLY"; rc=$?; discover; show_status; exit $rc ;;
esac
while :; do
  [ -n "$NEXT" ] || { say "  ${G}Every step is done.${N} scripts/setup.sh --step N runs one again."; exit 0; }
  run_step "$NEXT"; rc=$?
  say "$(ts) refreshing the cluster state"
  QUIET_DISCOVERY=1 discover; show_status
  [ "$rc" = 0 ] || { say "  ${R}Stopped at step $NEXT${N}: fix what is reported above, then run scripts/setup.sh again (it resumes there)."; exit 1; }
done
