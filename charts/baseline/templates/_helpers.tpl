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
