# Vagrant Hyper-V - Kubernetes Cluster com kubeadm

Cluster Kubernetes automatizado com 1 Control Plane + 2 Worker Nodes no Hyper-V (Windows 11).

## Topologia

![Topologia do Cluster](docs/topology.png)

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          Windows 11 Host                                  │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │               Hyper-V Default Switch (NAT + DHCP)                  │  │
│  │                    192.168.x.0/24                                   │  │
│  └──────────┬────────────────────┬────────────────────┬───────────────┘  │
│             │                    │                    │                   │
│  ┌──────────▼──────────┐ ┌──────▼──────────┐ ┌──────▼──────────┐        │
│  │   control-plane     │ │    worker-1     │ │    worker-2     │        │
│  │   Ubuntu 22.04      │ │   Ubuntu 22.04  │ │   Ubuntu 22.04  │        │
│  │   2 vCPU | 1 GB     │ │   2 vCPU | 1 GB │ │   2 vCPU | 1 GB │        │
│  │                     │ │                 │ │                 │        │
│  │  ┌───────────────┐  │ │  ┌───────────┐  │ │  ┌───────────┐  │        │
│  │  │  containerd   │  │ │  │ containerd│  │ │  │ containerd│  │        │
│  │  │  kubelet      │  │ │  │ kubelet   │  │ │  │ kubelet   │  │        │
│  │  │  kubeadm      │  │ │  │ kubeadm   │  │ │  │ kubeadm   │  │        │
│  │  │  kubectl      │  │ │  └───────────┘  │ │  └───────────┘  │        │
│  │  │               │  │ │                 │ │                 │        │
│  │  │  API Server   │  │ │   join ───────────────────┐         │        │
│  │  │  etcd         │  │ │       ▲         │ │       ▲         │        │
│  │  │  scheduler    │  │ │       │         │ │       │         │        │
│  │  │  ctrl-manager │  │ │       │         │ │       │         │        │
│  │  │               │  │ │       │         │ │       │         │        │
│  │  │  Calico (CNI) │  │ │  Calico (CNI)   │ │  Calico (CNI)   │        │
│  │  └───────┬───────┘  │ │       │         │ │       │         │        │
│  └──────────┼──────────┘ └───────┼─────────┘ └───────┼─────────┘        │
│             │                    │                    │                   │
│             └────────────────────┴────────────────────┘                   │
│                        API Server :6443                                    │
│                     Pod CIDR: 192.168.0.0/16                              │
│                   Service CIDR: 10.96.0.0/12                              │
└──────────────────────────────────────────────────────────────────────────┘
```

## Cenário

| VM            | Função         | CPU | RAM    | Componentes |
|---------------|----------------|-----|--------|-------------|
| control-plane | Control Plane  | 2   | 1024MB | kubeadm, kubelet, kubectl, containerd, Calico, etcd, API Server |
| worker-1      | Worker Node    | 2   | 1024MB | kubeadm, kubelet, containerd, Calico |
| worker-2      | Worker Node    | 2   | 1024MB | kubeadm, kubelet, containerd, Calico |

## Stack

| Componente | Versão |
|------------|--------|
| OS | Ubuntu 22.04 (generic/ubuntu2204) |
| Container Runtime | containerd 1.7.22 |
| Kubernetes | v1.30.14 (kubeadm) |
| CNI | Calico v3.27.0 |
| Hypervisor | Hyper-V (Windows 11) |
| Automação | Vagrant + Shell provisioning |

## Pré-requisitos (Windows 11)

### 1. Habilitar Hyper-V

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
```

Reiniciar após a instalação.

### 2. Instalar Vagrant

https://developer.hashicorp.com/vagrant/install

### 3. Verificar

```powershell
vagrant --version
Get-VMSwitch
```

## Como usar

### Subir o cluster

> ⚠️ Executar o terminal como **Administrador**.

```powershell
cd <caminho-do-projeto>
vagrant up --provider=hyperv
```

Selecione o **Default Switch** quando perguntado.

O provisioning executa automaticamente:
1. Configura pré-requisitos do sistema (swap, módulos, sysctl)
2. Instala containerd 1.7.22 com systemd cgroup driver
3. Instala kubeadm, kubelet e kubectl v1.30.14
4. Inicializa o cluster no control-plane (`kubeadm init`)
5. Instala o CNI Calico v3.27.0
6. Workers fazem join automaticamente (scan de rede + SSH)

### Verificar o cluster

```powershell
vagrant ssh control-plane
```

```bash
kubectl get nodes
kubectl get pods -A

# Health check completo
bash /home/vagrant/validate-cluster.sh
```

### Aliases disponíveis

Ao acessar qualquer VM, os seguintes aliases estão configurados:

```bash
k       # kubectl
kgn     # kubectl get nodes
kgp     # kubectl get pods -A
```

### Reprovisioning (idempotente)

Os scripts podem ser executados múltiplas vezes sem efeitos colaterais:

```powershell
# Re-executar toda a configuração (não recria as VMs)
vagrant provision

# Apenas no control-plane
vagrant provision control-plane
```

Se precisar reinicializar o cluster do zero:

```powershell
# Reset antes de reprovisionar
vagrant ssh control-plane -c "sudo kubeadm reset -f"
vagrant ssh worker-1 -c "sudo kubeadm reset -f"
vagrant ssh worker-2 -c "sudo kubeadm reset -f"

# Re-provisionar
vagrant provision
```

### Join manual dos workers (se necessário)

Como o Hyper-V usa DHCP, o join automático pode falhar. Nesse caso:

```powershell
# 1. Obter o comando de join
vagrant ssh control-plane -c "cat /home/vagrant/join-command.sh"

# 2. Executar no worker
vagrant ssh worker-1 -c "sudo kubeadm join <IP>:6443 --token <token> --discovery-token-ca-cert-hash <hash>"
vagrant ssh worker-2 -c "sudo kubeadm join <IP>:6443 --token <token> --discovery-token-ca-cert-hash <hash>"
```

### Se o token expirar (24h)

```bash
# No control-plane
kubeadm token create --print-join-command
```

## Comandos úteis

```powershell
# Status das VMs
vagrant status

# Acessar VMs
vagrant ssh control-plane
vagrant ssh worker-1
vagrant ssh worker-2

# Parar o cluster
vagrant halt

# Destruir tudo
vagrant destroy -f

# Recriar apenas um worker
vagrant destroy worker-1 -f && vagrant up worker-1 --provider=hyperv
```

## Estrutura do projeto

```
.
├── Vagrantfile              # Definição das 3 VMs (configurações centralizadas)
├── README.md                # Este arquivo
├── docs/
│   └── topology.png         # Diagrama da topologia
└── scripts/
    ├── common.sh            # Pré-requisitos + containerd + kubeadm (todas as VMs)
    ├── control-plane.sh     # kubeadm init + Calico (somente control-plane)
    ├── worker.sh            # kubeadm join (somente workers)
    └── validate-cluster.sh  # Health check do cluster
```

## Observações sobre Hyper-V + Kubernetes

### Rede
- O Hyper-V atribui IPs via DHCP (Default Switch). Não há IPs estáticos via Vagrant.
- O script detecta automaticamente o IP da VM em múltiplas interfaces (eth0, ens33, enp0s1) com fallback via `ip route`.
- O Calico gerencia a rede de pods (CIDR: 192.168.0.0/16).
- Service CIDR: 10.96.0.0/12 (padrão do kubeadm).

### Descoberta automática do Control Plane

Os workers descobrem o control-plane automaticamente:
1. Tentam resolver o hostname `control-plane`
2. Fazem scan otimizado na porta 6443 (IPs próximos primeiro)
3. Obtêm o join command via SSH (senha padrão do Vagrant)
4. Validam o formato do comando antes de executar

### Para IPs fixos (recomendado para produção)

Crie um switch interno no Windows:

```powershell
New-VMSwitch -SwitchName "K8sSwitch" -SwitchType Internal
New-NetIPAddress -IPAddress 172.89.0.1 -PrefixLength 24 -InterfaceAlias "vEthernet (K8sSwitch)"
New-NetNat -Name "K8sNAT" -InternalIPInterfaceAddressPrefix "172.89.0.0/24"
```

### Troubleshooting

```bash
# Verificar status dos nodes
kubectl get nodes -o wide

# Verificar todos os pods
kubectl get pods -A

# Logs do kubelet
systemctl status kubelet
journalctl -u kubelet -f

# Verificar containerd
systemctl status containerd
crictl ps

# Re-gerar token de join (se expirou)
kubeadm token create --print-join-command

# Reset de um node (para refazer o join)
sudo kubeadm reset -f

# Verificar conectividade com o API Server
curl -k https://<IP-control-plane>:6443/healthz
```

## Credenciais

| Campo | Valor |
|-------|-------|
| Usuário | `vagrant` |
| Senha | `vagrant` |
| Sudo | sem senha (NOPASSWD) |
| Acesso | `vagrant ssh <vm-name>` |
