#!/usr/bin/env bash
# Verificações da Parte 1 contra uma imagem já buildada.
# Uso: scripts/test-image.sh contador:<versao>
# shellcheck disable=SC2015  # `teste && ok || falha`: ok() sempre retorna 0
set -euo pipefail

IMG=${1:?uso: $0 <imagem:tag>}
TOKEN="${TEST_TOKEN:-token-de-exemplo-$RANDOM$RANDOM}"   # valor falso, só para o teste
WORK=$(mktemp -d)
NAME="contador-teste-$$"
VOL="contador-teste-dados-$$"
FALHAS=0

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
falha(){ printf '  \033[31mFALHA\033[0m %s\n' "$*"; FALHAS=$((FALHAS+1)); }
etapa(){ printf '\n\033[1m%s\033[0m\n' "$*"; }

limpar() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm "$VOL" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap limpar EXIT

# Segredo com CRLF de propósito: o entrypoint precisa limpar o \r.
printf '%s\r\n' "$TOKEN" > "$WORK/api_token"
chmod 0644 "$WORK/api_token"

etapa "1. Usuário não-root"
user=$(docker inspect -f '{{.Config.User}}' "$IMG")
[[ "$user" == "10001:10001" ]] && ok "Config.User = $user" || falha "Config.User = '$user'"
uid=$(docker run --rm --entrypoint id "$IMG" -u)
[[ "$uid" == "10001" ]] && ok "id -u no contêiner = $uid" || falha "id -u = $uid"

etapa "2. Sem segredo o contêiner não sobe (D3)"
set +e; out=$(docker run --rm "$IMG" 2>&1); rc=$?; set -e
[[ $rc -ne 0 && "$out" == *"ausente"* ]] && ok "saiu com código $rc: $out" || falha "rc=$rc saída='$out'"
printf '' > "$WORK/vazio"; chmod 0644 "$WORK/vazio"
set +e; out=$(docker run --rm -v "$WORK/vazio:/run/secrets/api_token:ro" "$IMG" 2>&1); rc=$?; set -e
[[ $rc -ne 0 && "$out" == *"vazio"* ]] && ok "segredo vazio também recusa (rc=$rc)" || falha "rc=$rc saída='$out'"

etapa "3. Com segredo, rootfs somente leitura, sem capabilities"
docker run -d --name "$NAME" \
  --read-only --cap-drop ALL --security-opt no-new-privileges \
  -v "$VOL:/data" \
  -v "$WORK/api_token:/run/secrets/api_token:ro" \
  -p 127.0.0.1::8080 "$IMG" >/dev/null
PORT=$(docker port "$NAME" 8080/tcp | head -1 | cut -d: -f2)
URL="http://127.0.0.1:$PORT"
for _ in $(seq 1 30); do curl -fsS "$URL/healthz" >/dev/null 2>&1 && break; sleep 0.5; done

r1=$(curl -fsS "$URL/"); r2=$(curl -fsS "$URL/")
[[ "$r2" == *'"visitas": 2'* ]] && ok "GET / grava em /data (volume): $r2" || falha "contador: $r1 / $r2"

etapa "4. Token lido do arquivo (e com CRLF limpo)"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-Api-Token: errado" "$URL/reset")
[[ "$code" == 401 ]] && ok "token errado → $code" || falha "token errado → $code"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-Api-Token: $TOKEN" "$URL/reset")
[[ "$code" == 200 ]] && ok "token certo → $code" || falha "token certo → $code"

etapa "5. HEALTHCHECK da imagem"
for _ in $(seq 1 40); do
  st=$(docker inspect -f '{{.State.Health.Status}}' "$NAME"); [[ "$st" == healthy ]] && break; sleep 0.5
done
[[ "$st" == healthy ]] && ok "Health.Status = $st" || falha "Health.Status = $st"

etapa "6. Parada rápida com SIGTERM (D4)"
t0=$(date +%s.%N); docker stop -t 10 "$NAME" >/dev/null; t1=$(date +%s.%N)
dur=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')
ec=$(docker inspect -f '{{.State.ExitCode}}' "$NAME")
awk -v d="$dur" 'BEGIN{exit !(d < 2)}' && [[ "$ec" == 0 ]] \
  && ok "docker stop em ${dur}s, exit code $ec" || falha "docker stop em ${dur}s, exit code $ec (esperado <2s e 0)"
docker logs "$NAME" 2>&1 | grep -q encerrado && ok "app registrou 'encerrado' no log" || falha "sem log de encerramento"

etapa "7. Token não está na imagem"
env=$(docker inspect -f '{{json .Config.Env}}' "$IMG")
[[ "$env" != *API_TOKEN* ]] && ok "Config.Env sem API_TOKEN" || falha "Config.Env contém API_TOKEN: $env"
docker save "$IMG" -o "$WORK/img.tar"
mkdir "$WORK/img" && tar -xf "$WORK/img.tar" -C "$WORK/img"
achou=0
while IFS= read -r -d '' blob; do
  # layers podem vir em gzip, zstd ou sem compressão: escolhe o leitor certo por blob
  if gzip -t "$blob" 2>/dev/null; then ler=(zcat)
  elif zstd -qt "$blob" 2>/dev/null; then ler=(zstdcat -q)
  else ler=(cat); fi
  # sem -q de propósito: com pipefail, "grep -q" sai no 1º acerto, o leitor leva
  # SIGPIPE e o pipeline inteiro "falha" justamente quando o token FOI encontrado.
  if "${ler[@]}" "$blob" | grep -aF "$TOKEN" >/dev/null; then achou=1; fi
done < <(find "$WORK/img" -type f -print0)
[[ $achou == 0 ]] && ok "valor do token não aparece em nenhum blob/layer do docker save" || falha "token encontrado na imagem!"
hist=$(docker history --no-trunc "$IMG")
[[ "$hist" != *"$TOKEN"* && "$hist" != *API_TOKEN=* ]] && ok "docker history sem o token" || falha "token no history"

etapa "8. Rastreabilidade"
rev=$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$IMG")
ver=$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMG")
[[ "$rev" =~ ^[0-9a-f]{40}$ ]] && ok "label revision = $rev (version = $ver)" || falha "label revision = '$rev'"

echo
if [[ $FALHAS -eq 0 ]]; then echo "todas as verificações passaram"; else echo "$FALHAS verificação(ões) falharam"; exit 1; fi
