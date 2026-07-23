{{/* Generate a consistent base name */}}
{{- define "devops-sample-api.fullname" -}}
{{- printf "%s-devops-sample-api" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "devops-sample-api.labels" -}}
app.kubernetes.io/name: devops-sample-api
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "devops-sample-api.selectorLabels" -}}
app.kubernetes.io/name: devops-sample-api
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
