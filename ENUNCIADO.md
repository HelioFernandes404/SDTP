# Desafio prático — DevOps Pleno (ATD/DECEA)

Obrigado por seguir no processo. O desafio leva **até 4 horas** de trabalho, e você tem **5 dias corridos** para entregar.
Não esperamos tudo perfeito. Esperamos ver **como você decide**, **como verifica** e **como explica**.

## Contexto

Nosso time mantém uma plataforma com centenas de serviços que hoje rodam em **Docker Swarm**.
Estamos migrando esses serviços aos poucos para **Kubernetes on-premise (k0s)**.
A rede é restrita: o acesso à internet passa por NAT e proxy, e as imagens públicas vêm de um mirror de registry.

Neste pacote você recebe:

- `app/app.py`: um contador de visitas em Python, que usa só a biblioteca padrão;
- `docker-stack.yml`: a stack como ela roda hoje no Swarm de produção.

## O que entregar

Um repositório Git público (GitLab ou GitHub) com o que está abaixo. Mande o link por e-mail.

### Parte 1 — Imagem (≈ 30 min)

Escreva um `Dockerfile` para a aplicação.

- A imagem final deve rodar como usuário **não-root**.
- A imagem base deve vir de um registry configurável por *build arg*, porque aqui usamos mirror. O padrão pode ser o Docker Hub.
- O segredo `API_TOKEN` **não** pode ficar na imagem. Na stack atual, o entrypoint lê o token de `/run/secrets/api_token`; reproduza esse comportamento.

### Parte 2 — Pipeline (≈ 45 min)

Escreva um `.gitlab-ci.yml` com, no mínimo:

1. um estágio de **build** e **push** da imagem, com tag rastreável até o commit;
2. um estágio de **deploy em homologação**, automático a partir da branch `develop`;
3. um estágio de **deploy em produção**, **manual**, a partir de uma tag.

Você não precisa ter um cluster real para o pipeline. Os jobs de deploy podem rodar `kubectl` contra um contexto definido por variável de CI.
O que avaliamos é a estrutura, e não se o pipeline passou.
Se usar o GitHub, entregue o `.gitlab-ci.yml` mesmo assim; um workflow do GitHub Actions equivalente pode ir junto.

### Parte 3 — Migração da stack para Kubernetes (≈ 1h30)

Converta o `docker-stack.yml` para manifests Kubernetes (YAML puro, Kustomize ou Helm, como preferir).
Todo comportamento da stack deve ter um equivalente no Kubernetes, ou uma justificativa de por que não tem.

- Use um **Ingress** com o host `contador.exemplo.local` e TLS.
- Rode tudo num cluster local (k0s, k3s, kind, minikube ou k3d) e **mostre que funciona**: saída de comandos, prints ou um `make verify`.

### Parte 4 — Preparação do host com Ansible (≈ 45 min)

Escreva um playbook que prepare um servidor **Ubuntu 22.04 ou 24.04** para virar nó do cluster:

- crie um usuário de operação com chave SSH e `sudo`;
- desabilite login SSH por senha e por root;
- instale e deixe em execução o que o nó precisa, do jeito que você escolher (container runtime, k0s ou k3s, sysctl, módulos do kernel);
- o playbook deve ser **idempotente**;
- o inventário terá dezenas de nós. Mostre como você aplicaria primeiro em **um** nó, verificaria, e só depois seguiria para o resto.

Você pode testar num contêiner ou numa VM, mas não é obrigatório. Diga no README se testou e como.

### README (obrigatório, ≈ 30 min)

O README vale tanto quanto o código. Ele deve ter:

1. **Como rodar e como verificar** cada parte, com comandos.
2. **Decisões e trade-offs**: o que você escolheu e por quê, principalmente na Parte 3.
3. **O que ficou de fora** e o que você faria com mais tempo.
4. **Riscos** que você enxerga ao fazer essa migração em produção, com dezenas de serviços parecidos.
5. **Uso de IA**: pode usar assistentes de IA à vontade. Diga quais usou, em que partes, e o que você corrigiu ou rejeitou do que eles sugeriram. Isso não tira ponto; esconder tira.

## Regras

- Não coloque segredos reais no repositório. Use valores de exemplo e diga como seriam injetados de verdade.
- Commits pequenos, com mensagens claras. O histórico também é avaliado.
- Na entrevista técnica, vamos abrir o seu repositório e conversar sobre ele por uns 30 minutos.
  Esteja pronto para explicar qualquer linha.

Dúvidas sobre o enunciado: responda o e-mail que trouxe este pacote. Se algo estiver ambíguo, você também pode decidir sozinho e registrar a premissa no README.
