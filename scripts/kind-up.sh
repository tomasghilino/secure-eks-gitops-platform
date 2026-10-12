#!/usr/bin/env bash
# Brings up the local platform on kind: cluster, API images, Argo CD and its bootstrap.
# Safe to run again on an existing cluster; it only creates what is missing.
set -euo pipefail

CLUSTER=segp
ARGOCD_CHART_VERSION=10.9.7
KYVERNO_CHART_VERSION=3.9.1
REPO_URL=git@github.com:tomasghilino/secure-eks-gitops-platform.git
DEPLOY_KEY_FILE=${DEPLOY_KEY_FILE:-$HOME/.ssh/segp-argocd}

cd "$(dirname "$0")/.."

for tool in docker kind kubectl helm git openssl; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
[ -f "$DEPLOY_KEY_FILE" ] || { echo "missing deploy key: $DEPLOY_KEY_FILE" >&2; exit 1; }

echo "==> cluster"
if kind get clusters | grep -qx "$CLUSTER"; then
  echo "cluster $CLUSTER already exists"
else
  kind create cluster --config kind/cluster.yaml
fi
kubectl config use-context "kind-$CLUSTER"
kubectl wait --for=condition=Ready nodes --all --timeout=180s

echo "==> api images"
while read -r tag; do
  if ! docker image inspect "segp-api:$tag" >/dev/null 2>&1; then
    # build from the code of that exact commit, not from the working tree
    git archive --format=tar "$tag:app" | docker build -t "segp-api:$tag" -
  fi
  kind load docker-image "segp-api:$tag" --name "$CLUSTER"
done < <(grep -h 'tag:' environments/*/api.yaml | cut -d'"' -f2 | sort -u)

echo "==> argo cd"
helm repo add argo https://argoproj.github.io/argo-helm --force-update
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
helm repo add kyverno https://kyverno.github.io/kyverno --force-update
helm upgrade --install kyverno kyverno/kyverno --version "$KYVERNO_CHART_VERSION" \
  --namespace kyverno --create-namespace --values kyverno/values.yaml --wait --timeout 10m

echo "==> environments"
for env in staging production; do
  kubectl get namespace "$env" >/dev/null 2>&1 || kubectl create namespace "$env"
  if ! kubectl get secret db-credentials --namespace "$env" >/dev/null 2>&1; then
    kubectl create secret generic db-credentials --namespace "$env" \
      --from-literal=PGUSER=api \
      --from-literal=PGPASSWORD="$(openssl rand -hex 24 | tr -d '\r')"
  fi
done

echo "==> monitoring"
kubectl apply -f observability/namespaces/namespaces.yaml
if ! kubectl get secret grafana-admin --namespace monitoring >/dev/null 2>&1; then
  kubectl create secret generic grafana-admin --namespace monitoring \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(openssl rand -hex 24 | tr -d '\r')"
fi

echo "==> bootstrap"
kubectl apply -f argocd/bootstrap.yaml
kubectl wait application root --namespace argocd --for=jsonpath='{.status.sync.status}'=Synced --timeout=300s
kubectl wait application --all --namespace argocd --for=jsonpath='{.status.health.status}'=Healthy --timeout=600s
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
