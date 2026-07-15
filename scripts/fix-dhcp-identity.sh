#!/bin/bash
set -euo pipefail

# =============================================================================
# fix-dhcp-identity.sh
# =============================================================================
# Executado ANTES do vagrant-reload.
# Objetivo: garantir que cada VM obtenha um IP de management ÚNICO via DHCP.
#
# Problema original: linked clones herdam o mesmo /etc/machine-id -> DUID
# idêntico -> o servidor DHCP entrega o MESMO IP para todas as VMs.
#
# Solução (SEM IP estático):
#   1. Regenerar /etc/machine-id  -> identidade única por VM.
#   2. Configurar o cliente DHCP para se identificar pelo MAC
#      (dhcp-identifier: mac), que já é único por NIC, em vez do DUID
#      derivado do machine-id.
#
# Por que não IP estático na eth0:
#   A rede de management (LOCAL_NETWORK) é a LAN física real, com pool de DHCP
#   ativo e dispositivos existentes. IPs estáticos ali colidem com equipamentos
#   da rede e com o pool. Com machine-id único + dhcp-identifier: mac, o DHCP já
#   entrega IPs distintos e sem conflito.
#
# NOTA: a eth1 (rede de cluster, K8sSwitch) continua ESTÁTICA, definida no
# common.sh. Aqui tratamos apenas a eth0 (management/LOCAL_NETWORK).
#
# Argumentos: ignorados (mantidos por compatibilidade com o Vagrantfile, que
# ainda passa ip/mask/gw/dns do modelo estático antigo).
# =============================================================================

echo "============================================"
echo " Garantindo identidade DHCP única (management)"
echo " VM: $(hostname)"
echo "============================================"

# --- Detectar a NIC de management (a que já tem IP via DHCP) ---
MGMT_IFACE=""
for iface in $(ls /sys/class/net/ | grep -v lo | sort); do
  if ip -4 addr show "$iface" 2>/dev/null | grep -q "inet "; then
    MGMT_IFACE="$iface"
    break
  fi
done
MGMT_IFACE="${MGMT_IFACE:-eth0}"

# --- Capturar o MAC da NIC de management ---
# O netplan casa por MAC (não por nome): em linked clones no Hyper-V a ordem de
# enumeração eth0/eth1 pode inverter após o reload; casando por MAC o DHCP roda
# sempre na placa do LOCAL_NETWORK.
MGMT_MAC="$(cat /sys/class/net/${MGMT_IFACE}/address 2>/dev/null | tr 'A-Z' 'a-z' || true)"

echo ">>> Interface de management detectada: ${MGMT_IFACE} (MAC ${MGMT_MAC:-N/A})"

if [ -z "$MGMT_MAC" ]; then
  echo "ERRO: não foi possível determinar o MAC da interface ${MGMT_IFACE}."
  exit 1
fi

# --- Regenerar machine-id (identidade única por VM) ---
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
# Sem isso, o cloud-init regenera um netplan DHCP SEM dhcp-identifier: mac no
# próximo boot, reintroduzindo a colisão de DUID.
if [ -d /etc/cloud/cloud.cfg.d ]; then
  echo ">>> Desabilitando cloud-init network config..."
  echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
fi

# --- Criar netplan: DHCP na NIC de management, identificado por MAC ---
# Nome do arquivo mantido como '98-mgmt-static.yaml' por compatibilidade com as
# verificações/detecção do common.sh (embora agora seja DHCP, não estático).
echo ">>> Criando netplan DHCP (dhcp-identifier: mac) casando o MAC ${MGMT_MAC}..."
cat <<EOF > /etc/netplan/98-mgmt-static.yaml
network:
  version: 2
  ethernets:
    mgmt0:
      match:
        macaddress: ${MGMT_MAC}
      dhcp4: true
      dhcp-identifier: mac
EOF
chmod 600 /etc/netplan/98-mgmt-static.yaml

echo ">>> Netplan criado: /etc/netplan/98-mgmt-static.yaml"
echo ">>> Conteúdo:"
cat /etc/netplan/98-mgmt-static.yaml

# --- Limpar leases DHCP antigas (força novo lease com a nova identidade) ---
echo ">>> Limpando leases DHCP..."
rm -f /var/lib/dhcp/dhclient*.leases 2>/dev/null || true
rm -f /run/systemd/netif/leases/* 2>/dev/null || true
rm -f /var/lib/NetworkManager/*.lease 2>/dev/null || true

# --- Aplicar netplan imediatamente ---
echo ">>> Aplicando netplan..."
netplan apply 2>/dev/null || true
sleep 2

echo ""
echo "============================================"
echo " Pronto. Após reboot (vagrant-reload):"
echo "   management via DHCP identificado por MAC -> IP único por VM"
echo "   (sem colisão com IP estático ou com a LAN física)"
echo "   eth1 (cluster) permanece estático via common.sh"
echo "============================================"
