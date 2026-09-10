# Cluster bootstrap (cluster admin, once per cluster)

The quickstart itself installs as a regular user (see the main README). This
directory is for a cluster administrator who starts from a bare OpenShift
cluster and needs the platform prerequisites in place:

| Component | Why |
|---|---|
| Node Feature Discovery | labels GPU nodes so the GPU Operator can find them |
| NVIDIA GPU Operator | drivers and the device plugin that expose `nvidia.com/gpu` |
| Red Hat OpenShift AI | KServe model serving (vLLM), TrustyAI, dashboard |
| OpenShift GitOps | Argo CD, only needed for the GitOps deployment path |
| cert-manager | Required by OpenShift AI 3.x for KServe; issues the TURN certificate when the cluster has no trusted wildcard |

Run `scripts/check-prereqs.sh` first. It reports which of these are missing.
`scripts/bootstrap-cluster.sh` applies these manifests for whatever is absent, waits for
each operator, configures GPU time-slicing (`instances/gpu-time-slicing.yaml`, replica
count from `GPU_SLICES`), makes sure KServe is Managed, lowers the GPU memory share of the
pre-deployed language model (`LLM_NAME`, `LLM_GPU_FRACTION`), and creates the project; `scripts/setup.sh`
in the repository root drives it (README, Setup). `operators/cert-manager.yaml` is required by OpenShift AI 3.x
and used by `scripts/setup.sh` (step 4) to issue the TURN certificate when the cluster has no trusted wildcard.

## Apply in two phases

Operators must finish installing before their custom resources exist, so the
manifests are split into `operators/` (Subscriptions) and `instances/` (the
resources that configure each operator).

```bash
oc apply -k deploy/bootstrap/operators
# wait until every CSV shows Succeeded (5 to 10 minutes)
watch 'oc get csv -A | grep -E "nfd|gpu-operator|rhods|gitops"'
oc apply -k deploy/bootstrap/instances
```

Channels and operand versions are pinned in the manifests. Review them against
the OpenShift version you run before applying; the defaults match OpenShift
4.20, GPU Operator 25.3, and OpenShift AI 3.5. The ClusterPolicy references the
time-slicing ConfigMap; remove its `devicePlugin.config` block for exclusive GPUs.

If a component is already installed, delete its file from the relevant
`kustomization.yaml` or just leave it: applying an identical Subscription is a
no-op.
