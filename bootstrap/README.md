# bootstrap — laboratório local com VMs

Sobe 3 VMs Ubuntu 24.04 (KVM/libvirt) para testar o cluster k0s e o playbook Ansible
num ambiente parecido com servidores reais, e não em contêineres.

| VM           | papel previsto | IP             |
|--------------|----------------|----------------|
| desafio-cp1  | controller k0s | 192.168.150.11 |
| desafio-w1   | worker         | 192.168.150.21 |
| desafio-w2   | worker         | 192.168.150.22 |

## Requisitos

`libvirt` (`qemu:///system`, usuário no grupo `libvirt`), `virt-install`, `qemu-img`, `xorriso`, `curl`.
Não precisa de sudo: os discos são criados no pool `default` via `virsh vol-*`.

Se o host usa **ufw**, libere a bridge do lab uma vez (o script avisa se faltar):

```sh
sudo ufw allow in on virbr-desafio
sudo ufw route allow in on virbr-desafio
sudo ufw route allow out on virbr-desafio
```

## Uso

```sh
make up        # rede + imagem base + VMs; espera SSH/cloud-init e gera inventory.ini
make status
make ssh VM=desafio-cp1
make down      # desliga
make destroy   # apaga VMs, discos e rede (mantém a imagem base no pool)
```

Tudo é idempotente: `make up` de novo não recria nada que já existe.

## Como verificar

```sh
ansible -i inventory.ini all -m ping

# baseline inseguro do SSH (antes da Parte 4): espera-se "yes" nas três linhas
ansible -i inventory.ini all -b -m shell \
  -a 'sshd -T | grep -E "^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin) "'
```

## Decisões

- **Ubuntu "cru":** o cloud-init só cria o usuário temporário `bootstrap` com chave SSH.
  Usuário de operação, endurecimento do SSH e k0s são papel do playbook (Parte 4), para que ele
  seja testado contra um servidor recém-entregue.
- **Baseline de SSH propositalmente inseguro:** a imagem oficial do Ubuntu já vem com login por
  senha desligado, então um teste do playbook passaria mesmo sem ele fazer nada. O cloud-init grava
  `/etc/ssh/sshd_config.d/01-lab-baseline-inseguro.conf` ligando senha, keyboard-interactive e root.
  O `01-` importa: o sshd usa o **primeiro** valor que lê e percorre `sshd_config.d` em ordem
  alfabética, então esse arquivo vence o `60-cloudimg-settings.conf` da imagem. O playbook da
  Parte 4 precisa levar isso em conta (um arquivo com nome "maior" seria ignorado em silêncio).
- **Rede própria** (`desafio-net`, NAT, `192.168.150.0/24`) com IP fixo por MAC: inventário
  previsível e sem mexer na rede `default` do libvirt.
- **Overlay qcow2** sobre uma imagem base única: cada VM nasce em segundos e ocupa pouco disco.
- **Chave SSH exclusiva do lab** (`.ssh/`, fora do git). Nenhuma chave pessoal é injetada.
- **Shell + virt-install em vez de Terraform/Vagrant:** menos dependências e cada linha é explicável.

## Fora do escopo (por enquanto)

Simular a rede restrita do enunciado (proxy HTTP + mirror de registry). Dá para fazer com uma
4ª VM rodando squid + `registry:2` como pull-through cache e bloquear a saída direta da `desafio-net`.
