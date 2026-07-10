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
    --ignore-preflight-errors=Mem,NumCPU

  echo ">>> kubeadm init concluído."
fi

# -------------------------------------------
# 3. Configurar kubectl para o usuário vagrant
# -------------------------------------------
echo ">>> Configurando kubectl para o usuário vagrant..."

export KUBECONFIG=/etc/kubernetes/admin.conf

mkdir -p /home/vagrant/.kube
cp -f /etc/kubernetes/admin.conf /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

echo ">>> kubectl configurado."

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
# 6. Health check
# -------------------------------------------
echo ""
echo ">>> Verificando saúde do cluster..."
echo ""
kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide
echo ""
kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n kube-system
echo ""

echo "============================================"
echo " Control Plane inicializado com sucesso!"
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
