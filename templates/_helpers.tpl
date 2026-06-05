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
Resolve Odoo's database connection from the right source:
- bundled (postgresql.enabled): credentials come from postgresql.auth.*, the
  host is the bundled service "<release>-postgresql" and the port is 5432.
- external (postgresql.enabled false): credentials come from externalDatabase.*
  ("..dbHost" fails fast if externalDatabase.host is not set).
These take the root context (they need .Release / .Values).
*/}}
{{- define "..dbHost" -}}
{{- if .Values.postgresql.enabled -}}
{{- printf "%s-postgresql" .Release.Name -}}
{{- else -}}
{{- required "externalDatabase.host is required when postgresql.enabled is false" .Values.externalDatabase.host -}}
{{- end -}}
{{- end }}

{{- define "..dbPort" -}}
{{- if .Values.postgresql.enabled -}}5432{{- else -}}{{ .Values.externalDatabase.port }}{{- end -}}
{{- end }}

{{- define "..dbName" -}}
{{- if .Values.postgresql.enabled -}}{{ .Values.postgresql.auth.database }}{{- else -}}{{ .Values.externalDatabase.name }}{{- end -}}
{{- end }}

{{- define "..dbUser" -}}
{{- if .Values.postgresql.enabled -}}{{ .Values.postgresql.auth.username }}{{- else -}}{{ .Values.externalDatabase.user }}{{- end -}}
{{- end }}

{{- define "..dbPassword" -}}
{{- if .Values.postgresql.enabled -}}{{ .Values.postgresql.auth.password }}{{- else -}}{{ .Values.externalDatabase.password }}{{- end -}}
{{- end }}

{{/*
Generate odoo.conf content.
Call with dict: "Values" .Values "dbHost" <host> "dbPort" <port> "dbName" <name>
"dbUser" <user> "dbPassword" <password> "adminPasswd" <passwd>
Connection and sensitive values are passed as parameters so both secrets.yaml
and externalsecrets.yaml can share a single source of truth.
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
db_host = {{ .dbHost }}
{{- if .Values.odoo.db_name }}
db_name = {{ .dbName }}
{{- else }}
db_name = False
{{- end }}
db_port = {{ .dbPort }}
db_user = {{ .dbUser }}
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

{{/*
Shared spec for the Odoo init/update hook Job containers.
Renders image, pull policy, the odoo.conf mount and extraEnv/extraEnvFrom — but
NOT name or command (each Job sets those). Filestore (PVC) is intentionally not
mounted: the hooks only touch the database, and skipping the RWO volume avoids
contention with the running Odoo deployment. Call with the root context.
*/}}
{{- define "..hookOdooContainer" -}}
image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
imagePullPolicy: {{ .Values.image.pullPolicy }}
securityContext:
  {{- toYaml .Values.containerSecurityContext | nindent 2 }}
volumeMounts:
  - name: {{ include "..fullname" . }}-odoo-conf
    mountPath: /etc/odoo/odoo.conf
    subPath: odoo.conf
    readOnly: true
{{- if .Values.extraEnv }}
env:
{{- toYaml .Values.extraEnv | nindent 2 }}
{{- end }}
{{- if .Values.extraEnvFrom }}
envFrom:
{{- toYaml .Values.extraEnvFrom | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Volumes for the init/update hook Jobs: the odoo.conf secret. Call with root context.
*/}}
{{- define "..hookVolumes" -}}
- name: {{ include "..fullname" . }}-odoo-conf
  secret:
    {{- /* existingSecret: the user's pre-existing <fullname>-odoo-conf is mounted
        directly (it already exists at hook time). generated/externalsecrets: the
        Jobs mount the dedicated pre-install hook copy <fullname>-odoo-conf-hook —
        the runtime <fullname>-odoo-conf is a NORMAL resource, applied only after
        pre-install hooks, so it is not yet available to the Jobs. */}}
    secretName: "{{ include "..fullname" . }}-odoo-conf{{ if not .Values.existingSecret.enabled }}-hook{{ end }}"
{{- end }}

{{/*
"prepare" initContainer for the init/update hook Jobs. Scales the Odoo and cron
deployments to 0 and waits for their pods to terminate — but only if they already
exist (on pre-install they do not yet, so it is a graceful no-op; on pre-upgrade
it quiesces the running pods so nothing writes to the DB while the hook runs).
Requires the <fullname>-hook ServiceAccount/RBAC. Render under `initContainers:`
with nindent 8. Call with the root context.
*/}}
{{- define "..hookScaleDownInitContainer" -}}
{{- $fullName := include "..fullname" . -}}
{{- $selector := printf "app.kubernetes.io/instance=%s,app.kubernetes.io/name=%s" .Release.Name (include "..name" .) -}}
- name: prepare
  image: "{{ .Values.odoo.hooks.kubectlImage }}"
  securityContext:
    {{- toYaml .Values.containerSecurityContext | nindent 4 }}
  command:
    - /bin/sh
    - -c
    - |
      set -e
      # Scale a deployment to 0 and wait for its pods to go away, but only if it
      # already exists. A deployment being created by this same install/upgrade
      # (e.g. cron enabled for the first time) does not exist yet at hook time.
      scale_down() {
        if kubectl get deployment "$1" >/dev/null 2>&1; then
          echo "scaling down $1"
          kubectl scale deployment "$1" --replicas=0
          if kubectl get pods -l "$2" --no-headers -o name | grep -q .; then
            kubectl wait --for=delete pod -l "$2" --timeout=300s
          fi
        else
          echo "deployment $1 not found, skipping"
        fi
      }
      scale_down {{ $fullName }} "{{ $selector }},app.kubernetes.io/component=server"
      scale_down {{ $fullName }}-cron "{{ $selector }},app.kubernetes.io/component=cron"
{{- end }}

{{/*
"wait-for-db" initContainer for the init/update hook Jobs: blocks until the
database host:port accepts a TCP connection, so `odoo -i`/`odoo -u` never runs
before the DB is reachable. Render under `initContainers:` with nindent 8; the
caller gates on .Values.odoo.hooks.waitForDb. Call with the root context.
*/}}
{{- define "..hookWaitForDbInitContainer" -}}
- name: wait-for-db
  image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
  securityContext:
    {{- toYaml .Values.containerSecurityContext | nindent 4 }}
  command:
    - /bin/bash
    - -c
    - |
      until bash -c "echo > /dev/tcp/{{ include "..dbHost" . }}/{{ include "..dbPort" . }}" 2>/dev/null; do
        echo "waiting for database {{ include "..dbHost" . }}:{{ include "..dbPort" . }}..."
        sleep 2
      done
      echo "database is reachable"
{{- end }}
