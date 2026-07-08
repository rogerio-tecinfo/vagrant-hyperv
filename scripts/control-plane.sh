#!/bin/bash
set -euo pipefail

# Script executado SOMENTE no Control Plane
# - Inicializa o cluster com kubeadm init
# - Instala CNI (Calico)
# - Gera token de join para os workers

echo "============================================"
echo " Inicializando Control Plane"
echo "============================================"

# -------------------------------------------
# 1. Detectar IP da máquina
# -------------------------------------------
# No Hyper-V, o IP é atribuído via DHCP
CONTROL_PLANE_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)

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
echo ">>> Executando kubeadm init..."

kubeadm init \
  --apiserver-advertise-address="${CONTROL_PLANE_IP}" \
  --pod-network-cidr=192.168.0.0/16 \
  --node-name="control-plane" \
  --ignore-preflight-errors=Mem,NumCPU

echo ">>> kubeadm init concluído."

# -------------------------------------------
# 3. Configurar kubectl para o usuário vagrant
# -------------------------------------------
echo ">>> Configurando kubectl para o usuário vagrant..."

# Para root
export KUBECONFIG=/etc/kubernetes/admin.conf

# Para o usuário vagrant
mkdir -p /home/vagrant/.kube
cp -f /etc/kubernetes/admin.conf /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

echo ">>> kubectl configurado."

# -------------------------------------------
# 4. Instalar CNI - Calico
# -------------------------------------------
echo ">>> Instalando Calico CNI..."

kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

echo ">>> Calico instalado. Aguardando pods ficarem prontos..."

# Aguardar o Calico estar ready (timeout de 120s)
kubectl --kubeconfig=/etc/kubernetes/admin.conf wait --for=condition=Ready pods --all -n kube-system --timeout=120s || true

# -------------------------------------------
# 5. Gerar comando de join para os workers
# -------------------------------------------
echo ">>> Gerando token de join para os workers..."

JOIN_COMMAND=$(kubeadm token create --print-join-command)

# Salvar o comando de join em um arquivo acessível
echo "${JOIN_COMMAND}" > /etc/kubernetes/join-command.sh
chmod 644 /etc/kubernetes/join-command.sh

# Salvar também no home do vagrant para fácil acesso
echo "${JOIN_COMMAND}" > /home/vagrant/join-command.sh
chown vagrant:vagrant /home/vagrant/join-command.sh

echo "============================================"
echo " Control Plane inicializado com sucesso!"
echo "============================================"
echo ""
echo " IP do Control Plane: ${CONTROL_PLANE_IP}"
echo " Comando de join salvo em: /home/vagrant/join-command.sh"
echo ""
echo " Para os workers se juntarem ao cluster, execute:"
echo " ${JOIN_COMMAND}"
echo ""
echo " Verificar o cluster:"
echo "   vagrant ssh control-plane"
echo "   kubectl get nodes"
echo "============================================"
