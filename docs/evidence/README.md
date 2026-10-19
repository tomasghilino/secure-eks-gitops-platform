# Evidence

These are excerpts from real runs and from failures I caused on purpose, to show that each control actually stops something. Account IDs, hostnames and secrets were removed.

If you only have a few minutes, start with the admission checks, then the promotion and rollback, and then Falco catching an attack. Those three show the platform working end to end.

| File | What you'll see |
|---|---|
| [signed-supply-chain.md](signed-supply-chain.md) | How a push to dev ends with an image in ECR that carries a signature, an SBOM and a provenance record, and what I found on the way |
| [signed-images-at-admission.md](signed-images-at-admission.md) | Kyverno admitting the signed image and rejecting an unsigned one, one without an SBOM, one from Docker Hub and a copy in someone else's registry |
| [promotion-and-rollback.md](promotion-and-rollback.md) | A pull request that tried to skip staging, a real promotion, and a rollback by reverting the pull request |
| [drift-self-heal.md](drift-self-heal.md) | A manual change in production that Argo CD undid within two seconds |
| [github-oidc.md](github-oidc.md) | CI logging in to AWS without stored keys, and a pull request that tried to widen that trust |
| [ci-role-permissions.md](ci-role-permissions.md) | What the CI role can do in AWS, checked with the IAM policy simulator |
| [terraform-ci-gates.md](terraform-ci-gates.md) | Checkov stopping a change that would have made the Terraform state bucket public |
| [semgrep-first-findings.md](semgrep-first-findings.md) | Two real issues Semgrep found on its first run, and their fixes |
| [pod-security-restricted.md](pod-security-restricted.md) | The environment namespaces rejecting privileged and root pods |
| [network-policies.md](network-policies.md) | A stray pod that could reach everything, and then nothing |
| [platform-on-eks.md](platform-on-eks.md) | Moving the platform from kind to EKS, and three traps found on the way |
| [rds-and-external-secrets.md](rds-and-external-secrets.md) | Database passwords that never touch Git, the Terraform state or the logs, and one that leaked into query statistics |
| [secrets-across-environments.md](secrets-across-environments.md) | Staging asking for production's database secret, and AWS refusing |
| [alerts-and-drill.md](alerts-and-drill.md) | Alert rules with unit tests, and a database outage followed from the alert to the trace |
| [falco-runtime-detection.md](falco-runtime-detection.md) | Falco catching an attacker inside a container, and an alert that would have missed the first attack |
| [admission-and-rbac-review.md](admission-and-rbac-review.md) | A review of who can do what, which closed a bypass through debug containers |
| [renovate.md](renovate.md) | Dependency update pull requests that follow the same rules I applied by hand |
| [interrupted-apply-and-spot.md](interrupted-apply-and-spot.md) | Recovering a Terraform apply cut off by a dropped connection, and a spot interruption during bootstrap |
| [teardown.md](teardown.md) | Removing an environment and proving nothing billable is left |
