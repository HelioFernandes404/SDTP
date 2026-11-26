#!/bin/sh
# make release: cria a tag vX.Y.Z do app calculada pelo cog (Conventional Commits -> SemVer)
# e envia só essa tag. A tag dispara o pipeline de produção (deploy manual).
set -eu

ramo="$(git rev-parse --abbrev-ref HEAD)"
[ "$ramo" = develop ] || { echo "erro: release sai da develop (você está em '$ramo')" >&2; exit 1; }
git diff --quiet HEAD -- || { echo "erro: há mudanças não commitadas" >&2; exit 1; }

git fetch --quiet --tags origin develop
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/develop)" ] || {
  echo "erro: HEAD diferente da origin/develop; a tag precisa ficar num commit que já passou pelo pipeline" >&2
  exit 1
}

if git describe --exact-match --tags --match 'v[0-9]*' HEAD >/dev/null 2>&1; then
  echo "erro: este commit já é a release $(git describe --exact-match --tags --match 'v[0-9]*' HEAD)" >&2
  exit 1
fi

# Mesma regra do scripts/versao.sh: sem feat/fix/breaking (ex.: chore(deps) com correção de
# segurança no Dockerfile), a release é patch.
tipo=--auto
proxima="$(cog bump --auto --dry-run 2>/dev/null | grep -E '^v[0-9]' || true)"
if [ -z "$proxima" ]; then
  tipo=--patch
  proxima="$(cog bump --patch --dry-run 2>/dev/null | grep -E '^v[0-9]' || true)"
fi
[ -n "$proxima" ] || { echo "erro: cog não calculou a versão" >&2; exit 1; }

echo "commit: $(git log -1 --format='%h %s')"
echo "versão: $proxima ($tipo)"
printf 'Criar e enviar a tag %s? [s/N] ' "$proxima"
read -r resposta
[ "$resposta" = s ] || { echo "cancelado"; exit 1; }

cog bump "$tipo"
git push origin "$proxima"
