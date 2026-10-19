# The platform moves from kind to EKS, with the signed ECR image and real network policies

Short version: the same Git repository that ran on kind now runs the staging platform on EKS: Argo CD, Kyverno, Prometheus, Grafana, Loki, Tempo, the OpenTelemetry Collector, Postgres and the API. Getting there turned up two silent traps, and a third problem showed up during the first bootstrap:

- EKS ignores NetworkPolicies unless you switch them on.
- The ECR address would have put the account ID in Git.
- On the first bootstrap, the API raced its own guardrail.

## Trap 1: network policies were decoration

The VPC CNI accepts NetworkPolicy objects and enforces none of them until `enableNetworkPolicy` is set. I proved it before changing anything:

```text
namespace np-test, policy default-deny (Ingress + Egress)
client -> web              http 200          <- the policy is ignored

+ vpc-cni configuration_values { enableNetworkPolicy = "true" }   (1 changed, aws-node rolled out)
  aws-eks-nodeagent --enable-network-policy=true
client -> web              blocked (curl exit 28), PolicyEndpoint default-deny-xxxxx created
```

## Trap 2: the account ID hides in every ECR image reference

Git says `segp-api:<commit>@sha256:<digest>` with no registry. The bootstrap script writes the registry address to an `image-registry` ConfigMap in the namespace. A Kyverno `NamespacedMutatingPolicy` (`use-ecr-registry`) completes the image when a pod is created, and only for digest-pinned `segp-api` images. It works on pods only, so Argo CD never sees a difference between Git and the Deployment.

```text
deployment says   segp-api:750de9aa...@sha256:eec81819d13b5...
the pod runs      <account>.dkr.ecr.us-east-1.amazonaws.com/segp-api:750de9aa...@sha256:eec81819d13...
```

The digest is the image CI built, scanned and signed ([signed-supply-chain.md](signed-supply-chain.md)).

My first version used `resource.get('v1', 'configmaps', <namespace>, 'image-registry')`, and Kyverno's own webhook rejected it twice ("found no matching overload"). In a namespaced policy the lookup takes no namespace, because it can only read its own. I tested each variant with `kubectl apply --dry-run=server` before committing the fix.

## Problem 3: the API raced its own guardrail

```text
api-migrate pod created   17:00:22
use-ecr-registry created  17:04:59
api-migrate -> ImagePullBackOff, pulling "docker.io/library/segp-api@sha256:..."
```

Nothing completed the image because the policy didn't exist yet. `failurePolicy: Fail` protects only while the policy exists. The fix is sync waves:

- projects at -2;
- guardrails, observability and Postgres at -1;
- the API at 0.

Argo CD also needs a health check for Applications (removed in Argo CD 1.8 and documented for this exact case), so the root app waits for each wave to be healthy. This also removed the sync retries the API had needed on kind. I recreated the stuck pod, and the next one came out with the full ECR address.

## Bootstrap and result

```text
$ AUTO_APPROVE=1 ./scripts/eks-up.sh
==> terraform    No changes. Apply complete! Resources: 0 added
==> kubectl · argo cd · kyverno · environment · monitoring · bootstrap
exit=0

api-staging · baseline-staging · kube-prometheus-stack · loki · opentelemetry-collector
postgres-staging · root · tempo                                  all Synced / Healthy
```

The staging cluster gets no production apps, because its root app excludes `*-production.yaml`.

## Checks on EKS

```text
api (port-forward)     health/ready 200 · POST /users 201 · GET /users 200 · ?limit=101 400
pod security           nginx:latest plain pod -> forbidden: violates PodSecurity "restricted:v1.35"
kyverno                same pod made compliant -> denied: Policy disallow-latest-tag failed
intruder pod           dns OPEN · api BLOCKED · postgres BLOCKED · 1.1.1.1:443 BLOCKED · prometheus BLOCKED
prometheus targets     api, apiserver x2, kube-dns x2, kubelet x6, node-exporter x2, kube-state-metrics,
                       grafana, operator, alertmanager x2, prometheus x2   all up
alerts                 Watchdog only
loki                   argocd 4545 lines, staging 99, kyverno 28 (last 30 min)
tempo                  api GET /users · api GET /users · api POST /users
pvc volumes            storage-loki-0, storage-tempo-0, data-postgres-0   gp3, all encrypted
```

## Control plane logs, measured again

```text
10-minute buckets: 5.0, 12.0, 8.0, 66.1 (bootstrap), 30.7 MB  ->  ~146 MB/h, ~0.07 USD/h
```

The bootstrap spike inflates this number. I'll measure again in steady state before deciding whether staging keeps the audit log.

## What happened to kind

Staging now points at the ECR digest, so the kind setup could no longer run it as-is. kind became an offline lab instead: `scripts/kind-up.sh` builds the API image locally and runs it with Postgres in a `lab` namespace, without Argo CD, Kyverno or AWS.
