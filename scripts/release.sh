#!/bin/sh
# make release: cria a tag vX.Y.Z do app, com a versão calculada pelo scripts/versao.sh (a mesma
# conta que gerou as RCs), e envia só essa tag. A tag dispara o pipeline de produção (deploy manual).
set -eu

ramo="$(git rev-parse --abbrev-ref HEAD)"
[ "$ramo" = develop ] || { echo "erro: release sai da develop (você está em '$ramo')" >&2; exit 1; }
# --porcelain: inclui arquivos não rastreados (git diff ignoraria um arquivo novo esquecido).
[ -z "$(git status --porcelain)" ] || { echo "erro: há mudanças locais ou arquivos não rastreados" >&2; exit 1; }

git fetch --quiet --tags origin develop
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/develop)" ] || {
  echo "erro: HEAD diferente da origin/develop; a release precisa ser um commit que está na origin" >&2
  echo "      (confira se o pipeline desse commit passou em homologação antes de lançar)" >&2
  exit 1
}

atual="$(git tag --points-at HEAD | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)"
[ -z "$atual" ] || { echo "erro: este commit já é a release $atual" >&2; exit 1; }

versao="v$(scripts/versao.sh --proxima)"

echo "commit: $(git log -1 --format='%h %s')"
echo "versão: $versao"
printf 'Criar e enviar a tag %s? [s/N] ' "$versao"
read -r resposta
[ "$resposta" = s ] || { echo "cancelado"; exit 1; }

cog bump --version "${versao#v}"
# Se o envio falhar, apaga a tag local: senão o próximo make release acharia que a release já existe.
git push origin "$versao" || { git tag -d "$versao" >/dev/null; echo "erro: push da tag falhou; tag local removida" >&2; exit 1; }
