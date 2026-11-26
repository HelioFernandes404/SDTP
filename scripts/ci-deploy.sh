#!/bin/sh
# Passo de deploy do GitHub Actions: prepara o kubeconfig do environment e chama o contrato (make deploy).
# Sem cluster configurado (o caso deste repositório público: o cluster é local), não finge sucesso:
# registra no resumo do job que o deploy NÃO foi executado e mostra o comando que rodaria.
set -eu

if [ -z "${KUBECONFIG_B64:-}" ] || [ -z "${KUBE_CONTEXT:-}" ]; then
  msg="deploy em $AMBIENTE NÃO executado: environment sem KUBECONFIG_B64/KUBE_CONTEXT (cluster não alcançável daqui)"
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
