# Threat model

A threat model is a structured way of asking "what could go wrong here, and what stops it?". This one covers what the repository builds: the CI workflow, the shared AWS resources and the two EKS environments. It goes through what's worth protecting, where trust changes hands, the threats that matter for this design, the control that answers each one, and the risks I accepted on purpose.

## What's worth protecting

| Asset | Where it lives | Why it matters |
|---|---|---|
| Source code, workflow and environment values | Private GitHub repository | The workflow decides what CI does with its AWS role, and the values decide what each cluster runs |
| CI role | IAM role `segp-github-ci`, assumed through GitHub's OIDC token | It pushes images and signs them |
| Signing key | KMS key `alias/segp-cosign`, the private half never leaves AWS | Anything signed with it passes the cluster's signature check |
| Images | ECR repository `segp-api`, immutable tags | They're the exact code running in each environment |
| Clusters | EKS in each environment's VPC | Control of the workloads, their secrets and their AWS roles |
| Database and its passwords | RDS in database subnets, passwords in Secrets Manager and copied into Kubernetes Secrets | Application data |
| Terraform state | S3 bucket encrypted with its own KMS key | Configuration and resource IDs of every stack |
| Argo CD deploy key | Kubernetes Secret in the `argocd` namespace | Read access to the repository |
| AWS account access | IAM Identity Center (SSO) | Control of everything above |

## Where trust changes hands

A trust boundary is any point where something less trusted talks to something more trusted. Those are the places where checks have to happen.

```mermaid
flowchart LR
    engineer([Engineer]) -->|commits and merges| github[GitHub]
    github -->|OIDC token,<br/>pushes to dev only| ci[CI role]
    ci -->|push and sign| ecr[(ECR)]
    engineer -->|SSO, admin IP only| eks
    subgraph eks [EKS cluster]
        argocd[Argo CD] -->|creates| pods[Pods]
        kyverno[Kyverno] -->|admits or denies| pods
    end
    argocd -->|read-only deploy key| github
    kyverno -->|reads signatures| ecr
    pods -->|Pod Identity| aws[Secrets Manager, ECR]
    pods -->|TLS, verify-full| rds[(RDS)]
```

1. Engineer to GitHub. Whatever reaches `dev` runs in staging. Production values only change through a pull request.
2. GitHub to AWS. CI gets short-lived credentials only for pushes to `dev` in this repository. Pull requests and other branches get nothing.
3. CI to the registry. CI pushes the image it scanned, then signs it and attaches its SBOM and provenance.
4. Git to the cluster. Argo CD pulls from the repository with a read-only key. CI has no credentials for any cluster.
5. Registry to the cluster. Kyverno checks the image, its signature and its attestations before any pod in an environment namespace starts.
6. Pods to AWS. Each controller that calls AWS has its own Pod Identity role, valid only for its service account in its namespace and cluster.
7. Pods to each other and to the database. Network policies deny everything in the environment namespaces except what each workload needs.
8. People to the clusters. Only through SSO, from one IP address, as cluster admin through an EKS access entry.

## Attack surface

This is everything an attacker could try to reach:

- Public: the EKS API endpoint of each cluster, which only answers the admin's IP address and still requires IAM authentication. There's no load balancer, and nothing else in the VPCs has a public address.
- Administrative: the AWS console and CLI through SSO, `kubectl`, and the Argo CD and Grafana interfaces through `kubectl port-forward`.
- Supply chain: everything I didn't write but run anyway, like npm packages, base images, CI tool images, GitHub Actions, Helm charts and their images, and Terraform providers. Each one is pinned by version, digest or lock file, and Renovate proposes updates.

## Threats and controls

Each row is one thing that could go wrong, what this repository does about it, and the risk that's still left.

| Threat | What the repository does | What's still left |
|---|---|---|
| A secret gets committed | Gitleaks scans the full history on every push and pull request, and Trivy scans the image for secrets. Terraform generates the database passwords as ephemeral values and writes them with write-only arguments, so they're never in Git or in the state. The ECR address stays out of Git because it holds the account ID | A leaked secret still has to be rotated and removed from history |
| Someone abuses the CI's AWS access | No access keys. The role trusts one exact OIDC subject, using GitHub's immutable format with the owner and repository IDs, and a custom Checkov rule fails any wildcard. The job that runs `npm ci` and builds the image has no credentials; a separate job pushes the scanned tarball. The role can only push to and sign for `segp-api`. Its ID is masked in the logs | Anyone who can push to `dev` can get an image signed. I'm the only committer, and branch protection isn't available for a private repository on the free plan |
| An image CI didn't build runs in a cluster | Kyverno only admits the API image pinned to a commit and a digest, signed with the KMS key, with a signed SBOM and a signed provenance that names this repository's `dev` branch. Debug containers get the same rules. The policies fail closed, and Kyverno runs three replicas | The provenance is written by the workflow itself (SLSA Build L1), so it's only as trustworthy as the workflow. There's no transparency log while the repository is private; CloudTrail records every `kms:Sign` instead |
| Production gets an image staging never ran | Promotion is a pull request that copies the staging tag and digest. A CI job fails it if that pair never appeared in the staging values, and Kyverno checks the image again at admission | The merge is the approval. On the free plan GitHub can't require the checks to pass before merging |
| Someone changes a cluster by hand | Argo CD self-heal puts back anything that differs from Git. Only my SSO role is cluster admin, and the API endpoint only answers my IP address | A cluster admin can pause self-heal, as the alert drill did |
| Argo CD is compromised or misused | It reads one repository with a read-only key. Each Application belongs to an AppProject that limits what it may deploy and where, and the catch-all `default` project allows nothing | Argo CD's application controller has cluster-wide rights by design. It still has its initial admin account, reachable only through a port-forward |
| A container is compromised | Pod Security `restricted` in the environment namespaces: non-root, no privilege escalation, no capabilities, seccomp. The API runs with a read-only filesystem and no service account token. IMDSv2 with a hop limit of 1 keeps pods away from the node role. Falco reports suspicious behavior within seconds | Falco detects but doesn't block, and Alertmanager has no receiver, so nobody gets paged |
| An attacker moves sideways inside the cluster | Default deny network policies in `staging` and `production`, with DNS allowed. The API may only reach the database subnets and the trace collector. The VPC CNI enforces them | The platform namespaces have no network policies, and the database security group accepts the whole cluster, so the database login is the last barrier there |
| One environment reaches another's data | Separate VPCs and clusters. Each Pod Identity role names its own environment's secrets by ARN and trusts only its own cluster, namespace and service account | Both environments live in one AWS account |
| The database or its passwords leak | No route to the internet, no public address, TLS forced by the server and verified by the client. The API logs in as a role that owns its tables but can't administer anything. `pg_stat_statements` doesn't keep `ALTER ROLE` statements | The admin login sits in a Kubernetes Secret in each environment namespace, for the setup hook |
| A malicious or vulnerable dependency | `npm ci` from the lock file, with a seven-day minimum release age. Trivy scans the lock file and the image, Semgrep the code. Upstream images are pinned by digest, after checking their cosign signatures where the project publishes them. Renovate also waits seven days | Trivy can't see the Node.js runtime inside the distroless image, so Renovate's node runtime group is what keeps it patched. A malicious release with no advisory would still get through |
| An insecure infrastructure change | `terraform fmt`, `validate`, TFLint and Checkov on every push and pull request. I read every plan before applying. The state is versioned, encrypted and locked during writes. CI never applies | Applies run from a workstation, and people use `AdministratorAccess` through SSO |

## Accepted risks and what's out of scope

Some things were left out on purpose:

- The API has no authentication. It's the payload of the platform, not a product.
- There's no load balancer, TLS ingress or WAF. The API is reached with `kubectl port-forward`, because there's no domain for a certificate and the clusters only exist during working sessions.
- Staging and production share one AWS account.
- RDS runs in one availability zone with one day of backups and no deletion protection, and each VPC has a single NAT gateway. Both environments are rebuilt every working session anyway.
- Argo CD and Grafana use local admin accounts instead of SSO.
- External Secrets runs with cluster-wide permissions. It could be scoped to each environment's namespace.
- Account-level detection (CloudTrail analysis, GuardDuty, Security Hub) is outside this project.

The [README](../README.md#what-would-change-in-production) lists what would change for a real production deployment.
