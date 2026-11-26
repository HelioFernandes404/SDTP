#!/bin/sh
# Imprime a tag da imagem para o commit atual. Mesma conta no Makefile, no Actions e no GitLab.
#
#   pipeline disparado pela tag v1.5.0  -> 1.5.0
#   3 commits depois da v1.4.2          -> 1.5.0-rc.3.gd743945   (1.5.0 = próxima versão calculada pelo cog)
#   árvore com mudanças locais          -> ...-dirty
#   --proxima                           -> só a próxima versão (1.5.0), usada pelo make release
#
# Quem decide entre release e RC é a REF que disparou o pipeline, não a existência de uma tag no commit:
# um pipeline da develop que roda depois do `make release` enxerga a tag nova no clone, mas continua RC
# (senão publicaria 1.5.0 antes do pipeline da tag, que então falharia com "já existe").
#
# Ponto e "g" antes do hash: no SemVer cada parte entre pontos é comparada sozinha, então rc.3 < rc.10
# ("3" é número). O "g" impede um hash só de dígitos com zero à esquerda (0123456), inválido no SemVer.
set -eu

semver='^v[0-9]+\.[0-9]+\.[0-9]+$'

# Tag que disparou o pipeline (GitLab ou GitHub). Vazio em pipeline de branch e fora do CI.
tag_ci="${CI_COMMIT_TAG:-}"
if [ "${GITHUB_REF_TYPE:-}" = tag ]; then tag_ci="$GITHUB_REF_NAME"; fi

if [ -n "$tag_ci" ] && [ "${1:-}" != --proxima ]; then
  echo "$tag_ci" | grep -Eq "$semver" || { echo "erro: tag '$tag_ci' fora do formato vX.Y.Z" >&2; exit 1; }
  echo "${tag_ci#v}"
  exit 0
fi

# Só tags de release estritas: --exclude tira v1.5.0-rc.1, v2-experimento etc.
# --long: sempre v1.4.2-<n>-g<sha>, inclusive em cima da tag (n = 0).
# Sem --always: sem tag no clone (ex.: clone raso), falha em vez de inventar versão.
desc="$(git describe --tags --long --match 'v[0-9]*.[0-9]*.[0-9]*' --exclude 'v*-*' --exclude 'v*+*')"
ultima="${desc%-*-g*}"                  # v1.4.2
resto="${desc#"$ultima"-}"              # 3-gd743945
n="${resto%%-*}"                        # 3
sha="${resto#*-g}"                      # d743945
echo "$ultima" | grep -Eq "$semver" || { echo "erro: última tag '$ultima' fora do formato vX.Y.Z" >&2; exit 1; }

# Próxima versão pelos Conventional Commits. Sem feat/fix/breaking desde a última release
# (o cog responde "No conventional commits ... required a bump"), sobe patch: ex. chore(deps) no Dockerfile.
# Qualquer outra saída sem versão é erro (cog.toml quebrado etc.): falha, não cai em patch escondido.
proxima() {
  saida="$(cog bump --auto --dry-run 2>&1)" || { echo "erro: cog falhou: $saida" >&2; return 1; }
  v="$(printf '%s\n' "$saida" | grep -E "$semver" || true)"
  if [ -z "$v" ]; then
    printf '%s' "$saida" | grep -q 'No conventional commits' || { echo "erro: saída inesperada do cog: $saida" >&2; return 1; }
    v="$(cog bump --patch --dry-run 2>/dev/null | grep -E "$semver")" || { echo "erro: cog --patch falhou" >&2; return 1; }
  fi
  echo "${v#v}"
}

if [ "${1:-}" = --proxima ]; then
  proxima
  exit 0
fi

sujo=""
[ -z "$(git status --porcelain)" ] || sujo="-dirty"

# Fora do CI, em cima de uma tag e sem mudanças: é a própria release (ex.: make image no checkout da tag).
if [ -z "${CI:-}" ] && [ "$n" = 0 ] && [ -z "$sujo" ]; then
  echo "${ultima#v}"
  exit 0
fi

base="$(proxima)"   # atribuição separada: falha do cog para o script (dentro do echo seria ignorada)
echo "${base}-rc.${n}.g${sha}${sujo}"
