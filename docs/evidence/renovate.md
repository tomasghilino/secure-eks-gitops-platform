# Renovate: dependency update pull requests, with the same 7-day rule I follow by hand

Short version: Renovate (the Mend-hosted GitHub app) watches every pinned version in the repository and opens pull requests into dev. Each pull request waits for the same CI as any other change, and I merge it myself. The config encodes the rules I had been following by hand: wait 7 days after a release, treat a major version as a decision, and move together the things that must stay equal.

## What it watches (local dry run, `renovate --platform=local --dry-run=extract`, Renovate 44.137.0)

```text
argocd          argocd/apps/*.yaml       chart versions: external-secrets 2.12.0, kube-prometheus-stack 91.9.0, loki 18.13.8,
                                         opentelemetry-collector 0.175.0, tempo 3.1.0 (and falco 9.2.0, added after)
dockerfile      app/Dockerfile           node:24.21.0-trixie-slim@digest, gcr.io/distroless/nodejs24-debian13:nonroot@digest
github-actions  .github/workflows/ci.yml actions pinned by commit (checkout, setup-node, upload/download-artifact,
                                         configure-aws-credentials), node 24.21.0
regex (custom)  .github/workflows/ci.yml trivy, gitleaks, semgrep, kyverno-cli, prometheus, terraform, tflint, checkov, cosign
regex (custom)  charts/baseline          the postgres image in the allowlist
regex (custom)  kind/cluster.yaml        kindest/node:v1.35.8@digest
regex (custom)  scripts/eks-up.sh        argo-cd 10.9.7, kyverno 3.9.1 (each annotated with a "# renovate:" comment)
helm-values     charts/api, charts/postgres   postgres:17-alpine@digest
npm             app/package.json         38 dependencies
terraform       infra/*                  aws ~> 6.67, random ~> 3.9, terraform ~> 1.16
tflint-plugin   .tflint.hcl              tflint-ruleset-aws 0.49.0
renovate-config-validator --strict: Config validated successfully
```

The first local run found nothing: Renovate only reads files that git tracks, and renovate.json wasn't staged yet.

## Rules in renovate.json

- `minimumReleaseAge: 7 days` + `internalChecksFilter: strict`: no pull request before a release is a week old (the rule I applied by hand all project, for example skipping chart 92.x and External Secrets 2.13.0).
- Majors need approval on the dependency dashboard.
- Grouped:
  - node runtime (build image, distroless runtime, CI node). Distroless has no package list, so Trivy can't see its node version. These pull requests are what keeps it patched.
  - postgres image: the baseline allowlist must hold the same digest as the api chart's setup job, or Kyverno would reject the job.
- Upstream charts whose values pin image digests by hand get a note in the pull request: move the digests and verify the signatures with cosign before merging. Renovate can bump a chart, but it can't check who signed its images.
- Our own image and repository are ignored: they are promoted by pull request, not updated.

## First run (2026-10-19)

The app was installed with access to this repository only, but nothing showed up on GitHub. The Mend portal showed why: four finished jobs, and the repository in silent mode. New Mend installations start with "Automated PRs" off, so Renovate scans the repository and only lists the updates in the portal. I turned on Automated PRs and Require config file (Renovate only acts where our `renovate.json` exists) and left onboarding pull requests off, then started a scan from the portal.

```text
Dependency Dashboard (issue)
  Pending Approval        4    typescript 7, kube-prometheus-stack 92, postgres 18, vitest 5   (majors)
  Rate-Limited           17    config:recommended opens at most 2 pull requests per hour
  Pending Status Checks   7    not 7 days old yet: trivy 0.76, node runtime, external-secrets 2.13.0,
                               tempo 3.2.0, terraform 1.16.6, vitest 4.1.12, ubuntu 26 runner
  Open                    2    checkov 3.3.28, oxlint-tsgolint 7.0.2004 (lockfile)
```

The ubuntu 26 runner is a major, yet it sits under "Pending Status Checks", not "Pending Approval". In Renovate's code the release age check comes before the approval check, so it moves to "Pending Approval" once it is a week old. Nothing to change.

The first two pull requests ran the full CI, plus a `renovate/stability-days` check that confirms the 7-day rule. The checkov pull request is tested by the tool it updates: the terraform job ran checkov 3.3.28 on our infrastructure code before the merge.

```text
pr: checkov 3.3.23 -> 3.3.28 (one line in ci.yml: tag + digest)
  terraform job   bridgecrew/checkov:3.3.28@sha256:19ab…   Passed checks: 268, Failed checks: 0, Skipped checks: 43
  every other job pass, renovate/stability-days pass
pr: oxlint-tsgolint 7.0.2002 -> 7.0.2004 (package-lock.json only)
  every job pass
```

I squash-merged both into dev.

```text
dev after both merges: ci run for the second merge (it carries both changes) -> every job success, publish success
                       (the run for the first merge was cancelled by the newer push, as the workflow's concurrency rule intends)
```
