# GitOps deployment with Argo CD (optional)

This path deploys the same Helm chart as `helm install`, but Argo CD keeps the
cluster in sync with the `main` branch. It needs the OpenShift GitOps operator
(see `deploy/bootstrap`).

1. Create the project and let the default Argo CD instance manage it:

   ```bash
   oc new-project voice-avatar-assistant
   oc label namespace voice-avatar-assistant argocd.argoproj.io/managed-by=openshift-gitops
   ```

2. Create the secrets once (they are never stored in git):

   ```bash
   NAMESPACE=voice-avatar-assistant scripts/create-secrets.sh
   ```

3. Register the application:

   ```bash
   oc apply -f deploy/argocd/appproject.yaml
   oc apply -f deploy/argocd/application.yaml
   ```

4. Watch the sync in the Argo CD UI (route `openshift-gitops-server` in the
   `openshift-gitops` namespace) or with `oc get applications.argoproj.io -n openshift-gitops`.

`application.yaml` points at `values.yaml` plus `values-demo-cluster.yaml`;
`scripts/deploy-argocd.sh` replaces the second file with `VALUES_FILE` (one file per
cluster, `values-demo-cluster-2.yaml` for the second demo cluster) and sets
`global.domain` as a Helm parameter, so no domain is stored in git. To deploy a
different branch or a fork, pass `TARGET_REVISION` and `REPO_URL` to the script.
