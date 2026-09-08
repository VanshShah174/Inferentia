{{/*
=============================================================================
vllm-inference — Template Helpers
=============================================================================
Reusable template functions used across all manifests in this chart.
*/}}

{{/*
Chart name (truncated to 63 chars for Kubernetes name limits)
*/}}
{{- define "vllm-inference.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name (release + chart, truncated to 63 chars)
*/}}
{{- define "vllm-inference.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Chart label value (name + version)
*/}}
{{- define "vllm-inference.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to all resources
*/}}
{{- define "vllm-inference.labels" -}}
helm.sh/chart: {{ include "vllm-inference.chart" . }}
{{ include "vllm-inference.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels (used in Deployment matchLabels and Service selector)
*/}}
{{- define "vllm-inference.selectorLabels" -}}
app.kubernetes.io/name: {{ include "vllm-inference.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Model download path on PVC
*/}}
{{- define "vllm-inference.modelPath" -}}
{{- printf "/models/%s" (last (splitList "/" .Values.model.name)) }}
{{- end }}

{{/*
Image reference (repository:tag)
*/}}
{{- define "vllm-inference.image" -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag }}
{{- end }}

{{/*
PVC name for model weights
*/}}
{{- define "vllm-inference.pvcName" -}}
{{- printf "%s-model-weights" (include "vllm-inference.fullname" .) }}
{{- end }}
