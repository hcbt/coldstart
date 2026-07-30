{{- define "coldstart.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "coldstart.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "coldstart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "coldstart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "coldstart.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "coldstart.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "coldstart.image" -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}

{{- /*
The PVC the workload's state lives on. An existing claim wins, so a cluster can
hand the chart a volume it provisioned itself.
*/ -}}
{{- define "coldstart.persistenceClaim" -}}
{{- default (printf "%s-data" (include "coldstart.fullname" .)) .Values.persistence.existingClaim -}}
{{- end -}}

{{- /*
Every volumeMount the workload container gets. Shared with the chown
initContainer so the two cannot drift — that container has to see the same
paths it is fixing ownership on.
*/ -}}
{{- define "coldstart.volumeMounts" -}}
- name: tmp
  mountPath: /tmp
{{- if .Values.nixStore.enabled }}
- name: nix-store
  mountPath: {{ .Values.nixStore.mountPath }}
{{- end }}
{{- if .Values.persistence.enabled }}
- name: data
  mountPath: {{ .Values.persistence.mountPath }}
{{- end }}
{{- if .Values.nss.enabled }}
- name: nss
  mountPath: /etc/passwd
  subPath: passwd
- name: nss
  mountPath: /etc/group
  subPath: group
{{- end }}
{{- with .Values.extraVolumeMounts }}
{{- toYaml . }}
{{- end }}
{{- end -}}
