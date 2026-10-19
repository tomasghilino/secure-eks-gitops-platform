# Architecture

Here's how the pieces fit together. The API runs in two EKS clusters, staging and production, each in its own VPC and built from the same Terraform module. GitHub Actions builds, scans and signs the image, but never touches a cluster. Argo CD runs inside each cluster and pulls what Git says it should run. A few long-lived resources are shared by both environments: the Terraform state bucket, the image registry, the signing key and the role CI uses.

```mermaid
flowchart LR
    engineer([Engineer]) -->|git push, pull requests| github[GitHub repository]
    github -->|push to dev| ci[GitHub Actions]
    ci -->|OIDC role: push| ecr[(ECR)]
    ci -->|OIDC role: sign| kms[KMS signing key]
    engineer -->|kubectl and port-forward,<br/>admin IP only| eks
    subgraph env [Environment VPC, one per environment]
        subgraph public [Public subnets]
            nat[NAT gateway]
        end
        subgraph private [Private subnets]
            subgraph eks [EKS cluster]
                argocd[Argo CD]
                kyverno[Kyverno]
                api[API pods]
                eso[External Secrets]
                obs[Prometheus, Grafana,<br/>Loki, Tempo, collector]
                falco[Falco]
            end
        end
        subgraph db [Database subnets]
            rds[(RDS PostgreSQL)]
        end
    end
    argocd -->|read-only deploy key,<br/>through the NAT| github
    kyverno -->|signature, SBOM,<br/>provenance| ecr
    api -->|TLS, verify-full| rds
    eso -->|Pod Identity| secrets[Secrets Manager]
```

## Terraform layout

The infrastructure is split into stacks by how long things live. Each stack has its own state under its own key in one S3 bucket.

| Stack | What's in it | How long it lives |
|---|---|---|
| `infra/bootstrap` | S3 state bucket and its KMS key | Created once |
| `infra/shared` | ECR repository, cosign signing key, GitHub OIDC provider and CI role, flow log bucket, the KMS key for Kubernetes secrets, EBS encryption by default | Long lived, about 2 to 3 USD a month |
| `infra/staging`, `infra/production` | Backend, provider and one call to the environment module | Created and destroyed every working session |
| `infra/modules/environment` | The 56 resources of one environment: network, EKS, node group, add-ons, Pod Identity roles, RDS, secrets and logs | Takes a name, a /16, the node capacity type and instance types |

The two environments only differ in their name, their address range (10.20.0.0/16 and 10.30.0.0/16) and their nodes: staging runs on spot instances across five instance types, production on on-demand `t3.large`. They read the shared stack's outputs through `terraform_remote_state`, so nothing is copied by hand. The state bucket is versioned and encrypted with its own KMS key, and Terraform locks it with a lock file in S3.

I wrote the module with plain AWS resources instead of the community EKS and VPC modules. It's more code, but Checkov scans every resource without downloading anything, and I know what each line does.

## Network

Each VPC spans two availability zones with three kinds of subnets:

| Subnets | What runs there | Route to the internet |
|---|---|---|
| Public, two /24 | The NAT gateway | Internet gateway |
| Private, two /19 | Nodes and pods | Through the NAT gateway |
| Database, two /24 | RDS | None |

The private subnets are large because the VPC CNI gives every pod a real VPC address. The nodes need outbound internet access: Argo CD reads the repository on GitHub, and the platform charts pull images from public registries. Project 1 used VPC endpoints instead of a NAT gateway, but that only works when everything you talk to is an AWS service. There's a single NAT gateway in one zone to save the cost of a second one, plus the free S3 gateway endpoint. If that zone fails, the nodes lose internet access, which is acceptable here.

Nothing in the VPC is reachable from the internet. There's no load balancer, and the API is reached with `kubectl port-forward`. The default security group has no rules, and VPC flow logs record every accepted and rejected connection into the shared log bucket.

## Cluster

EKS runs Kubernetes 1.35, a version in standard support until March 2027 (extended support costs six times more per hour). The API server has a public endpoint that only answers the admin's IP address, looked up when the stack is applied and never committed, plus a private endpoint for the nodes. Access uses EKS access entries instead of the old `aws-auth` ConfigMap. My SSO role gets cluster admin through an explicit entry, instead of the automatic admin rights EKS gives whoever created the cluster. Kubernetes Secrets are encrypted with a KMS key, and all five control plane log types go to CloudWatch for seven days.

A managed node group runs two nodes. Their launch template requires IMDSv2 with a hop limit of 1, so pods can't reach the node's instance metadata or borrow the node role. The add-ons (VPC CNI, kube-proxy, CoreDNS, EBS CSI driver and the Pod Identity agent) are pinned to the versions EKS marks as default for 1.35, so every session builds the same cluster. The VPC CNI ignores NetworkPolicies unless network policy support is switched on, which I only noticed by testing it ([details](evidence/platform-on-eks.md)).

Each namespace gets a Pod Security level:

| Level | Namespaces | Why |
|---|---|---|
| restricted | `staging`, `production`, `monitoring`, `external-secrets` | No root, no privilege escalation, no capabilities, seccomp required |
| privileged | `monitoring-agents`, `falco` | The log collector and Falco read host paths on every node |

## Delivery with Argo CD

Argo CD runs in each cluster and follows the `dev` branch. The bootstrap applies a single root Application, which deploys everything under `argocd/apps`. The staging cluster skips the `*-production.yaml` apps and the production cluster skips the `*-staging.yaml` ones. Argo CD reads the private repository with a read-only deploy key, polls it every few minutes, and has self-heal on, so a manual change to the cluster is put back within seconds ([demo](evidence/drift-self-heal.md)).

Environments are folders, not branches. `environments/staging/api.yaml` and `environments/production/api.yaml` hold the values each environment's API gets, including the image tag and digest. Deploying to staging is a commit that changes the staging values. Production only changes through a pull request that copies the staging tag and digest, opened by `scripts/promote.sh`. Rolling back is reverting that pull request ([demo](evidence/promotion-and-rollback.md)).

Every Application belongs to an AppProject, which limits what it may deploy and where:

| Project | Deploys |
|---|---|
| `platform` | Only the Applications and AppProjects themselves |
| `baseline` | Each environment's namespace, network policies, default service account, Kyverno policies, External Secrets objects and the viewers role binding |
| `segp` | The API: Deployments, Services, Jobs, service accounts, network policies and monitoring rules, in `staging` and `production` only |
| `external-secrets`, `observability`, `runtime-security` | One upstream chart each, with the cluster-wide objects that chart needs |
| `default` | Nothing. Argo CD's catch-all project is emptied on purpose |

The split keeps the app chart from granting itself permissions or creating namespaces. Sync waves set the order on a fresh cluster: projects first, then External Secrets, then the guardrails and the monitoring stack, then the API and Falco.

## Admission control

Kyverno checks every pod in the environment namespaces before it starts. It runs three replicas, because its policies fail closed: with Kyverno down, no new pod would start in staging or production. The policies come from the baseline chart, so each environment carries its own copy:

| Policy | What it does |
|---|---|
| `restrict-image-sources` | Only the API image pinned to a full commit SHA and a digest, or an image listed in the baseline values by exact digest |
| `use-ecr-registry` | Adds the ECR address to the API image when a pod is created. Git never contains the registry, because the address holds the account ID |
| `verify-api-image` | The API image must be signed with the CI's KMS key and carry a CycloneDX SBOM and a SLSA provenance signed with the same key, and the provenance must say it was built from this repository's `dev` branch |
| `restrict-debug-container-images` | The same image rules for containers added with `kubectl debug` |
| `disallow-latest-tag`, `require-memory-limit`, `disallow-service-account-token` | Basic hygiene for every pod |

Kyverno reads signatures from ECR with its own Pod Identity role, which can only read the `segp-api` repository. CI runs the validating policies with the Kyverno CLI against the rendered charts, so most violations fail a pull request before they reach a cluster. The signature check needs the registry, so it only runs in the cluster.

## Identities

Nothing in this project uses an access key. People sign in through IAM Identity Center, CI uses GitHub's OIDC token, and pods use EKS Pod Identity.

| Role | Used by | Allowed to |
|---|---|---|
| `segp-github-ci` | GitHub Actions, only for pushes to `dev` in this repository | Push to `segp-api` and sign with the cosign key |
| `segp-<env>-cluster` | The EKS control plane | Run the cluster and encrypt Secrets with its KMS key |
| `segp-<env>-node` | The worker nodes | Join the cluster and pull images |
| `segp-<env>-vpc-cni`, `segp-<env>-ebs-csi` | The network and storage add-ons | Manage pod addresses and EBS volumes |
| `segp-<env>-external-secrets` | External Secrets in that cluster | Read that environment's two database secrets |
| `segp-<env>-kyverno` | Kyverno's admission controller | Read images and their signatures from `segp-api` |

Pod Identity tags every session with the cluster, namespace and service account, and each role's trust policy requires all three. A pod in staging can't use production's roles, or another service account's ([demo](evidence/secrets-across-environments.md)).

## The database and its secrets

Each environment has RDS PostgreSQL 17 on a `db.t4g.micro` in the database subnets, with encrypted storage and no public address. The server refuses connections without TLS, and the API connects with `verify-full`, checking the certificate against the RDS CA bundle.

Terraform generates two passwords during the apply with ephemeral resources and writes them with write-only arguments, so they never reach the state. Secrets Manager keeps them as `<env>/database/admin` and `<env>/database/api`. External Secrets copies them into Kubernetes Secrets. Before each deploy, a setup hook uses the admin login to create the `api` role, which owns the tables but can't administer anything, and the migration job runs as `api`. A parameter group stops `pg_stat_statements` from keeping `ALTER ROLE ... PASSWORD` statements, a leak I found while checking the setup ([details](evidence/rds-and-external-secrets.md)).

## Observability

The API is instrumented with OpenTelemetry. It exposes Prometheus metrics, writes JSON logs with the trace ID, and sends traces to a collector that runs on every node. The collector also reads every pod's logs and forwards them to Loki, and sends the traces to Tempo. kube-prometheus-stack provides Prometheus, Alertmanager and Grafana, and the Grafana dashboard for the API is a JSON file in the repository.

The API's alert rules (error rate, latency, no available pods) live in its Helm chart, and promtool unit tests in CI check that they fire when they should and stay quiet when they shouldn't ([drill](evidence/alerts-and-drill.md)). Retention is short, two days for metrics, logs and traces, because the clusters only exist during working sessions. Alertmanager has no receiver yet, so alerts are visible in Alertmanager and Grafana but don't page anyone.

## Runtime detection

Admission control decides what may start. Falco watches what running containers do, through the modern eBPF probe, with four specific capabilities instead of a privileged container. Its rules come inside the pinned image, so nothing is downloaded at runtime. Falco events go to Loki with the full detail, and a counter per rule feeds two Prometheus alerts, one for warnings and one for critical events. The default rules were tuned for this platform: the controllers that talk to the Kubernetes API by design are excluded, and a stricter rule flags any pod in `staging` or `production` that reaches the API, since the API pods have no service account token and no reason to ([demo](evidence/falco-runtime-detection.md)).

## Dependency updates

Renovate opens pull requests into `dev` for every pinned version in the repository: npm packages, base images, CI tool images, GitHub Actions, Helm charts in the Argo CD apps and the scripts, Terraform providers and the kind node image. A version has to be at least seven days old, major versions wait for approval on the dependency dashboard, and versions that must move together are grouped. Every update pull request goes through the same CI as any other change ([details](evidence/renovate.md)).
