#!/bin/bash
set -euo pipefail

# =============================================================================
# fix-dhcp-identity.sh
# =============================================================================
# Script MÍNIMO executado ANTES do vagrant-reload.
# Objetivo: configurar IP ESTÁTICO na interface de management (eth0) para que
# cada VM tenha um IP único desde o primeiro boot após reload.
#
# Problema original: linked clones herdam o mesmo /etc/machine-id → DUID idêntico
# → DHCP server entrega o mesmo IP para todas as VMs, independente do MAC.
#
# Solução: abandonar DHCP na eth0 e usar IP estático (definido no Vagrantfile).
# Isso elimina a dependência do DHCP server e garante IPs únicos deterministicamente.
#
# Argumentos:
#   $1 = IP estático da interface de management (ex: 192.168.15.11)
#   $2 = Máscara de rede (ex: 24)
#   $3 = Gateway (ex: 192.168.15.1)
#   $4 = DNS servers (ex: 8.8.8.8,8.8.4.4)
# =============================================================================

MGMT_IP="${1:-}"
MGMT_NETMASK="${2:-24}"
MGMT_GATEWAY="${3:-}"
MGMT_DNS="${4:-8.8.8.8,8.8.4.4}"

if [ -z "$MGMT_IP" ] || [ -z "$MGMT_GATEWAY" ]; then
  echo "ERRO: MGMT_IP e MGMT_GATEWAY são obrigatórios."
  echo "Uso: $0 <ip> <mask> <gateway> <dns>"
  exit 1
fi

echo "============================================"
echo " Configurando IP estático de management"
echo " VM: $(hostname)"
echo " IP: ${MGMT_IP}/${MGMT_NETMASK}"
echo " GW: ${MGMT_GATEWAY}"
echo " DNS: ${MGMT_DNS}"
echo "============================================"

# --- Detectar interface de management (a que tem IP DHCP atribuído) ---
MGMT_IFACE=""
for iface in $(ls /sys/class/net/ | grep -v lo | sort); do
  if ip -4 addr show "$iface" 2>/dev/null | grep -q "inet "; then
    MGMT_IFACE="$iface"
    break
  fi
done
MGMT_IFACE="${MGMT_IFACE:-eth0}"

# --- Capturar o MAC da NIC de management ---
# O netplan vai casar por MAC (não por nome). Em linked clones no Hyper-V a
# ordem de enumeração das NICs pode inverter após o vagrant-reload; casando por
# MAC o IP estático segue SEMPRE a placa do LOCAL_NETWORK, independente de o
# kernel chamá-la de eth0 ou eth1.
MGMT_MAC="$(cat /sys/class/net/${MGMT_IFACE}/address 2>/dev/null || true)"
MGMT_MAC="$(echo "$MGMT_MAC" | tr 'A-Z' 'a-z')"

echo ">>> Interface de management detectada: ${MGMT_IFACE}"
echo ">>> MAC: ${MGMT_MAC:-N/A}"

if [ -z "$MGMT_MAC" ]; then
  echo "ERRO: não foi possível determinar o MAC da interface ${MGMT_IFACE}."
  exit 1
fi

# --- Regenerar machine-id (para boa prática, evita outros problemas) ---
if [ ! -f /etc/machine-id.vagrant-regen ]; then
  echo ">>> Regenerando machine-id..."
  OLD_ID=$(cat /etc/machine-id 2>/dev/null || echo "vazio")
  : > /etc/machine-id
  rm -f /var/lib/dbus/machine-id
  systemd-machine-id-setup 2>/dev/null || true
  ln -sf /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true
  touch /etc/machine-id.vagrant-regen
  echo "    antigo: ${OLD_ID}"
  echo "    novo:   $(cat /etc/machine-id)"
fi

# --- Remover TODOS os netplan configs da box ---
echo ">>> Removendo netplan configs da box..."
for f in /etc/netplan/*.yaml; do
  [ -f "$f" ] || continue
  echo "    rm $f"
  rm -f "$f"
done

# --- Desabilitar cloud-init network ---
if [ -d /etc/cloud/cloud.cfg.d ]; then
  echo ">>> Desabilitando cloud-init network config..."
  echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
fi

# --- Converter lista de DNS para formato YAML ---
DNS_YAML=""
IFS=',' read -ra DNS_ARRAY <<< "$MGMT_DNS"
for dns in "${DNS_ARRAY[@]}"; do
  DNS_YAML="${DNS_YAML}
          - ${dns}"
done

# --- Criar netplan com IP estático na interface de management ---
# Casamos por MAC (match.macaddress) em vez de por nome de interface. Assim o IP
# estático adere à NIC física do LOCAL_NETWORK mesmo que o kernel reordene os
# nomes eth0/eth1 no boot seguinte ao vagrant-reload. A chave 'mgmt0' é apenas
# um identificador lógico; 'set-name' garante um nome estável para o common.sh.
echo ">>> Criando netplan (match por MAC ${MGMT_MAC}) com IP estático ${MGMT_IP}/${MGMT_NETMASK}..."
cat <<EOF > /etc/netplan/98-mgmt-static.yaml
network:
  version: 2
  ethernets:
    mgmt0:
      match:
        macaddress: ${MGMT_MAC}
      set-name: mgmt0
      dhcp4: false
      addresses:
        - ${MGMT_IP}/${MGMT_NETMASK}
      routes:
        - to: default
          via: ${MGMT_GATEWAY}
      nameservers:
        addresses:${DNS_YAML}
EOF
chmod 600 /etc/netplan/98-mgmt-static.yaml

echo ">>> Netplan criado: /etc/netplan/98-mgmt-static.yaml"
echo ">>> Conteúdo:"
cat /etc/netplan/98-mgmt-static.yaml

# --- Limpar leases DHCP antigas ---
echo ">>> Limpando leases DHCP..."
rm -f /var/lib/dhcp/dhclient*.leases 2>/dev/null || true
rm -f /run/systemd/netif/leases/* 2>/dev/null || true
rm -f /var/lib/NetworkManager/*.lease 2>/dev/null || true

# --- Aplicar netplan imediatamente (IP estático ativo antes do reboot) ---
echo ">>> Aplicando netplan (IP estático ativo agora)..."
netplan apply 2>/dev/null || true
sleep 2

echo ""
echo "============================================"
echo " Pronto. Após reboot (vagrant-reload):"
echo "   a NIC ${MGMT_MAC} vira 'mgmt0' com IP ${MGMT_IP} (estático)"
echo "   IP casado por MAC (imune à reordenação eth0/eth1)"
echo "   Sem dependência de DHCP"
echo "============================================"
