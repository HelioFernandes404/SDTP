#!/bin/sh
# Imprime a tag da imagem para o commit atual. Mesma conta no Makefile, no Actions e no GitLab.
#
#   commit com tag v1.5.0          -> 1.5.0
#   3 commits depois da v1.4.2     -> 1.5.0-rc.3.d743945   (1.5.0 = próxima versão calculada pelo cog)
#   árvore com mudanças locais     -> ...-dirty
#
# Ponto antes do hash: no SemVer cada parte entre pontos é comparada sozinha, então "3" é número
# e rc.3 < rc.10. Com hífen ("3-d743945") viraria texto e rc.10 ordenaria antes de rc.3.
#
# Próxima versão: Conventional Commits (feat -> minor, fix -> patch, ! -> major) via `cog`.
# Sem feat/fix desde a última release (ex.: chore(deps) no Dockerfile), sobe patch.
set -eu

# --match: só tags de release do app (vX.Y.Z), ignorando qualquer outra tag do repo.
# --long: sempre no formato v1.4.2-<n>-g<sha>, inclusive em cima da tag (n = 0).
# Sem --always: se não houver tag (ex.: clone raso no CI), falha em vez de inventar versão.
desc="$(git describe --tags --match 'v[0-9]*' --long)"
ultima="${desc%-*-g*}"                  # v1.4.2
resto="${desc#"$ultima"-}"              # 3-gd743945
n="${resto%%-*}"                        # 3
sha="${resto#*-g}"                      # d743945

sujo=""
git diff --quiet HEAD -- || sujo="-dirty"

if [ "$n" = 0 ] && [ -z "$sujo" ]; then
  echo "${ultima#v}"                    # release: exatamente a tag
  exit 0
fi

# O cog imprime mensagens além da versão: fica só a linha vX.Y.Z.
# Quando não há o que subir, o cog pode sair sem versão: por isso valida a saída, não o exit code.
proxima="$(cog bump --auto --dry-run 2>/dev/null | grep -E '^v[0-9]' || true)"
if [ -z "$proxima" ]; then
  proxima="$(cog bump --patch --dry-run 2>/dev/null | grep -E '^v[0-9]' || true)"
fi
if [ -z "$proxima" ]; then
  echo "erro: cog não calculou a próxima versão (cog instalado? cog.toml?)" >&2
  exit 1
fi

echo "${proxima#v}-rc.${n}.${sha}${sujo}"
