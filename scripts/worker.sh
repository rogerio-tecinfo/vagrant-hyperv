#!/bin/bash
set -euo pipefail

# Script executado SOMENTE nos Worker Nodes
# - Faz join no cluster Kubernetes usando o token do control-plane
#
# IDEMPOTENTE: verifica se já fez join antes de tentar novamente
#
# Estratégia de descoberta do Control Plane:
# 1. Resolve hostname "control-plane"
# 2. IP via rota padrão (gateway adjacente)
# 3. Scan na porta 6443 (IPs próximos primeiro)
# 4. Se nenhum funcionar, exibe instruções para join manual

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
  if [ -n "$CONTROL_PLANE_IP" ]; then
    echo ">>> Resolvido via hostname: ${CONTROL_PLANE_IP}"
  fi
fi

# Método 2: Scan otimizado na porta 6443 (IPs próximos primeiro)
if [ -z "$CONTROL_PLANE_IP" ]; then
  echo ">>> Hostname não resolveu. Buscando API Server (porta 6443)..."

  MY_IP=$(ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || \
          ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\d+(\.\d+){3}' | head -1)
  SUBNET=$(echo "$MY_IP" | cut -d. -f1-3)
  MY_LAST_OCTET=$(echo "$MY_IP" | cut -d. -f4)

  # Scan inteligente: começa pelos IPs próximos ao worker (geralmente o control-plane
  # está com IP menor, pois foi criado antes)
  SCAN_ORDER=""
  for offset in $(seq 1 20); do
    lower=$((MY_LAST_OCTET - offset))
    upper=$((MY_LAST_OCTET + offset))
    [ "$lower" -ge 1 ] && SCAN_ORDER="$SCAN_ORDER $lower"
    [ "$upper" -le 254 ] && [ "$upper" -ne "$MY_LAST_OCTET" ] && SCAN_ORDER="$SCAN_ORDER $upper"
  done
  # Adicionar o restante
  for i in $(seq 1 254); do
    [ "$i" -eq "$MY_LAST_OCTET" ] && continue
    echo "$SCAN_ORDER" | grep -qw "$i" 2>/dev/null || SCAN_ORDER="$SCAN_ORDER $i"
  done

  for i in $SCAN_ORDER; do
    TARGET="${SUBNET}.${i}"
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

# Instalar sshpass temporariamente para obter o join command
SSHPASS_INSTALLED=false
if ! command -v sshpass &> /dev/null; then
  apt-get install -y -qq sshpass > /dev/null 2>&1 && SSHPASS_INSTALLED=true
fi

if command -v sshpass &> /dev/null; then
  JOIN_CMD=$(sshpass -p 'vagrant' ssh \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=5 \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    vagrant@${CONTROL_PLANE_IP} "cat /home/vagrant/join-command.sh" 2>/dev/null || true)
fi

# Remover sshpass se foi instalado apenas para este script
if [ "$SSHPASS_INSTALLED" = true ]; then
  apt-get remove -y -qq sshpass > /dev/null 2>&1 || true
fi

# Validar formato do join command antes de executar
if [ -n "$JOIN_CMD" ] && echo "$JOIN_CMD" | grep -qP '^kubeadm join \d+\.\d+\.\d+\.\d+:\d+ --token \S+ --discovery-token-ca-cert-hash sha256:\S+$'; then
  echo ">>> Join command válido. Executando join..."
  $JOIN_CMD --ignore-preflight-errors=Mem

  echo ""
  echo "============================================"
  echo " Worker $(hostname) adicionado ao cluster!"
  echo "============================================"
elif [ -n "$JOIN_CMD" ]; then
  echo "============================================"
  echo " ERRO: Join command com formato inesperado. Abortando por segurança."
  echo " Conteúdo recebido: ${JOIN_CMD}"
  echo ""
  echo " Join manual necessário:"
  echo "   1. vagrant ssh control-plane -c \"cat /home/vagrant/join-command.sh\""
  echo "   2. vagrant ssh $(hostname) -c \"sudo <comando-copiado>\""
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
echo ">>> Worker $(hostname) - IP: $(ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo 'N/A')"
