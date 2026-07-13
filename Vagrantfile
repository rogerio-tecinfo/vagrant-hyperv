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
# eth0  -> LOCAL_NETWORK (estático) : plano de MANAGEMENT (SSH/Vagrant/internet)
# eth1  -> K8sSwitch (Internal)     : plano de CLUSTER (API server, kubelet, join)
#
# IPs fixos em AMBAS as interfaces eliminam a dependência de DHCP e garantem
# que cada VM tenha endereço único e determinístico.
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
  cluster_ip: "172.30.0.10",
  mgmt_ip: "192.168.15.10"
}

WORKERS = [
  { name: "worker-1", hostname: "worker-1", cpus: 2, memory: 1024, cluster_ip: "172.30.0.11", mgmt_ip: "192.168.15.11" },
  { name: "worker-2", hostname: "worker-2", cpus: 2, memory: 1024, cluster_ip: "172.30.0.12", mgmt_ip: "192.168.15.12" }
]

# Gateway e DNS da rede de management (192.168.15.0/24)
# Ajustar conforme seu roteador. O gateway é necessário para saída à internet.
MGMT_GATEWAY = "192.168.15.1"
MGMT_DNS     = "8.8.8.8,8.8.4.4"
MGMT_NETMASK = "24"

BOX_IMAGE = "generic/ubuntu2204"
# =========================================================

# Plugin necessário para o reboot automático após o fix-dhcp-identity.sh.
# O reload aplica o IP estático na eth0, garantindo que cada VM tenha um IP
# de management único antes de iniciar o provisioning de K8s.
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

    master.vm.provider "hyperv" do |hv|
      hv.vmname = CONTROL_PLANE[:name]
      hv.cpus = CONTROL_PLANE[:cpus]
      hv.memory = CONTROL_PLANE[:memory]
      hv.maxmemory = CONTROL_PLANE[:memory]
      hv.enable_virtualization_extensions = true
      hv.linked_clone = true
    end

    # Configurar NICs ANTES de iniciar a VM:
    # - NIC padrão (criada pelo Vagrant) → conectar ao LOCAL_NETWORK (management)
    # - NIC extra "Cluster" → conectar ao K8sSwitch (cluster)
    # Isso garante exatamente 2 NICs por VM.
    master.trigger.before :"VagrantPlugins::HyperV::Action::StartInstance", type: :action do |trigger|
      trigger.info = "Configurando NICs de #{CONTROL_PLANE[:name]}..."
      trigger.run = {
        privileged: "true",
        powershell_elevated_interactive: "true",
        inline: <<-PS
          $vmName = "#{CONTROL_PLANE[:name]}"
          $mgmtSwitch = "#{MGMT_SWITCH}"
          $clusterSwitch = "#{CLUSTER_SWITCH}"

          # --- Conectar NIC padrão ao switch de management ---
          $defaultNic = Get-VM $vmName | Get-VMNetworkAdapter | Select-Object -First 1
          if ($defaultNic -and $defaultNic.SwitchName -ne $mgmtSwitch) {
            Write-Host "Conectando NIC padrao ao switch '$mgmtSwitch'..."
            Connect-VMNetworkAdapter -VMName $vmName -Name $defaultNic.Name -SwitchName $mgmtSwitch
          }

          # --- Criar switch interno K8sSwitch se não existir ---
          if (-not (Get-VMSwitch -Name $clusterSwitch -ErrorAction SilentlyContinue)) {
            Write-Host "Criando switch interno '$clusterSwitch'..."
            New-VMSwitch -Name $clusterSwitch -SwitchType Internal
            $ifAlias = "vEthernet ($clusterSwitch)"
            New-NetIPAddress -IPAddress 172.30.0.1 -PrefixLength 24 -InterfaceAlias $ifAlias -ErrorAction SilentlyContinue
          }

          # --- Adicionar NIC de cluster (se não existir) ---
          $clusterNic = Get-VM $vmName | Get-VMNetworkAdapter | Where-Object { $_.SwitchName -eq $clusterSwitch }
          if ($null -eq $clusterNic) {
            Write-Host "Adicionando NIC '$clusterSwitch' em '$vmName'..."
            Add-VMNetworkAdapter -VMName $vmName -SwitchName $clusterSwitch -Name "Cluster"
          } else {
            Write-Host "NIC '$clusterSwitch' ja existe em '$vmName'. Pulando."
          }

          # --- Remover NICs extras (mais de 2 = sobra de configs anteriores) ---
          $allNics = Get-VM $vmName | Get-VMNetworkAdapter
          if ($allNics.Count -gt 2) {
            Write-Host "Removendo NICs extras (total: $($allNics.Count), esperado: 2)..."
            $allNics | Select-Object -Skip 2 | ForEach-Object {
              Write-Host "  Removendo NIC: $($_.Name) ($($_.SwitchName))"
              Remove-VMNetworkAdapter -VMName $vmName -Name $_.Name
            }
          }
        PS
      }
    end

    # 1. Corrigir identidade de rede ANTES do reboot: atribui IP estático na eth0
    master.vm.provision "shell", path: "scripts/fix-dhcp-identity.sh",
      args: [CONTROL_PLANE[:mgmt_ip], MGMT_NETMASK, MGMT_GATEWAY, MGMT_DNS]
    # 2. Reboot para aplicar: VM reinicia com IP estático único na eth0
    master.vm.provision :reload
    # 3. Após reboot (IP único): configurar pré-requisitos do K8s
    master.vm.provision "shell", path: "scripts/common.sh",
      args: [K8S_VERSION, CONTROL_PLANE[:cluster_ip], CLUSTER_NETMASK]
    # 4. Inicializar cluster
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

      worker.vm.provider "hyperv" do |hv|
        hv.vmname = worker_config[:name]
        hv.cpus = worker_config[:cpus]
        hv.memory = worker_config[:memory]
        hv.maxmemory = worker_config[:memory]
        hv.enable_virtualization_extensions = true
        hv.linked_clone = true
      end

      # Configurar NICs ANTES de iniciar a VM
      worker.trigger.before :"VagrantPlugins::HyperV::Action::StartInstance", type: :action do |trigger|
        trigger.info = "Configurando NICs de #{worker_config[:name]}..."
        trigger.run = {
          privileged: "true",
          powershell_elevated_interactive: "true",
          inline: <<-PS
            $vmName = "#{worker_config[:name]}"
            $mgmtSwitch = "#{MGMT_SWITCH}"
            $clusterSwitch = "#{CLUSTER_SWITCH}"

            # --- Conectar NIC padrão ao switch de management ---
            $defaultNic = Get-VM $vmName | Get-VMNetworkAdapter | Select-Object -First 1
            if ($defaultNic -and $defaultNic.SwitchName -ne $mgmtSwitch) {
              Write-Host "Conectando NIC padrao ao switch '$mgmtSwitch'..."
              Connect-VMNetworkAdapter -VMName $vmName -Name $defaultNic.Name -SwitchName $mgmtSwitch
            }

            # --- Criar switch interno K8sSwitch se não existir ---
            if (-not (Get-VMSwitch -Name $clusterSwitch -ErrorAction SilentlyContinue)) {
              Write-Host "Criando switch interno '$clusterSwitch'..."
              New-VMSwitch -Name $clusterSwitch -SwitchType Internal
              $ifAlias = "vEthernet ($clusterSwitch)"
              New-NetIPAddress -IPAddress 172.30.0.1 -PrefixLength 24 -InterfaceAlias $ifAlias -ErrorAction SilentlyContinue
            }

            # --- Adicionar NIC de cluster (se não existir) ---
            $clusterNic = Get-VM $vmName | Get-VMNetworkAdapter | Where-Object { $_.SwitchName -eq $clusterSwitch }
            if ($null -eq $clusterNic) {
              Write-Host "Adicionando NIC '$clusterSwitch' em '$vmName'..."
              Add-VMNetworkAdapter -VMName $vmName -SwitchName $clusterSwitch -Name "Cluster"
            } else {
              Write-Host "NIC '$clusterSwitch' ja existe em '$vmName'. Pulando."
            }

            # --- Remover NICs extras (mais de 2 = sobra de configs anteriores) ---
            $allNics = Get-VM $vmName | Get-VMNetworkAdapter
            if ($allNics.Count -gt 2) {
              Write-Host "Removendo NICs extras (total: $($allNics.Count), esperado: 2)..."
              $allNics | Select-Object -Skip 2 | ForEach-Object {
                Write-Host "  Removendo NIC: $($_.Name) ($($_.SwitchName))"
                Remove-VMNetworkAdapter -VMName $vmName -Name $_.Name
              }
            }
          PS
        }
      end

      # 1. Corrigir identidade de rede ANTES do reboot: atribui IP estático na eth0
      worker.vm.provision "shell", path: "scripts/fix-dhcp-identity.sh",
        args: [worker_config[:mgmt_ip], MGMT_NETMASK, MGMT_GATEWAY, MGMT_DNS]
      # 2. Reboot para aplicar: VM reinicia com IP estático único na eth0
      worker.vm.provision :reload
      # 3. Após reboot (IP único): configurar pré-requisitos do K8s
      worker.vm.provision "shell", path: "scripts/common.sh",
        args: [K8S_VERSION, worker_config[:cluster_ip], CLUSTER_NETMASK]
      # 4. Join no cluster
      worker.vm.provision "shell", path: "scripts/worker.sh",
        args: [CONTROL_PLANE[:cluster_ip], JOIN_TOKEN]
    end
  end
end
