# -*- mode: ruby -*-
# vi: set ft=ruby :

# Cenário: Kubernetes Cluster com kubeadm no Hyper-V (Windows 11)
# - 1 Control Plane + 2 Worker Nodes
# - Container Runtime: containerd
# - CNI: Calico
# - Kubernetes v1.30
#
# Uso:
#   vagrant up --provider=hyperv       (criar cluster)
#   vagrant provision                  (re-executar scripts - idempotente)
#   vagrant provision control-plane    (apenas control-plane)
#   vagrant destroy -f                 (destruir tudo)
#
# IMPORTANTE: Executar como Administrador

# ===================== CONFIGURAÇÕES =====================
K8S_VERSION = "1.30"

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

BOX_IMAGE = "generic/ubuntu2204"
# =========================================================

Vagrant.configure("2") do |config|
  config.vm.synced_folder ".", "/vagrant", disabled: true
  config.vm.boot_timeout = 600  # 10 min - VMs com 1GB podem demorar

  # ============================================================
  # Control Plane
  # ============================================================
  config.vm.define CONTROL_PLANE[:name], primary: true do |master|
    master.vm.box = BOX_IMAGE
    master.vm.hostname = CONTROL_PLANE[:hostname]

    master.vm.provider "hyperv" do |hv|
      hv.vmname = CONTROL_PLANE[:name]
      hv.cpus = CONTROL_PLANE[:cpus]
      hv.memory = CONTROL_PLANE[:memory]
      hv.enable_virtualization_extensions = true
      hv.linked_clone = true
    end

    master.vm.provision "shell", path: "scripts/common.sh", args: [K8S_VERSION]
    master.vm.provision "shell", path: "scripts/control-plane.sh"
    master.vm.provision "file", source: "scripts/validate-cluster.sh", destination: "/home/vagrant/validate-cluster.sh"
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
        hv.enable_virtualization_extensions = true
        hv.linked_clone = true
      end

      worker.vm.provision "shell", path: "scripts/common.sh", args: [K8S_VERSION]
      worker.vm.provision "shell", path: "scripts/worker.sh"
    end
  end
end
