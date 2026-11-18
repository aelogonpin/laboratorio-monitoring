{{/*
Evalúa una ruta "a.b.c" relativa a .Values.global (p.ej. "monitoring.grafana", "logging.loki").
Lo usa la ingesta para renderizar solo en la Application que tiene ese flag.
*/}}
{{- define "ms.globalFlag" -}}
{{- $cur := .root.Values.global -}}
{{- range (splitList "." .path) -}}
{{- if kindIs "map" $cur }}{{ $cur = index $cur . }}{{ else }}{{ $cur = false }}{{ end -}}
{{- end -}}
{{- if $cur }}true{{ end -}}
{{- end -}}
