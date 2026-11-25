#cloud-config
# Mínimo necessário para o Ansible conseguir entrar. Nada de k0s/hardening aqui:
# isso é responsabilidade do playbook (Parte 4), para que ele seja testável
# contra um Ubuntu "cru", como seria um servidor recém-entregue.
hostname: __HOSTNAME__
fqdn: __HOSTNAME__.desafio.local
manage_etc_hosts: true

users:
  - name: __BOOT_USER__
    gecos: Usuario temporario de bootstrap
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - __SSH_PUBKEY__

# Baseline propositalmente INSEGURO: a imagem oficial já vem com senha desligada,
# o que tornaria o teste da Parte 4 inútil (passaria sem o playbook fazer nada).
# Aqui simulamos um servidor "como entregue", com senha e root liberados no SSH.
# O sshd usa o PRIMEIRO valor que encontra e lê sshd_config.d em ordem
# alfabética, por isso "01-" vence o 60-cloudimg-settings.conf da imagem.
write_files:
  - path: /etc/ssh/sshd_config.d/01-lab-baseline-inseguro.conf
    permissions: "0644"
    content: |
      # Criado pelo bootstrap do lab. O playbook da Parte 4 deve neutralizar isto.
      PasswordAuthentication yes
      KbdInteractiveAuthentication yes
      PermitRootLogin yes

package_update: false
packages:
  - qemu-guest-agent
runcmd:
  - [systemctl, enable, --now, qemu-guest-agent]
  - [systemctl, try-reload-or-restart, ssh]
