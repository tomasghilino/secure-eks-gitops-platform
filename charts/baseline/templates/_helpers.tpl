{{- /* the api image as git names it (segp-api:<commit>@sha256:<digest>), with or without an ecr registry */ -}}
{{- define "baseline.apiImagePattern" -}}
^([0-9]{12}[.]dkr[.]ecr[.]us-east-1[.]amazonaws[.]com/)?segp-api:[0-9a-f]{40}@sha256:[0-9a-f]{64}$
{{- end }}

{{- define "baseline.podPolicySpec" -}}
validationActions:
  - {{ .Values.kyverno.action }}
matchConstraints:
  resourceRules:
    - apiGroups: [""]
      apiVersions: [v1]
      operations: [CREATE, UPDATE]
      resources: [pods]
# also check the Deployments, StatefulSets and Jobs that create the pods, so the error shows up there
autogen:
  podControllers:
    controllers: [deployments, statefulsets, jobs]
variables:
  - name: containers
    expression: "object.spec.containers + object.spec.?initContainers.orValue([])"
{{- end }}
