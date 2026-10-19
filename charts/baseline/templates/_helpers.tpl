{{- define "baseline.podPolicySpec" -}}
validationActions:
  - {{ .Values.kyverno.action }}
matchConstraints:
  resourceRules:
    - apiGroups: [""]
      apiVersions: [v1]
      operations: [CREATE, UPDATE]
      # kubectl debug adds containers to a running pod through this subresource, not through a pod update
      resources: [pods, pods/ephemeralcontainers]
# also check the Deployments, StatefulSets and Jobs that create the pods, so the error shows up there
autogen:
  podControllers:
    controllers: [deployments, statefulsets, jobs]
variables:
  - name: containers
    expression: "object.spec.containers + object.spec.?initContainers.orValue([])"
  # debug containers can't set resources, so only the image rules look at them
  - name: allContainers
    expression: "variables.containers + object.spec.?ephemeralContainers.orValue([])"
{{- end }}
