{{/*
Expand the name of the chart.
*/}}
{{- define "openshell-gateway.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
The namespace to deploy into.
*/}}
{{- define "openshell-gateway.namespace" -}}
{{- default .Release.Namespace .Values.namespace.name }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "openshell-gateway.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
app.kubernetes.io/name: {{ include "openshell-gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Values.image.tag }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
{{- end }}
{{- end }}

{{/*
Selector labels used by Deployment and Service.
*/}}
{{- define "openshell-gateway.selectorLabels" -}}
app.kubernetes.io/name: {{ include "openshell-gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
The gateway image reference.
*/}}
{{- define "openshell-gateway.image" -}}
{{- $tag := required "image.tag is required" .Values.image.tag }}
{{- printf "%s:%s" (required "image.repository is required" .Values.image.repository) $tag }}
{{- end }}
