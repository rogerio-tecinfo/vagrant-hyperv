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

# -------------------------------------------
# 3. Validação pós-join
# -------------------------------------------
echo ""
echo ">>> Validando worker $(hostname)..."

VALIDATION_ERRORS=0
validate() {
  local desc="$1"
  local cmd="$2"
  if eval "$cmd" > /dev/null 2>&1; then
    echo "  [OK] $desc"
  else
    echo "  [FALHOU] $desc"
    ((VALIDATION_ERRORS++)) || true
  fi
}

# Detectar interface do cluster (mesma lógica do common.sh)
CLUSTER_IFACE=""
for iface in $(ls /sys/class/net/ | grep -v lo); do
  if ip -4 addr show "$iface" 2>/dev/null | grep -q "172.30.0"; then
    CLUSTER_IFACE="$iface"
    break
  fi
done

validate "kubelet ativo" "systemctl is-active --quiet kubelet"
validate "kubelet.conf criado (join concluído)" "test -f /etc/kubernetes/kubelet.conf"
validate "containerd rodando" "systemctl is-active --quiet containerd"
validate "IP do cluster atribuído" "test -n '$CLUSTER_IFACE' && ip -4 addr show $CLUSTER_IFACE 2>/dev/null | grep -q '172.30.0'"
validate "Conectividade com API Server" "timeout 5 bash -c 'echo > /dev/tcp/${CONTROL_PLANE_IP}/${API_PORT}' 2>/dev/null"

# Aguardar node aparecer como registrado (até 30s)
echo ""
echo ">>> Aguardando registro do node no cluster (até 30s)..."
NODE_REGISTERED=false
for i in $(seq 1 6); do
  if curl -sk "https://${CONTROL_PLANE_IP}:${API_PORT}/api/v1/nodes/$(hostname)" 2>/dev/null | grep -q '"kind":"Node"'; then
    NODE_REGISTERED=true
    break
  fi
  sleep 5
done

if [ "$NODE_REGISTERED" = true ]; then
  echo "  [OK] Node $(hostname) registrado no cluster"
else
  echo "  [FALHOU] Node $(hostname) não aparece no cluster ainda"
  ((VALIDATION_ERRORS++)) || true
fi

echo ""
echo "============================================"
if [ $VALIDATION_ERRORS -eq 0 ]; then
  echo " Worker $(hostname): TODOS OS CHECKS PASSARAM"
else
  echo " Worker $(hostname): ${VALIDATION_ERRORS} CHECK(S) FALHARAM"
fi
echo " IP (cluster): $(ip -4 addr show ${CLUSTER_IFACE:-eth1} 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo 'N/A')"
echo "============================================"
