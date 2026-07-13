#!/bin/bash
set -euo pipefail

# Script comum executado em TODAS as VMs (control-plane e workers)
# Instala: containerd, kubeadm, kubelet, kubectl
#
# IDEMPOTENTE: pode ser executado múltiplas vezes sem efeitos colaterais

K8S_VERSION="${1:-1.30}"
CLUSTER_IP="${2:-}"          # IP fixo no plano de cluster (2ª NIC)
CLUSTER_NETMASK="${3:-24}"
CONTAINERD_VERSION="1.7.22-1"
K8S_PATCH_VERSION="1.30.14-1.1"

# -------------------------------------------
# Detectar a interface do plano de cluster (2ª NIC / K8sSwitch)
# No Hyper-V, nomes podem variar (eth1, ens*, etc.)
# Estratégia: a 2ª NIC é aquela SEM IP atribuído (a 1ª já tem DHCP).
# -------------------------------------------
detect_cluster_iface() {
  # Listar interfaces que NÃO são lo e NÃO têm endereço IPv4
  local iface
  for iface in $(ls /sys/class/net/ | grep -v lo); do
    # Pular a interface que já tem IP (é a de management/DHCP)
    if ! ip -4 addr show "$iface" 2>/dev/null | grep -q "inet "; then
      echo "$iface"
      return
    fi
  done
  # Fallback: tentar eth1
  echo "eth1"
}

CLUSTER_IFACE=$(detect_cluster_iface)

# Detectar a interface de management (eth0 / LOCAL_NETWORK / DHCP):
# é a que JÁ possui IPv4 e NÃO é a interface do plano de cluster.
detect_mgmt_iface() {
  local iface
  for iface in $(ls /sys/class/net/ | grep -v lo); do
    [ "$iface" = "$CLUSTER_IFACE" ] && continue
    if ip -4 addr show "$iface" 2>/dev/null | grep -q "inet "; then
      echo "$iface"
      return
    fi
  done
  echo "eth0"
}
MGMT_IFACE=$(detect_mgmt_iface)

# -------------------------------------------
# Evitar IP duplicado no eth0 (management/DHCP)
# -------------------------------------------
# As VMs são linked clones da MESMA box, então herdam o mesmo /etc/machine-id.
# O systemd-networkd usa, por padrão, dhcp-identifier=duid, e o DUID é derivado
# do machine-id. machine-id igual => DUID igual => o servidor DHCP entrega a
# MESMA lease para VMs diferentes (ex.: worker-1 e worker-2 com o mesmo IP em eth0).
#
# Defesa dupla (idempotente):
#   1. Regenerar o machine-id (uma vez por VM) para dar identidade única.
#   2. Forçar dhcp-identifier=mac no eth0. Como o Hyper-V atribui MAC único por
#      adapter, a lease passa a ser determinística mesmo que o DUID coincida.
#
# Ambos passam a valer no PRÓXIMO boot da NIC (não fazemos 'netplan apply' aqui
# para não derrubar o SSH/DNS da sessão de provisionamento atual).
if [ ! -f /etc/machine-id.vagrant-regen ]; then
  echo ">>> Regenerando machine-id (evita DUID/IP duplicado no eth0 entre clones)..."
  : > /etc/machine-id
  rm -f /var/lib/dbus/machine-id
  systemd-machine-id-setup >/dev/null 2>&1 || true
  ln -sf /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true
  touch /etc/machine-id.vagrant-regen
fi

echo ">>> Fixando dhcp-identifier=mac no ${MGMT_IFACE} (lease única por MAC)..."
cat <<EOF > /etc/netplan/98-mgmt-dhcp-identifier.yaml
network:
  version: 2
  ethernets:
    ${MGMT_IFACE}:
      dhcp4: true
      dhcp-identifier: mac
EOF
chmod 600 /etc/netplan/98-mgmt-dhcp-identifier.yaml

echo "============================================"
echo " Configurando pré-requisitos do Kubernetes"
echo " K8s: v${K8S_VERSION} | Containerd: ${CONTAINERD_VERSION}"
echo " Cluster IP: ${CLUSTER_IP:-<none>} (${CLUSTER_IFACE})"
echo "============================================"

# -------------------------------------------
# 0. Rede do plano de cluster (IP fixo em eth1)
# -------------------------------------------
# Segrega o tráfego: eth0 (LOCAL_NETWORK/DHCP) = management/SSH,
# eth1 (K8sSwitch/estático) = tráfego de cluster (API server, kubelet, join).
if [ -n "$CLUSTER_IP" ]; then
  echo ">>> Configurando IP fixo ${CLUSTER_IP}/${CLUSTER_NETMASK} em ${CLUSTER_IFACE}..."

  # Estratégia: configurar a interface IMEDIATAMENTE com 'ip' (sem perturbar DNS/rotas)
  # e salvar o netplan apenas para persistência no reboot.
  # O 'netplan apply' reinicia o networkd e pode derrubar momentaneamente o DNS da eth0.

  # 1. Ativar interface e atribuir IP imediatamente (idempotente)
  ip link set "${CLUSTER_IFACE}" up 2>/dev/null || true
  if ! ip -4 addr show "${CLUSTER_IFACE}" 2>/dev/null | grep -q "${CLUSTER_IP}"; then
    ip addr add "${CLUSTER_IP}/${CLUSTER_NETMASK}" dev "${CLUSTER_IFACE}" 2>/dev/null || true
  fi

  # 2. Salvar netplan para persistência no reboot (sem executar 'netplan apply')
  cat <<EOF > /etc/netplan/99-k8s-cluster.yaml
network:
  version: 2
  ethernets:
    ${CLUSTER_IFACE}:
      dhcp4: false
      optional: true
      link-local: []
      addresses:
        - ${CLUSTER_IP}/${CLUSTER_NETMASK}
EOF
  chmod 600 /etc/netplan/99-k8s-cluster.yaml

  echo ">>> IP ${CLUSTER_IP} ativo em ${CLUSTER_IFACE} (persistido via netplan)."
fi

# -------------------------------------------
# 1. Configurações básicas do sistema
# -------------------------------------------
echo ">>> Configurando sistema..."

# Trocar mirror Ubuntu (mirrors.edge.kernel.org pode ser lento/instável)
# Usar archive.ubuntu.com como fallback confiável
if grep -q "mirrors.edge.kernel.org" /etc/apt/sources.list 2>/dev/null; then
  echo ">>> Trocando mirror Ubuntu para archive.ubuntu.com..."
  sed -i 's|https\?://mirrors.edge.kernel.org/ubuntu|http://archive.ubuntu.com/ubuntu|g' /etc/apt/sources.list
fi

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
CONTAINERD_INSTALLED=false

if command -v containerd &> /dev/null; then
  INSTALLED_VERSION=$(containerd --version | grep -oP '\d+\.\d+\.\d+' | head -1)
  EXPECTED_VERSION="${CONTAINERD_VERSION%%-*}"
  if [ "$INSTALLED_VERSION" = "$EXPECTED_VERSION" ]; then
    echo ">>> containerd ${INSTALLED_VERSION} já instalado. Pulando..."
    CONTAINERD_INSTALLED=true
  fi
fi

if [ "$CONTAINERD_INSTALLED" = false ]; then
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

  # Configurar containerd para usar systemd cgroup driver (somente na instalação)
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

  systemctl restart containerd
  systemctl enable containerd
else
  # Apenas garantir que está habilitado e rodando (sem restart)
  systemctl enable containerd
  if ! systemctl is-active --quiet containerd; then
    systemctl start containerd
  fi
fi

echo ">>> containerd OK."

# -------------------------------------------
# 3. Instalar kubeadm, kubelet e kubectl
# -------------------------------------------
if command -v kubeadm &> /dev/null && [ "$(kubeadm version -o short)" = "v${K8S_VERSION}" ] 2>/dev/null; then
  echo ">>> kubeadm já instalado ($(kubeadm version -o short)). Pulando..."
else
  echo ">>> Instalando kubeadm, kubelet e kubectl v${K8S_VERSION}..."

  # Instalar dependências se necessário
  apt-get install -y -qq curl apt-transport-https ca-certificates gnupg 2>/dev/null

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" -o /tmp/k8s.gpg
  gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg /tmp/k8s.gpg
  rm -f /tmp/k8s.gpg

  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list

  apt-get update -qq
  apt-get install -y -qq \
    -o Dpkg::Options::="--force-confold" \
    -o Dpkg::Options::="--force-confdef" \
    "kubelet=${K8S_PATCH_VERSION}" \
    "kubeadm=${K8S_PATCH_VERSION}" \
    "kubectl=${K8S_PATCH_VERSION}"

  apt-mark hold kubelet kubeadm kubectl
fi

systemctl enable kubelet

# Fixar o node-ip do kubelet na rede de cluster (evita usar o IP DHCP da eth0)
if [ -n "$CLUSTER_IP" ]; then
  echo "KUBELET_EXTRA_ARGS=--node-ip=${CLUSTER_IP}" > /etc/default/kubelet
fi

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
echo " IP (management): $(ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo 'N/A')"
echo " IP (cluster):    ${CLUSTER_IP:-N/A} (${CLUSTER_IFACE})"
echo "============================================"

# -------------------------------------------
# 6. Validação dos pré-requisitos
# -------------------------------------------
echo ""
echo ">>> Validando pré-requisitos..."

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

validate "containerd ativo" "systemctl is-active --quiet containerd"
validate "containerd com SystemdCgroup" "grep -q 'SystemdCgroup = true' /etc/containerd/config.toml"
validate "kubelet instalado" "command -v kubelet"
validate "kubeadm instalado" "command -v kubeadm"
validate "kubectl instalado" "command -v kubectl"
validate "swap desabilitado" "[ $(swapon --show --noheadings | wc -l) -eq 0 ]"
validate "br_netfilter carregado" "lsmod | grep -q br_netfilter"
validate "overlay carregado" "lsmod | grep -q overlay"
validate "ip_forward habilitado" "[ $(cat /proc/sys/net/ipv4/ip_forward) -eq 1 ]"
validate "machine-id único regenerado" "test -f /etc/machine-id.vagrant-regen && test -s /etc/machine-id"
validate "dhcp-identifier=mac no ${MGMT_IFACE}" "grep -q 'dhcp-identifier: mac' /etc/netplan/98-mgmt-dhcp-identifier.yaml 2>/dev/null"

if [ -n "$CLUSTER_IP" ]; then
  validate "IP do cluster configurado (${CLUSTER_IFACE})" \
    "ip -4 addr show ${CLUSTER_IFACE} 2>/dev/null | grep -q '${CLUSTER_IP}'"
  validate "node-ip configurado no kubelet" \
    "grep -q 'node-ip=${CLUSTER_IP}' /etc/default/kubelet 2>/dev/null"
fi

echo ""
if [ $VALIDATION_ERRORS -eq 0 ]; then
  echo "  >>> Pré-requisitos: TODOS OS CHECKS PASSARAM"
else
  echo "  >>> Pré-requisitos: ${VALIDATION_ERRORS} CHECK(S) FALHARAM"
  exit 1
fi
echo ""
