#!/bin/bash
set -euo pipefail

# Script executado SOMENTE nos Worker Nodes
# - Faz join no cluster Kubernetes usando o token do control-plane
#
# IDEMPOTENTE: verifica se já fez join antes de tentar novamente
#
# Estratégia de descoberta do Control Plane:
# 1. Resolve hostname "control-plane"
# 2. Scan na porta 6443 da subnet
# 3. Se nenhum funcionar, exibe instruções para join manual

echo "============================================"
echo " Configurando Worker Node: $(hostname)"
echo "============================================"

# -------------------------------------------
# 0. Verificar se já fez join
# -------------------------------------------
if [ -f /etc/kubernetes/kubelet.conf ]; then
  echo ">>> Este node já fez join no cluster. Pulando..."
  echo ">>> Para refazer o join, execute primeiro: sudo kubeadm reset -f"
  exit 0
fi

# -------------------------------------------
# 1. Descobrir o Control Plane
# -------------------------------------------
echo ">>> Descobrindo o Control Plane na rede..."

CONTROL_PLANE_IP=""

# Método 1: Resolver hostname
if ping -c 1 -W 2 control-plane > /dev/null 2>&1; then
  CONTROL_PLANE_IP=$(getent hosts control-plane | awk '{print $1}')
  echo ">>> Resolvido via hostname: ${CONTROL_PLANE_IP}"
fi

# Método 2: Scan na porta 6443
if [ -z "$CONTROL_PLANE_IP" ]; then
  echo ">>> Hostname não resolveu. Buscando API Server (porta 6443)..."

  MY_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
  SUBNET=$(echo "$MY_IP" | cut -d. -f1-3)

  for i in $(seq 1 254); do
    TARGET="${SUBNET}.${i}"
    [ "$TARGET" = "$MY_IP" ] && continue

    if timeout 1 bash -c "echo > /dev/tcp/${TARGET}/6443" 2>/dev/null; then
      CONTROL_PLANE_IP="$TARGET"
      echo ">>> API Server encontrado: ${CONTROL_PLANE_IP}"
      break
    fi
  done
fi

# -------------------------------------------
# 2. Fazer join no cluster
# -------------------------------------------
if [ -z "$CONTROL_PLANE_IP" ]; then
  echo "============================================"
  echo " ATENÇÃO: Control Plane não encontrado."
  echo ""
  echo " Join manual necessário:"
  echo "   1. vagrant ssh control-plane -c \"cat /home/vagrant/join-command.sh\""
  echo "   2. vagrant ssh $(hostname) -c \"sudo <comando-copiado>\""
  echo "============================================"
  exit 0
fi

echo ">>> Control Plane: ${CONTROL_PLANE_IP}"
echo ">>> Obtendo join command..."

JOIN_CMD=""

# Tentar SSH com senha padrão do Vagrant
if command -v sshpass &> /dev/null || apt-get install -y -qq sshpass > /dev/null 2>&1; then
  JOIN_CMD=$(sshpass -p 'vagrant' ssh \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=5 \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    vagrant@${CONTROL_PLANE_IP} "cat /home/vagrant/join-command.sh" 2>/dev/null || true)
fi

if [ -n "$JOIN_CMD" ] && echo "$JOIN_CMD" | grep -q "kubeadm join"; then
  echo ">>> Join command obtido. Executando join..."
  eval "sudo $JOIN_CMD --ignore-preflight-errors=Mem"

  echo ""
  echo "============================================"
  echo " Worker $(hostname) adicionado ao cluster!"
  echo "============================================"
else
  echo "============================================"
  echo " ATENÇÃO: Não foi possível obter o join command via SSH."
  echo ""
  echo " Join manual necessário:"
  echo "   1. vagrant ssh control-plane -c \"cat /home/vagrant/join-command.sh\""
  echo "   2. vagrant ssh $(hostname) -c \"sudo <comando-copiado>\""
  echo "============================================"
fi

echo ""
echo ">>> Worker $(hostname) - IP: $(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)"
