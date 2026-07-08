# -*- mode: ruby -*-
# vi: set ft=ruby :

# Cenário: Kubernetes Cluster com kubeadm no Hyper-V (Windows 11)
# - 1 Control Plane + 2 Worker Nodes
# - Container Runtime: containerd
# - CNI: Calico
# - Kubernetes v1.30
#
# IMPORTANTE:
# 1. Executar o terminal como Administrador
# 2. vagrant up --provider=hyperv
# 3. Selecionar "Default Switch" quando perguntado
# 4. Após o up, o cluster estará pronto automaticamente

# Versão do Kubernetes
K8S_VERSION = "1.30"

# Configuração das VMs
CONTROL_PLANE = {
  name: "control-plane",
  hostname: "control-plane",
  cpus: 2,
  memory: 1024
}

WORKERS = [
  { name: "worker-1", hostname: "worker-1", cpus: 2, memory: 1024 },
  { name: "worker-2", hostname: "worker-2", cpus: 2, memory: 1024 }
]

# Box compatível com Hyper-V
BOX_IMAGE = "generic/ubuntu2204"

Vagrant.configure("2") do |config|
  config.vm.synced_folder ".", "/vagrant", disabled: true

  # ============================================================
  # Control Plane
  # ============================================================
  config.vm.define CONTROL_PLANE[:name] do |master|
    master.vm.box = BOX_IMAGE
    master.vm.hostname = CONTROL_PLANE[:hostname]

    master.vm.provider "hyperv" do |hv|
      hv.vmname = CONTROL_PLANE[:name]
      hv.cpus = CONTROL_PLANE[:cpus]
      hv.memory = CONTROL_PLANE[:memory]
      # Não definir maxmemory para desabilitar Dynamic Memory
      # Isso garante que a VM receba os 2048 MB completos
      hv.enable_virtualization_extensions = true
      hv.linked_clone = true
    end

    # Script comum: pré-requisitos + containerd + kubeadm
    master.vm.provision "shell", path: "scripts/common.sh", args: [K8S_VERSION]

    # Script do control plane: kubeadm init + CNI
    master.vm.provision "shell", path: "scripts/control-plane.sh"
  end

  # ============================================================
  # Worker Nodes
  # ============================================================
  WORKERS.each do |worker_config|
    config.vm.define worker_config[:name] do |worker|
      worker.vm.box = BOX_IMAGE
      worker.vm.hostname = worker_config[:hostname]

      worker.vm.provider "hyperv" do |hv|
        hv.vmname = worker_config[:name]
        hv.cpus = worker_config[:cpus]
        hv.memory = worker_config[:memory]
        # Não definir maxmemory para desabilitar Dynamic Memory
        hv.enable_virtualization_extensions = true
        hv.linked_clone = true
      end

      # Script comum: pré-requisitos + containerd + kubeadm
      worker.vm.provision "shell", path: "scripts/common.sh", args: [K8S_VERSION]

      # Script do worker: kubeadm join
      worker.vm.provision "shell", path: "scripts/worker.sh"
    end
  end
end
