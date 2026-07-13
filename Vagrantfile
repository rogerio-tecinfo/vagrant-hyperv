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
# eth0  -> LOCAL_NETWORK (DHCP)   : plano de MANAGEMENT (SSH/Vagrant)
# eth1  -> K8sSwitch (Internal)   : plano de CLUSTER (API server, kubelet, join)
#
# IPs fixos no switch interno eliminam o port-scan e o sshpass no join.
MGMT_SWITCH = "LOCAL_NETWORK"      # vSwitch de management (eth0) - já existente no host
CLUSTER_SWITCH = "K8sSwitch"       # switch interno criado no host (ver README)
CLUSTER_NETMASK = "24"
# Token de bootstrap fixo (lab). Formato: [a-z0-9]{6}.[a-z0-9]{16}
JOIN_TOKEN = "k8slab.0123456789abcdef"

CONTROL_PLANE = {
  name: "control-plane",
  hostname: "control-plane",
  cpus: 2,
  memory: 2048,
  cluster_ip: "172.30.0.10"
}

WORKERS = [
  { name: "worker-1", hostname: "worker-1", cpus: 2, memory: 1024, cluster_ip: "172.30.0.11" },
  { name: "worker-2", hostname: "worker-2", cpus: 2, memory: 1024, cluster_ip: "172.30.0.12" }
]

BOX_IMAGE = "generic/ubuntu2204"
# =========================================================

# Plugin necessário para o reboot automático após o common.sh.
# O reload aplica o novo machine-id / dhcp-identifier=mac no eth0, garantindo
# que cada VM receba uma lease DHCP única (evita worker-2 com o mesmo IP do eth0).
unless Vagrant.has_plugin?("vagrant-reload")
  raise "Plugin 'vagrant-reload' é obrigatório. Instale com: vagrant plugin install vagrant-reload"
end

Vagrant.configure("2") do |config|
  config.vm.synced_folder ".", "/vagrant", disabled: true
  config.vm.boot_timeout = 600  # 10 min - VMs com 1GB podem demorar

  # ============================================================
  # Control Plane
  # ============================================================
  config.vm.define CONTROL_PLANE[:name], primary: true do |master|
    master.vm.box = BOX_IMAGE
    master.vm.hostname = CONTROL_PLANE[:hostname]

    # NIC primária (eth0) vinculada ao switch de management (DHCP/internet/SSH)
    master.vm.network "public_network", bridge: MGMT_SWITCH

    master.vm.provider "hyperv" do |hv|
      hv.vmname = CONTROL_PLANE[:name]
      hv.cpus = CONTROL_PLANE[:cpus]
      hv.memory = CONTROL_PLANE[:memory]
      hv.maxmemory = CONTROL_PLANE[:memory]
      hv.enable_virtualization_extensions = true
      hv.linked_clone = true
    end

    # Adicionar 2ª NIC (K8sSwitch) ANTES de iniciar a VM.
    # O provider Hyper-V não suporta vm.network "private_network" para criar NICs extras.
    # Usamos um action trigger que executa após a importação, antes do boot.
    master.trigger.before :"VagrantPlugins::HyperV::Action::StartInstance", type: :action do |trigger|
      trigger.info = "Adicionando NIC do cluster (#{CLUSTER_SWITCH}) em #{CONTROL_PLANE[:name]}..."
      trigger.run = {
        privileged: "true",
        powershell_elevated_interactive: "true",
        inline: <<-PS
          $vmName = "#{CONTROL_PLANE[:name]}"
          $switchName = "#{CLUSTER_SWITCH}"
          # Criar switch interno se não existir
          if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
            Write-Host "Criando switch interno '$switchName'..."
            New-VMSwitch -Name $switchName -SwitchType Internal
            $ifAlias = "vEthernet ($switchName)"
            New-NetIPAddress -IPAddress 172.30.0.1 -PrefixLength 24 -InterfaceAlias $ifAlias -ErrorAction SilentlyContinue
          }
          # Adicionar NIC à VM
          $adapter = Get-VM $vmName | Get-VMNetworkAdapter | Where-Object { $_.SwitchName -eq $switchName }
          if ($null -eq $adapter) {
            Write-Host "Adicionando NIC '$switchName' em '$vmName'..."
            Add-VMNetworkAdapter -VMName $vmName -SwitchName $switchName -Name "Cluster"
          } else {
            Write-Host "NIC '$switchName' já existe em '$vmName'. Pulando."
          }
        PS
      }
    end

    # common.sh recebe: versão do K8s + IP fixo do plano de cluster
    master.vm.provision "shell", path: "scripts/common.sh",
      args: [K8S_VERSION, CONTROL_PLANE[:cluster_ip], CLUSTER_NETMASK]
    # Reboot para aplicar machine-id/dhcp-identifier únicos (lease única no eth0)
    # antes de inicializar o cluster.
    master.vm.provision :reload
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

      worker.vm.network "public_network", bridge: MGMT_SWITCH

      worker.vm.provider "hyperv" do |hv|
        hv.vmname = worker_config[:name]
        hv.cpus = worker_config[:cpus]
        hv.memory = worker_config[:memory]
        hv.maxmemory = worker_config[:memory]
        hv.enable_virtualization_extensions = true
        hv.linked_clone = true
      end

      # Adicionar 2ª NIC (K8sSwitch) antes do boot
      worker.trigger.before :"VagrantPlugins::HyperV::Action::StartInstance", type: :action do |trigger|
        trigger.info = "Adicionando NIC do cluster (#{CLUSTER_SWITCH}) em #{worker_config[:name]}..."
        trigger.run = {
          privileged: "true",
          powershell_elevated_interactive: "true",
          inline: <<-PS
            $vmName = "#{worker_config[:name]}"
            $switchName = "#{CLUSTER_SWITCH}"
            # Criar switch interno se não existir
            if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
              Write-Host "Criando switch interno '$switchName'..."
              New-VMSwitch -Name $switchName -SwitchType Internal
              $ifAlias = "vEthernet ($switchName)"
              New-NetIPAddress -IPAddress 172.30.0.1 -PrefixLength 24 -InterfaceAlias $ifAlias -ErrorAction SilentlyContinue
            }
            # Adicionar NIC à VM
            $adapter = Get-VM $vmName | Get-VMNetworkAdapter | Where-Object { $_.SwitchName -eq $switchName }
            if ($null -eq $adapter) {
              Write-Host "Adicionando NIC '$switchName' em '$vmName'..."
              Add-VMNetworkAdapter -VMName $vmName -SwitchName $switchName -Name "Cluster"
            } else {
              Write-Host "NIC '$switchName' já existe em '$vmName'. Pulando."
            }
          PS
        }
      end

      worker.vm.provision "shell", path: "scripts/common.sh",
        args: [K8S_VERSION, worker_config[:cluster_ip], CLUSTER_NETMASK]
      # Reboot para aplicar machine-id/dhcp-identifier únicos (lease única no eth0)
      # antes de fazer o join no cluster.
      worker.vm.provision :reload
      # worker.sh recebe: IP fixo do control-plane + token fixo
      worker.vm.provision "shell", path: "scripts/worker.sh",
        args: [CONTROL_PLANE[:cluster_ip], JOIN_TOKEN]
    end
  end
end
