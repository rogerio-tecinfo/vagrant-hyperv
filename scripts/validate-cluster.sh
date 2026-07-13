#!/bin/bash
# =============================================================================
# Smoke Test - Validação completa do cluster Kubernetes
# Executar no control-plane: bash /home/vagrant/validate-cluster.sh
#
# Testa:
#   1. Infraestrutura (nodes, kubelet, containerd)
#   2. Control Plane (API, etcd, scheduler, controller-manager)
#   3. CNI / Calico (pods, conectividade entre nós)
#   4. CoreDNS (resolução de nomes internos)
#   5. kube-proxy (Services)
#   6. NetworkPolicies
#   7. Deploy de workload real (nginx + connectivity test)
# =============================================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ERRORS=0
WARNINGS=0
TOTAL=0

check() {
  local desc="$1"
  local cmd="$2"
  ((TOTAL++)) || true

  if eval "$cmd" > /dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $desc"
  else
    echo -e "  ${RED}✗${NC} $desc"
    ((ERRORS++)) || true
  fi
}

warn_check() {
  local desc="$1"
  local cmd="$2"
  ((TOTAL++)) || true

  if eval "$cmd" > /dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $desc"
  else
    echo -e "  ${YELLOW}⚠${NC} $desc (não bloqueante)"
    ((WARNINGS++)) || true
  fi
}

header() {
  echo ""
  echo -e "${BLUE}━━━ $1 ━━━${NC}"
}

cleanup() {
  echo ""
  echo ">>> Limpando recursos de teste..."
  kubectl delete namespace smoke-test --ignore-not-found --timeout=30s > /dev/null 2>&1 || true
}

trap cleanup EXIT

echo ""
echo "============================================"
echo " Smoke Test - Cluster Kubernetes"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"

# =============================================================================
header "1. INFRAESTRUTURA (Nodes)"
# =============================================================================

check "Control Plane está Ready" \
  "kubectl get node control-plane --no-headers | grep -q ' Ready'"

check "Worker-1 está Ready" \
  "kubectl get node worker-1 --no-headers | grep -q ' Ready'"

check "Worker-2 está Ready" \
  "kubectl get node worker-2 --no-headers | grep -q ' Ready'"

check "Control Plane com InternalIP 172.30.0.10" \
  "kubectl get node control-plane -o jsonpath='{.status.addresses[?(@.type==\"InternalIP\")].address}' | grep -q '172.30.0.10'"

check "Worker-1 com InternalIP 172.30.0.11" \
  "kubectl get node worker-1 -o jsonpath='{.status.addresses[?(@.type==\"InternalIP\")].address}' | grep -q '172.30.0.11'"

check "Worker-2 com InternalIP 172.30.0.12" \
  "kubectl get node worker-2 -o jsonpath='{.status.addresses[?(@.type==\"InternalIP\")].address}' | grep -q '172.30.0.12'"

check "Todos os nodes com versão v1.30" \
  "kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.kubeletVersion}' | grep -q 'v1.30'"

check "Container runtime é containerd" \
  "kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}' | grep -q 'containerd'"

# =============================================================================
header "2. CONTROL PLANE (componentes estáticos)"
# =============================================================================

check "API Server saudável (/healthz)" \
  "curl -sk https://172.30.0.10:6443/healthz | grep -q ok"

check "API Server respondendo (cluster-info)" \
  "kubectl cluster-info 2>&1 | grep -q 'control plane'"

check "etcd rodando" \
  "kubectl get pods -n kube-system -l component=etcd --field-selector=status.phase=Running --no-headers | grep -q ."

check "kube-apiserver rodando" \
  "kubectl get pods -n kube-system -l component=kube-apiserver --field-selector=status.phase=Running --no-headers | grep -q ."

check "kube-scheduler rodando" \
  "kubectl get pods -n kube-system -l component=kube-scheduler --field-selector=status.phase=Running --no-headers | grep -q ."

check "kube-controller-manager rodando" \
  "kubectl get pods -n kube-system -l component=kube-controller-manager --field-selector=status.phase=Running --no-headers | grep -q ."

check "Token de bootstrap ativo" \
  "kubectl get secrets -n kube-system --no-headers | grep -q bootstrap-token"

# =============================================================================
header "3. CNI - CALICO"
# =============================================================================

CALICO_NODES=$(kubectl get pods -n kube-system -l k8s-app=calico-node --no-headers 2>/dev/null | wc -l)
check "calico-node DaemonSet (3 instâncias)" \
  "[ '$CALICO_NODES' -eq 3 ]"

check "Todos os calico-node Running" \
  "[ $(kubectl get pods -n kube-system -l k8s-app=calico-node --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l) -eq $CALICO_NODES ]"

check "calico-kube-controllers Running" \
  "kubectl get pods -n kube-system -l k8s-app=calico-kube-controllers --field-selector=status.phase=Running --no-headers | grep -q ."

check "Pod CIDR atribuído a control-plane" \
  "kubectl get node control-plane -o jsonpath='{.spec.podCIDR}' | grep -q ."

check "Pod CIDR atribuído a worker-1" \
  "kubectl get node worker-1 -o jsonpath='{.spec.podCIDR}' | grep -q ."

check "Pod CIDR atribuído a worker-2" \
  "kubectl get node worker-2 -o jsonpath='{.spec.podCIDR}' | grep -q ."

# =============================================================================
header "4. CoreDNS"
# =============================================================================

check "CoreDNS pods Running" \
  "kubectl get pods -n kube-system -l k8s-app=kube-dns --field-selector=status.phase=Running --no-headers | grep -q ."

check "CoreDNS service existe" \
  "kubectl get svc -n kube-system kube-dns --no-headers | grep -q ."

check "Service CIDR correto (10.96.x)" \
  "kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}' | grep -q '10.96'"

# =============================================================================
header "5. KUBE-PROXY"
# =============================================================================

PROXY_PODS=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy --no-headers 2>/dev/null | wc -l)
check "kube-proxy DaemonSet (3 instâncias)" \
  "[ '$PROXY_PODS' -eq 3 ]"

check "Todos os kube-proxy Running" \
  "[ $(kubectl get pods -n kube-system -l k8s-app=kube-proxy --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l) -eq $PROXY_PODS ]"

# =============================================================================
header "6. NETWORK POLICIES"
# =============================================================================

check "default-deny policy existe" \
  "kubectl get networkpolicy -n default --no-headers 2>/dev/null | grep -qi deny"

check "allow-dns policy existe" \
  "kubectl get networkpolicy -n default --no-headers 2>/dev/null | grep -qi dns"

# =============================================================================
header "7. SMOKE TEST - Deploy de workload"
# =============================================================================

echo "  >>> Criando namespace smoke-test..."
kubectl create namespace smoke-test --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1

# Deploy nginx
echo "  >>> Deployando nginx..."
kubectl apply -n smoke-test -f - > /dev/null 2>&1 <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-test
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx-test
  template:
    metadata:
      labels:
        app: nginx-test
    spec:
      containers:
      - name: nginx
        image: nginx:1.25-alpine
        ports:
        - containerPort: 80
      tolerations:
      - operator: Exists
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-test-svc
spec:
  selector:
    app: nginx-test
  ports:
  - port: 80
    targetPort: 80
EOF

# Aguardar deployment ficar pronto (timeout 120s)
echo "  >>> Aguardando pods do nginx (até 120s)..."
kubectl rollout status deployment/nginx-test -n smoke-test --timeout=120s > /dev/null 2>&1

check "Deployment nginx-test com 2 replicas prontas" \
  "kubectl get deployment nginx-test -n smoke-test -o jsonpath='{.status.readyReplicas}' | grep -q 2"

check "Pods nginx rodando em nodes diferentes" \
  "[ $(kubectl get pods -n smoke-test -l app=nginx-test -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u | wc -l) -ge 2 ]"

# Teste de DNS interno
echo "  >>> Testando resolução DNS interna..."
DNS_RESULT=$(kubectl run dns-test -n smoke-test --image=busybox:1.36 --restart=Never --rm -i --timeout=30s \
  -- nslookup nginx-test-svc.smoke-test.svc.cluster.local 2>&1 || true)

check "DNS resolve Service (nginx-test-svc.smoke-test.svc.cluster.local)" \
  "echo '$DNS_RESULT' | grep -q 'Address'"

# Teste de conectividade via Service
echo "  >>> Testando acesso ao Service..."
SVC_IP=$(kubectl get svc nginx-test-svc -n smoke-test -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
CURL_RESULT=$(kubectl run curl-test -n smoke-test --image=curlimages/curl:8.5.0 --restart=Never --rm -i --timeout=30s \
  -- curl -s -o /dev/null -w "%{http_code}" "http://${SVC_IP}:80" 2>&1 || true)

check "Service acessível via ClusterIP (HTTP 200)" \
  "echo '$CURL_RESULT' | grep -q '200'"

# Teste de conectividade entre pods (cross-node)
echo "  >>> Testando conectividade cross-node..."
POD1_IP=$(kubectl get pods -n smoke-test -l app=nginx-test -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
if [ -n "$POD1_IP" ]; then
  CROSS_RESULT=$(kubectl run cross-test -n smoke-test --image=curlimages/curl:8.5.0 --restart=Never --rm -i --timeout=30s \
    -- curl -s -o /dev/null -w "%{http_code}" "http://${POD1_IP}:80" 2>&1 || true)
  check "Conectividade cross-node (pod-to-pod)" \
    "echo '$CROSS_RESULT' | grep -q '200'"
else
  echo -e "  ${YELLOW}⚠${NC} Não foi possível obter IP do pod para teste cross-node"
  ((WARNINGS++)) || true
fi

# =============================================================================
header "8. SISTEMA (kubelet & containerd)"
# =============================================================================

check "kubelet ativo no control-plane" \
  "systemctl is-active --quiet kubelet"

check "containerd ativo no control-plane" \
  "systemctl is-active --quiet containerd"

warn_check "Nenhum pod em CrashLoopBackOff" \
  "! kubectl get pods -A --no-headers 2>/dev/null | grep -q CrashLoopBackOff"

warn_check "Nenhum pod em Pending" \
  "! kubectl get pods -A --no-headers 2>/dev/null | grep -q Pending"

warn_check "Nenhum pod em Error" \
  "! kubectl get pods -A --field-selector=status.phase=Failed --no-headers 2>/dev/null | grep -q ."

# =============================================================================
# RESUMO
# =============================================================================
echo ""
echo "============================================"
echo " RESULTADO DO SMOKE TEST"
echo "============================================"
echo ""

PASSED=$((TOTAL - ERRORS - WARNINGS))
echo -e "  Total de checks: ${TOTAL}"
echo -e "  ${GREEN}Passaram:${NC}  ${PASSED}"
if [ $WARNINGS -gt 0 ]; then
  echo -e "  ${YELLOW}Warnings:${NC}  ${WARNINGS}"
fi
if [ $ERRORS -gt 0 ]; then
  echo -e "  ${RED}Falharam:${NC}  ${ERRORS}"
fi
echo ""

if [ $ERRORS -eq 0 ]; then
  echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  ${GREEN}  ✓ CLUSTER SAUDÁVEL - Todos os checks OK${NC}"
  echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
else
  echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  ${RED}  ✗ ${ERRORS} CHECKS FALHARAM${NC}"
  echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo "  Pods com problema:"
  kubectl get pods -A --no-headers | grep -v "Running" | grep -v "Completed" || echo "  (nenhum)"
fi

echo ""
echo "  Cluster info:"
echo "    Kubernetes: $(kubectl version -o yaml 2>/dev/null | grep -A5 serverVersion | grep gitVersion | awk '{print $2}' || echo 'N/A')"
echo "    Nodes: $(kubectl get nodes --no-headers 2>/dev/null | wc -l)"
echo "    Pods total: $(kubectl get pods -A --no-headers 2>/dev/null | wc -l)"
echo "    Pods Running: $(kubectl get pods -A --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)"
echo ""
echo "============================================"

exit $ERRORS
