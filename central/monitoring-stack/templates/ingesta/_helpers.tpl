{{- define "ms.ingesta.tenant" -}}{{ .tenant | default .nombre }}{{- end -}}
{{- define "ms.ingesta.host" -}}{{ .c.nombre }}.{{ .root.Values.ingesta.dominio }}{{- end -}}
{{- /* Señal permitida al cliente: logs y métricas (por defecto las dos). */ -}}
{{- define "ms.ingesta.senal" -}}{{- $s := .c.senales | default (list "logs" "metricas") -}}{{- if has .senal $s }}true{{ end -}}{{- end -}}
{{- /*
Clientes de ingesta.clientes (los pone el values de cada entorno). Falla si un nombre se repite o no es válido.
*/ -}}
{{- define "ms.ingesta.clientes" -}}
{{- $vistos := dict -}}
{{- range .Values.ingesta.clientes }}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$" (.nombre | default "")) }}{{ fail (printf "ingesta.clientes: nombre no válido: %q" (.nombre | default "")) }}{{ end }}
{{- if hasKey $vistos .nombre }}{{ fail (printf "ingesta.clientes: cliente repetido: %s" .nombre) }}{{ end }}
{{- $_ := set $vistos .nombre true }}
{{- if and .cas .caSecret }}{{ fail (printf "ingesta.clientes: %s lleva cas y caSecret, solo uno" .nombre) }}{{ end }}
{{- end }}
{{- toJson .Values.ingesta.clientes -}}
{{- end -}}
{{- /*
Secret con la CA pública de un cliente en modo caSecret: {"name", "namespace"}. Por defecto ingesta-ca-<cliente>
en ingesta.casClientes.namespace (vacío = el de la release). caSecret puede ser true o {name, namespace}.
*/ -}}
{{- define "ms.ingesta.caRef" -}}
{{- $d := dict "name" (printf "ingesta-ca-%s" .c.nombre) "namespace" (.root.Values.ingesta.casClientes.namespace | default .root.Release.Namespace) -}}
{{- if kindIs "map" .c.caSecret }}{{ $d = merge (deepCopy .c.caSecret) $d }}{{ end -}}
{{- toJson $d -}}
{{- end -}}
