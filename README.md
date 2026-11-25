# Desafio DevOps Pleno — contador

Migração de um serviço do Docker Swarm para Kubernetes (k0s): imagem, pipeline, manifests e
preparação dos nós com Ansible. Enunciado original em [`ENUNCIADO.md`](ENUNCIADO.md).

| Parte | Status | Onde |
|---|---|---|
| Lab local (3 VMs Ubuntu 24.04) | ✅ | [`bootstrap/`](bootstrap/README.md) |
| 1 — Imagem | ✅ | [`Dockerfile`](Dockerfile), [`docker/entrypoint.sh`](docker/entrypoint.sh) |
| 2 — Pipeline | ⏳ | |
| 3 — Kubernetes | ⏳ | |
| 4 — Ansible | ⏳ | |

---

## Parte 1 — Imagem

### Como rodar e verificar

```sh
make image        # build com tag rastreável (git describe) e SHA do commit na label
make image-test   # 14 verificações (abaixo)
make image-scan   # trivy: falha se houver CVE HIGH/CRITICAL com correção disponível
make lint         # hadolint + shellcheck

# usando o mirror em vez do Docker Hub
make image REGISTRY=mirror.gcr.io

# rodando à mão
printf 'meu-token' > /tmp/api_token
docker run --rm -p 8080:8080 -v /tmp/api_token:/run/secrets/api_token:ro -v dados:/data contador:<tag>
```

`scripts/test-image.sh` verifica, contra a imagem buildada:

1. **não-root:** `Config.User = 10001:10001` e `id -u` = 10001 dentro do contêiner;
2. **sem segredo não sobe:** arquivo ausente ou vazio → exit 1 com mensagem clara;
3. roda com **rootfs somente leitura**, `--cap-drop ALL` e `no-new-privileges`, gravando só no volume `/data`;
4. **token vem do arquivo:** `POST /reset` com token errado = 401, certo = 200 (o arquivo de teste tem CRLF de propósito);
5. **HEALTHCHECK** chega a `healthy`;
6. **parada rápida:** `docker stop` em < 2 s com exit code 0;
7. **token fora da imagem:** nem em `Config.Env`, nem no `docker history`, nem em nenhum layer
   (o teste extrai o `docker save`, descompacta cada blob e procura o valor falso usado no teste);
8. **rastreabilidade:** label `org.opencontainers.image.revision` com o SHA completo (40 hex).

Resultado da última execução: 14/14 OK. Verificações extras feitas à mão:

| Verificação | Resultado |
|---|---|
| `app.py` **original** (sem handler): `docker stop` | **10,3 s, exit 137** (SIGKILL) |
| `app.py` com handler de SIGTERM | **0,2 s, exit 0** |
| `docker build` sem `VCS_REF` | falha com `erro: --build-arg VCS_REF=<sha do commit> é obrigatório` |
| Digest de `python:3.12-slim-bookworm` no Docker Hub e no `mirror.gcr.io` | idênticos (`sha256:44cf1793…`) |
| Build com `REGISTRY=mirror.gcr.io` | ok |
| trivy 0.58.1 (HIGH/CRITICAL com correção) | 0 |
| hadolint 2.12.0 | sem apontamentos |
| **Controle positivo** da verificação 7: imagem com o token gravado de propósito | o teste acusa `FALHA` (layer e history) — a verificação funciona |
| Cache: 2 builds com `VCS_REF` diferentes | `useradd` e `COPY` saem `CACHED`; só o passo final muda |

### Decisões e trade-offs

| # | Decisão | Por quê | Alternativa descartada |
|---|---|---|---|
| D1 | Base `python:3.12-slim-bookworm` | Tem `sh` para o entrypoint, glibc, conhecida pelo time | Alpine (ganho pequeno, musl); distroless (sem shell, hoje Python 3.13, precisa estar no mirror) |
| D2 | Base fixada por **tag + digest**, `REGISTRY` por build arg | Build reproduzível; o digest é o mesmo no Hub e no mirror | Só tag: dois builds do mesmo commit podem sair diferentes. Custo aceito: atualizar o digest (Renovate/Dependabot) |
| D3 | **Sem segredo, o contêiner não sobe** | O secret é `external` e obrigatório na stack; erro de configuração aparece na hora (restart/CrashLoop) | Subir só com aviso: o serviço funcionaria com `/reset` sempre negando, e o erro passaria despercebido |
| D4 | **Handler de SIGTERM no `app.py`** | Python como PID 1 ignora SIGTERM; cada deploy esperava 10 s (Docker) / 30 s (k8s) e matava com SIGKILL | `STOPSIGNAL SIGINT` (depende do runtime respeitar); `tini` (pacote a mais para um app sem processos filhos) |
| D5 | `HEALTHCHECK` na imagem em `/healthz` | Vale em `docker run` e no Swarm durante a migração; o k8s usa probes próprias | Deixar só no orquestrador |
| D6 | **Sem `VOLUME /data`** | Quem fornece o volume é o orquestrador (volume nomeado no Swarm, PVC no k8s); `VOLUME` cria volume anônimo e não pode ser desfeito em imagens filhas | — |
| D7 | `USER 10001:10001` **numérico** | O k8s só valida `runAsNonRoot` com UID numérico; 10001 não colide com usuários do host | `USER app` (nome) |
| D8 | Tag por `git describe --tags`, SHA completo na label OCI, build falha sem SHA | Legível para humanos (`1.4.2-3-g3f9a2c1`) e rastreável até o commit por dois caminhos | Tag `latest` ou só versão |

Detalhes que valem explicar:

- **Mudança no `app.py` (D4):** só tratamento de sinal. O enunciado permite alterar o app com
  justificativa: o handler levanta `SystemExit`, o que interrompe o `serve_forever()` na thread
  principal. Chamar `shutdown()` dentro do handler travaria, porque ele espera o próprio loop terminar.
- **Entrypoint:** `exec "$@"` faz o Python virar PID 1 e receber o sinal direto. O token é lido com
  `tr -d '\r'`: segredo criado no Windows (CRLF) quebraria a comparação de forma silenciosa.
- **Código como root e só leitura** (`COPY --chmod=0444/0555`): o processo não consegue alterar o
  próprio código. Só `/data` é do UID 10001.
- **`.dockerignore` em lista branca:** só `app/app.py` e `docker/entrypoint.sh` entram no contexto,
  então nada do repositório (inclusive a chave do lab) vaza para a imagem.
- **`ARG VCS_REF` no fim do Dockerfile:** um `ARG` muda a chave de cache de todo `RUN` depois dele.
  No topo, cada commit novo refaria `useradd` e `COPY`; no fim, só o passo de label muda.
- **Sem `# syntax=docker/dockerfile:1`:** essa diretiva baixa o frontend do BuildKit do Docker Hub, o
  que numa rede restrita também precisaria passar pelo mirror. O BuildKit atual já suporta tudo o que usamos.

### Achados no material recebido

- **Healthcheck da stack quebrado:** o `docker-stack.yml` chama `/health`, mas o app só responde em
  `/healthz`. `urlopen` levanta exceção em 404, então esse healthcheck sempre falharia.
  A imagem já usa `/healthz`; a stack e os manifests serão corrigidos na Parte 3.
- **Token lido uma vez:** o app lê `API_TOKEN` só na inicialização. Rotacionar o segredo exige
  reiniciar os pods (rollout), o que será explicado na Parte 3.

---

## Uso de IA

Ferramentas: **Claude Code** (Claude Opus) como assistente principal e **Codex** como revisor independente
dos planos. Processo adotado em cada parte: o Claude lê o enunciado, escreve um plano com as decisões
e alternativas, o Codex revisa o plano, e **eu escolho cada trade-off** antes de qualquer código.
Os planos e minhas escolhas ficam registrados fora do repositório, nas minhas notas.

| Parte | O que a IA fez | O que eu decidi, corrigi ou rejeitei |
|---|---|---|
| Lab (`bootstrap/`) | Claude escreveu o script de VMs com libvirt e cloud-init e diagnosticou o ufw bloqueando o DHCP da bridge nova. Um agente auxiliar apontou que a imagem do Ubuntu já vem com login por senha desligado, o que tornaria inútil o teste da Parte 4 | Escolhi 3 VMs. Pedi o baseline de SSH inseguro para o teste da Parte 4 provar algo |
| Parte 1 | Claude escreveu o plano D1–D8, o Dockerfile, o entrypoint e os testes. O Codex corrigiu fatos do plano: distroless hoje é Python 3.13, digest igual no mirror não é garantido, `$(cat)` remove todas as quebras finais, layers do `docker save` vêm comprimidos | **D3:** troquei "avisar e subir" (sugestão do Claude) por **falhar sem o token**. **D4:** troquei `STOPSIGNAL` (sugestão do Claude) por **handler no app**, seguindo o Codex. **D8:** a tag com versão + hash foi ideia minha |
| | _(a completar por mim: o que revisei linha a linha, o que mudei ou não aceitei)_ | |
