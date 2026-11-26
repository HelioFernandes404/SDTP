#!/bin/sh
# Publica a imagem no registry sem nunca sobrescrever uma tag (tags são imutáveis).
#   uso: scripts/publicar-imagem.sh <imagem> <versão> <sha-do-commit> <registry-da-base>
#
#   tag não existe                      -> build + push
#   tag existe, mesmo commit na label   -> nada a fazer (rerodar o pipeline é seguro, ex.: runner caiu após o push)
#   tag existe, outro commit            -> erro
#   registry não respondeu "not found"  -> erro (503, auth, rede: na dúvida, não publica)
set -eu

imagem="$1" versao="$2" vcs_ref="$3" registry="$4"
ref="$imagem:$versao"

[ -n "$versao" ] || { echo "erro: versão vazia (scripts/versao.sh falhou?)" >&2; exit 1; }

# imagetools lê a config da imagem direto do registry, sem baixar os layers.
if saida="$(docker buildx imagetools inspect "$ref" --format '{{json .Image}}' 2>&1)"; then
  # O JSON vem formatado ("chave": "valor"): aceita espaço depois dos dois-pontos.
  rev="$(printf '%s' "$saida" | grep -o '"org.opencontainers.image.revision": *"[0-9a-f]*"' | head -1 | grep -o '[0-9a-f]\{40\}' || true)"
  if [ "$rev" = "$vcs_ref" ]; then
    echo "$ref já publicada para o commit $vcs_ref; nada a fazer"
    exit 0
  fi
  echo "erro: $ref já existe no registry (commit ${rev:-desconhecido}); tags são imutáveis" >&2
  exit 1
fi
case "$saida" in
  *"not found"*) ;;   # tag livre
  *) echo "erro: não consegui confirmar que $ref está livre: $saida" >&2; exit 1 ;;
esac

make image IMAGE="$imagem" VERSION="$versao" VCS_REF="$vcs_ref" REGISTRY="$registry"
docker push "$ref"
