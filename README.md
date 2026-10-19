# Secure EKS GitOps Platform

A small NestJS API running on two EKS clusters, staging and production, where only images built and signed by my own CI are allowed to run. GitHub Actions tests and scans every commit, pushes the image to ECR and signs it with a KMS key. Argo CD deploys whatever Git says, production only changes through a pull request, and Kyverno checks the signature again before any pod starts. Everything is Terraform, and every check below was triggered on purpose at least once.

![Architecture overview: GitHub Actions pushes images to ECR and signs them with a KMS key; in each environment's VPC, Argo CD pulls from GitHub, Kyverno verifies the signature in ECR, External Secrets reads Secrets Manager and the cluster reaches RDS over TLS](docs/images/architecture-overview.jpg)

## Stack

- API: NestJS and PostgreSQL 17, instrumented with OpenTelemetry
- CI: GitHub Actions with OIDC to AWS, Gitleaks, Semgrep, Trivy, Checkov and TFLint
- Supply chain: cosign with a KMS key, CycloneDX SBOM, SLSA provenance and Renovate
- Kubernetes: EKS, Helm, Argo CD, Kyverno, Pod Security Standards, NetworkPolicies, External Secrets, Pod Identity and Falco
- Observability: Prometheus, Grafana, Loki, Tempo and the OpenTelemetry Collector
- Infrastructure: Terraform on AWS (VPC, EKS, RDS, ECR, KMS, Secrets Manager)

## How it works

Each environment has its own VPC and EKS cluster, built from the same Terraform module. The nodes live in private subnets, the database has no route to the internet, and nothing is public except the cluster's API endpoint, which only answers my IP. I reach the API and the dashboards with `kubectl port-forward`.

CI never touches a cluster. Argo CD runs inside each one and pulls from the repository with a read-only key, so the only way to change what runs is a commit:

1. Every push and pull request runs the tests, secret scanning, static analysis, dependency and image scans, the Helm and policy checks, and the Terraform checks.
2. On `dev`, a separate job logs in to AWS with OIDC, pushes the exact image that was scanned, and signs it along with its SBOM and provenance.
3. A commit puts the new image digest in the staging values. Argo CD deploys it, and Kyverno verifies the signature before the pods start.
4. `scripts/promote.sh` opens a pull request that copies that digest to production, and CI fails it if staging never ran that image. Merging is the approval, and reverting is the rollback.

[docs/architecture.md](docs/architecture.md) has the details.

<details>
<summary>The architecture as a Mermaid diagram</summary>

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

</details>

## Failures tested on purpose

| What was broken | What caught it |
|---|---|
| An unsigned image, one without an SBOM, and a copy in another account's registry | [Kyverno at admission](docs/evidence/signed-images-at-admission.md) |
| A production pull request with an image staging never ran | [The promotion check in CI](docs/evidence/promotion-and-rollback.md) |
| A pull request widening CI's AWS trust to any branch | [A custom Checkov rule, and AWS itself](docs/evidence/github-oidc.md) |
| A manual `kubectl scale` in production | [Argo CD self-heal](docs/evidence/drift-self-heal.md) |
| Staging asking for production's database password | [IAM, through Pod Identity](docs/evidence/secrets-across-environments.md) |
| An attacker reading `/etc/shadow` and hunting for AWS keys in a container | [Falco and an alert](docs/evidence/falco-runtime-detection.md) |
| A debug container with an unapproved image | [A new Kyverno policy, after the bypass worked](docs/evidence/debug-container-bypass.md) |

## Security

There are no stored keys anywhere. People use SSO, CI gets a one-hour role through OIDC that only works for pushes to `dev`, and each pod that calls AWS gets its own Pod Identity role. The database passwords never touch Git or the Terraform state. Inside the clusters, the environment namespaces reject root and privileged pods and deny all traffic by default, and Falco watches what runs. The [threat model](docs/threat-model.md) covers what's still exposed and why.

## Design choices

- EKS instead of ECS, to use the Kubernetes-native controls. My previous project ran the same API on ECS Fargate, which is the better fit for a single service.
- Staging runs on spot nodes and production on on-demand, because a spot interruption there would take half of the API down.
- Argo CD pulls instead of CI pushing, so CI has no cluster credentials at all.
- Production gets the exact digest staging ran, checked once by CI and again by Kyverno.
- cosign with a KMS key instead of keyless signing, because GitHub's attestations need a public repository on the free plan. The provenance is SLSA Build L1, since my own workflow writes it.
- Both environments are created and destroyed each working session. Staging costs about 0.30 USD/h and production about 0.40 USD/h.

## What would change in production

- Separate AWS accounts for staging and production
- Branch protection with required checks
- Keyless signing with GitHub's attestations
- An ingress with TLS and a WAF instead of port-forwarding
- SSO for Argo CD and Grafana, and alerts that page someone

## Running it

```bash
cp .env.example .env
docker compose up --build
```

`scripts/kind-up.sh` runs the API on a local kind cluster. On AWS, `./scripts/eks-up.sh staging` builds an environment in 20 to 30 minutes and `./scripts/eks-down.sh staging` removes it. The [deployment guide](docs/deployment.md) has the full steps.

## Repository

```text
app/            NestJS API, tests and Dockerfile
charts/         Helm charts for the API and the namespace guardrails
environments/   The values, and the image, each environment runs
argocd/         Argo CD applications and projects
infra/          Terraform
observability/  Monitoring stack
falco/          Runtime detection
scripts/        eks-up, eks-down, promote and the kind lab
docs/           Architecture, threat model, deployment guide and evidence
```

## Status

A practice project, last updated on October 19, 2026. It isn't maintained, so the pinned versions and image digests will fall behind and new vulnerabilities will show up over time; update them before reusing any of it. The clusters only existed during working sessions, so there is no live endpoint.

AI assistants sped up the writing, the same way they do in my day-to-day work. The decisions and trade-offs were mine, and I can explain what any part of this does and why.
