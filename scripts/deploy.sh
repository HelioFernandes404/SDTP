#!/bin/sh
# Contrato de deploy do pipeline: o job só chama este script com o ambiente e a tag da imagem.
# Hoje aplica com kubectl (o que o enunciado sugere); a Parte 3 troca só o corpo deste script
# (helm upgrade, kubectl apply -k ou commit num repo de GitOps) sem mudar nenhum pipeline.
#
#   uso: scripts/deploy.sh <homologacao|producao> <tag-da-imagem>
#   variáveis: IMAGE (repositório da imagem), KUBE_CONTEXT (contexto do kubeconfig do ambiente),
#              NAMESPACE (padrão: contador), ROLLOUT_TIMEOUT (padrão: 180s)
set -eu

ambiente="${1:?uso: deploy.sh <ambiente> <tag>}"
tag="${2:?uso: deploy.sh <ambiente> <tag>}"
: "${IMAGE:?defina IMAGE (ex.: ghcr.io/org/contador)}"
: "${KUBE_CONTEXT:?defina KUBE_CONTEXT (contexto do cluster de $ambiente)}"
ns="${NAMESPACE:-contador}"

k() { kubectl --context "$KUBE_CONTEXT" --namespace "$ns" "$@"; }

echo "deploy: $ambiente <- $IMAGE:$tag (contexto $KUBE_CONTEXT, namespace $ns)"
k set image deployment/contador "contador=$IMAGE:$tag"
# change-cause aparece no `kubectl rollout history` (qual versão cada revisão subiu).
# Depois do set image: o controller copia a anotação para o ReplicaSet novo. Antes dele,
# ela iria parar no ReplicaSet antigo (testado: o histórico ficava com as versões trocadas).
k annotate deployment/contador --overwrite "kubernetes.io/change-cause=$ambiente $tag (pipeline)"

# Espera o rollout terminar: se o pod novo não ficar pronto, o job fica vermelho.
# Sem isso, o pipeline ficaria verde mesmo com a aplicação quebrada.
if ! k rollout status deployment/contador --timeout "${ROLLOUT_TIMEOUT:-180s}"; then
  echo "erro: rollout de $tag não terminou em $ambiente; a versão anterior segue atendendo (maxUnavailable=0)." >&2
  echo "      para voltar: kubectl --context $KUBE_CONTEXT -n $ns rollout undo deployment/contador" >&2
  exit 1
fi
