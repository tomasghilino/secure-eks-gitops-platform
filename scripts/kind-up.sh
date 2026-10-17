#!/usr/bin/env bash
# Brings up the offline lab on kind: a three-node cluster and the api with an in-cluster postgres in namespace lab,
# behind the same pod security level and network policies as the eks environments. No aws, no argo cd: the
# environments run on eks, and this is for practicing kubectl and breaking things on purpose.
# Safe to run again; it only creates what is missing. Remove everything with: kind delete cluster --name segp
set -euo pipefail

CLUSTER=segp
NAMESPACE=lab

cd "$(dirname "$0")/.."

for tool in docker kind kubectl helm git openssl; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

echo "==> cluster"
if kind get clusters | grep -qx "$CLUSTER"; then
  echo "cluster $CLUSTER already exists"
else
  kind create cluster --config kind/cluster.yaml
fi
kubectl config use-context "kind-$CLUSTER"
kubectl wait --for=condition=Ready nodes --all --timeout=180s

echo "==> api image"
# built from the last commit, not from the working tree, and loaded into the nodes: nothing is pulled from ecr
tag=$(git rev-parse --short HEAD)
if ! docker image inspect "segp-api:$tag" >/dev/null 2>&1; then
  git archive --format=tar "$tag:app" | docker build -t "segp-api:$tag" -
fi
kind load docker-image "segp-api:$tag" --name "$CLUSTER"

echo "==> namespace"
# the namespace, network policies and default service account of the baseline chart, without its kyverno
# and external secrets parts, which need kyverno and aws
helm template baseline charts/baseline --namespace "$NAMESPACE" \
  --show-only templates/namespace.yaml \
  --show-only templates/networkpolicies.yaml \
  --show-only templates/default-serviceaccount.yaml |
  kubectl apply --namespace "$NAMESPACE" -f -
if ! kubectl get secret db-credentials --namespace "$NAMESPACE" >/dev/null 2>&1; then
  kubectl create secret generic db-credentials --namespace "$NAMESPACE" \
    --from-literal=PGUSER=api \
    --from-literal=PGPASSWORD="$(openssl rand -hex 24 | tr -d '\r')"
fi

echo "==> postgres and api"
helm upgrade --install postgres charts/postgres --namespace "$NAMESPACE" --wait --timeout 5m
helm upgrade --install api charts/api --namespace "$NAMESPACE" \
  --values kind/lab-values.yaml --set image.tag="$tag" --wait --timeout 5m
kubectl get pods --namespace "$NAMESPACE" --output wide

cat <<EOF

The api:
  kubectl port-forward service/api -n $NAMESPACE 8080:80
  curl http://localhost:8080/health/ready
When done:
  kind delete cluster --name $CLUSTER
EOF
