{{- define "api.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "api.labels" -}}
{{ include "api.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default (.Values.image.digest | trimPrefix "sha256:" | trunc 12) | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{/* the tag is for people; when a digest is set, it is what the node pulls */}}
{{- define "api.image" -}}
{{- if not (or .Values.image.tag .Values.image.digest) }}{{ fail "image.tag or image.digest is required" }}{{ end -}}
{{ .Values.image.repository }}{{ with .Values.image.tag }}:{{ . }}{{ end }}{{ with .Values.image.digest }}@{{ . }}{{ end }}
{{- end }}

{{- define "api.env" -}}
{{- /* on rds the host is only known once the database exists, so it comes from the secret */ -}}
- name: PGHOST
{{- if .Values.database.host }}
  value: {{ .Values.database.host | quote }}
{{- else }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.credentialsSecret }}
      key: PGHOST
{{- end }}
- name: PGPORT
  value: {{ .Values.database.port | quote }}
- name: PGDATABASE
  value: {{ .Values.database.name | quote }}
- name: PGUSER
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.credentialsSecret }}
      key: PGUSER
- name: PGPASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.credentialsSecret }}
      key: PGPASSWORD
{{- with .Values.database.sslMode }}
- name: PGSSLMODE
  value: {{ . | quote }}
{{- end }}
{{- if .Values.database.caConfigMap }}
# node trusts these on top of its own list, so the database certificate is verified, not just accepted
- name: NODE_EXTRA_CA_CERTS
  value: /etc/database-ca/ca.pem
{{- end }}
{{- end }}

{{- define "api.caVolumeMounts" -}}
{{- if .Values.database.caConfigMap }}
- name: database-ca
  mountPath: /etc/database-ca
  readOnly: true
{{- end }}
{{- end }}

{{- define "api.caVolumes" -}}
{{- if .Values.database.caConfigMap }}
- name: database-ca
  configMap:
    name: {{ .Values.database.caConfigMap }}
{{- end }}
{{- end }}
