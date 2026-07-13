#!/bin/bash
set -euo pipefail

# Script executado SOMENTE no Control Plane
# - Inicializa o cluster com kubeadm init
# - Instala CNI (Calico)
# - Gera token de join para os workers
#
# IDEMPOTENTE: detecta se o cluster já foi inicializado

CALICO_VERSION="v3.27.0"
POD_CIDR="10.244.0.0/16"          # não colide com a rede de nós nem com o Service CIDR (10.96.0.0/12)
CONTROL_PLANE_IP="${1:-}"          # IP fixo no plano de cluster (eth1) vindo do Vagrantfile
JOIN_TOKEN="${2:-}"                # token de bootstrap fixo (lab)

echo "============================================"
echo " Inicializando Control Plane"
echo "============================================"

# -------------------------------------------
# 1. IP do plano de cluster (fixo via Vagrantfile)
# -------------------------------------------
# Fallback para autodetecção caso o IP não tenha sido passado como argumento.
if [ -z "$CONTROL_PLANE_IP" ]; then
  echo ">>> IP não informado; tentando autodetecção..."
  for iface in eth1 eth0 ens33 enp0s1 enp0s3; do
    CONTROL_PLANE_IP=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)
    [ -n "$CONTROL_PLANE_IP" ] && { echo ">>> Interface detectada: ${iface}"; break; }
  done
fi

if [ -z "$CONTROL_PLANE_IP" ]; then
  CONTROL_PLANE_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\d+(\.\d+){3}' | head -1 || true)
fi

if [ -z "$CONTROL_PLANE_IP" ]; then
  echo "ERRO: Não foi possível determinar o IP do control-plane."
  ip -4 addr show
  exit 1
fi

echo ">>> IP do Control Plane: ${CONTROL_PLANE_IP}"

# -------------------------------------------
# 2. Inicializar o cluster (kubeadm init)
# -------------------------------------------
if [ -f /etc/kubernetes/admin.conf ]; then
  echo ">>> Cluster já inicializado. Pulando kubeadm init..."
else
  echo ">>> Executando kubeadm init..."

  # Token fixo (--token-ttl 0 = não expira) para que os workers façam join
  # de forma determinística, sem SSH/sshpass e sem depender de expiração de 24h.
  TOKEN_ARGS=""
  if [ -n "$JOIN_TOKEN" ]; then
    TOKEN_ARGS="--token ${JOIN_TOKEN} --token-ttl 0"
  fi

  kubeadm init \
    --apiserver-advertise-address="${CONTROL_PLANE_IP}" \
    --pod-network-cidr="${POD_CIDR}" \
    --node-name="control-plane" \
    ${TOKEN_ARGS} \
    --ignore-preflight-errors=NumCPU

  echo ">>> kubeadm init concluído."
fi

# -------------------------------------------
# 3. Configurar kubectl para o usuário vagrant e root
# -------------------------------------------
echo ">>> Configurando kubectl para o usuário vagrant..."

export KUBECONFIG=/etc/kubernetes/admin.conf

mkdir -p /home/vagrant/.kube
cp -f /etc/kubernetes/admin.conf /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

# Configurar também para root (sudo su)
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config

echo ">>> kubectl configurado (vagrant + root)."

# -------------------------------------------
# 4. Instalar CNI - Calico (idempotente - kubectl apply)
# -------------------------------------------
echo ">>> Aplicando Calico CNI ${CALICO_VERSION}..."

# Baixa o manifesto e força o IPPool do Calico para o mesmo POD_CIDR do kubeadm.
# Sem isto o Calico usaria seu default (192.168.0.0/16), gerando divergência de rotas.
curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" -o /tmp/calico.yaml
sed -i \
  -e 's|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|' \
  -e "s|#   value: \"192.168.0.0/16\"|  value: \"${POD_CIDR}\"|" \
  /tmp/calico.yaml

kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f /tmp/calico.yaml
rm -f /tmp/calico.yaml

echo ">>> Calico aplicado (Pod CIDR: ${POD_CIDR}). Aguardando pods ficarem prontos..."

# Aguardar os pods do kube-system (timeout de 180s)
kubectl --kubeconfig=/etc/kubernetes/admin.conf wait \
  --for=condition=Ready pods --all \
  -n kube-system --timeout=180s || true

# -------------------------------------------
# 4b. Aplicar NetworkPolicies (segregação de rede)
# -------------------------------------------
# Modelo default-deny no namespace "default" + liberação explícita de DNS.
# Não afeta o kube-system (control plane/CNI/CoreDNS continuam funcionando).
if [ -f /home/vagrant/network-policies.yaml ]; then
  echo ">>> Aplicando NetworkPolicies (default-deny + allow DNS)..."
  kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f /home/vagrant/network-policies.yaml || \
    echo ">>> AVISO: falha ao aplicar NetworkPolicies (verifique manualmente)."
fi

# -------------------------------------------
# 5. Comando de join para os workers
# -------------------------------------------
# Os workers usam o token fixo (definido no init) diretamente, sem SSH.
# Registramos o comando apenas para referência/uso manual.
if [ -n "$JOIN_TOKEN" ]; then
  JOIN_COMMAND="kubeadm join ${CONTROL_PLANE_IP}:6443 --token ${JOIN_TOKEN} --discovery-token-unsafe-skip-ca-verification"
else
  # Fallback (sem token fixo): gera um novo com o CA hash real.
  JOIN_COMMAND=$(kubeadm token create --print-join-command)
fi

echo "${JOIN_COMMAND}" > /home/vagrant/join-command.sh
chmod 600 /home/vagrant/join-command.sh
chown vagrant:vagrant /home/vagrant/join-command.sh

# -------------------------------------------
# 6. Validação do Control Plane
# -------------------------------------------
echo ""
echo ">>> Validando provisionamento do Control Plane..."
echo ""

KC="kubectl --kubeconfig=/etc/kubernetes/admin.conf"
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

echo "--- API Server & etcd ---"
validate "API Server respondendo" "curl -sk https://127.0.0.1:6443/healthz | grep -q ok"
validate "etcd rodando" "$KC get pods -n kube-system -l component=etcd --field-selector=status.phase=Running --no-headers | grep -q ."
validate "kube-apiserver rodando" "$KC get pods -n kube-system -l component=kube-apiserver --field-selector=status.phase=Running --no-headers | grep -q ."
validate "kube-scheduler rodando" "$KC get pods -n kube-system -l component=kube-scheduler --field-selector=status.phase=Running --no-headers | grep -q ."
validate "kube-controller-manager rodando" "$KC get pods -n kube-system -l component=kube-controller-manager --field-selector=status.phase=Running --no-headers | grep -q ."
echo ""

echo "--- CNI (Calico) ---"
validate "calico-node rodando no control-plane" "$KC get pods -n kube-system -l k8s-app=calico-node --field-selector=status.phase=Running --no-headers | grep -q ."
validate "calico-kube-controllers rodando" "$KC get pods -n kube-system -l k8s-app=calico-kube-controllers --field-selector=status.phase=Running --no-headers | grep -q ."
validate "Pod CIDR atribuído ao node" "$KC get node control-plane -o jsonpath='{.spec.podCIDR}' | grep -q ."
echo ""

echo "--- CoreDNS & kube-proxy ---"
validate "CoreDNS rodando" "$KC get pods -n kube-system -l k8s-app=kube-dns --field-selector=status.phase=Running --no-headers | grep -q ."
validate "kube-proxy rodando" "$KC get pods -n kube-system -l k8s-app=kube-proxy --field-selector=status.phase=Running --no-headers | grep -q ."
echo ""

echo "--- Rede & Node ---"
validate "Control Plane está Ready" "$KC get nodes control-plane | grep -q ' Ready'"
validate "InternalIP é 172.30.0.10" "$KC get node control-plane -o jsonpath='{.status.addresses[?(@.type==\"InternalIP\")].address}' | grep -q '172.30.0.10'"
validate "Service CIDR correto (10.96.x)" "$KC get svc kubernetes -o jsonpath='{.spec.clusterIP}' | grep -q '10.96'"
echo ""

echo "--- Token de join ---"
validate "Token de bootstrap ativo" "$KC get secrets -n kube-system | grep -q bootstrap-token"
echo ""

echo "--- NetworkPolicies ---"
validate "default-deny-all aplicada" "$KC get networkpolicy -n default 2>/dev/null | grep -q deny"
validate "allow-dns-egress aplicada" "$KC get networkpolicy -n default 2>/dev/null | grep -q dns"
echo ""

# Resumo
echo "============================================"
if [ $VALIDATION_ERRORS -eq 0 ]; then
  echo " Control Plane: TODOS OS CHECKS PASSARAM"
else
  echo " Control Plane: ${VALIDATION_ERRORS} CHECK(S) FALHARAM"
  echo ""
  echo " Pods com problema:"
  $KC get pods -A --no-headers | grep -v "Running" || echo "  (nenhum)"
fi
echo "============================================"
echo ""
echo " IP: ${CONTROL_PLANE_IP}"
echo " Join command: /home/vagrant/join-command.sh"
echo " Calico: ${CALICO_VERSION}"
echo " Pod CIDR: ${POD_CIDR}"
echo ""
echo " Comando de join para os workers:"
echo " ${JOIN_COMMAND}"
echo "============================================"
