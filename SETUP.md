# Setting up the demo cluster from scratch

This guide takes a freshly provisioned OpenShift AI cluster to a working demo of the
assistant: platform prerequisites verified, one GPU shared by the model servers, keys and
integrations created from nothing, the chart deployed through Argo CD, n8n wired to Slack and
Google Docs, and the sample documents loaded. It is written to be repeated, because the
environment it targets is destroyed after two days.

Every command says where it runs. **Bastion** is the SSH host that comes with the
environment, logged in to the cluster as an administrator. **Laptop** is your own machine with
a browser; nothing is installed on it. Budget about two hours, most of it waiting for
operators and model downloads.

- [1. Prerequisites](#1-prerequisites)
- [2. Get the repository onto the bastion](#2-get-the-repository-onto-the-bastion)
- [3. Prepare the cluster](#3-prepare-the-cluster)
- [4. TURN certificate for voice](#4-turn-certificate-for-voice)
- [5. Keys and integrations](#5-keys-and-integrations)
- [6. Deploy with Argo CD](#6-deploy-with-argo-cd)
- [7. n8n first run](#7-n8n-first-run)
- [8. Sample documents and verification](#8-sample-documents-and-verification)
- [9. Day-two changes](#9-day-two-changes)
- [10. Repeating the setup on the next cluster](#10-repeating-the-setup-on-the-next-cluster)
- [11. When something fails](#11-when-something-fails)

## 1. Prerequisites

### 1.1 The cluster

This guide always assumes the following environment. Red Hat employees can provision it
from the Red Hat Demo Platform catalog item
[Red Hat OpenShift AI 3](https://catalog.demo.redhat.com/catalog/babylon-catalog-prod?item=babylon-catalog-prod/published.openshift-ai-v3.prod);
anyone else needs a cluster with the same properties.

| Assumed | Detail |
|---|---|
| 1. OpenShift Container Platform 4.20, single-node (SNO) | One AWS GPU instance runs everything. OpenShift Lightspeed is enabled on it (not used by the assistant) |
| 2. Red Hat OpenShift AI 3 | Installed from the `stable-3.x` channel, with KServe enabled and the supporting operators from the environment's own guide: cert-manager, Node Feature Discovery, NVIDIA GPU Operator, Red Hat Connectivity Link |
| 3. A Llama 3.2 3B Instruct model deployed as `llama-32-3b-instruct` | Deployed from the OpenShift AI model catalog by following the environment's guide: project `my-first-model`, vLLM runtime in standard (raw) mode, no token authentication, and `--gpu-memory-utilization=0.95`, which step 3 lowers. The assistant uses it as its language model; the chart deploys no other LLM on this cluster |
| 4. A bastion host | SSH access with `oc` logged in as `kubeadmin`. The provisioning e-mail or Showroom page has the host, user and password. Every command in this guide runs there unless it says **laptop** |
| Instance size | **g6.8xlarge**: 32 vCPU, 128 GB RAM, one NVIDIA L4 with 24 GB. Every `g6.*xlarge` size has a single L4; `g6.12xlarge` and `g6.24xlarge` have four, `g6.48xlarge` eight |

Two properties of the environment shape this guide:

- **One GPU, already partly used.** The deployed Llama 3.2 3B holds the L4 by itself. The GPU
  Operator's time-slicing advertises the card as four schedulable GPUs so that Whisper and
  BGE-M3 can join it, and each server gets a fixed share of the 24 GB: the bootstrap script
  lowers the deployed model's share to 60% and the chart gives Whisper 15% and BGE-M3 12%
  (`chart/values-demo-cluster.yaml`). Granite Guardian does not fit, so the guardrail provider
  is off. With a four-GPU instance, run step 3 with `GPU_SLICES=1` and restore the guardrail
  and LLM settings from `chart/values.yaml`.
- **Auto-stop after six hours, auto-destroy after 48.** Disable auto-stop in RHDP if you keep
  the environment (the catalog item warns about stop/start problems), and expect to redo
  everything on a new cluster; section 10 is the checklist for that.

Verify the starting point on the **bastion** before anything else:

```bash
oc whoami && oc get clusterversion version -o jsonpath='OpenShift {.status.desired.version}{"\n"}' && oc get nodes -L node.kubernetes.io/instance-type,nvidia.com/gpu.count && oc get csv -A | grep -E 'rhods|gpu-operator|nfd|cert-manager|gitops' && oc get datasciencecluster -o jsonpath='{range .items[*]}{.metadata.name} kserve={.spec.components.kserve.managementState}{"\n"}{end}' && oc get isvc -A
```

Expected: `kubeadmin`, OpenShift 4.20.x, one node with `nvidia.com/gpu.count` 1 and the
`g6.8xlarge` instance type, `rhods-operator` 3.x with the GPU, NFD and cert-manager CSVs in
`Succeeded`, a DataScienceCluster with `kserve=Managed`, and an InferenceService
`llama-32-3b-instruct` with `READY True`. GitOps may be missing; step 3 installs it. If
OpenShift AI shows a 2.x version, or the model is missing, this is not the expected
environment: finish the environment's own guide first.

### 1.2 Accounts

For the integrations, created from scratch in section 5:

| Account | Used for | Cost |
|---|---|---|
| A Slack workspace where you can create apps and channels | Approval cards, notifications | Free |
| [Tavus](https://platform.tavus.io) | Avatar video | Free plan: 25 conversational minutes a month, one concurrent stream |
| A Google account with access to [Google Cloud console](https://console.cloud.google.com) | Google Docs and Drive for transcript archival | Free |
| Optional: [ElevenLabs](https://elevenlabs.io) | Cloud text-to-speech instead of Kokoro | Free tier |

No GitHub or Quay account is needed: the application images are public on Quay and Argo CD
reads the public repository. A fork is only needed to change chart values (section 9).

### 1.3 Tools on the bastion

`oc`, `git`, `jq`, `python3`, `openssl` and `curl` are normally present. `helm` is needed by
the test scripts. Check and install what is missing:

```bash
for t in oc git jq python3 openssl curl helm; do printf '%-8s ' $t; command -v $t >/dev/null && echo ok || echo MISSING; done
```

```bash
sudo dnf install -y git jq python3 openssl curl && curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

## 2. Get the repository onto the bastion

On the **bastion**, clone the repository; every script runs from this clone:

```bash
git clone https://github.com/rh-ai-quickstart/enterprise-voice-avatar-assistant.git ~/enterprise-voice-avatar-assistant && cd ~/enterprise-voice-avatar-assistant
```

If the bastion has no access to GitHub, copy the repository from the **laptop** instead
(replace the host and user with the ones from the provisioning e-mail):

```bash
scp -r ~/enterprise-voice-avatar-assistant lab-user@bastion.example.opentlc.com:~/
```

Later updates: `cd ~/enterprise-voice-avatar-assistant && git pull`.

## 3. Prepare the cluster

One script does the cluster-administrator work. It checks each prerequisite, installs what is
absent from `deploy/bootstrap/`, configures GPU sharing, makes sure KServe is on, waits for
Argo CD, and creates the project. Every check prints `OK`, `WARN` or `FAIL`, the commands it
runs are echoed with `$`, each failure is followed by a `debug:` line with the commands that
show why, and the whole output is also written to `~/assistant-bootstrap-<timestamp>.log`.

On the **bastion**:

```bash
cd ~/enterprise-voice-avatar-assistant && GPU_SLICES=4 LLM_GPU_FRACTION=0.6 PROJECT=voice-avatar-assistant scripts/bootstrap-cluster.sh
```

What each step does and what to expect:

| Step | Action | Expected | Time |
|---|---|---|---|
| 1 Access and facts | Verifies cluster-admin, prints version, nodes, apps domain, default StorageClass | `OK` lines; a `WARN` on OpenShift older than 4.19 | seconds |
| 2 Operators | NFD, GPU Operator, cert-manager, GitOps: installed if absent. OpenShift AI is never installed or changed when present; a 2.x version fails the run | GitOps usually gets installed here | 5 min for GitOps |
| 3 OpenShift AI components | Sets `kserve` to Managed if it is not, waits for the DataScienceCluster and the KServe controller | `DataScienceCluster default-dsc Ready` | 1 to 5 min |
| 4 NFD instance | Creates the NodeFeatureDiscovery if absent, waits for the GPU node label | GPU node listed | seconds |
| 5 GPU Operator | Creates the ClusterPolicy if absent, waits for it, applies the time-slicing ConfigMap and points the ClusterPolicy at it, waits until the node advertises `GPU_SLICES` GPUs | `allocatable nvidia.com/gpu = 4` | 1 to 10 min |
| 6 Language model | Finds `llama-32-3b-instruct`, prints its vLLM arguments, and if its GPU memory share is above `LLM_GPU_FRACTION` (0.6) patches the InferenceService and waits for the model to come back Ready | `Ready with --gpu-memory-utilization=0.6`, then the GPU memory in use | 2 to 5 min |
| 7 Argo CD | Waits for the Argo CD server, prints its URL | URL | 1 min |
| 8 Project | Creates `voice-avatar-assistant`, labels it for Argo CD and for the OpenShift AI dashboard (the chart's models appear there with their metrics), applies the AppProject | `OK` | seconds |
| 9 Summary | Runs `scripts/check-prereqs.sh` | `All required checks passed` | seconds |

Verify afterwards:

```bash
oc get nodes -o custom-columns='NAME:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu,REPLICAS:.metadata.labels.nvidia\.com/gpu\.replicas' && oc get clusterpolicy -o jsonpath='ClusterPolicy {.items[0].status.state}{"\n"}' && oc get isvc -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,ARGS:.spec.predictor.model.args' && oc get namespace voice-avatar-assistant --show-labels
```

Expected: `GPUS 4`, `REPLICAS 4`, `ClusterPolicy ready`, the model `Ready True` with
`--gpu-memory-utilization=0.6` among its arguments, the namespace with
`argocd.argoproj.io/managed-by=openshift-gitops`.

If GPU sharing does not appear, the device plugin has not picked up the ConfigMap:
`oc get pods -n nvidia-gpu-operator` and `oc logs -n nvidia-gpu-operator -l app=nvidia-device-plugin-daemonset --tail=30`.
Rerunning the script is safe at any point.

## 4. TURN certificate for voice

Browsers on corporate networks reach the media server only through TURN over TLS on port
443, which needs a certificate the browser trusts for `livekit-turn-voice-avatar-assistant.<apps domain>`.
The chart expects it in the secret `livekit-turn-tls`; LiveKit waits until it exists.

On the **bastion**, copy the cluster's wildcard certificate into the project. The script
checks that the certificate is publicly trusted and covers the apps domain before copying:

```bash
cd ~/enterprise-voice-avatar-assistant && scripts/setup-turn-tls.sh copy
```

RHDP clusters usually have a trusted wildcard certificate and this succeeds. If it reports
that the certificate is self-signed or does not cover the domain, ask Let's Encrypt for one
through cert-manager instead (the HTTP-01 challenge is served by an OpenShift route, so the
apps domain must be reachable from the internet, which it is on AWS):

```bash
cd ~/enterprise-voice-avatar-assistant && ACME_EMAIL=you@example.com scripts/setup-turn-tls.sh cert-manager
```

Verify:

```bash
oc get secret livekit-turn-tls -n voice-avatar-assistant -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer -enddate
```

The copied wildcard certificate is rotated by the cluster from time to time; rerun the copy
when `enddate` gets close. Certificates from cert-manager renew themselves.

## 5. Keys and integrations

Everything the deployment needs is written into one file on the bastion, `~/secrets.env`,
and turned into OpenShift secrets by the deploy script. Nothing is typed into `oc`
commands. Start from the template:

```bash
cd ~/enterprise-voice-avatar-assistant && cp -n secrets.env.example ~/secrets.env && chmod 600 ~/secrets.env && echo "edit ~/secrets.env"
```

Two URLs in the steps below contain the cluster's apps domain. Print it once and keep it
at hand:

```bash
oc get ingresses.config.openshift.io cluster -o jsonpath='n8n host: n8n-voice-avatar-assistant.{.spec.domain}{"\n"}'
```

### 5.1 Slack

On the **laptop**, in the browser:

1. Open [api.slack.com/apps](https://api.slack.com/apps), choose **Create New App**, then
   **From a manifest**, pick the workspace, and paste the contents of
   `n8n/slack-app-manifest.json` from the repository. Before creating, replace `N8N_HOST` in
   the manifest with the n8n host printed above; the request URL becomes
   `https://n8n-voice-avatar-assistant.<apps domain>/webhook/slack-interactions`.
2. Under **Install App**, install it to the workspace and copy the **Bot User OAuth Token**
   (`xoxb-…`). It goes into `~/secrets.env` as `SLACK_BOT_TOKEN`.
3. Under **Basic Information**, copy the **Signing Secret** into `SLACK_SIGNING_SECRET`.
4. In Slack, create the channels `#assistant-ingestion`, `#assistant-documents`,
   `#assistant-approvals`, `#assistant-tickets` and `#assistant-knowledge-gaps`, and invite
   the app to each one (`/invite @Enterprise Assistant` in the channel).

The bot token is a secret: keep it in `~/secrets.env` only, never in a chat, a ticket or the
repository. If the app already exists from an earlier cluster, only the request URL under
**Interactivity & Shortcuts** changes; the token stays valid.

### 5.2 Tavus

On the **laptop**: sign up at [platform.tavus.io](https://platform.tavus.io), open the
developer settings and create an API key. It goes into `~/secrets.env` as `TAVUS_API_KEY`.

The faces offered in the UI are listed in `chart/values-demo-cluster.yaml` under
`voiceAgent.faces` (four Tavus stock faces). To see the whole stock catalog with its ids,
run on the **bastion** once the key is in the file:

```bash
cd ~/enterprise-voice-avatar-assistant && TAVUS_API_KEY=$(grep '^TAVUS_API_KEY=' ~/secrets.env | cut -d= -f2-) scripts/list-tavus-faces.sh
```

Changing the faces means changing the values file, which Argo CD reads from git; see
section 9. The free plan's single concurrent stream means one voice session with the
avatar at a time; rehearse with the avatar off if minutes matter.

### 5.3 Google Docs and Drive

On the **laptop**, in [Google Cloud console](https://console.cloud.google.com):

1. Create a project (any name).
2. **APIs & Services > Library**: enable the **Google Docs API** and the **Google Drive API**.
3. **APIs & Services > OAuth consent screen**: user type **External**, fill in the app name
   and your e-mail, and add your own Google account under **Test users**.
4. **APIs & Services > Credentials > Create credentials > OAuth client ID**: type
   **Web application**, authorized redirect URI
   `https://n8n-voice-avatar-assistant.<apps domain>/rest/oauth2-credential/callback`.
   Keep the **Client ID** and **Client secret**: they are entered in n8n in step 7, not in
   the file.
5. In [Google Drive](https://drive.google.com), create a folder for the transcripts and open
   it; the folder id is the part of the URL after `/folders/`. It goes into `~/secrets.env`
   as `GOOGLE_DOCS_FOLDER_ID`.

While the consent screen stays in **Testing**, Google expires the sign-in after seven days,
which is fine for a two-day cluster; publishing the app removes the limit.

### 5.4 Optional providers

`ELEVENLABS_API_KEY` switches text-to-speech to ElevenLabs when `TTS_PROVIDER=elevenlabs` is
set on the voice agent (values `voiceAgent.extraEnv`); `SIMLI_API_KEY` and `SIMLI_FACE_ID`
are for the Simli avatar provider. Leave them empty otherwise.

### 5.5 Fill in the file

On the **bastion**:

```bash
nano ~/secrets.env
```

Fill in `SLACK_BOT_TOKEN`, `SLACK_SIGNING_SECRET`, `TAVUS_API_KEY` and
`GOOGLE_DOCS_FOLDER_ID`; leave the rest empty. Passwords for PostgreSQL, MinIO, Qdrant,
LiveKit and the n8n encryption key are generated. Check that nothing is quoted or padded:

```bash
grep -v '^#' ~/secrets.env | grep -v '^$' | sed 's/=.*/=<set>/'
```

### 5.6 The values file

`chart/values-demo-cluster.yaml` is the values file for this environment: images from Quay,
Tavus with four faces, Whisper and BGE-M3 with their GPU shares, guardrails off, TURN on.
It contains nothing cluster-specific: the apps domain and the endpoint of the deployed
language model are passed by the deploy script, and every key lives in `~/secrets.env`. CI
writes new image tags into it after every build, so the cluster follows `main`.

## 6. Deploy with Argo CD

One script finds the deployed language model, creates the secrets from the file, registers
the Argo CD application with the cluster's apps domain and the model endpoint, and waits
for the sync, the models and the pods. Its output goes to `~/assistant-deploy-<timestamp>.log`
too. On the **bastion**:

```bash
cd ~/enterprise-voice-avatar-assistant && SECRETS_FILE=~/secrets.env RUN_TESTS=1 scripts/deploy-argocd.sh
```

What happens:

| Step | Action | Expected | Time |
|---|---|---|---|
| 1 Checks | Login, project, Argo CD, apps domain, values file, secrets file, TURN secret | `OK` lines; a `WARN` if the TURN secret is missing | seconds |
| 2 Language model | Finds `llama-32-3b-instruct`, builds its in-cluster URL, asks it for its model list from inside the cluster, writes `~/assistant-cluster.env` | `endpoint answers; served model id: …` | seconds |
| 3 Secrets | `scripts/create-secrets.sh` with the file; existing secrets are kept | `created assistant-…` six times, then `SLACK_BOT_TOKEN set` etc. | seconds |
| 4 Application | Applies `deploy/argocd/`, sets the repository, branch, values file, `global.domain` and the model endpoint on the application | `Application voice-avatar-assistant: … llm … at http://…` | seconds |
| 5 Sync | Waits for `Synced/Healthy`, printing unhealthy resources every minute | `application Synced/Healthy` | 5 to 15 min |
| 6 Models | Waits for the Whisper and BGE-M3 InferenceServices; the first start downloads about 3 GB of weights | `all InferenceServices Ready` | 5 to 10 min |
| 7 Pods | Waits for every pod | `all pods Running or Completed` | with the above |
| 8 URLs | Prints the frontend, n8n, LiveKit, Qdrant and Argo CD URLs | URLs | |
| 9 Tests | With `RUN_TESTS=1`, the connectivity test pod calls every model and store | every check `OK` | 1 min |

The models share one GPU with the deployed Llama 3.2 3B. If an InferenceService stays not
Ready, look at its pod log and at the GPU memory:
`oc logs -n voice-avatar-assistant -l serving.kserve.io/inferenceservice=<name> --tail=50`
and `oc exec -n nvidia-gpu-operator ds/nvidia-driver-daemonset -- nvidia-smi`. A vLLM message
such as "Free memory on device … is less than desired GPU memory utilization" means the
shares add up to more than the card has left: the deployed model's share (bootstrap,
`LLM_GPU_FRACTION`) plus Whisper and BGE-M3 (`chart/values-demo-cluster.yaml`) must stay
below about 90%.

If step 2 warns that the model endpoint did not answer, the model was deployed with token
authentication or serves TLS. Put the token in `~/secrets.env` as `LLM_API_KEY`, or pass the
right URL with `LLM_ENDPOINT=https://…/v1` (the services trust the OpenShift service CA), and
run the deploy script again.

Verify from the **laptop**: open the frontend URL, type a question such as *How often must
administrator passwords be rotated?* and expect "I could not find it in the company
documents" until section 8 loads the documents. The status bar lists the models.

## 7. n8n first run

The workflows are imported and published automatically when n8n starts, and the Slack
credential is created from `SLACK_BOT_TOKEN`. Two things are done by hand, in the browser
on the **laptop**, at the n8n URL printed by the deploy script:

1. **Owner account.** The first visit asks for an owner e-mail and password. Create it and
   keep the password with the other secrets.
2. **Google Docs credential.** Open **Credentials > Create credential**, choose **Google Docs
   OAuth2 API**, paste the Client ID and Client secret from step 5.3, and click **Sign in
   with Google**; approve with the test-user account. Then open the workflow
   **WF5 Transcript archival**, select the Google Docs node, pick the new credential, save,
   and publish the workflow (the import left it unpublished because the credential did not
   exist yet).
3. **Workflow check.** In **Overview**, every workflow WF1 to WF7 shows **Published**. Send a
   test by posting a document later in section 8; the first Slack messages appear in
   `#assistant-ingestion`.

For the scripts that talk to n8n (`scripts/import-workflows.sh`, `scripts/n8n-executions.sh`),
create an API key under **Settings > n8n API** and keep it in your shell on the bastion only
(`read -rs N8N_API_KEY; export N8N_API_KEY`). It is not part of `~/secrets.env`.

## 8. Sample documents and verification

On the **bastion**, load the fifteen sample documents (policies to the `documents` bucket,
invoices and contracts to the `inbox` bucket) and follow the ingestion:

```bash
cd ~/enterprise-voice-avatar-assistant && NS=voice-avatar-assistant scripts/load-sample-docs.sh && sleep 60 && NS=voice-avatar-assistant scripts/check-index.sh
```

Expected: `#assistant-ingestion` in Slack reports each document, `#assistant-documents`
shows the classified invoice and contract with extracted fields, and `check-index.sh`
lists the indexed documents with a hit for the password policy.

Full pre-demo check, the same one used before every demo:

```bash
cd ~/enterprise-voice-avatar-assistant && . ~/assistant-cluster.env && NS=$PROJECT scripts/demo-preflight.sh -f chart/$VALUES_FILE --set global.domain=$DOMAIN --set models.llm.endpoint=$LLM_ENDPOINT --set models.llm.servedModelName=$LLM_MODEL
```

`~/assistant-cluster.env` is written by the deploy script with the domain, the values file and
the model endpoint, so these commands need no retyping.

Then walk through [docs/demo-script.md](docs/demo-script.md) once from the **laptop**: a
cited text answer, a voice session with the avatar (the browser asks for the microphone),
a request by voice with its approval card in Slack, and the archive button producing a
Google Doc.

## 9. Day-two changes

- **Application updates.** Every push to `main` that touches the services builds images and
  commits their tags into `chart/values-demo-cluster.yaml`; Argo CD syncs within minutes.
  `oc get application voice-avatar-assistant -n openshift-gitops` shows the state.
- **A changed key.** Edit `~/secrets.env`, rewrite only that secret, and restart the pods that
  read it:

  ```bash
  cd ~/enterprise-voice-avatar-assistant && SECRETS_FILE=~/secrets.env NAMESPACE=voice-avatar-assistant REFRESH=assistant-integrations scripts/create-secrets.sh && oc rollout restart deployment/n8n deployment/rag-api deployment/voice-agent -n voice-avatar-assistant
  ```

  Never use `FORCE=1` on a running cluster: it regenerates the database and n8n passwords.
- **Chart values** (faces, voices, model shares). Argo CD deploys what is in git, so the
  change is a commit to `chart/values-demo-cluster.yaml` on `main`, or on a fork: run the
  deploy script again with `REPO_URL=<fork url>` and it re-points the application.
- **Workflows.** After editing `chart/files/n8n-workflows/`, re-import on the bastion with
  `N8N_URL=https://<n8n host> N8N_API_KEY=… scripts/import-workflows.sh`; credentials attached
  in the editor survive the re-import.

## 10. Repeating the setup on the next cluster

After the environment is destroyed and a new one provisioned:

1. **Bastion:** section 2 (clone), section 3 (bootstrap, which also resizes the deployed
   model's GPU share), section 4 (TURN), then `nano ~/secrets.env` is only needed if a key
   changed. The environment's own guide must have been followed first, so that OpenShift AI
   and `llama-32-3b-instruct` are there.
2. **Laptop:** the apps domain changed, so update the two URLs that contain it: the Slack
   app's request URL under **Interactivity & Shortcuts**, and the Google OAuth client's
   redirect URI under **Credentials**. Tokens, keys and the Drive folder stay valid.
3. **Bastion:** section 6 (deploy), section 8 (documents).
4. **Laptop:** section 7 (n8n owner account, Google credential, publish WF5).

About 90 minutes, most of it the model download.

## 11. When something fails

- The scripts leave logs in the home directory of the bastion:
  `~/assistant-bootstrap-*.log` and `~/assistant-deploy-*.log`. Each `FAIL` line is followed
  by a `debug:` line with the commands to run.
- `scripts/check-prereqs.sh` reports the platform state at any time;
  `scripts/demo-preflight.sh` the application state.
- Argo CD shows why a resource is unhealthy: the URL is printed by the deploy script, or
  `oc describe application voice-avatar-assistant -n openshift-gitops`.
- [docs/troubleshooting.md](docs/troubleshooting.md) lists the symptoms met while building
  the quickstart, by component, with the command that confirms each and the fix.
- Cluster-level problems on this environment (GPU node not ready, operators stuck) are in
  the RHDP environment's own guide and its support channel.
