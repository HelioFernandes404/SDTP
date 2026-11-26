#!/bin/sh
# Passo de deploy do GitHub Actions: prepara o kubeconfig do environment e chama o contrato (make deploy).
#   env: AMBIENTE, IMAGE, IMAGE_TAG, KUBECONFIG_B64 (secret), KUBE_CONTEXT, DEPLOY_SIMULADO (variáveis do environment)
set -eu

# Homologação: só a ponta da develop é implantada (ver scripts/ainda-e-ponta.sh).
if [ "$AMBIENTE" = homologacao ]; then
  scripts/ainda-e-ponta.sh develop "$GITHUB_SHA" || {
    rc=$?
    [ "$rc" = 1 ] && exit 0   # commit superado: pular é o certo
    exit "$rc"                # não conseguiu verificar: falha
  }
fi

if [ -z "${KUBECONFIG_B64:-}" ] || [ -z "${KUBE_CONTEXT:-}" ]; then
  # Sem cluster configurado o job FALHA, a não ser que o environment declare DEPLOY_SIMULADO=true
  # (caso deste repositório público: o cluster é local). Assim, uma variável apagada ou com nome errado
  # em produção deixa o job vermelho, em vez de verde sem deploy.
  if [ "${DEPLOY_SIMULADO:-}" != true ]; then
    echo "erro: environment $AMBIENTE sem KUBECONFIG_B64/KUBE_CONTEXT (e sem DEPLOY_SIMULADO=true)" >&2
    exit 1
  fi
  msg="deploy em $AMBIENTE SIMULADO (DEPLOY_SIMULADO=true): nenhum comando foi enviado ao cluster"
  echo "::warning::$msg"
  {
    echo "### ⚠️ $msg"
    echo "Comando que rodaria: \`make deploy AMBIENTE=$AMBIENTE IMAGE_TAG=$IMAGE_TAG\` com \`IMAGE=$IMAGE\`"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
  exit 0
fi

KUBECONFIG="$(mktemp)"
export KUBECONFIG
trap 'rm -f "$KUBECONFIG"' EXIT
printf '%s' "$KUBECONFIG_B64" | base64 -d > "$KUBECONFIG"

make deploy AMBIENTE="$AMBIENTE" IMAGE_TAG="$IMAGE_TAG"
