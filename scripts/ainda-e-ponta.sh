#!/bin/sh
# Sai com 0 se <sha> ainda é a ponta de <branch> na origin; com 1 se já existe commit mais novo.
#   uso: scripts/ainda-e-ponta.sh develop "$GITHUB_SHA"
# Evita que o deploy de um commit antigo, cujo build terminou depois, sobrescreva o de um commit mais novo
# em homologação. O deploy pulado não é perda: o pipeline do commit mais novo faz o dele.
set -eu

branch="$1" sha="$2"
ponta="$(git ls-remote origin "refs/heads/$branch" | cut -f1)"
[ -n "$ponta" ] || { echo "erro: não consegui ler a ponta de $branch na origin" >&2; exit 2; }

if [ "$ponta" != "$sha" ]; then
  echo "commit $sha não é mais a ponta de $branch ($ponta): deploy pulado, o pipeline mais novo fará o dele"
  exit 1
fi
