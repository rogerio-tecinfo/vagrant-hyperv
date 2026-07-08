#!/bin/bash
# Script de validação do cluster Kubernetes
# Executar no control-plane: vagrant ssh control-plane -c "bash /home/vagrant/validate-cluster.sh"

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ERRORS=0

check() {
  local desc="$1"
  local cmd="$2"

  if eval "$cmd" > /dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $desc"
  else
    echo -e "  ${RED}✗${NC} $desc"
    ((ERRORS++))
  fi
}

echo ""
echo "============================================"
echo " Validação do Cluster Kubernetes"
echo "============================================"
echo ""

# --- Nodes ---
echo "Nodes:"
check "Control Plane está Ready" "kubectl get nodes | grep control-plane | grep -q Ready"
check "Worker-1 está Ready" "kubectl get nodes | grep worker-1 | grep -q Ready"
check "Worker-2 está Ready" "kubectl get nodes | grep worker-2 | grep -q Ready"
echo ""

# --- Componentes do sistema ---
echo "Componentes do sistema (kube-system):"
check "CoreDNS rodando" "kubectl get pods -n kube-system | grep coredns | grep -q Running"
check "Calico rodando" "kubectl get pods -n kube-system | grep calico-node | grep -q Running"
check "kube-proxy rodando" "kubectl get pods -n kube-system | grep kube-proxy | grep -q Running"
check "etcd rodando" "kubectl get pods -n kube-system | grep etcd | grep -q Running"
check "kube-apiserver rodando" "kubectl get pods -n kube-system | grep kube-apiserver | grep -q Running"
check "kube-scheduler rodando" "kubectl get pods -n kube-system | grep kube-scheduler | grep -q Running"
check "kube-controller-manager rodando" "kubectl get pods -n kube-system | grep kube-controller-manager | grep -q Running"
echo ""

# --- Rede ---
echo "Rede:"
check "Service CIDR acessível" "kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}' | grep -q '10.96'"
check "Pod CIDR configurado" "kubectl cluster-info dump 2>/dev/null | grep -q 'podCIDR'"
echo ""

# --- Serviços ---
echo "Serviços:"
check "API Server respondendo" "kubectl cluster-info | grep -q 'Kubernetes control plane'"
check "DNS resolvendo" "kubectl run --rm -it dns-test --image=busybox:1.36 --restart=Never --timeout=30s -- nslookup kubernetes.default 2>/dev/null | grep -q 'Address'"
echo ""

# --- Resumo ---
echo "============================================"
if [ $ERRORS -eq 0 ]; then
  echo -e " ${GREEN}Cluster saudável! Todos os checks passaram.${NC}"
else
  echo -e " ${YELLOW}${ERRORS} check(s) falharam.${NC}"
  echo " Verifique: kubectl get pods -A | grep -v Running"
fi
echo "============================================"
echo ""

# Info geral
echo "Info:"
echo "  Kubernetes: $(kubectl version --short 2>/dev/null | grep Server | awk '{print $3}' || kubectl version -o json 2>/dev/null | grep gitVersion | head -1)"
echo "  Nodes: $(kubectl get nodes --no-headers | wc -l)"
echo "  Pods: $(kubectl get pods -A --no-headers | wc -l)"
echo ""

exit $ERRORS
