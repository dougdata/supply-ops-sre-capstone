{{- define "supply-worker.name" -}}
supply-worker
{{- end -}}

{{- define "supply-worker.fullname" -}}
{{- printf "%s" (include "supply-worker.name" .) -}}
{{- end -}}

{{- define "supply-worker.labels" -}}
app.kubernetes.io/name: {{ include "supply-worker.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: Helm
{{- end -}}
