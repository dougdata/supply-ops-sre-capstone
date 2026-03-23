{{- define "supply-api.name" -}}
supply-api
{{- end -}}

{{- define "supply-api.fullname" -}}
{{- printf "%s" (include "supply-api.name" .) -}}
{{- end -}}

{{- define "supply-api.labels" -}}
app.kubernetes.io/name: {{ include "supply-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: Helm
{{- end -}}
