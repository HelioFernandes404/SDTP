# Desafio DevOps Pleno — contador

Migração de um serviço do Docker Swarm para Kubernetes (k0s): imagem, pipeline, manifests e
preparação dos nós com Ansible. Enunciado original em [`ENUNCIADO.md`](ENUNCIADO.md).

| Parte | Status | Onde |
|---|---|---|
| Lab local (3 VMs Ubuntu 24.04) | ✅ | [`bootstrap/`](bootstrap/README.md) |
| 1 — Imagem | ✅ | [`Dockerfile`](Dockerfile), [`docker/entrypoint.sh`](docker/entrypoint.sh) |
| 2 — Pipeline | ✅ | [`.gitlab-ci.yml`](.gitlab-ci.yml), [`.github/workflows/`](.github/workflows/), [`scripts/`](scripts/) |
| 3 — Kubernetes | ⏳ | |
| 4 — Ansible | ⏳ | |

---

## Parte 1 — Imagem

### Como rodar e verificar

```sh
make image        # build com tag rastreável (scripts/versao.sh, ver Parte 2) e SHA do commit na label
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
| D8 | Tag legível + SHA completo na label OCI, build falha sem SHA | Rastreável até o commit por dois caminhos. Formato revisado na Parte 2 (`1.5.0-rc.3.d743945`) | Tag `latest` ou só versão |

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

## Parte 2 — Pipeline

O `.gitlab-ci.yml` é a entrega. O mesmo fluxo roda de verdade no GitHub Actions
([`pipeline.yml`](.github/workflows/pipeline.yml)), publicando em `ghcr.io/heliofernandes404/contador`.

```
PR/MR para develop  → lint das mensagens de commit e do título (a versão sai delas)
push na develop     → build + push 1.5.0-rc.3.d743945 → deploy em homologação (automático)
make release        → cria a tag v1.5.0 calculada a partir dos commits
tag v1.5.0          → build + push 1.5.0              → deploy em produção (manual)
```

### Como rodar e verificar

```sh
scripts/versao.sh                # tag da imagem para o commit atual (precisa do cog: mise use -g cocogitto@7.0.0)
make image                       # build local com essa tag
make release                     # só na develop, igual à origin, pede confirmação; cria e envia vX.Y.Z

# contrato de deploy (o que os jobs chamam)
IMAGE=ghcr.io/heliofernandes404/contador KUBE_CONTEXT=<contexto> \
  make deploy AMBIENTE=homologacao IMAGE_TAG=1.5.0-rc.3.d743945
```

| Verificação | Resultado |
|---|---|
| `versao.sh` em repo descartável: na tag / feat / fix / `feat!` / chore depois de release / árvore suja | `1.5.0` / `1.5.0-rc.2.<sha>` / patch / `2.0.0-rc…` / patch / `…-dirty` |
| `versao.sh` em clone raso | falha (exit 128) em vez de inventar versão |
| `make release` em repo descartável | recusa HEAD à frente da origin, recusa commit que já é release, cria e envia só a tag nova |
| `make deploy` em cluster k3d descartável: tag existente | rollout completo, exit 0, `rollout history` com a versão |
| `make deploy` com tag inexistente | job falha após o timeout; os 2 pods antigos seguem atendendo (`maxUnavailable: 0`) |
| `gitlab-ci-local --list` simulando push na develop / tag `v1.5.0` / MR / outra tag | `build → deploy-homologacao` / `build → deploy-producao (manual)` / `commits` / nada |
| `actionlint`, `shellcheck`, schema do GitLab CI | sem apontamentos |

No GitHub, o repositório não alcança um cluster, então o passo de deploy **avisa que não rodou** (com o
comando que rodaria) em vez de ficar verde em silêncio. Com `KUBECONFIG_B64`/`KUBE_CONTEXT` no environment, ele executa.

### Decisões e trade-offs

| # | Decisão | Por quê | Alternativa descartada |
|---|---|---|---|
| D8 | Tag `1.5.0-rc.3.d743945` na develop, `1.5.0` na release; SHA completo na label OCI | Mostra a versão que está sendo preparada, quantos commits desde a última e o commit. Ordena certo no SemVer | `git describe` puro: `1.4.2-3-gabc` é pré-release e ordena **antes** da 1.4.2. Hífen antes do hash: `rc.10-…` ordenaria antes de `rc.3-…` |
| D9/D13 | Versão calculada por Conventional Commits com o **Cocogitto** (binário único: lint + cálculo); a tag é criada por uma pessoa (`make release`) | A máquina faz a conta; a pessoa decide quando lançar. Lint e cálculo usam a mesma regra | Arquivo `VERSION` (alguém esquece de subir); semantic-release (Node, tag criada no CI com `GITHUB_TOKEN` não dispara o pipeline de produção) |
| D10 | Build com Docker (`docker:dind` no GitLab), o mesmo `make image` em todo lugar | Igual local, Actions e GitLab | Kaniko (arquivado pelo Google em 2025); BuildKit rootless (outro comando) |
| D11 | O pipeline da tag reconstrói a imagem | Simples e igual ao enunciado; a base fixada por digest (D2) deixa o resultado praticamente igual | Promover a imagem testada em homologação — ver propostas abaixo |
| D23 | **Contrato de deploy**: o job só chama `make deploy AMBIENTE IMAGE_TAG`; hoje `kubectl set image` + `rollout status` | É o que o enunciado sugere, e o job fica vermelho se o pod novo não subir. A Parte 3 troca só `scripts/deploy.sh` | Fechar Helm/ArgoCD antes de analisar a stack (Parte 3) |
| P7 | Produção **manual** | Item 2 "deploy em homologação, automático" × item 3 "deploy em produção, manual". `make release` decide **o que** vai; o clique decide **quando** | Deploy automático na tag |
| — | Tags imutáveis | `make image-push` recusa tag existente; ruleset do GitHub impede apagar/mover tags `v*` | Sobrescrever a tag ao rerodar o pipeline |
| P8 | Só "merge commit" no repo + lint do título | Squash trocaria os commits checados pelo título do PR, e a versão sairia errada sem aviso | Squash merge |

Detalhes que valem explicar:

- **`GIT_DEPTH: 0`** no GitLab: o clone raso padrão (20 commits) quebraria o `git describe`; o script falha alto nesse caso.
- **Versão calculada uma vez**: o build grava `IMAGE_TAG` num `dotenv` e os deploys usam esse valor (não recalculam).
- **`resource_group`** (GitLab) e **`concurrency`** (Actions): um deploy por ambiente por vez.
- **Credenciais**: kubeconfig por environment (variável File no GitLab, secret no Actions), nunca no repositório.
  No Actions o `GITHUB_TOKEN` tem leitura por padrão; só o build pede `packages: write`.
- **Rede restrita**: imagens dos jobs via `BASE_REGISTRY` (mirror) e o binário do cog via `COG_URL`, conferido por sha256.

### Propostas para a conversa técnica (não implementadas)

Discuti estas ideias e deixei fora do código por escopo; são a minha posição:

- **Promover em vez de reconstruir**: produção rodaria exatamente o digest testado em homologação. O pipeline da develop
  registraria um "carimbo" no commit (digest + homologação ok) e o pipeline da tag promoveria esse digest.
- **Modelo de branch**: `develop` como tronco e produção = tags (nenhum passo muda o SHA entre homologação e release).
  Hotfix sai da última tag (`hotfix/*`), passa por homologação e volta para a develop.
- **GitOps com ArgoCD**: o job de deploy só gravaria a versão num repositório de estado e o ArgoCD aplicaria;
  o CI não teria credencial de cluster. App-of-apps para centenas de serviços. Depende da Parte 3.
- **Repositórios separados** (app / chart / estado): ciclos de vida e donos diferentes, um pipeline não trava o outro.
  Aqui tudo fica num repo porque o enunciado pede um, mas cortado nesses limites.
- **Vários clusters**: o enunciado fala de dezenas de **nós** (Parte 4), não de clusters. Se existir um cluster por
  regional do DECEA (CINDACTA I–IV, CRCEA-SE), com principal e contingência, a produção iria cluster por cluster.

### Riscos

- **Runner privilegiado** para o dind: um job comprometido tem mais alcance. Para runner compartilhado, BuildKit rootless.
- **Aprovação de environment no GitLab é Premium**: no plano gratuito, a proteção é `when: manual` + tags `v*` e branch
  `develop` protegidas (variáveis protegidas só chegam a refs protegidas).
- **Corrida no push da tag**: a checagem "já existe" antes do push não é atômica; a garantia real é regra de imutabilidade no registry.
- **Rerodar o pipeline de uma tag** falha no build (tag já publicada): para refazer só o deploy, rerodar o job de deploy.

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
| Revisão do PR #2 | Me ajudou a elaborar os trade-offs e fez o trabalho manual. Me guiou num tour arquivo por arquivo | Revisei linha por linha, critiquei os pontos que achei fracos e pedi ajustes. Na revisão apareceram e foram corrigidos: o `ARG VCS_REF` no topo do Dockerfile invalidava o cache a cada commit; o `grep -q` com `pipefail` escondia o token em layers grandes (reproduzido com 50 MB); a IA afirmou que o `docker inspect` mostrava o token (não mostra); a contagem de testes estava errada (14, não 15) |
| Parte 2 | Claude escreveu o plano, os scripts e os pipelines, e testou cada peça (repo descartável, k3d, gitlab-ci-local). O Codex revisou o plano. Um revisor independente (Claude Opus, contexto limpo) achou: Parte 3 decidida cedo demais, ordenação SemVer quebrada a partir de `rc.10`, deploy de tag inexistente, `GIT_DEPTH`. Agentes auxiliares apontaram: chore sem versão nova, pipeline verde sem deploy real, squash merge quebrando a versão | **Tag RC** com versão calculada (ideia minha, no lugar do `git describe`). **Cocogitto** (escolhi por ser binário único; voltei a ele depois de considerar semantic-release). **`make release`** e o carimbo de homologação (ideias minhas; o carimbo ficou como proposta). Rejeitei o monorepo do cog depois do teste mostrar que ele não sobe a versão do app. **Mantive produção manual** depois de rediscutir a leitura do enunciado. Aceitei o contrato mínimo de deploy e levei Helm/ArgoCD para a Parte 3 |
