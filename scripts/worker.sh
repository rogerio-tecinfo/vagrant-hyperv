#!/bin/bash
set -euo pipefail

# Script executado SOMENTE nos Worker Nodes
# - Faz join no cluster Kubernetes usando IP fixo do control-plane + token fixo
#
# IDEMPOTENTE: verifica se já fez join antes de tentar novamente
#
# Com IPs fixos no switch interno (K8sSwitch) e token de bootstrap fixo,
# o join é determinístico: NÃO há mais port-scan de rede nem sshpass.

CONTROL_PLANE_IP="${1:-}"   # IP fixo do control-plane (plano de cluster / eth1)
JOIN_TOKEN="${2:-}"          # token de bootstrap fixo (lab)
API_PORT="6443"

echo "============================================"
echo " Configurando Worker Node: $(hostname)"
echo " Control Plane: ${CONTROL_PLANE_IP:-<none>}:${API_PORT}"
echo "============================================"

# -------------------------------------------
# 0. Verificar se já fez join
# -------------------------------------------
if [ -f /etc/kubernetes/kubelet.conf ]; then
  echo ">>> Este node já fez join no cluster. Pulando..."
  echo ">>> Para refazer o join, execute primeiro: sudo kubeadm reset -f"
  exit 0
fi

if [ -z "$CONTROL_PLANE_IP" ] || [ -z "$JOIN_TOKEN" ]; then
  echo "ERRO: CONTROL_PLANE_IP e JOIN_TOKEN são obrigatórios (definidos no Vagrantfile)."
  exit 1
fi

# -------------------------------------------
# 1. Aguardar o API Server do control-plane ficar acessível
# -------------------------------------------
echo ">>> Aguardando API Server em ${CONTROL_PLANE_IP}:${API_PORT}..."
API_READY=false
for attempt in $(seq 1 30); do
  if timeout 2 bash -c "echo > /dev/tcp/${CONTROL_PLANE_IP}/${API_PORT}" 2>/dev/null; then
    API_READY=true
    echo ">>> API Server acessível (tentativa ${attempt})."
    break
  fi
  sleep 10
done

if [ "$API_READY" = false ]; then
  echo "============================================"
  echo " ATENÇÃO: API Server não respondeu em ${CONTROL_PLANE_IP}:${API_PORT}."
  echo " Verifique se o control-plane subiu e se a NIC eth1 (K8sSwitch) está ativa."
  echo "============================================"
  exit 1
fi

# -------------------------------------------
# 2. Fazer join no cluster (token fixo, CA hash via token discovery)
# -------------------------------------------
# --discovery-token-unsafe-skip-ca-verification: aceitável em LAB isolado
# (switch interno). Remove a necessidade do CA hash e de SSH ao control-plane.
echo ">>> Executando kubeadm join..."
kubeadm join "${CONTROL_PLANE_IP}:${API_PORT}" \
  --token "${JOIN_TOKEN}" \
  --discovery-token-unsafe-skip-ca-verification \
  --ignore-preflight-errors=Mem

echo ""
echo "============================================"
echo " Worker $(hostname) adicionado ao cluster!"
echo " IP (plano de cluster): $(ip -4 addr show eth1 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo 'N/A')"
echo "============================================"
