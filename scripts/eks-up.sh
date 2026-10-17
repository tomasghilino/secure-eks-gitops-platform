#!/usr/bin/env bash
# Brings up an environment on EKS: network and cluster with terraform, kubectl access, Argo CD and its bootstrap.
# Usage: ./scripts/eks-up.sh [staging|production]   (staging by default)
# Terraform shows its plan and asks before applying; AUTO_APPROVE=1 skips the question.
# Safe to run again on a running environment; it only creates what is missing.
set -euo pipefail

ENV=${1:-staging}
case "$ENV" in staging | production) ;; *) echo "usage: $0 [staging|production]" >&2; exit 1 ;; esac
CLUSTER=segp-$ENV
ARGOCD_CHART_VERSION=10.9.7
KYVERNO_CHART_VERSION=3.9.1
REPO_URL=git@github.com:tomasghilino/secure-eks-gitops-platform.git
DEPLOY_KEY_FILE=${DEPLOY_KEY_FILE:-$HOME/.ssh/segp-argocd}
# always the project account, never whatever profile the shell happens to export
export AWS_PROFILE=segp
export AWS_REGION=us-east-1

cd "$(dirname "$0")/.."

for tool in aws terraform kubectl helm curl openssl; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
[ -f "$DEPLOY_KEY_FILE" ] || { echo "missing deploy key: $DEPLOY_KEY_FILE" >&2; exit 1; }
aws sts get-caller-identity >/dev/null || { echo "no aws session: aws sso login --sso-session jsp" >&2; exit 1; }

echo "==> terraform"
# the api endpoint only answers this address, so it is looked up on every run
admin_cidr="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')/32"
terraform -chdir="infra/$ENV" init -input=false >/dev/null
approve=()
[ "${AUTO_APPROVE:-0}" = 1 ] && approve=(-auto-approve)
terraform -chdir="infra/$ENV" apply -input=false "${approve[@]}" -var "admin_cidr=$admin_cidr"

echo "==> kubectl"
aws eks update-kubeconfig --name "$CLUSTER" --alias "$CLUSTER" >/dev/null
kubectl config use-context "$CLUSTER"
kubectl wait --for=condition=Ready nodes --all --timeout=300s

echo "==> argo cd"
helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace --values argocd/values.yaml --wait --timeout 10m

if ! kubectl get secret repo-segp --namespace argocd >/dev/null 2>&1; then
  kubectl create secret generic repo-segp --namespace argocd \
    --from-literal=type=git \
    --from-literal=url="$REPO_URL" \
    --from-file=sshPrivateKey="$DEPLOY_KEY_FILE"
  kubectl label secret repo-segp --namespace argocd argocd.argoproj.io/secret-type=repository
fi

echo "==> kyverno"
helm repo add kyverno https://kyverno.github.io/kyverno --force-update >/dev/null
helm upgrade --install kyverno kyverno/kyverno --version "$KYVERNO_CHART_VERSION" \
  --namespace kyverno --create-namespace --values kyverno/values.yaml --wait --timeout 10m

echo "==> environment"
kubectl get namespace "$ENV" >/dev/null 2>&1 || kubectl create namespace "$ENV"
# the database credentials are not created here: external secrets copies them from secrets manager
# the ecr address holds the account id, so it lives in the cluster instead of git;
# the use-ecr-registry policy reads it when api pods are created
registry="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$AWS_REGION.amazonaws.com"
kubectl create configmap image-registry --namespace "$ENV" --from-literal=registry="$registry" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "==> monitoring"
kubectl apply -f observability/namespaces/namespaces.yaml
if ! kubectl get secret grafana-admin --namespace monitoring >/dev/null 2>&1; then
  kubectl create secret generic grafana-admin --namespace monitoring \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(openssl rand -hex 24 | tr -d '\r')"
fi

echo "==> bootstrap"
kubectl apply -f "argocd/bootstrap-$ENV.yaml"
kubectl wait application root --namespace argocd --for=jsonpath='{.status.sync.status}'=Synced --timeout=300s
kubectl wait application --all --namespace argocd --for=jsonpath='{.status.health.status}'=Healthy --timeout=900s
kubectl get applications --namespace argocd

cat <<'EOF'

Argo CD UI:
  kubectl port-forward service/argocd-server -n argocd 8080:443
  https://localhost:8080  (user admin)
Admin password:
  kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d

Grafana UI:
  kubectl port-forward service/kube-prometheus-stack-grafana -n monitoring 3001:80
  http://localhost:3001  (user admin)
Admin password:
  kubectl get secret grafana-admin -n monitoring -o jsonpath="{.data.admin-password}" | base64 -d

EOF
echo "When done: ./scripts/eks-down.sh $ENV"
