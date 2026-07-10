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
# PRÉ-REQUISITO: criar o switch interno "K8sSwitch" (ver README).

# ===================== CONFIGURAÇÕES =====================
K8S_VERSION = "1.30"

# --- Segregação de rede ---------------------------------------------------
# eth0  -> Default Switch (DHCP)  : plano de MANAGEMENT (SSH/Vagrant)
# eth1  -> K8sSwitch (Internal)   : plano de CLUSTER (API server, kubelet, join)
#
# IPs fixos no switch interno eliminam o port-scan e o sshpass no join.
CLUSTER_SWITCH = "K8sSwitch"       # switch interno criado no host (ver README)
CLUSTER_NETMASK = "24"
# Token de bootstrap fixo (lab). Formato: [a-z0-9]{6}.[a-z0-9]{16}
JOIN_TOKEN = "k8slab.0123456789abcdef"

CONTROL_PLANE = {
  name: "control-plane",
  hostname: "control-plane",
  cpus: 2,
  memory: 1024,
  cluster_ip: "172.30.0.10"
}

WORKERS = [
  { name: "worker-1", hostname: "worker-1", cpus: 2, memory: 1024, cluster_ip: "172.30.0.11" },
  { name: "worker-2", hostname: "worker-2", cpus: 2, memory: 1024, cluster_ip: "172.30.0.12" }
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

    # NIC do plano de cluster (switch interno)
    master.vm.network "private_network", bridge: CLUSTER_SWITCH

    master.vm.provider "hyperv" do |hv|
      hv.vmname = CONTROL_PLANE[:name]
      hv.cpus = CONTROL_PLANE[:cpus]
      hv.memory = CONTROL_PLANE[:memory]
      hv.enable_virtualization_extensions = true
      hv.linked_clone = true
    end

    # common.sh recebe: versão do K8s + IP fixo do plano de cluster
    master.vm.provision "shell", path: "scripts/common.sh",
      args: [K8S_VERSION, CONTROL_PLANE[:cluster_ip], CLUSTER_NETMASK]
    # control-plane.sh recebe: IP fixo (advertise) + token fixo
    master.vm.provision "shell", path: "scripts/control-plane.sh",
      args: [CONTROL_PLANE[:cluster_ip], JOIN_TOKEN]
    master.vm.provision "file", source: "scripts/validate-cluster.sh", destination: "/home/vagrant/validate-cluster.sh"
    master.vm.provision "file", source: "manifests/network-policies.yaml", destination: "/home/vagrant/network-policies.yaml"
  end

  # ============================================================
  # Worker Nodes
  # ============================================================
  WORKERS.each do |worker_config|
    config.vm.define worker_config[:name] do |worker|
      worker.vm.box = BOX_IMAGE
      worker.vm.hostname = worker_config[:hostname]

      # NIC do plano de cluster (switch interno)
      worker.vm.network "private_network", bridge: CLUSTER_SWITCH

      worker.vm.provider "hyperv" do |hv|
        hv.vmname = worker_config[:name]
        hv.cpus = worker_config[:cpus]
        hv.memory = worker_config[:memory]
        hv.enable_virtualization_extensions = true
        hv.linked_clone = true
      end

      worker.vm.provision "shell", path: "scripts/common.sh",
        args: [K8S_VERSION, worker_config[:cluster_ip], CLUSTER_NETMASK]
      # worker.sh recebe: IP fixo do control-plane + token fixo
      worker.vm.provision "shell", path: "scripts/worker.sh",
        args: [CONTROL_PLANE[:cluster_ip], JOIN_TOKEN]
    end
  end
end
