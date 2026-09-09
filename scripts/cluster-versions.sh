#!/usr/bin/env bash
# Prints the versions behind the README's tested-versions table: OpenShift, the relevant
# operators, GPU driver and CUDA from the node labels, and vLLM inside a served model pod.
# Read-only. Usage: NS=<namespace> scripts/cluster-versions.sh
set -uo pipefail
NS="${NS:-$(oc project -q)}"
echo -n "OpenShift: "; oc get clusterversion version -o jsonpath='{.status.desired.version}'; echo
echo "Operators:"
oc get csv -A -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.version}{"\n"}{end}' 2>/dev/null \
  | grep -iE 'gpu-operator|^nfd|rhods|openshift-gitops|cert-manager|serverless|authorino' | sort -u | sed 's/^/  /'
echo "GPU nodes (driver / CUDA from the GPU operator labels):"
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" driver="}{.metadata.labels.nvidia\.com/cuda\.driver-version\.full}{" cuda="}{.metadata.labels.nvidia\.com/cuda\.runtime-version\.full}{" gpu="}{.metadata.labels.nvidia\.com/gpu\.product}{"\n"}{end}' | grep 'driver=[0-9]' | sed 's/^/  /' || echo "  none labelled"
POD=$(oc get pods -n "$NS" -l serving.kserve.io/inferenceservice --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$POD" ]; then
  echo -n "vLLM in $POD: "
  oc exec -n "$NS" "$POD" -c kserve-container -- python -c "import torch, vllm; print('vllm', vllm.__version__, '| torch', torch.__version__, '| cuda', torch.version.cuda)" 2>/dev/null | tail -1
fi
for d in n8n livekit; do
  img=$(oc get deploy "$d" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null) && echo "$d: $img"
done
