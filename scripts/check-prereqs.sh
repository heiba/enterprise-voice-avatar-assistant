#!/usr/bin/env bash
# Verifies that the current cluster meets the quickstart prerequisites.
# Read-only. Usage: NAMESPACE=voice-avatar-assistant scripts/check-prereqs.sh
set -uo pipefail

NS="${NAMESPACE:-voice-avatar-assistant}"
WARNS=0
FAILS=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; WARNS=$((WARNS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILS=$((FAILS + 1)); }

echo "Cluster access"
if user=$(oc whoami 2>/dev/null); then
  pass "logged in as ${user}"
else
  fail "not logged in; run oc login first"
  exit 1
fi
version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)
if [ -n "${version}" ]; then
  major=${version%%.*}; rest=${version#*.}; minor=${rest%%.*}
  if [ "${major}" -gt 4 ] || { [ "${major}" -eq 4 ] && [ "${minor}" -ge 16 ]; }; then
    pass "OpenShift ${version}"
  else
    fail "OpenShift ${version} is older than 4.16"
  fi
else
  warn "could not read the cluster version (missing permission?)"
fi

echo "OpenShift AI"
if oc get crd datascienceclusters.datasciencecluster.opendatahub.io >/dev/null 2>&1; then
  dsc=$(oc get datasciencecluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "${dsc}" ]; then
    kserve=$(oc get datasciencecluster "${dsc}" -o jsonpath='{.spec.components.kserve.managementState}' 2>/dev/null || true)
    if [ "${kserve}" = "Managed" ]; then pass "DataScienceCluster ${dsc}: kserve is Managed"; else fail "DataScienceCluster ${dsc}: kserve is not Managed"; fi
    trusty=$(oc get datasciencecluster "${dsc}" -o jsonpath='{.spec.components.trustyai.managementState}' 2>/dev/null || true)
    if [ "${trusty}" = "Managed" ]; then pass "TrustyAI is Managed"; else warn "TrustyAI is not Managed (only needed for the trustyai guardrails provider)"; fi
  else
    fail "OpenShift AI operator present but no DataScienceCluster exists (see deploy/bootstrap/instances)"
  fi
  rhoai=$(oc get csv -A -o jsonpath='{range .items[?(@.spec.displayName=="Red Hat OpenShift AI")]}{.spec.version}{"\n"}{end}' 2>/dev/null | head -n 1)
  [ -n "${rhoai}" ] && pass "OpenShift AI ${rhoai}"
else
  fail "OpenShift AI is not installed (see deploy/bootstrap)"
fi

echo "GPUs"
gpus=$(oc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END {print s+0}')
if [ "${gpus}" -gt 0 ]; then
  pass "${gpus} allocatable NVIDIA GPU(s)"
else
  warn "no allocatable GPUs; set models.<name>.deploy=false and use external endpoints"
fi
if oc get csv -A 2>/dev/null | grep 'Node Feature Discovery' >/dev/null; then pass "Node Feature Discovery operator"; else warn "Node Feature Discovery operator not found (needed for GPU nodes)"; fi
if oc get csv -A 2>/dev/null | grep 'NVIDIA GPU Operator' >/dev/null; then pass "NVIDIA GPU Operator"; else warn "NVIDIA GPU Operator not found (needed for GPU nodes)"; fi

echo "Storage and ingress"
sc=$(oc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null || true)
if [ -n "${sc}" ]; then pass "default StorageClass ${sc}"; else fail "no default StorageClass; set global.storageClassName"; fi
domain=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)
if [ -n "${domain}" ]; then pass "apps domain ${domain} (pass --set global.domain=${domain})"; else warn "could not read the apps domain; set global.domain manually"; fi

echo "Permissions in namespace ${NS}"
for res in deployments.apps services routes.route.openshift.io persistentvolumeclaims secrets configmaps jobs.batch \
           inferenceservices.serving.kserve.io servingruntimes.serving.kserve.io; do
  if oc auth can-i create "${res}" -n "${NS}" >/dev/null 2>&1; then pass "can create ${res}"; else fail "cannot create ${res} in ${NS}"; fi
done

echo "GitOps (optional)"
if oc get namespace openshift-gitops >/dev/null 2>&1; then pass "OpenShift GitOps is installed"; else warn "OpenShift GitOps not installed; only needed for the Argo CD path"; fi

echo
if [ "${FAILS}" -gt 0 ]; then
  echo "${FAILS} failure(s), ${WARNS} warning(s). Fix the failures before installing."
  exit 1
fi
echo "All required checks passed with ${WARNS} warning(s)."
