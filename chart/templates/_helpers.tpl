{{/*
Common labels for every resource.
*/}}
{{- define "assistant.labels" -}}
app.kubernetes.io/part-of: enterprise-voice-avatar-assistant
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/*
Labels for one component. Call with (dict "root" $ "name" "<component>").
*/}}
{{- define "assistant.componentLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/component: {{ .name }}
{{ include "assistant.labels" .root }}
{{- end -}}

{{/*
Selector labels for one component. Must stay stable across chart versions.
*/}}
{{- define "assistant.selector" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end -}}

{{/*
Container security context compatible with the restricted SCC.
*/}}
{{- define "assistant.securityContext" -}}
allowPrivilegeEscalation: false
runAsNonRoot: true
capabilities:
  drop:
    - ALL
{{- end -}}

{{/*
Deterministic Route host when global.domain is set, else empty.
Call with (dict "root" $ "name" "<route name>").
*/}}
{{- define "assistant.host" -}}
{{- if .root.Values.global.domain -}}
{{ printf "%s-%s.%s" .name .root.Release.Namespace .root.Values.global.domain }}
{{- end -}}
{{- end -}}

{{/*
Public host: explicit override, else computed. Call with (dict "root" $ "name" "<route>" "override" "<value>").
*/}}
{{- define "assistant.publicHost" -}}
{{- if .override -}}
{{ .override }}
{{- else -}}
{{ include "assistant.host" . }}
{{- end -}}
{{- end -}}

{{/*
Image reference for an application component. Call with (dict "root" $ "name" "<component>" "override" "<image>").
*/}}
{{- define "assistant.image" -}}
{{- if .override -}}
{{ .override }}
{{- else -}}
{{ printf "%s/assistant-%s:%s" .root.Values.images.registry .name .root.Values.images.tag }}
{{- end -}}
{{- end -}}

{{/*
OpenAI-compatible base URL for a model. Call with (dict "root" $ "key" "llm|stt|embeddings|guardrails|tts").
In-cluster KServe raw deployments expose <name>-predictor on port 8080.
*/}}
{{- define "assistant.modelEndpoint" -}}
{{- $m := index .root.Values.models .key -}}
{{- if eq .key "tts" -}}
{{- if $m.deploy -}}http://tts:8880/v1{{- else -}}{{ $m.endpoint }}{{- end -}}
{{- else if $m.deploy -}}
http://{{ $m.name }}-predictor.{{ .root.Release.Namespace }}.svc.cluster.local:8080/v1
{{- else -}}
{{ $m.endpoint }}
{{- end -}}
{{- end -}}
