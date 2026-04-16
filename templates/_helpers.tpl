{{/*
Expand the name of the chart.
*/}}
{{- define "..name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "..fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "..chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "..labels" -}}
helm.sh/chart: {{ include "..chart" . }}
{{ include "..selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "..selectorLabels" -}}
app.kubernetes.io/name: {{ include "..name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "..serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "..fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Generate odoo.conf content.
Call with dict: "Values" .Values "dbPassword" <password> "adminPasswd" <passwd>
Sensitive values are passed as parameters so both secrets.yaml and
externalsecrets.yaml can share a single source of truth.
*/}}
{{- define "..odooConf" -}}
[options]
proxy_mode = {{ .Values.odoo.proxy_mode }}
{{- if .Values.odoo.addons_path }}
addons_path = {{ .Values.odoo.addons_path }}
{{- end }}
server_wide_modules = {{ .Values.odoo.server_wide_modules }}
data_dir = /var/lib/odoo
workers = {{ .Values.odoo.workers | int }}
limit_memory_soft = {{ .Values.odoo.limit_memory_soft | int }}
limit_memory_hard = {{ .Values.odoo.limit_memory_hard | int }}
limit_time_cpu = {{ .Values.odoo.limit_time_cpu | int }}
limit_time_real = {{ .Values.odoo.limit_time_real | int }}
limit_time_real_cron = {{ .Values.odoo.limit_time_real_cron | int }}
limit_request = {{ .Values.odoo.limit_request | int }}
{{- if .Values.odoo.dbfilter }}
dbfilter = {{ .Values.odoo.dbfilter }}
{{- end }}
db_host = {{ .Values.postgresql.host }}
{{- if .Values.odoo.db_name }}
db_name = {{ .Values.postgresql.auth.database }}
{{- else }}
db_name = False
{{- end }}
db_port = {{ .Values.postgresql.port }}
db_user = {{ .Values.postgresql.auth.username }}
db_password = {{ .dbPassword }}
db_maxconn = {{ .Values.odoo.db_maxconn | int }}
{{- if .Values.odoo.db_replica_host }}
db_replica_host = {{ .Values.odoo.db_replica_host }}
db_replica_port = {{ .Values.odoo.db_replica_port | int }}
{{- end }}
without_demo = {{ .Values.odoo.without_demo }}
admin_passwd = {{ .adminPasswd }}
list_db = {{ .Values.odoo.list_db }}
smtp_server = {{ .Values.odoo.smtp_server }}
load_language = {{ .Values.odoo.load_language }}
log_level = {{ .Values.odoo.log_level }}
log_handler = {{ .Values.odoo.log_handler }}
{{- if .Values.cron.enabled }}
max_cron_threads = 0
{{- else }}
max_cron_threads = {{ .Values.odoo.max_cron_threads | int }}
{{- end }}
{{- end }}
