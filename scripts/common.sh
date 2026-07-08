#!/bin/bash
set -euo pipefail

# Script comum executado em TODAS as VMs (control-plane e workers)
# Instala: containerd, kubeadm, kubelet, kubectl

K8S_VERSION="${1:-1.30}"

echo "============================================"
echo " Configurando pré-requisitos do Kubernetes"
echo " Versão: ${K8S_VERSION}"
echo "============================================"

# -------------------------------------------
# 1. Configurações básicas do sistema
# -------------------------------------------

# Desabilitar swap (requisito obrigatório do kubelet)
swapoff -a
sed -i '/swap/d' /etc/fstab

# Carregar módulos do kernel
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# Parâmetros sysctl para Kubernetes
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system > /dev/null 2>&1

# -------------------------------------------
# 2. Instalar containerd
# -------------------------------------------
echo ">>> Instalando containerd..."

apt-get update -qq
apt-get install -y -qq \
  curl \
  apt-transport-https \
  ca-certificates \
  gnupg \
  lsb-release

# Adicionar repositório Docker (para containerd)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.gpg
gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg /tmp/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
rm -f /tmp/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -qq
apt-get install -y -qq containerd.io

# Configurar containerd para usar systemd cgroup driver
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml > /dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

echo ">>> containerd instalado e configurado."

# -------------------------------------------
# 3. Instalar kubeadm, kubelet e kubectl
# -------------------------------------------
echo ">>> Instalando kubeadm, kubelet e kubectl v${K8S_VERSION}..."

# Adicionar repositório Kubernetes
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" -o /tmp/k8s.gpg
gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg /tmp/k8s.gpg
rm -f /tmp/k8s.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl

# Impedir atualização automática dos pacotes
apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet

echo ">>> kubeadm, kubelet e kubectl instalados."
echo ">>> Versão instalada:"
kubeadm version -o short

# -------------------------------------------
# 4. Configuração de rede - crictl
# -------------------------------------------
cat <<EOF | tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

echo "============================================"
echo " Pré-requisitos concluídos em: $(hostname)"
echo " IP: $(ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo 'N/A')"
echo "============================================"
