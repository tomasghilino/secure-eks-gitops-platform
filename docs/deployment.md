# Deployment guide

How to run the API locally, set up AWS, bring an environment up, ship a change and tear it all down. The commands assume a POSIX shell at the repository root and an AWS CLI profile called `segp` from IAM Identity Center. The scripts set that profile themselves, so they can't act on the wrong account.

You'll need Docker, Terraform 1.16, the AWS CLI, kubectl, Helm 4 and the GitHub CLI. kind is only for the local lab.

## Run it locally

```bash
cp .env.example .env
docker compose up --build
curl http://127.0.0.1:3000/health
```

For the tests, run `npm ci`, `npm test` and `npm run test:e2e` inside `app/`. The integration tests start their own PostgreSQL with Testcontainers.

## The kind lab

```bash
./scripts/kind-up.sh
kubectl port-forward service/api -n lab 8080:80
kind delete cluster --name segp
```

This runs the API and PostgreSQL on a local three-node cluster, with the same Pod Security level and network policies as EKS. There's no Argo CD, Kyverno or AWS, and it costs nothing, so it's the place to practice and break things.

## One-time AWS setup

1. Apply `infra/bootstrap`, which creates the state bucket. The first apply has to use local state: set `backend.tf` aside, apply, put it back and run `terraform init -migrate-state`. In a new account the bucket gets a different name, so update `bucket` in every `backend.tf` and in the `terraform_remote_state` blocks.
2. Apply `infra/shared`, which creates ECR, the signing key and the CI role:

   ```bash
   terraform -chdir=infra/shared init
   terraform -chdir=infra/shared apply
   ```

3. Give CI its role. Both values contain the account ID, so they're secrets and stay masked in the logs:

   ```bash
   gh secret set AWS_CI_ROLE_ARN --body "$(aws iam get-role --role-name segp-github-ci --query Role.Arn --output text)"
   gh secret set AWS_CI_ROLE_ID --body "$(aws iam get-role --role-name segp-github-ci --query Role.RoleId --output text)"
   ```

4. Export the signing key's public half. CI checks that both copies match:

   ```bash
   cosign public-key --key awskms:///alias/segp-cosign > cosign.pub
   cp cosign.pub charts/baseline/files/cosign.pub
   ```

5. Create a key for Argo CD and add the public half to the repository as a read-only deploy key:

   ```bash
   ssh-keygen -t ed25519 -N "" -C argocd-segp -f ~/.ssh/segp-argocd
   ```

Then push to `dev` once. CI publishes the first signed image, and the publish job's summary shows its digest. Put the commit SHA and the digest in `environments/staging/api.yaml`.

## Bring an environment up

```bash
aws sso login --sso-session jsp
./scripts/eks-up.sh staging
```

The script runs Terraform (you approve the plan), installs Argo CD and Kyverno, and applies the bootstrap. Argo CD installs everything else from Git. Staging takes 20 to 30 minutes from nothing, and production works the same way with `production`.

To look around:

```bash
kubectl port-forward service/argocd-server -n argocd 8080:443
kubectl port-forward service/kube-prometheus-stack-grafana -n monitoring 3001:80
kubectl port-forward service/api -n staging 8081:80
```

The script prints how to read the Argo CD and Grafana admin passwords.

## Ship, promote and roll back

Push to `dev`, and CI runs every check, then pushes and signs the image. To deploy it to staging, commit its tag and digest:

```yaml
image:
  tag: "<full commit sha>"
  digest: "sha256:<digest from the publish job>"
```

Argo CD picks it up within a few minutes. To promote, run `./scripts/promote.sh`, which opens a pull request with the same tag and digest for production. Merging it deploys production one pod at a time.

To roll back, use GitHub's Revert button on that pull request and merge the one it opens. A `kubectl rollout undo` won't last, because Argo CD puts back whatever Git says.

## Tear it down

```bash
AUTO_APPROVE=1 ./scripts/eks-down.sh staging
```

This takes about ten minutes. The script first deletes what Kubernetes created behind Terraform's back, like EBS volumes and load balancers, then destroys the stack. It fails if anything that costs money is still running.

To remove everything, destroy `infra/shared` and then `infra/bootstrap` after emptying ECR and the state bucket.

## Cost

Staging costs about 0.30 USD/h and production about 0.40 USD/h, mostly the EKS control plane, the nodes, the NAT gateway and the control plane logs. The long-lived resources cost about 2 to 3 USD a month. Kubernetes 1.35 stays in standard support until March 2027; after that, extended support would add 0.50 USD/h per cluster.
