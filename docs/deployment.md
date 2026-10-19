# Deployment guide

This is the practical side: how to run the API on your machine, create the AWS infrastructure, bring an environment up, ship a change, promote it, roll it back and tear everything down. The commands assume a POSIX shell at the repository root and an AWS CLI profile called `segp` from IAM Identity Center. The scripts set `AWS_PROFILE=segp` themselves, so they never act on whatever account the shell happens to point at.

## What you need

- Docker with Compose
- Node.js 24 and npm, only if you want to run the tests outside containers
- Terraform 1.16, AWS CLI v2, kubectl, Helm 4 and the GitHub CLI
- kind, only for the offline lab
- An AWS account with an IAM Identity Center user allowed to administer it
- Admin access to the GitHub repository, to add a deploy key and two Actions secrets

## Run it locally

```bash
cp .env.example .env
docker compose up --build
curl http://127.0.0.1:3000/health
```

Compose starts PostgreSQL, runs the migrations in a one-off container and then starts the API on `127.0.0.1:3000`, with the same read-only filesystem and non-root user it gets in the cluster.

For the tests:

```bash
cd app
npm ci
npm test
npm run test:e2e
```

The integration tests start their own throwaway PostgreSQL with Testcontainers, so they need Docker but not the Compose stack.

## The offline Kubernetes lab

`scripts/kind-up.sh` creates a three-node kind cluster, builds the API image from the current commit and runs it with an in-cluster PostgreSQL in a namespace called `lab`. The namespace gets the same Pod Security level, network policies and default service account as the EKS environments, but there's no Argo CD, Kyverno or AWS. It takes about two minutes and costs nothing, so it's the place to practice `kubectl` and break things on purpose.

```bash
./scripts/kind-up.sh
kubectl port-forward service/api -n lab 8080:80
curl http://localhost:8080/health/ready
kind delete cluster --name segp
```

## Create the long-lived AWS resources

These two stacks are created once and stay up. Together they cost about 2 to 3 USD a month.

One catch in a new account: S3 bucket names are global, so your state bucket gets a different name, and the `bucket` value in every `backend.tf` (and in the `terraform_remote_state` blocks of `infra/staging` and `infra/production`) has to change to match.

1. `infra/bootstrap` creates the state bucket and its KMS key. Terraform needs the bucket to store its state, but the bucket is created by Terraform, so the first apply uses local state: set `backend.tf` aside, apply, put it back and run `terraform init -migrate-state` to move the state into the bucket.
2. `infra/shared` creates the ECR repository, the cosign signing key, GitHub's OIDC provider and the CI role, the flow log bucket, the KMS key for Kubernetes secrets and EBS encryption by default.

   ```bash
   terraform -chdir=infra/shared init
   terraform -chdir=infra/shared apply
   ```

3. Give CI its role. The ARN and the role ID both contain the account ID, so they're secrets rather than variables, which keeps them masked in the logs:

   ```bash
   gh secret set AWS_CI_ROLE_ARN --body "$(aws iam get-role --role-name segp-github-ci --query Role.Arn --output text)"
   gh secret set AWS_CI_ROLE_ID --body "$(aws iam get-role --role-name segp-github-ci --query Role.RoleId --output text)"
   ```

4. Export the public half of the signing key. CI verifies with the copy at the root, and the clusters trust the copy in the baseline chart. CI checks that both are identical.

   ```bash
   cosign public-key --key awskms:///alias/segp-cosign > cosign.pub
   cp cosign.pub charts/baseline/files/cosign.pub
   ```

5. Create a key pair for Argo CD and add its public half to the repository as a read-only deploy key. The bootstrap script reads the private half from `~/.ssh/segp-argocd`.

   ```bash
   ssh-keygen -t ed25519 -N "" -C argocd-segp -f ~/.ssh/segp-argocd
   ```

Push to `dev` once. CI builds, scans, pushes and signs the first image, and the publish job's summary prints its digest. Put the commit SHA and the digest in `environments/staging/api.yaml`.

## Bring an environment up

```bash
aws sso login --sso-session jsp
./scripts/eks-up.sh staging
```

The script looks up your public IP (the only address the cluster's API endpoint will answer), runs `terraform apply` on `infra/staging` and waits for you to approve the plan. It then installs Argo CD and Kyverno with Helm, stores the deploy key, creates the environment namespace with the `image-registry` ConfigMap and the Grafana admin secret, applies `argocd/bootstrap-staging.yaml` and waits until every Argo CD application is healthy. From there, Argo CD installs everything else from Git in sync wave order.

From nothing, staging takes 20 to 30 minutes: about 12 for the EKS cluster, with RDS created in parallel, and about 8 for the platform. Production is the same with `production`, and it runs both API replicas on on-demand nodes. Running the script again on a running environment only creates what's missing.

To look around:

```bash
kubectl port-forward service/argocd-server -n argocd 8080:443
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d

kubectl port-forward service/kube-prometheus-stack-grafana -n monitoring 3001:80
kubectl get secret grafana-admin -n monitoring -o jsonpath="{.data.admin-password}" | base64 -d

kubectl port-forward service/api -n staging 8080:80
```

## Ship a change

Push to `dev`. Every push and pull request runs the same checks: tests and lint, Gitleaks, Semgrep, Trivy on the dependencies, the chart checks (Helm lint, Trivy config, the Kyverno policies, the alert rule tests) and the Terraform checks. Then the image is built, smoke tested and scanned. Only pushes to `dev` go on to the publish job, which logs in to AWS, pushes the scanned image, and signs it and its SBOM and provenance.

To deploy to staging, commit the new tag and digest to `environments/staging/api.yaml`:

```yaml
image:
  tag: "<full commit sha>"
  digest: "sha256:<digest from the publish job>"
```

Argo CD notices within a few minutes. Before the new pods start, the setup and migration hooks run, and Kyverno checks the image's signature, SBOM and provenance.

## Promote to production

```bash
./scripts/promote.sh
```

The script copies the staging tag and digest into `environments/production/api.yaml` on a new branch and opens a pull request with `gh`. The `promotion` check fails if that tag and digest never appeared in the staging values on `dev`. Merging the pull request is the approval, and Argo CD rolls production one pod at a time, with Kyverno checking the image again.

## Roll back

Revert the promotion pull request with GitHub's Revert button and merge the pull request it opens. The `promotion` check passes, because the previous image did run in staging, and Argo CD rolls back the same way it rolled forward. In staging, revert the deploy commit.

A `kubectl rollout undo` won't last: Argo CD's self-heal puts back whatever Git says within seconds, so every rollback goes through Git.

## Tear it down

At the end of every working session:

```bash
AUTO_APPROVE=1 ./scripts/eks-down.sh staging
```

The script scales Argo CD's application controller to zero, so it can't recreate what gets deleted. It deletes any load balancer services and ingresses, then the namespaces that hold persistent volumes, and waits until no EBS volume is left. Those volumes and load balancers are created by Kubernetes, not Terraform, so `terraform destroy` wouldn't know about them. Then it destroys the stack and checks for EKS clusters, NAT gateways, Elastic IPs, volumes and load balancers. It exits with an error if anything that bills is still there. It takes about ten minutes ([example](evidence/teardown.md)).

To tear down both environments at the same time, give each run its own `KUBECONFIG` file so one can't switch the other's context.

To remove absolutely everything, go in reverse order: destroy `infra/shared` after deleting the images in ECR (the signing key and the KMS keys go into their deletion waiting period), then `infra/bootstrap` after moving its state back to a local file and emptying the versioned bucket.

## Cost

Prices for us-east-1, checked with the AWS Pricing API in October 2026.

| Resource | Cost | When |
|---|---|---|
| Staging | about 0.30 USD/h | While it exists |
| Production | about 0.40 USD/h | While it exists |
| Long-lived resources | about 2 to 3 USD/month | Always: KMS keys, state and log buckets, ECR storage |

The biggest parts of an environment are the EKS control plane (0.10 USD/h), the nodes, the NAT gateway and its IP (about 0.05 USD/h) and the control plane logs (about 0.05 USD/h, almost all of it the audit log). Two spot nodes in staging cost about 0.06 USD/h, and production's two on-demand `t3.large` about 0.17 USD/h. RDS on a `db.t4g.micro` is about 0.02 USD/h. Each bring-up also pays for the images the nodes pull through the NAT gateway.

Kubernetes 1.35 is in standard support until March 2027. A version in extended support would add 0.50 USD/h per cluster, so the version has to move before then. A 50 USD monthly budget with alerts in the management account keeps an eye on the total.
