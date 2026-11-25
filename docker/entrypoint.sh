#!/bin/sh
# Lê o API_TOKEN de um arquivo montado em runtime (Swarm secret / Secret do k8s)
# e exporta para o app. O token nunca é gravado na imagem.
#
# O token é obrigatório: sem ele o contêiner não sobe (falha cedo, visível
# como CrashLoop/restart, em vez de rodar com /reset sempre negando).
set -eu

f="${API_TOKEN_FILE:-/run/secrets/api_token}"

if [ ! -r "$f" ]; then
  echo "erro: segredo '$f' ausente ou sem permissão de leitura para uid $(id -u)" >&2
  exit 1
fi

# $(...) remove as quebras de linha finais; tr remove \r de arquivo salvo com CRLF.
API_TOKEN="$(tr -d '\r' < "$f")"
if [ -z "$API_TOKEN" ]; then
  echo "erro: segredo '$f' está vazio" >&2
  exit 1
fi
export API_TOKEN

# exec: o app vira PID 1 e recebe o SIGTERM diretamente.
exec "$@"
