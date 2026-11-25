#!/usr/bin/env bash
# Sobe/derruba o laboratório de VMs (KVM/libvirt) usado para testar k0s e Ansible.
#
# Uso: ./bootstrap.sh {up|down|destroy|status|inventory|ssh <vm>}
#
# Tudo é idempotente: rodar "up" duas vezes não recria o que já existe.
# Discos ficam no pool do libvirt (vol-create/vol-upload), então não precisa de sudo.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env
source "$HERE/config.env"

CACHE="$HERE/.cache"
KEY="$HERE/.ssh/id_ed25519"
INVENTORY="$HERE/inventory.ini"
VIRSH=(virsh -q -c "$LIBVIRT_URI")

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERRO:\033[0m %s\n' "$*" >&2; exit 1; }

nodes() { echo "$NODES" | awk 'NF==5'; }

need() {
  for c in virsh virt-install qemu-img xorriso curl sha256sum ssh-keygen; do
    command -v "$c" >/dev/null || die "comando '$c' não encontrado"
  done
}

ensure_key() {
  [[ -f "$KEY" ]] && return
  log "gerando chave SSH exclusiva do lab em $KEY"
  mkdir -p "$(dirname "$KEY")"
  ssh-keygen -q -t ed25519 -N '' -C "desafio-lab" -f "$KEY"
}

BRIDGE=$(sed -n "s/.*<bridge name='\([^']*\)'.*/\1/p" "$HERE/libvirt/$NET_NAME.xml")

# Hosts com ufw (ex.: Omarchy) bloqueiam DHCP/DNS/forward em bridges novas;
# sem isso as VMs sobem mas nunca recebem IP.
check_firewall() {
  systemctl is-active -q ufw 2>/dev/null || return 0
  grep -q -- "-i $BRIDGE -j ACCEPT" /etc/ufw/user.rules 2>/dev/null && return 0
  cat >&2 <<EOF
AVISO: ufw ativo e sem regra para a bridge $BRIDGE. As VMs não vão pegar IP.
       Libere uma vez com:
         sudo ufw allow in on $BRIDGE
         sudo ufw route allow in on $BRIDGE
         sudo ufw route allow out on $BRIDGE
EOF
  return 1
}

ensure_network() {
  if ! "${VIRSH[@]}" net-info "$NET_NAME" &>/dev/null; then
    log "definindo rede $NET_NAME"
    "${VIRSH[@]}" net-define "$HERE/libvirt/$NET_NAME.xml" >/dev/null
  fi
  if [[ "$("${VIRSH[@]}" net-info "$NET_NAME" | awk '/^Active:/{print $2}')" != "yes" ]]; then
    log "iniciando rede $NET_NAME"
    "${VIRSH[@]}" net-start "$NET_NAME" >/dev/null
  fi
}

# Envia um arquivo local para um volume do pool (cria o volume se não existir).
upload_vol() {
  local file=$1 vol=$2 fmt=$3
  "${VIRSH[@]}" vol-info "$vol" --pool "$POOL" &>/dev/null && return
  local size; size=$(stat -c %s "$file")
  "${VIRSH[@]}" vol-create-as "$POOL" "$vol" "$size" --format "$fmt" >/dev/null
  "${VIRSH[@]}" vol-upload "$vol" "$file" --pool "$POOL"
}

ensure_base_image() {
  "${VIRSH[@]}" vol-info "$BASE_VOL" --pool "$POOL" &>/dev/null && return
  mkdir -p "$CACHE"
  local img; img="$CACHE/$(basename "$IMG_URL")"
  if [[ ! -f "$img" ]]; then
    log "baixando $(basename "$img")"
    curl -fL --progress-bar -o "$img.part" "$IMG_URL"
    mv "$img.part" "$img"
  fi
  log "conferindo SHA256"
  curl -fsSL "$IMG_SUMS_URL" | grep " \*\?$(basename "$img")\$" | sed 's/\*//' \
    | (cd "$CACHE" && sha256sum -c -) || die "checksum não confere; apague $img e rode de novo"
  log "enviando imagem base para o pool $POOL"
  upload_vol "$img" "$BASE_VOL" qcow2
}

make_seed() {
  local name=$1 dir="$CACHE/seed-$1"
  mkdir -p "$dir"
  sed -e "s|__HOSTNAME__|$name|g" \
      -e "s|__BOOT_USER__|$BOOT_USER|g" \
      -e "s|__SSH_PUBKEY__|$(cat "$KEY.pub")|g" \
      "$HERE/cloud-init/user-data.tpl" > "$dir/user-data"
  printf 'instance-id: %s\nlocal-hostname: %s\n' "$name" "$name" > "$dir/meta-data"
  xorriso -as mkisofs -quiet -V cidata -J -r -o "$dir/seed.iso" "$dir/user-data" "$dir/meta-data" 2>/dev/null
  echo "$dir/seed.iso"
}

create_vm() {
  local name=$1 cpus=$2 ram=$3 mac=$4
  if "${VIRSH[@]}" dominfo "$name" &>/dev/null; then
    log "$name já existe; garantindo que está ligada"
    [[ "$("${VIRSH[@]}" domstate "$name")" == "running" ]] || "${VIRSH[@]}" start "$name" >/dev/null
    return
  fi
  log "criando $name ($cpus vCPU, ${ram} MiB, $DISK_SIZE)"
  "${VIRSH[@]}" vol-create-as "$POOL" "$name.qcow2" "$DISK_SIZE" --format qcow2 \
    --backing-vol "$BASE_VOL" --backing-vol-format qcow2 >/dev/null
  upload_vol "$(make_seed "$name")" "$name-seed.iso" raw

  virt-install --connect "$LIBVIRT_URI" --noautoconsole --quiet \
    --name "$name" --vcpus "$cpus" --memory "$ram" \
    --osinfo ubuntu24.04 --import \
    --disk "vol=$POOL/$name.qcow2,bus=virtio" \
    --disk "vol=$POOL/$name-seed.iso,device=cdrom" \
    --network "network=$NET_NAME,mac=$mac,model=virtio" \
    --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
    --graphics none --console pty,target.type=serial
}

wait_ssh() {
  local name=$1 ip=$2
  printf '    aguardando SSH em %s (%s) ' "$name" "$ip"
  for _ in $(seq 1 90); do
    if ssh -n "${SSH_OPTS[@]}" "$BOOT_USER@$ip" 'cloud-init status --wait >/dev/null 2>&1; true' 2>/dev/null; then
      echo ok; return
    fi
    printf '.'; sleep 2
  done
  echo; die "$name não respondeu por SSH"
}

SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=3 -o BatchMode=yes)

write_inventory() {
  {
    echo "# Gerado por bootstrap/bootstrap.sh — não editar à mão."
    echo "[controllers]"
    nodes | awk '$1 ~ /-cp[0-9]+$/ {print $1" ansible_host="$5}'
    echo
    echo "[workers]"
    nodes | awk '$1 ~ /-w[0-9]+$/ {print $1" ansible_host="$5}'
    echo
    echo "[all:vars]"
    echo "ansible_user=$BOOT_USER"
    echo "ansible_ssh_private_key_file=$KEY"
    echo "ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'"
  } > "$INVENTORY"
  log "inventário escrito em $INVENTORY"
}

cmd_up() {
  need; check_firewall || die "ajuste o firewall e rode de novo"
  ensure_key; ensure_network; ensure_base_image
  while read -r name cpus ram mac _; do create_vm "$name" "$cpus" "$ram" "$mac"; done < <(nodes)
  while read -r name _ _ _ ip; do wait_ssh "$name" "$ip"; done < <(nodes)
  write_inventory
  cmd_status
}

cmd_down() {
  while read -r name _; do
    [[ "$("${VIRSH[@]}" domstate "$name" 2>/dev/null)" == "running" ]] || continue
    log "desligando $name"; "${VIRSH[@]}" shutdown "$name" >/dev/null
  done < <(nodes)
}

cmd_destroy() {
  while read -r name _; do
    if "${VIRSH[@]}" dominfo "$name" &>/dev/null; then
      log "removendo $name"
      "${VIRSH[@]}" destroy "$name" &>/dev/null || true
      "${VIRSH[@]}" undefine "$name" --nvram &>/dev/null || "${VIRSH[@]}" undefine "$name" >/dev/null
    fi
    for v in "$name.qcow2" "$name-seed.iso"; do
      "${VIRSH[@]}" vol-delete "$v" --pool "$POOL" &>/dev/null || true
    done
    rm -rf "$CACHE/seed-$name"
  done < <(nodes)
  if "${VIRSH[@]}" net-info "$NET_NAME" &>/dev/null; then
    log "removendo rede $NET_NAME"
    "${VIRSH[@]}" net-destroy "$NET_NAME" &>/dev/null || true
    "${VIRSH[@]}" net-undefine "$NET_NAME" >/dev/null
  fi
  rm -f "$INVENTORY"
  log "imagem base ($BASE_VOL) mantida no pool; para apagar: virsh vol-delete $BASE_VOL --pool $POOL"
}

cmd_status() {
  printf '%-14s %-10s %s\n' VM ESTADO IP
  while read -r name _ _ _ ip; do
    printf '%-14s %-10s %s\n' "$name" "$("${VIRSH[@]}" domstate "$name" 2>/dev/null || echo ausente)" "$ip"
  done < <(nodes)
}

cmd_ssh() {
  local target=${1:?informe a VM, ex: desafio-cp1}; shift || true
  local ip; ip=$(nodes | awk -v n="$target" '$1==n {print $5}')
  [[ -n "$ip" ]] || die "VM '$target' não está em config.env"
  exec ssh "${SSH_OPTS[@]/BatchMode=yes/BatchMode=no}" "$BOOT_USER@$ip" "$@"
}

case "${1:-}" in
  up) cmd_up ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  status) cmd_status ;;
  inventory) write_inventory ;;
  ssh) shift; cmd_ssh "$@" ;;
  *) echo "uso: $0 {up|down|destroy|status|inventory|ssh <vm> [cmd]}"; exit 1 ;;
esac
