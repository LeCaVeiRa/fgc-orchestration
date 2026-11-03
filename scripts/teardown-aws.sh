#!/usr/bin/env bash
# Limpeza do que foi criado FORA do Terraform da env, enquanto os controllers ainda estão no cluster.
# Rodar depois de `terraform destroy` em fgc-infra/messaging e ANTES do destroy de fgc-infra/env:
#   - Ingress: o AWS Load Balancer Controller precisa estar vivo para apagar o ALB e seus security
#     groups (senão a VPC não é removida);
#   - ExternalSecrets/ClusterSecretStore: têm finalizers tratados pelo External Secrets Operator;
#     se o operador sai antes, o namespace fgc fica preso em Terminating e o destroy estoura o tempo;
#   - stack SAM da Lambda de notificações.
set -euo pipefail
REGION="${REGION:-us-east-2}"
export AWS_PROFILE="${AWS_PROFILE:-fgc}"

aws eks update-kubeconfig --name fgc --region "$REGION" >/dev/null

echo "==> Ingress/ALB"
kubectl -n fgc delete ingress --all --wait=true --ignore-not-found
for _ in $(seq 1 30); do
  left="$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "length(LoadBalancers[?starts_with(LoadBalancerName,'k8s-fgc')])" --output text)"
  [ "$left" = 0 ] && break
  sleep 10
done
echo "ALBs restantes: $left"

echo "==> ExternalSecrets e ClusterSecretStore"
kubectl -n fgc delete externalsecrets --all --wait=true --ignore-not-found
kubectl delete clustersecretstore --all --wait=true --ignore-not-found

echo "==> Stack SAM"
aws cloudformation delete-stack --stack-name fgc-notifications-lambda --region "$REGION"
aws cloudformation wait stack-delete-complete --stack-name fgc-notifications-lambda --region "$REGION"

echo "Pronto. Agora: cd fgc-infra/env && terraform plan -destroy -out destroy.tfplan && terraform apply destroy.tfplan"
