#!/bin/sh
# Instala o cog (Cocogitto) no CI: versão fixa e conferida por sha256.
# Rede restrita: COG_URL aponta para o mirror de artefatos (ex.: Nexus/Artifactory) com o mesmo arquivo.
#   uso: scripts/install-cog.sh [diretório]   (padrão: /usr/local/bin)
set -eu

COG_VERSION="7.0.0"
COG_SHA256="e03938ff2c4c86d71c00c0f3284dbbe95c5ca76fe34a51f33e945c23010d59bb"   # x86_64 musl (estático)
COG_URL="${COG_URL:-https://github.com/cocogitto/cocogitto/releases/download/${COG_VERSION}/cocogitto-${COG_VERSION}-x86_64-unknown-linux-musl.tar.gz}"
destino="${1:-/usr/local/bin}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/cog.tar.gz" "$COG_URL"
echo "$COG_SHA256  $tmp/cog.tar.gz" | sha256sum -c -
tar -xzf "$tmp/cog.tar.gz" -C "$tmp"
install -m 0755 "$tmp/x86_64-unknown-linux-musl/cog" "$destino/cog"
"$destino/cog" --version
