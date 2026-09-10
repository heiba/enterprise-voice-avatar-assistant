#!/usr/bin/env bash
# One-time cluster preparation, run on the bastion host as a cluster administrator.
# Verifies (and, unless INSTALL_MISSING=0, installs) the platform prerequisites, shares each
# GPU between several model servers, makes sure OpenShift AI serves models with KServe, and
# creates the project that Argo CD will manage. Safe to run again: every step checks before
# it changes anything. Everything printed also goes to the log file.
#
# Usage: scripts/bootstrap-cluster.sh
#   PROJECT=voice-avatar-assistant   project created for the assistant (Argo CD managed)
#   GPU_SLICES=4                     model servers that may share one GPU (1 = exclusive GPUs)
#   LLM_NAME=llama-32-3b-instruct    InferenceService already deployed on the cluster (prerequisite)
#   LLM_GPU_FRACTION=0.6             GPU memory share left to that model so Whisper and BGE-M3 fit
#   INSTALL_MISSING=1                install absent operators from deploy/bootstrap (0 = report only)
#   LOG_FILE=~/assistant-bootstrap-<timestamp>.log
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="${PROJECT:-voice-avatar-assistant}"
GPU_SLICES="${GPU_SLICES:-4}"
LLM_NAME="${LLM_NAME:-llama-32-3b-instruct}"
LLM_GPU_FRACTION="${LLM_GPU_FRACTION:-0.6}"
INSTALL_MISSING="${INSTALL_MISSING:-1}"
LOG_FILE="${LOG_FILE:-$HOME/assistant-bootstrap-$(date +%Y%m%d-%H%M%S).log}"
exec > >(tee -a "$LOG_FILE") 2>&1

STEP=0; FAILED=0
step() { STEP=$((STEP + 1)); printf '\n\033[1m== Step %s: %s\033[0m  (%s)\n' "$STEP" "$1" "$(date +%H:%M:%S)"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
info() { printf '  ..   %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=$((FAILED + 1)); }
debug(){ printf '  debug: %s\n' "$1"; }
run()  { printf '  $ %s\n' "$*"; "$@"; }
# wait_for <seconds> <description> <command...>: polls every 10 s, prints progress every minute
wait_for() {
  local timeout=$1 what=$2; shift 2
  local waited=0
  while ! "$@" >/dev/null 2>&1; do
    if [ "$waited" -ge "$timeout" ]; then return 1; fi
    sleep 10; waited=$((waited + 10))
    [ $((waited % 60)) -eq 0 ] && info "still waiting for $what (${waited}s)"
  done
  return 0
}
csv_phase() { oc get csv -A -o json 2>/dev/null | jq -r --arg n "$1" '.items[] | select(.metadata.name | startswith($n)) | "\(.status.phase) \(.spec.version)"' | head -1; }
csv_succeeded() { [ "$(csv_phase "$1" | cut -d' ' -f1)" = "Succeeded" ]; }
require_tool() { command -v "$1" >/dev/null || { fail "$1 is not installed on this host ($2)"; exit 1; }; }

echo "Bootstrap log: $LOG_FILE"

step "Access and cluster facts"
require_tool oc "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/"
require_tool jq "sudo dnf install -y jq"
if user=$(oc whoami 2>/dev/null); then ok "logged in as $user ($(oc whoami --show-server))"; else fail "not logged in: oc login <api url> -u kubeadmin"; exit 1; fi
if oc auth can-i create clusterpolicies.nvidia.com >/dev/null 2>&1 && oc auth can-i create namespaces >/dev/null 2>&1; then ok "cluster-admin permissions"; else fail "this user cannot create cluster-scoped resources; log in as kubeadmin or a cluster-admin"; exit 1; fi
version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
ok "OpenShift $version"
case "$version" in 4.1[0-8].*) warn "OpenShift AI 3.x needs 4.19.9 or later; this cluster is $version" ;; esac
info "nodes:"
oc get nodes -o custom-columns='NAME:.metadata.name,ROLES:.metadata.labels.node-role\.kubernetes\.io/worker,INSTANCE:.metadata.labels.node\.kubernetes\.io/instance-type,CPU:.status.capacity.cpu,MEMORY:.status.capacity.memory,GPU:.status.capacity.nvidia\.com/gpu' | sed 's/^/     /'
domain=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
ok "apps domain $domain"
sc=$(oc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}')
if [ -n "$sc" ]; then ok "default StorageClass $sc"; else fail "no default StorageClass (oc get storageclass; annotate one with storageclass.kubernetes.io/is-default-class=true)"; fi

step "Operators"
install_operator() {  # <display name> <csv prefix> <manifest>
  local name=$1 prefix=$2 manifest=$3
  if csv_succeeded "$prefix"; then ok "$name $(csv_phase "$prefix" | cut -d' ' -f2) (installed)"; return 0; fi
  if [ "$INSTALL_MISSING" != "1" ]; then fail "$name is not installed (INSTALL_MISSING=0, so not installing): oc apply -f $manifest"; return 1; fi
  info "$name is missing; installing from $manifest"
  run oc apply -f "$ROOT/$manifest" >/dev/null
  if wait_for 900 "$name" csv_succeeded "$prefix"; then ok "$name $(csv_phase "$prefix" | cut -d' ' -f2) installed"; else
    fail "$name did not reach Succeeded in 15 min"; debug "oc get csv -A | grep -i '${prefix}'; oc get subscription -A; oc get installplan -A"; return 1; fi
}
install_operator "Node Feature Discovery" "nfd" deploy/bootstrap/operators/nfd.yaml
install_operator "NVIDIA GPU Operator" "gpu-operator-certified" deploy/bootstrap/operators/gpu-operator.yaml
install_operator "cert-manager Operator" "cert-manager-operator" deploy/bootstrap/operators/cert-manager.yaml
install_operator "OpenShift GitOps" "openshift-gitops-operator" deploy/bootstrap/operators/gitops.yaml
if csv_succeeded "rhods-operator"; then
  channel=$(oc get subscription rhods-operator -n redhat-ods-operator -o jsonpath='{.spec.channel}' 2>/dev/null)
  ok "OpenShift AI $(csv_phase rhods-operator | cut -d' ' -f2) (channel ${channel:-unknown}; left as installed)"
  case "$(csv_phase rhods-operator | cut -d' ' -f2)" in 2.*) fail "OpenShift AI 2.x found; this quickstart needs 3.x (see SETUP.md prerequisites)";; esac
else
  install_operator "OpenShift AI" "rhods-operator" deploy/bootstrap/operators/rhoai.yaml || true
fi

step "OpenShift AI components (KServe)"
dsc=$(oc get datasciencecluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$dsc" ]; then
  if [ "$INSTALL_MISSING" = "1" ] && oc get crd datascienceclusters.datasciencecluster.opendatahub.io >/dev/null 2>&1; then
    info "no DataScienceCluster; creating the one from deploy/bootstrap/instances/rhoai.yaml"
    run oc apply -f "$ROOT/deploy/bootstrap/instances/rhoai.yaml" >/dev/null; dsc=default-dsc
  else
    fail "no DataScienceCluster found; create one in the OpenShift AI operator (see deploy/bootstrap/instances/rhoai.yaml)"
  fi
fi
if [ -n "$dsc" ]; then
  kserve=$(oc get datasciencecluster "$dsc" -o jsonpath='{.spec.components.kserve.managementState}')
  if [ "$kserve" = "Managed" ]; then ok "DataScienceCluster $dsc: kserve Managed"; else
    info "kserve is '${kserve:-unset}'; setting it to Managed"
    run oc patch datasciencecluster "$dsc" --type merge -p '{"spec":{"components":{"kserve":{"managementState":"Managed","rawDeploymentServiceConfig":"Headless"}}}}' >/dev/null
  fi
  dsc_ready() { [ "$(oc get datasciencecluster "$dsc" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = "True" ]; }
  if wait_for 600 "DataScienceCluster $dsc Ready" dsc_ready; then ok "DataScienceCluster $dsc Ready"; else
    fail "DataScienceCluster $dsc not Ready after 10 min"; debug "oc describe datasciencecluster $dsc | sed -n '/Conditions/,\$p'; oc get pods -n redhat-ods-applications"; fi
  if wait_for 300 "KServe controller" oc get deployment kserve-controller-manager -n redhat-ods-applications; then ok "KServe controller present"; else fail "kserve-controller-manager deployment missing in redhat-ods-applications"; fi
  ok "OpenShift AI dashboard: https://$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || echo '<no route yet>')"
fi

step "Node Feature Discovery instance"
if oc get nodefeaturediscovery -n openshift-nfd -o name 2>/dev/null | grep -q .; then ok "NodeFeatureDiscovery exists"; else
  if [ "$INSTALL_MISSING" = "1" ]; then run oc apply -f "$ROOT/deploy/bootstrap/instances/nfd-instance.yaml" >/dev/null; else fail "no NodeFeatureDiscovery instance (deploy/bootstrap/instances/nfd-instance.yaml)"; fi
fi
# NFD labels nodes with an NVIDIA PCI device (vendor 10de); the nvidia.com/* labels come later from the GPU operator
gpu_labelled() { oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true -o name 2>/dev/null | grep -q .; }
if wait_for 600 "NFD to label the GPU node" gpu_labelled; then ok "nodes with an NVIDIA device: $(oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true -o name | tr '\n' ' ')"; else
  fail "no node carries feature.node.kubernetes.io/pci-10de.present=true"; debug "oc get pods -n openshift-nfd; oc get nodefeaturediscovery -n openshift-nfd -o yaml | tail -20"; fi

step "NVIDIA GPU Operator: ClusterPolicy and GPU sharing"
if oc get clusterpolicy -o name 2>/dev/null | grep -q .; then ok "ClusterPolicy $(oc get clusterpolicy -o jsonpath='{.items[0].metadata.name}') exists"; else
  if [ "$INSTALL_MISSING" = "1" ]; then run oc apply -f "$ROOT/deploy/bootstrap/instances/gpu-clusterpolicy.yaml" >/dev/null; else fail "no ClusterPolicy (deploy/bootstrap/instances/gpu-clusterpolicy.yaml)"; fi
fi
policy=$(oc get clusterpolicy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
policy_ready() { [ "$(oc get clusterpolicy "$policy" -o jsonpath='{.status.state}')" = "ready" ]; }
if wait_for 1200 "ClusterPolicy $policy (driver build can take 10 min)" policy_ready; then ok "ClusterPolicy $policy ready"; else
  fail "ClusterPolicy $policy is $(oc get clusterpolicy "$policy" -o jsonpath='{.status.state}')"; debug "oc get pods -n nvidia-gpu-operator; oc logs -n nvidia-gpu-operator -l app=nvidia-driver-daemonset --tail=50"; fi
gpu_discovered() { oc get nodes -l nvidia.com/gpu.present=true -o name 2>/dev/null | grep -q .; }
if wait_for 300 "GPU feature discovery labels" gpu_discovered; then ok "GPU nodes: $(oc get nodes -l nvidia.com/gpu.present=true -o name | tr '\n' ' ')"; else
  fail "no node carries nvidia.com/gpu.present=true"; debug "oc get pods -n nvidia-gpu-operator -l app=gpu-feature-discovery; oc get nodes --show-labels | grep -o 'nvidia.com/gpu[^,]*' | sort -u"; fi
physical=$(oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[0].metadata.labels.nvidia\.com/gpu\.count}' 2>/dev/null || echo 0)
product=$(oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[0].metadata.labels.nvidia\.com/gpu\.product}' 2>/dev/null)
info "first GPU node: ${physical:-?} x ${product:-unknown}, driver $(oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[0].metadata.labels.nvidia\.com/cuda\.driver-version\.full}' 2>/dev/null), CUDA $(oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[0].metadata.labels.nvidia\.com/cuda\.runtime-version\.full}' 2>/dev/null)"
if [ "$GPU_SLICES" -gt 1 ]; then
  info "time-slicing: each GPU advertised as $GPU_SLICES nvidia.com/gpu"
  sed "s/replicas: 4/replicas: $GPU_SLICES/" "$ROOT/deploy/bootstrap/instances/gpu-time-slicing.yaml" | oc apply -f - >/dev/null && ok "ConfigMap device-plugin-config applied"
  run oc patch clusterpolicy "$policy" --type merge -p '{"spec":{"devicePlugin":{"config":{"name":"device-plugin-config","default":"any"}}}}' >/dev/null
  expected=$((physical * GPU_SLICES))
  sliced() { [ "$(oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}')" = "$expected" ]; }
  if wait_for 600 "allocatable nvidia.com/gpu to become $expected" sliced; then ok "allocatable nvidia.com/gpu = $expected on the first GPU node"; else
    fail "allocatable nvidia.com/gpu is $(oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}'), expected $expected"
    debug "oc get cm device-plugin-config -n nvidia-gpu-operator -o yaml; oc logs -n nvidia-gpu-operator -l app=nvidia-device-plugin-daemonset --tail=30; oc get nodes -L nvidia.com/gpu.replicas"; fi
else
  ok "GPU sharing off (GPU_SLICES=1); allocatable nvidia.com/gpu = $(oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}')"
fi

step "Pre-deployed language model ($LLM_NAME)"
llm_ns=$(oc get isvc -A -o json 2>/dev/null | jq -r --arg n "$LLM_NAME" '.items[] | select(.metadata.name==$n) | .metadata.namespace' | head -1)
if [ -z "$llm_ns" ]; then
  fail "no InferenceService named $LLM_NAME on the cluster; deploy Llama 3.2 3B Instruct from the OpenShift AI model catalog first (SETUP.md prerequisites), or set LLM_NAME"
  debug "oc get isvc -A"
else
  ready=$(oc get isvc "$LLM_NAME" -n "$llm_ns" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  ok "InferenceService $llm_ns/$LLM_NAME (Ready=$ready, url $(oc get isvc "$LLM_NAME" -n "$llm_ns" -o jsonpath='{.status.address.url}'))"
  pod=$(oc get pods -n "$llm_ns" -l "serving.kserve.io/inferenceservice=$LLM_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  args=$(oc get isvc "$LLM_NAME" -n "$llm_ns" -o json | jq -c '.spec.predictor.model.args // []')
  current=$(printf '%s' "$args" | jq -r '.[] | select(startswith("--gpu-memory-utilization")) | sub("^--gpu-memory-utilization=?";"")' | head -1)
  info "predictor pod ${pod:-none}; vLLM args $args; GPU memory share ${current:-unset (vLLM default 0.9)}"
  if [ "$GPU_SLICES" -gt 1 ] && [ "$(printf '%s\n' "${current:-0.9}" "$LLM_GPU_FRACTION" | sort -g | tail -1)" != "$LLM_GPU_FRACTION" ]; then
    info "lowering the model's GPU memory share to $LLM_GPU_FRACTION so Whisper and BGE-M3 fit next to it"
    newargs=$(printf '%s' "$args" | jq -c --arg f "--gpu-memory-utilization=$LLM_GPU_FRACTION" '[.[] | select(startswith("--gpu-memory-utilization") | not)] + [$f]')
    run oc patch isvc "$LLM_NAME" -n "$llm_ns" --type merge -p "{\"spec\":{\"predictor\":{\"model\":{\"args\":$newargs}}}}" >/dev/null
    llm_ready() { [ "$(oc get isvc "$LLM_NAME" -n "$llm_ns" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = "True" ] && [ "$(oc get pods -n "$llm_ns" -l "serving.kserve.io/inferenceservice=$LLM_NAME" --no-headers | grep -c Running)" = "1" ]; }
    sleep 20
    if wait_for 900 "$LLM_NAME to restart with the new share" llm_ready; then ok "$LLM_NAME Ready with --gpu-memory-utilization=$LLM_GPU_FRACTION"; else
      fail "$LLM_NAME did not come back Ready"; debug "oc get pods -n $llm_ns; oc logs -n $llm_ns -l serving.kserve.io/inferenceservice=$LLM_NAME --tail=50"; fi
  else
    ok "GPU memory share ${current:-0.9} needs no change"
  fi
  info "GPU memory now: $(oc exec -n nvidia-gpu-operator "$(oc get pods -n nvidia-gpu-operator -l app=nvidia-driver-daemonset -o jsonpath='{.items[0].metadata.name}')" -- nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null || echo 'nvidia-smi unavailable')"
fi

step "Argo CD"
argo_ready() { [ "$(oc get deployment openshift-gitops-server -n openshift-gitops -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "1" ]; }
if wait_for 600 "Argo CD server" argo_ready; then ok "Argo CD: https://$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}')"; else
  fail "openshift-gitops-server is not ready"; debug "oc get pods -n openshift-gitops; oc get argocd -n openshift-gitops"; fi

step "Project $PROJECT"
if oc get namespace "$PROJECT" >/dev/null 2>&1; then ok "project exists"; else run oc new-project "$PROJECT" >/dev/null && ok "project created"; fi
run oc label namespace "$PROJECT" argocd.argoproj.io/managed-by=openshift-gitops --overwrite >/dev/null && ok "managed by openshift-gitops"
# shown as a data science project in the OpenShift AI dashboard, with the chart's models and their metrics
run oc label namespace "$PROJECT" opendatahub.io/dashboard=true --overwrite >/dev/null && ok "visible in the OpenShift AI dashboard"
run oc apply -f "$ROOT/deploy/argocd/appproject.yaml" >/dev/null && ok "AppProject applied"

step "Summary"
NAMESPACE="$PROJECT" "$ROOT/scripts/check-prereqs.sh" || FAILED=$((FAILED + 1))
echo
if [ "$FAILED" -gt 0 ]; then echo "Bootstrap finished with $FAILED problem(s); see the FAIL lines above and the log $LOG_FILE"; exit 1; fi
echo "Bootstrap complete. Next: scripts/setup-turn-tls.sh, then SECRETS_FILE=~/secrets.env scripts/deploy-argocd.sh (see SETUP.md)."
