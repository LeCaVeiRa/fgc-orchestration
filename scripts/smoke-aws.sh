#!/usr/bin/env bash
# Smoke test contra o ALB na AWS, logando com o Admin semeado pelo Job de migração.
#   AWS_PROFILE=fgc ./scripts/smoke-aws.sh [http://<dns-do-alb>]
set -euo pipefail
REGION="${REGION:-us-east-2}"
export AWS_PROFILE="${AWS_PROFILE:-fgc}"

base="${1:-}"
if [ -z "$base" ]; then
  base="http://$(kubectl -n fgc get ingress fgc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
fi

secret="$(aws secretsmanager get-secret-value --secret-id fgc/users --region "$REGION" --query SecretString --output text)"
SMOKE_ADMIN_EMAIL="$(printf '%s' "$secret" | python -c "import json,sys; print(json.load(sys.stdin)['Seed__AdminEmail'])")"
SMOKE_ADMIN_PASSWORD="$(printf '%s' "$secret" | python -c "import json,sys; print(json.load(sys.stdin)['Seed__AdminPassword'])")"
export SMOKE_ADMIN_EMAIL SMOKE_ADMIN_PASSWORD

python "$(dirname "$0")/smoke.py" "$base"
