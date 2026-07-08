#!/bin/bash
# Script de validação do cluster Kubernetes
# Executar no control-plane: bash /home/vagrant/validate-cluster.sh

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
    ((ERRORS++)) || true
  fi
}

echo ""
echo "============================================"
echo " Validação do Cluster Kubernetes"
echo "============================================"
echo ""

# --- Nodes ---
echo "Nodes:"
check "Control Plane está Ready" "kubectl get nodes | grep control-plane | grep -q ' Ready'"
check "Worker-1 está Ready" "kubectl get nodes | grep worker-1 | grep -q ' Ready'"
check "Worker-2 está Ready" "kubectl get nodes | grep worker-2 | grep -q ' Ready'"
echo ""

# --- Componentes do sistema ---
echo "Componentes do sistema (kube-system):"
check "CoreDNS rodando" "kubectl get pods -n kube-system -l k8s-app=kube-dns --field-selector=status.phase=Running --no-headers | grep -q ."
check "Calico rodando" "kubectl get pods -n kube-system -l k8s-app=calico-node --field-selector=status.phase=Running --no-headers | grep -q ."
check "kube-proxy rodando" "kubectl get pods -n kube-system -l k8s-app=kube-proxy --field-selector=status.phase=Running --no-headers | grep -q ."
check "etcd rodando" "kubectl get pods -n kube-system -l component=etcd --field-selector=status.phase=Running --no-headers | grep -q ."
check "kube-apiserver rodando" "kubectl get pods -n kube-system -l component=kube-apiserver --field-selector=status.phase=Running --no-headers | grep -q ."
check "kube-scheduler rodando" "kubectl get pods -n kube-system -l component=kube-scheduler --field-selector=status.phase=Running --no-headers | grep -q ."
check "kube-controller-manager rodando" "kubectl get pods -n kube-system -l component=kube-controller-manager --field-selector=status.phase=Running --no-headers | grep -q ."
echo ""

# --- Rede ---
echo "Rede:"
check "Service CIDR acessível" "kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}' | grep -q '10.96'"
check "Pod CIDR configurado" "kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}' | grep -q ."
echo ""

# --- Serviços ---
echo "Serviços:"
check "API Server respondendo" "kubectl cluster-info 2>&1 | grep -q 'Kubernetes control plane'"
check "DNS resolvendo" "kubectl run dns-test --image=busybox:1.36 --restart=Never --rm --timeout=30s --command -- nslookup kubernetes.default 2>&1 | grep -q 'Address'"
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
K8S_SERVER_VERSION=$(kubectl version -o yaml 2>/dev/null | grep -A5 "serverVersion" | grep gitVersion | awk '{print $2}' || echo "N/A")
echo "Info:"
echo "  Kubernetes: ${K8S_SERVER_VERSION}"
echo "  Nodes: $(kubectl get nodes --no-headers 2>/dev/null | wc -l)"
echo "  Pods total: $(kubectl get pods -A --no-headers 2>/dev/null | wc -l)"
echo "  Pods Running: $(kubectl get pods -A --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)"
echo ""

exit $ERRORS
