{{- define "airprint-bridge.fullname" -}}
{{- .Release.Name }}-airprint-bridge
{{- end -}}

{{- define "airprint-bridge.labels" -}}
app.kubernetes.io/name: airprint-bridge
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}
