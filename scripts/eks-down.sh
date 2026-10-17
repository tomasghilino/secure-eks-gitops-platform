#!/usr/bin/env bash
# Tears down an environment on EKS without leaving anything billable behind. The volumes behind PVCs and the
# load balancers behind services are created by Kubernetes, not terraform, so they go first.
# Usage: ./scripts/eks-down.sh [staging|production]   (staging by default)
# Terraform shows its plan and asks before destroying; AUTO_APPROVE=1 skips the question.
set -euo pipefail

ENV=${1:-staging}
case "$ENV" in staging | production) ;; *) echo "usage: $0 [staging|production]" >&2; exit 1 ;; esac
CLUSTER=segp-$ENV
export AWS_PROFILE=segp
export AWS_REGION=us-east-1

cd "$(dirname "$0")/.."

for tool in aws terraform kubectl; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
aws sts get-caller-identity >/dev/null || { echo "no aws session: aws sso login --sso-session jsp" >&2; exit 1; }

pvc_volumes() {
  aws ec2 describe-volumes \
    --filters "Name=tag:KubernetesCluster,Values=$CLUSTER" "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
    --query 'length(Volumes)' --output text
}

if aws eks describe-cluster --name "$CLUSTER" >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "$CLUSTER" --alias "$CLUSTER" >/dev/null
  kubectl config use-context "$CLUSTER" >/dev/null

  echo "==> stop argo cd"
  # otherwise self-heal recreates what is deleted below
  kubectl scale statefulset argocd-application-controller --namespace argocd --replicas=0 2>/dev/null || true

  echo "==> load balancers"
  kubectl get services --all-namespaces \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' |
    while read -r ns name; do kubectl delete service "$name" --namespace "$ns" --wait=true; done
  kubectl delete ingress --all --all-namespaces --wait=true 2>/dev/null || true

  echo "==> volumes"
  # deleting the namespaces that hold claims stops their pods, which lets the driver delete the volumes
  for ns in $(kubectl get pvc --all-namespaces -o jsonpath='{.items[*].metadata.namespace}' | tr ' ' '\n' | sort -u); do
    kubectl delete namespace "$ns" --wait=true --timeout=10m
  done
  for _ in $(seq 60); do
    [ "$(pvc_volumes)" = 0 ] && break
    sleep 5
  done
fi

echo "==> terraform"
approve=()
[ "${AUTO_APPROVE:-0}" = 1 ] && approve=(-auto-approve)
# the value doesn't matter for a destroy, but the variable has no default
terraform -chdir="infra/$ENV" destroy -input=false "${approve[@]}" -var "admin_cidr=127.0.0.1/32"

echo "==> leftovers"
leftovers=0
check() {
  printf '%-28s %s\n' "$1" "$2"
  [ "$2" = 0 ] || leftovers=1
}
check "eks clusters" "$(aws eks list-clusters --query 'length(clusters[?@==`'"$CLUSTER"'`])' --output text)"
check "nat gateways" "$(aws ec2 describe-nat-gateways --filter Name=tag:Name,Values="$CLUSTER" Name=state,Values=pending,available,deleting --query 'length(NatGateways)' --output text)"
check "elastic ips" "$(aws ec2 describe-addresses --filters Name=tag:Name,Values="$CLUSTER-nat" --query 'length(Addresses)' --output text)"
check "pvc volumes" "$(pvc_volumes)"
check "load balancers" "$(aws elbv2 describe-load-balancers --query "length(LoadBalancers[?starts_with(LoadBalancerName, 'k8s-')])" --output text)"
kubectl config delete-context "$CLUSTER" >/dev/null 2>&1 || true
if [ "$leftovers" != 0 ]; then
  echo "something is still billing, check above" >&2
  exit 1
fi
echo "nothing left running"
