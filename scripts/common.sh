#!/bin/bash
set -euo pipefail

# Script comum executado em TODAS as VMs (control-plane e workers)
# Instala: containerd, kubeadm, kubelet, kubectl
#
# IDEMPOTENTE: pode ser executado múltiplas vezes sem efeitos colaterais

K8S_VERSION="${1:-1.30}"
CONTAINERD_VERSION="1.7.22-1"
K8S_PATCH_VERSION="1.30.14-1.1"

echo "============================================"
echo " Configurando pré-requisitos do Kubernetes"
echo " K8s: v${K8S_VERSION} | Containerd: ${CONTAINERD_VERSION}"
echo "============================================"

# -------------------------------------------
# 1. Configurações básicas do sistema
# -------------------------------------------
echo ">>> Configurando sistema..."

# Desabilitar swap (requisito obrigatório do kubelet)
swapoff -a
sed -i '/swap/d' /etc/fstab

# Carregar módulos do kernel (idempotente)
cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# Parâmetros sysctl para Kubernetes (idempotente)
cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system > /dev/null 2>&1

# -------------------------------------------
# 2. Instalar containerd
# -------------------------------------------
if command -v containerd &> /dev/null && containerd --version | grep -q "${CONTAINERD_VERSION%%"-"*}"; then
  echo ">>> containerd já instalado. Pulando..."
else
  echo ">>> Instalando containerd ${CONTAINERD_VERSION}..."

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
    $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y -qq "containerd.io=${CONTAINERD_VERSION}"
  apt-mark hold containerd.io
fi

# Configurar containerd para usar systemd cgroup driver (idempotente)
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

echo ">>> containerd OK."

# -------------------------------------------
# 3. Instalar kubeadm, kubelet e kubectl
# -------------------------------------------
if command -v kubeadm &> /dev/null && kubeadm version -o short | grep -q "v${K8S_VERSION}"; then
  echo ">>> kubeadm já instalado ($(kubeadm version -o short)). Pulando..."
else
  echo ">>> Instalando kubeadm, kubelet e kubectl v${K8S_VERSION}..."

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" -o /tmp/k8s.gpg
  gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg /tmp/k8s.gpg
  rm -f /tmp/k8s.gpg

  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list

  apt-get update -qq
  apt-get install -y -qq \
    "kubelet=${K8S_PATCH_VERSION}" \
    "kubeadm=${K8S_PATCH_VERSION}" \
    "kubectl=${K8S_PATCH_VERSION}"

  apt-mark hold kubelet kubeadm kubectl
fi

systemctl enable kubelet

echo ">>> kubeadm $(kubeadm version -o short) OK."

# -------------------------------------------
# 4. Configuração crictl
# -------------------------------------------
cat <<EOF > /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

# -------------------------------------------
# 5. Auto-complete kubectl (para o usuário vagrant)
# -------------------------------------------
if [ ! -f /etc/bash_completion.d/kubectl ]; then
  kubectl completion bash > /etc/bash_completion.d/kubectl
fi

# Alias para o usuário vagrant
if ! grep -q "alias k=" /home/vagrant/.bashrc 2>/dev/null; then
  cat <<'EOF' >> /home/vagrant/.bashrc
# Kubernetes aliases
alias k='kubectl'
alias kgn='kubectl get nodes'
alias kgp='kubectl get pods -A'
complete -o default -F __start_kubectl k
EOF
fi

echo "============================================"
echo " Pré-requisitos concluídos em: $(hostname)"
echo " IP: $(ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo 'N/A')"
echo "============================================"
