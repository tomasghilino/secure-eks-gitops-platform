# Reviewing who can do what: Argo CD projects, Kubernetes RBAC, IAM, and a hole in admission

Short version: the review closed one real bypass (debug containers skipped the image policies) and one Argo CD default (an open catch-all project). It also made Kyverno highly available, because its policies fail closed. Every IAM role checked out: no IAM users, Access Analyzer reported no findings, and the CI role used every permission it has.

## Finding 1: `kubectl debug` skipped the image rules

The image policies matched pod creation. `kubectl debug` adds a container to a running pod through the `pods/ephemeralcontainers` subresource, which they never saw:

```text
staging, before the fix:
  kubectl debug <api pod> --image=busybox:1.37@sha256:... --profile=restricted   -> accepted, image pulled
    (it only failed to start because busybox runs as root under runAsNonRoot)
  the same with runAsUser 65534                                                  -> running inside the api pod
    uid=65534(nobody)
```

A first fix added the subresource to the existing policies. It also made the CI's kyverno-cli step evaluate nothing (`pass: 0` instead of `pass: 12`): a policy that matches a subresource loses its autogen rules for Deployments and Jobs, and the CI checks those. Two follow-up commits:

```text
fix: check debug container images in a policy of their own   (restrict-debug-container-images, pods/ephemeralcontainers only)
ci: fail when kyverno evaluates no rule                        (grep 'pass: [1-9]' after each kyverno-cli run)

throwaway namespace, same policies:
  debug with busybox                  -> denied: debug containers may only use the api image pinned to a commit and a digest, or an image listed in the baseline values
  debug with the allowed postgres     -> accepted
  a busybox Deployment                -> denied at the Deployment level (autogen still works)
staging, after the fix:
  debug with busybox                  -> denied by restrict-debug-container-images
kyverno-cli in ci                     pass: 12 per environment again
```

The verify-api-image policy matches the subresource too, so an injected api image also needs our signature.

## Finding 2: Argo CD's default project was wide open

```text
AppProject default in git: sourceRepos [], destinations [], whitelists []   (Prune=false,Delete=false)
test Application "sneaky" in project default, our repo, namespace kube-system:
  InvalidSpecError: application repo ... is not permitted in project 'default'
  InvalidSpecError: application destination ... namespace 'kube-system' do not match any of the allowed destinations in project 'default'
  nothing synced, app deleted
```

The `segp` project no longer allows StatefulSets: only the kind lab's postgres needed them, and it runs outside Argo CD.

## Finding 3: one Kyverno replica, and policies that fail closed

The install printed `Setting the admission controller replica count below 2 means Kyverno is not running in high availability mode`. With `failurePolicy: Fail`, losing that pod (to a spot interruption, for example) blocks every new pod in staging and production. Fixed in kyverno/values.yaml:

```text
replicas: 3 + PodDisruptionBudget minAvailable 1
kyverno-admission-controller x3 Running, spread over both nodes; PDB allowed disruptions 2
a new api pod was admitted and verified through the new replicas
```

## Kubernetes RBAC in staging (who can, resolved from every binding)

```text
read secrets      argocd application-controller, argocd-server, external-secrets controller, prometheus operator,
                  kube-system controllers, eks:addon-manager, system:masters
exec into pods    argocd application-controller, system:masters, eks:addon-manager
everything        argocd application-controller, system:masters, eks:addon-manager
group developers  view only: no secrets, no exec, not in any line above
```

- Accepted: argo cd's controller can do everything, because it deploys everything. What limits it is the AppProjects (now including `default`) and a read-only deploy key on one repository.
- Accepted: the argo cd UI is only reachable through a port-forward, which already requires cluster admin, so its initial admin secret adds no new path in. SSO plus Argo CD RBAC would be the production answer.
- Improvement noted: external-secrets could be scoped to its environment's namespace instead of cluster-wide.
- Humans don't appear in RBAC: the SSO admin role is authorized by an EKS access entry (`AmazonEKSClusterAdminPolicy`).

## IAM (account segp-workloads)

```text
iam users 0 (so no long-lived access keys)
segp-github-ci                 trusted by GitHub OIDC (exact sub)   inline publish-api-image
segp-staging-cluster           trusted by eks.amazonaws.com         AmazonEKSClusterPolicy + inline encrypt-secrets
segp-staging-node              trusted by ec2.amazonaws.com         AmazonEKSWorkerNodePolicy, AmazonEC2ContainerRegistryPullOnly
segp-staging-{vpc-cni,ebs-csi,external-secrets,kyverno}   trusted by pods.eks.amazonaws.com (cluster + namespace + service account tags)

access analyzer validate-policy: no findings on any inline or trust policy, except one SUGGESTION on the ci trust:
  CONFIRM_AUDIENCE_CLAIM_TYPE "because this claim is single-valued, do not use a qualifier" -> already StringEquals, no qualifier

ci role, service last accessed (action level): every granted action was used
  ecr: BatchCheckLayerAvailability, BatchGetImage, CompleteLayerUpload, DescribeImages, GetAuthorizationToken,
       GetDownloadUrlForLayer, InitiateLayerUpload, PutImage, UploadLayerPart
  kms: DescribeKey, GetPublicKey, Sign
```
