# Deployment guide

The [README](../README.md) shows the one-command install. This page has the manual Helm steps behind it, the remote-model and Argo CD variants, the optional third-party accounts, and how to handle the generated secrets. Every chart value is documented in [../chart/README.md](../chart/README.md).

## Manual installation with Helm

1. Clone the repository:

```bash
git clone https://github.com/rh-ai-quickstart/enterprise-voice-avatar-assistant.git
cd enterprise-voice-avatar-assistant
```

2. Create a new OpenShift project and note the cluster apps domain:

```bash
PROJECT="voice-avatar-assistant"
DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
oc new-project ${PROJECT}
```

3. Create the secrets. The script generates passwords for PostgreSQL, MinIO, n8n, and LiveKit, and stores any API keys you export beforehand (the variable names are listed in the script header). Secrets are never stored in git.

```bash
NAMESPACE=${PROJECT} scripts/create-secrets.sh
```

4. Install the chart. `global.domain` gives Routes, n8n, and LiveKit stable public URLs. Pick one of the two model options.

**Option A: deploy the models with the chart (default)**

The chart creates InferenceServices on OpenShift AI for the LLM (Llama 3.1 8B Instruct, W4A16), Whisper, and the embeddings model, plus a CPU text-to-speech service. This needs three GPUs; see [Minimum hardware requirements](../README.md#minimum-hardware-requirements).

```bash
helm install assistant chart --namespace ${PROJECT} \
  --set global.domain=${DOMAIN}
```

**Option B: bring your own model endpoints (MaaS)**

Point any model at an existing OpenAI-compatible endpoint instead. Endpoints include the protocol and the `/v1` path. API keys are read by the secrets script from `LLM_API_KEY`, `STT_API_KEY`, `EMBEDDINGS_API_KEY`, and `TTS_API_KEY`.

```bash
helm install assistant chart --namespace ${PROJECT} \
  --set global.domain=${DOMAIN} \
  --set models.llm.deploy=false \
  --set models.llm.endpoint=https://LLM_ENDPOINT/v1 \
  --set models.llm.servedModelName=LLM_MODEL_NAME \
  --set models.stt.deploy=false \
  --set models.stt.endpoint=https://STT_ENDPOINT/v1 \
  --set models.stt.servedModelName=STT_MODEL_NAME \
  --set models.embeddings.deploy=false \
  --set models.embeddings.endpoint=https://EMBEDDINGS_ENDPOINT/v1 \
  --set models.embeddings.servedModelName=EMBEDDINGS_MODEL_NAME
```

The two options mix per model, for example a MaaS LLM with Whisper deployed locally. For longer configurations copy `chart/values.yaml`, edit it, and pass it with `-f my-values.yaml`. Guardrails, the avatar provider, and the integrations are configured through the same file. Every value with its default and meaning is listed in [chart/README.md](../chart/README.md).

5. The n8n workflows are imported and published automatically when n8n starts (the `n8n.workflows` values control this). If `SLACK_BOT_TOKEN` was in the integrations secret at install time, the Slack nodes are wired too; otherwise open the n8n Route, add a Slack credential, and attach it. Google Docs (transcript archival) always needs a one-time sign-in in n8n. To update workflows later, edit `chart/files/n8n-workflows/` and run `scripts/import-workflows.sh`.

```bash
echo https://$(oc get route/n8n -n ${PROJECT} --template='{{.spec.host}}')
```

## Deploying with Argo CD

If the OpenShift GitOps operator is installed, Argo CD can own the deployment and keep it in sync with the `main` branch. It renders the same chart, so nothing differs from a manual install.

```bash
oc label namespace ${PROJECT} argocd.argoproj.io/managed-by=openshift-gitops
oc apply -f deploy/argocd/appproject.yaml
oc apply -f deploy/argocd/application.yaml
```

See [deploy/argocd/README.md](../deploy/argocd/README.md) for per-cluster values files.

## Model endpoint validation

The chart refuses to install when a model is set to `deploy: false` without an endpoint and a served model name, and prints what to set. After the install, `helm test` checks every configured model from inside the cluster (model lists, an embeddings call, and an LLM chat completion) plus the datastores and services:

```bash
helm test assistant -n ${PROJECT} --logs
```

For Argo CD deployments there is no Helm release to test; `NS=${PROJECT} scripts/test-services.sh` renders the same test pod from the chart, runs it, and prints the results.

## Third-party accounts and keys

Everything below is optional; the assistant runs without any of it. Keys go into the `assistant-integrations` secret (created by `scripts/create-secrets.sh` from environment variables, or updated later with `oc set data secret/assistant-integrations -n ${PROJECT} KEY=value`), never into git.

**Tavus (avatar video).** Sign up at [platform.tavus.io](https://platform.tavus.io) and create an API key under the developer settings; put it in the secret as `TAVUS_API_KEY`. Pick a stock face in the [face library](https://maker.tavus.io/dev/faces); its ID starts with `r` and is not secret, so set it in values as `voiceAgent.extraEnv.TAVUS_FACE_ID` next to `voiceAgent.avatarProvider: tavus`. The free plan includes 25 conversational minutes per month and one concurrent stream, so rehearse with `avatarProvider: none` and switch Tavus on for the avatar runs. The provider receives only the assistant's synthesized speech; the microphone audio stays in the cluster.

**Slack (notifications and approvals).** Create an app from `n8n/slack-app-manifest.json` (in the repository root) at [api.slack.com/apps](https://api.slack.com/apps) (*Create New App*, *From a manifest*). Under *OAuth & Permissions* install it to the workspace and copy the *Bot User OAuth Token* (`xoxb-…`) into the secret as `SLACK_BOT_TOKEN`; n8n creates its Slack credential from it on first start. Under *Interactivity & Shortcuts* set the request URL to `https://<n8n host>/webhook/slack-interactions` and keep Socket Mode off. Create the channels `#assistant-ingestion`, `#assistant-documents`, `#assistant-approvals`, `#assistant-tickets`, and `#assistant-knowledge-gaps`, and invite the app to each.

**Google Docs (transcript archival).** In [Google Cloud console](https://console.cloud.google.com) create a project, enable the *Google Docs API* and *Google Drive API*, configure the OAuth consent screen as *External* and add yourself as a test user, then create an *OAuth client ID* of type *Web application* whose authorized redirect URI is `https://<n8n host>/rest/oauth2-credential/callback`. In n8n add a *Google Docs OAuth2 API* credential with the client ID and secret and sign in. Create a Drive folder for transcripts and set its ID (the part of the URL after `/folders/`) in values as `n8n.extraEnv.GOOGLE_DOCS_FOLDER_ID`. While the consent screen stays in *Testing*, Google expires the sign-in after seven days; publishing the app removes that limit.

**ElevenLabs (cloud text-to-speech, instead of Kokoro).** Create an API key at [elevenlabs.io](https://elevenlabs.io) and put it in the secret as `ELEVENLABS_API_KEY`; choose a voice ID from their voice library and set `voiceAgent.extraEnv.TTS_PROVIDER: elevenlabs` and `voiceAgent.extraEnv.ELEVENLABS_VOICE_ID: <id>`.

**Simli and Hedra (alternative avatar providers).** Same pattern as Tavus with `SIMLI_API_KEY` and `SIMLI_FACE_ID`, or `HEDRA_API_KEY` and `HEDRA_AVATAR_IMAGE`, and the matching `voiceAgent.avatarProvider`.

## Working with the generated secrets

`scripts/create-secrets.sh` creates seven Secrets in the project and never overwrites an existing one unless `FORCE=1` is set. Argo CD does not manage them, so they survive syncs.

| Secret | Keys |
|---|---|
| `assistant-postgres` | `POSTGRESQL_USER`, `POSTGRESQL_PASSWORD`, `POSTGRESQL_DATABASE`, `DATABASE_URL` |
| `assistant-minio` | `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD` |
| `assistant-n8n` | `N8N_ENCRYPTION_KEY` |
| `assistant-qdrant` | `QDRANT_API_KEY` |
| `assistant-livekit` | `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` |
| `assistant-models` | `LLM_API_KEY`, `STT_API_KEY`, `TTS_API_KEY`, `EMBEDDINGS_API_KEY`, `GUARDRAILS_API_KEY`, `HF_TOKEN` |
| `assistant-integrations` | `SLACK_BOT_TOKEN`, `SLACK_SIGNING_SECRET`, `TAVUS_API_KEY`, `TAVUS_FACE_ID`, `TAVUS_PAL_ID`, `SIMLI_API_KEY`, `SIMLI_FACE_ID`, `ELEVENLABS_API_KEY`, `GOOGLE_SERVICE_ACCOUNT_JSON` |

Read a value, for example the MinIO console login:

```bash
oc extract secret/assistant-minio -n ${PROJECT} --to=-
```

Add or rotate one key without touching the others, then restart the pod that reads it (the config map and secrets are read at start):

```bash
oc set data secret/assistant-integrations -n ${PROJECT} TAVUS_API_KEY=<value>
oc rollout restart deployment/voice-agent -n ${PROJECT}
```

Back up `assistant-n8n`: losing `N8N_ENCRYPTION_KEY` makes every credential stored in n8n unreadable. `FORCE=1 scripts/create-secrets.sh` regenerates all passwords and is only for a fresh install; on a running deployment it would lock the services out of PostgreSQL and MinIO.
