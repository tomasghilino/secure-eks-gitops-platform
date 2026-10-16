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
- name: PGHOST
  value: {{ .Values.database.host | quote }}
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
{{- end }}
