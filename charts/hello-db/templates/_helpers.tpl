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

{{- /* CloudNativePG Cluster name (HA mode) */ -}}
{{- define "hello-db.cnpgName" -}}
{{- printf "%s-pgha" (include "hello-db.fullname" .) -}}
{{- end -}}

{{- /* Host the app connects to: CNPG primary (-rw) in HA mode, else the
       single Postgres Service. */ -}}
{{- define "hello-db.dbHost" -}}
{{- if .Values.postgres.ha.enabled -}}
{{- printf "%s-rw" (include "hello-db.cnpgName" .) -}}
{{- else -}}
{{- include "hello-db.postgresName" . -}}
{{- end -}}
{{- end -}}

{{- /* Secret holding the app DB credentials.
       HA: a basic-auth secret (keys: username/password) consumed by CNPG.
       Non-HA: the Opaque secret (keys: POSTGRES_USER/POSTGRES_PASSWORD). */ -}}
{{- define "hello-db.dbSecret" -}}
{{- if .Values.postgres.ha.enabled -}}
{{- printf "%s-app" (include "hello-db.cnpgName" .) -}}
{{- else -}}
{{- include "hello-db.postgresName" . -}}
{{- end -}}
{{- end -}}
