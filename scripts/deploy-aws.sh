#!/usr/bin/env bash
# Deploy completo da FCG no EKS, depois de `terraform apply` em fgc-infra/env.
# Idempotente: pode ser rodado de novo após um destroy/apply sem editar nenhum manifesto.
#
#   AWS_PROFILE=fgc ./scripts/deploy-aws.sh            # tudo
#   SKIP_LAMBDA=1 ./scripts/deploy-aws.sh              # sem o sam deploy da Lambda
#
# Ordem: imagens -> plataforma (ClusterSecretStore) -> por serviço: config -> Job de migração -> app
#        -> Lambda (SAM) -> Kong + Ingress -> dashboard do Grafana.
# A camada fgc-infra/messaging (fila + Event Source Mapping) é aplicada depois, com terraform.
set -euo pipefail

REGION="${REGION:-us-east-2}"
CLUSTER="${CLUSTER:-fgc}"
NS=fgc
export AWS_PROFILE="${AWS_PROFILE:-fgc}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)" # pasta que contém os repositórios fgc-*
ORCH="$ROOT/fgc-orchestration"

# SAM CLI no Windows (Git Bash) é sam.cmd.
SAM="$(command -v sam || command -v sam.cmd || true)"

log() { printf '\n==> %s\n' "$*"; }

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

# Tag = SHA curto do repositório; working tree com alterações ganha sufixo (repositórios ECR são imutáveis).
image_tag() {
  local repo="$1" tag
  tag="$(git -C "$repo" rev-parse --short=12 HEAD)"
  if [ -n "$(git -C "$repo" status --porcelain)" ]; then
    tag="$tag-dirty-$(date +%Y%m%d%H%M%S)"
  fi
  echo "$tag"
}

build_push() {
  local name="$1" context="$2" tag="$3"
  if aws ecr describe-images --repository-name "$name" --image-ids imageTag="$tag" --region "$REGION" >/dev/null 2>&1; then
    echo "$name:$tag já existe no ECR"
    return
  fi
  docker build -t "$REGISTRY/$name:$tag" "$context"
  docker push "$REGISTRY/$name:$tag"
}

# Renderiza um kustomization trocando o placeholder DEPLOY_TAG e aplica.
apply_tagged() {
  local dir="$1" tag="$2"
  kubectl kustomize "$dir" | sed "s/:DEPLOY_TAG/:$tag/g" | kubectl apply -f -
}

secret_value() { # secret_value fgc/lambda JWT_KEY
  aws secretsmanager get-secret-value --secret-id "$1" --region "$REGION" --query SecretString --output text |
    python -c "import json,sys; print(json.load(sys.stdin)['$2'])"
}

log "kubeconfig"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null

log "Imagens (ECR $REGISTRY)"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"
declare -A TAGS
for svc in users catalog payments; do
  repo="$ROOT/fgc-$svc-api"
  TAGS[$svc]="$(image_tag "$repo")"
  build_push "fgc-$svc-api" "$repo" "${TAGS[$svc]}"
done
TAGS[kong]="$(image_tag "$ORCH")"
build_push fgc-kong "$ORCH/kong" "${TAGS[kong]}"

log "Plataforma (ClusterSecretStore)"
kubectl apply -k "$ORCH/k8s/platform"
kubectl wait clustersecretstore/aws-secrets-manager --for=condition=Ready --timeout=120s

for svc in users catalog payments; do
  name="fgc-$svc-api"
  repo="$ROOT/$name"
  log "$name (${TAGS[$svc]})"
  kubectl apply -k "$repo/k8s"
  kubectl -n "$NS" wait "externalsecret/$name" --for=condition=Ready --timeout=120s

  if [ -d "$repo/k8s/migrate" ]; then
    kubectl -n "$NS" delete job "$name-migrate" --ignore-not-found
    apply_tagged "$repo/k8s/migrate" "${TAGS[$svc]}"
    if ! kubectl -n "$NS" wait "job/$name-migrate" --for=condition=complete --timeout=300s; then
      kubectl -n "$NS" logs "job/$name-migrate" --tail=50 || true
      exit 1
    fi
  fi

  apply_tagged "$repo/k8s/app" "${TAGS[$svc]}"
  kubectl -n "$NS" rollout status "deployment/$name" --timeout=300s
done

if [ -z "${SKIP_LAMBDA:-}" ]; then
  log "Lambda de notificações (SAM)"
  (
    cd "$ROOT/fgc-notifications-lambda"
    [ -n "$SAM" ] || { echo "SAM CLI não encontrada (ou rode com SKIP_LAMBDA=1)"; exit 1; }
    "$SAM" build
    "$SAM" deploy --stack-name fgc-notifications-lambda --region "$REGION" --resolve-s3 \
      --capabilities CAPABILITY_IAM --no-confirm-changeset --no-fail-on-empty-changeset \
      --parameter-overrides "JwtKey=$(secret_value fgc/lambda JWT_KEY)"
  )
  history_url="$(aws cloudformation describe-stacks --stack-name fgc-notifications-lambda --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='HistoryApiUrl'].OutputValue" --output text)"
  kubectl -n "$NS" create configmap fgc-kong-runtime \
    --from-literal=NOTIFICATIONS_HISTORY_URL="$history_url" --dry-run=client -o yaml | kubectl apply -f -
fi

log "Kong + Ingress (${TAGS[kong]})"
apply_tagged "$ORCH/k8s/kong" "${TAGS[kong]}"
kubectl -n "$NS" wait externalsecret/fgc-kong --for=condition=Ready --timeout=120s
# Reinicia para recarregar NOTIFICATIONS_HISTORY_URL (envFrom só é lido na criação do pod).
kubectl -n "$NS" rollout restart deployment/fgc-kong
kubectl -n "$NS" rollout status deployment/fgc-kong --timeout=300s

log "Dashboard do Grafana"
kubectl -n monitoring create configmap fgc-grafana-dashboards \
  --from-file="$ORCH/grafana/dashboards/fgc-services.json" --dry-run=client -o yaml |
  kubectl label --local -f - grafana_dashboard=1 -o yaml | kubectl apply -f -

log "Endpoint público"
for _ in $(seq 1 30); do
  host="$(kubectl -n "$NS" get ingress fgc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [ -n "$host" ] && break
  sleep 10
done
echo "ALB: http://${host:-<ainda provisionando - kubectl -n fgc get ingress fgc>}"
echo "Próximo passo: terraform apply em fgc-infra/messaging; depois scripts/smoke-aws.sh http://$host"
