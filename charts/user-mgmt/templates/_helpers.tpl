{{/*
Reusable template functions for the user-mgmt chart.
Anything used by more than one manifest lives here.
*/}}

{{/* Chart name, overridable via nameOverride. */}}
{{- define "user-mgmt.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Release-wide name prefix, e.g. "user-mgmt" or "myrelease-user-mgmt". */}}
{{- define "user-mgmt.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "user-mgmt.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Name of a single component's objects, e.g. "user-mgmt-postgres".
Usage: {{ include "user-mgmt.componentName" (dict "root" . "component" "postgres") }}
*/}}
{{- define "user-mgmt.componentName" -}}
{{- printf "%s-%s" (include "user-mgmt.fullname" .root) .component | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Namespace the chart deploys into. Defaults to the namespace of the release
(or the ArgoCD Application destination), so the same chart can be installed
into one namespace per environment without any change.
*/}}
{{- define "user-mgmt.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end -}}

{{/*
Fully qualified in-cluster DNS name of a component's Service.
Usage: {{ include "user-mgmt.componentFqdn" (dict "root" . "component" "postgres") }}
*/}}
{{- define "user-mgmt.componentFqdn" -}}
{{- $name := include "user-mgmt.componentName" . -}}
{{- printf "%s.%s.svc.%s" $name (include "user-mgmt.namespace" .root) .root.Values.global.clusterDomain -}}
{{- end -}}

{{/* Chart identifier used in the helm.sh/chart label. */}}
{{- define "user-mgmt.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Labels every object in the chart carries.
Usage: {{ include "user-mgmt.labels" (dict "root" . "component" "backend") | nindent 4 }}
*/}}
{{- define "user-mgmt.labels" -}}
helm.sh/chart: {{ include "user-mgmt.chart" .root }}
app.kubernetes.io/name: {{ include "user-mgmt.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/version: {{ .root.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{ include "user-mgmt.selectorLabels" . }}
{{- with .root.Values.global.labels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
The minimal label set used by Service selectors and Deployment matchLabels.
Must stay stable - changing it breaks in-place upgrades.
*/}}
{{- define "user-mgmt.selectorLabels" -}}
app.kubernetes.io/name: {{ include "user-mgmt.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
Full image reference for a component, falling back to global.imageTag.
Usage: {{ include "user-mgmt.image" (dict "root" . "image" .Values.backend.image) }}
*/}}
{{- define "user-mgmt.image" -}}
{{- $tag := .image.tag | default .root.Values.global.imageTag -}}
{{- printf "%s:%s" .image.repository $tag -}}
{{- end -}}

{{/* Image pull policy for a component, falling back to global.imagePullPolicy. */}}
{{- define "user-mgmt.imagePullPolicy" -}}
{{- .image.pullPolicy | default .root.Values.global.imagePullPolicy -}}
{{- end -}}

{{/*
JDBC URL the backend uses to reach the database. Built from the postgres
values so the hostname always matches the generated Service name - this is
what guarantees the backend only ever talks to Postgres via its Service.
The name is fully qualified, so it also resolves across namespaces.
*/}}
{{- define "user-mgmt.datasourceUrl" -}}
{{- $host := include "user-mgmt.componentFqdn" (dict "root" . "component" "postgres") -}}
{{- printf "jdbc:postgresql://%s:%v/%s" $host .Values.postgres.service.port .Values.postgres.auth.database -}}
{{- end -}}

{{/* Name of the Secret holding the database credentials. */}}
{{- define "user-mgmt.postgresSecretName" -}}
{{- include "user-mgmt.componentName" (dict "root" . "component" "postgres") -}}
{{- end -}}

{{/*
Environment entries that inject the database username and password from the
Postgres Secret. Used by both the postgres and the backend Deployment, under
different variable names.
Usage: {{ include "user-mgmt.dbCredentialEnv" (dict "root" . "userVar" "POSTGRES_USER" "passwordVar" "POSTGRES_PASSWORD") | nindent 12 }}
*/}}
{{- define "user-mgmt.dbCredentialEnv" -}}
- name: {{ .userVar }}
  valueFrom:
    secretKeyRef:
      name: {{ include "user-mgmt.postgresSecretName" .root }}
      key: username
- name: {{ .passwordVar }}
  valueFrom:
    secretKeyRef:
      name: {{ include "user-mgmt.postgresSecretName" .root }}
      key: password
{{- end -}}
