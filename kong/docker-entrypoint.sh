#!/bin/sh
set -e

# kong.yml declarativo (DB-less) não suporta substituição nativa de variáveis de ambiente,
# então geramos o arquivo final a partir do template versionado (kong.yml.template) toda vez
# que o container sobe - o mesmo template serve compose e EKS, variando só env.
: "${JWT_SECRET:?JWT_SECRET não definida}"

# NOTIFICATIONS_HISTORY_URL opcional: sem ela (dev local sem a Lambda na AWS) a rota /notifications
# é removida em vez de apontar para um upstream inexistente.
if [ -n "${NOTIFICATIONS_HISTORY_URL:-}" ]; then
  cp /kong-src/kong.yml.template /tmp/kong.yml.src
else
  echo "NOTIFICATIONS_HISTORY_URL vazia - rota /notifications desligada"
  sed '/# BEGIN notifications-history/,/# END notifications-history/d' /kong-src/kong.yml.template > /tmp/kong.yml.src
fi

envsubst '${NOTIFICATIONS_HISTORY_URL} ${JWT_SECRET}' \
  < /tmp/kong.yml.src \
  > /tmp/kong.yml

exec /docker-entrypoint.sh kong docker-start
