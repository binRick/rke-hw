{{- define "hello-db.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "hello-db.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "hello-db.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "hello-db.labels" -}}
app.kubernetes.io/name: {{ include "hello-db.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "hello-db.postgresName" -}}
{{- printf "%s-postgres" (include "hello-db.fullname" .) -}}
{{- end -}}

{{- define "hello-db.appName" -}}
{{- printf "%s-app" (include "hello-db.fullname" .) -}}
{{- end -}}
