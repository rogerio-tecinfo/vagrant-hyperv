#!/bin/bash
set -euo pipefail

# Script executado SOMENTE no Control Plane
# - Inicializa o cluster com kubeadm init
# - Instala CNI (Calico)
# - Gera token de join para os workers
#
# IDEMPOTENTE: detecta se o cluster já foi inicializado

CALICO_VERSION="v3.27.0"
POD_CIDR="192.168.0.0/16"

echo "============================================"
echo " Inicializando Control Plane"
echo "============================================"

# -------------------------------------------
# 1. Detectar IP da máquina (multi-interface)
# -------------------------------------------
# Tenta eth0 primeiro, depois qualquer interface não-loopback
CONTROL_PLANE_IP=""

# Tentar interfaces comuns no Hyper-V
for iface in eth0 ens33 enp0s1 enp0s3; do
  CONTROL_PLANE_IP=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)
  if [ -n "$CONTROL_PLANE_IP" ]; then
    echo ">>> Interface detectada: ${iface}"
    break
  fi
done

# Fallback: pegar o IP da rota padrão
if [ -z "$CONTROL_PLANE_IP" ]; then
  CONTROL_PLANE_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\d+(\.\d+){3}' | head -1 || true)
fi

if [ -z "$CONTROL_PLANE_IP" ]; then
  echo "ERRO: Não foi possível detectar o IP do control-plane."
  echo "Interfaces disponíveis:"
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

  kubeadm init \
    --apiserver-advertise-address="${CONTROL_PLANE_IP}" \
    --pod-network-cidr="${POD_CIDR}" \
    --node-name="control-plane" \
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

kubectl --kubeconfig=/etc/kubernetes/admin.conf apply \
  -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

echo ">>> Calico aplicado. Aguardando pods ficarem prontos..."

# Aguardar os pods do kube-system (timeout de 180s)
kubectl --kubeconfig=/etc/kubernetes/admin.conf wait \
  --for=condition=Ready pods --all \
  -n kube-system --timeout=180s || true

# -------------------------------------------
# 5. Gerar comando de join para os workers
# -------------------------------------------
# Só gera novo token se o arquivo não existe ou se o token expirou
REGENERATE_TOKEN=false

if [ ! -f /home/vagrant/join-command.sh ]; then
  REGENERATE_TOKEN=true
elif ! kubeadm token list 2>/dev/null | grep -q "system:bootstrappers"; then
  REGENERATE_TOKEN=true
fi

if [ "$REGENERATE_TOKEN" = true ]; then
  echo ">>> Gerando token de join para os workers..."
  JOIN_COMMAND=$(kubeadm token create --print-join-command)

  echo "${JOIN_COMMAND}" > /etc/kubernetes/join-command.sh
  chmod 600 /etc/kubernetes/join-command.sh

  echo "${JOIN_COMMAND}" > /home/vagrant/join-command.sh
  chmod 600 /home/vagrant/join-command.sh
  chown vagrant:vagrant /home/vagrant/join-command.sh
else
  echo ">>> Token de join ainda válido. Reutilizando..."
  JOIN_COMMAND=$(cat /home/vagrant/join-command.sh)
fi

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
