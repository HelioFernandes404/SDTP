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

package_update: false
packages:
  - qemu-guest-agent
runcmd:
  - [systemctl, enable, --now, qemu-guest-agent]
