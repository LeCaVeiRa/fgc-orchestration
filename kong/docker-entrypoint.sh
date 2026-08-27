#!/bin/sh
set -e

# kong.yml declarativo (DB-less) não suporta substituição nativa de variáveis de ambiente,
# então geramos o arquivo final a partir do template versionado (kong.yml.template) toda vez
# que o container sobe - permite variar NOTIFICATIONS_HISTORY_URL entre dev (LocalStack) e
# produção (API Gateway real) sem duplicar o resto da configuração.
: "${NOTIFICATIONS_HISTORY_URL:?NOTIFICATIONS_HISTORY_URL não definida}"
: "${JWT_SECRET:?JWT_SECRET não definida}"

envsubst '${NOTIFICATIONS_HISTORY_URL} ${JWT_SECRET}' \
  < /kong-src/kong.yml.template \
  > /tmp/kong.yml

exec /docker-entrypoint.sh kong docker-start
