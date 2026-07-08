#!/bin/bash
set -euo pipefail

# Script executado SOMENTE nos Worker Nodes
# - Faz join no cluster Kubernetes usando o token do control-plane
#
# NOTA: Como o Hyper-V usa DHCP e não temos IPs estáticos,
# este script tenta descobrir o IP do control-plane automaticamente.
# Se não conseguir, será necessário fazer o join manualmente.

echo "============================================"
echo " Configurando Worker Node: $(hostname)"
echo "============================================"

# -------------------------------------------
# 1. Descobrir o Control Plane
# -------------------------------------------
echo ">>> Tentando descobrir o Control Plane na rede..."

# Método 1: Tentar resolver via hostname
CONTROL_PLANE_IP=""

# Tentar pingar o control-plane por hostname (pode funcionar via mDNS ou DNS do Hyper-V)
if ping -c 1 -W 2 control-plane > /dev/null 2>&1; then
  CONTROL_PLANE_IP=$(getent hosts control-plane | awk '{print $1}')
fi

# Método 2: Fazer scan na subnet para encontrar a porta 6443 (API Server)
if [ -z "$CONTROL_PLANE_IP" ]; then
  echo ">>> Hostname não resolveu. Buscando API Server na rede..."

  # Detectar a subnet atual
  MY_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
  SUBNET=$(echo "$MY_IP" | cut -d. -f1-3)

  # Procurar a porta 6443 aberta na subnet
  for i in $(seq 1 254); do
    TARGET="${SUBNET}.${i}"
    if [ "$TARGET" != "$MY_IP" ]; then
      if timeout 1 bash -c "echo > /dev/tcp/${TARGET}/6443" 2>/dev/null; then
        CONTROL_PLANE_IP="$TARGET"
        echo ">>> API Server encontrado em: ${CONTROL_PLANE_IP}"
        break
      fi
    fi
  done
fi

# -------------------------------------------
# 2. Obter comando de join
# -------------------------------------------
if [ -n "$CONTROL_PLANE_IP" ]; then
  echo ">>> Control Plane encontrado: ${CONTROL_PLANE_IP}"

  # Tentar obter o comando de join via SSH (usando a chave do Vagrant)
  JOIN_CMD=""

  # Tentar via SSH com a chave insecure do Vagrant
  VAGRANT_KEY="/home/vagrant/.ssh/authorized_keys"
  if [ -f "/home/vagrant/.ssh/id_rsa" ]; then
    JOIN_CMD=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      -i /home/vagrant/.ssh/id_rsa \
      vagrant@${CONTROL_PLANE_IP} "cat /home/vagrant/join-command.sh" 2>/dev/null || true)
  fi

  # Tentar com sshpass se disponível
  if [ -z "$JOIN_CMD" ]; then
    apt-get install -y -qq sshpass 2>/dev/null || true
    JOIN_CMD=$(sshpass -p 'vagrant' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      vagrant@${CONTROL_PLANE_IP} "cat /home/vagrant/join-command.sh" 2>/dev/null || true)
  fi

  if [ -n "$JOIN_CMD" ]; then
    echo ">>> Executando join no cluster..."
    eval "$JOIN_CMD"
    echo ">>> Worker $(hostname) adicionado ao cluster com sucesso!"
  else
    echo "============================================"
    echo " ATENÇÃO: Não foi possível obter o join command automaticamente."
    echo ""
    echo " Execute manualmente:"
    echo "   1. vagrant ssh control-plane"
    echo "   2. cat /home/vagrant/join-command.sh"
    echo "   3. Copie o comando"
    echo "   4. vagrant ssh $(hostname)"
    echo "   5. sudo <comando-copiado>"
    echo "============================================"
  fi
else
  echo "============================================"
  echo " ATENÇÃO: Control Plane não encontrado na rede."
  echo ""
  echo " Isso é esperado quando o Hyper-V atribui IPs dinâmicos."
  echo ""
  echo " Para fazer o join manualmente:"
  echo "   1. vagrant ssh control-plane"
  echo "   2. cat /home/vagrant/join-command.sh"
  echo "   3. Copie o comando de join"
  echo "   4. vagrant ssh $(hostname)"
  echo "   5. sudo <comando-copiado>"
  echo "============================================"
fi

echo ""
echo ">>> Worker $(hostname) - configuração concluída."
echo ">>> IP: $(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)"
