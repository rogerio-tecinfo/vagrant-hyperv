# Vagrant Hyper-V - Kubernetes Cluster com kubeadm

Cluster Kubernetes automatizado com 1 Control Plane + 2 Worker Nodes no Hyper-V (Windows 11).

## Topologia

![Topologia do Cluster](docs/topology.png)

## Cenário

| VM            | Função         | CPU | RAM    | IP (cluster / eth1) | Componentes |
|---------------|----------------|-----|--------|---------------------|-------------|
| control-plane | Control Plane  | 2   | 1024MB | 172.30.0.10         | kubeadm, kubelet, kubectl, containerd, Calico, etcd, API Server |
| worker-1      | Worker Node    | 2   | 1024MB | 172.30.0.11         | kubeadm, kubelet, containerd, Calico |
| worker-2      | Worker Node    | 2   | 1024MB | 172.30.0.12         | kubeadm, kubelet, containerd, Calico |

> RAM fixada em **1024MB por VM**. O control-plane fica abaixo do mínimo oficial do kubeadm (~1.7GB), por isso o `kubeadm init` usa `--ignore-preflight-errors=Mem`.

### Segregação de rede

O cluster usa **duas interfaces** por VM, separando os planos de tráfego:

| Interface | Switch                  | Faixa            | Uso |
|-----------|-------------------------|------------------|-----|
| `eth0`    | LOCAL_NETWORK (DHCP)    | dinâmica         | **Management** — SSH / Vagrant |
| `eth1`    | K8sSwitch (Internal)    | 172.30.0.0/24    | **Cluster** — API server (6443), kubelet, join |

- **Pod CIDR:** `10.244.0.0/16` (Calico) — sem sobreposição com a rede de nós nem com o Service CIDR.
- **Service CIDR:** `10.96.0.0/12` (padrão kubeadm).
- **NetworkPolicies:** modelo *default-deny* no namespace `default` + liberação explícita de DNS (`manifests/network-policies.yaml`).

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

### 3. Switches virtuais (obrigatório)

O cluster usa **dois** vSwitches:

- **`LOCAL_NETWORK`** — management (eth0). vSwitch **já existente** no host, com saída para a internet (DHCP). É definido em `MGMT_SWITCH` no Vagrantfile.
- **`K8sSwitch`** — plano de cluster (eth1), **Internal** com IPs fixos (`172.30.0.0/24`). Crie-o uma vez, como Administrador:

```powershell
New-VMSwitch -SwitchName "K8sSwitch" -SwitchType Internal
New-NetIPAddress -IPAddress 172.30.0.1 -PrefixLength 24 -InterfaceAlias "vEthernet (K8sSwitch)"
```

> O host fica em `172.30.0.1`; as VMs usam `.10`, `.11`, `.12` (ver Vagrantfile). A `eth0` (LOCAL_NETWORK) provê saída para a internet.
>
> Se o seu vSwitch de management tiver outro nome, ajuste `MGMT_SWITCH` no Vagrantfile.

### 4. Verificar

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

As interfaces já vêm fixadas nos vSwitches (`LOCAL_NETWORK` e `K8sSwitch`) — sem prompt de seleção.

O provisioning executa automaticamente:
1. Configura o IP fixo do plano de cluster (eth1 / K8sSwitch) via netplan
2. Configura pré-requisitos do sistema (swap, módulos, sysctl)
3. Instala containerd 1.7.22 com systemd cgroup driver
4. Instala kubeadm, kubelet e kubectl v1.30.14
5. Inicializa o cluster no control-plane (`kubeadm init` com Pod CIDR `10.244.0.0/16`)
6. Instala o CNI Calico v3.27.0 (alinhado ao Pod CIDR)
7. Aplica as NetworkPolicies (default-deny + allow DNS)
8. Workers fazem join de forma determinística (IP fixo `172.30.0.10` + token fixo, sem scan/SSH)

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

Com IP fixo (`172.30.0.10`) e token fixo, o join é determinístico. Se precisar refazê-lo manualmente:

```powershell
vagrant ssh worker-1 -c "sudo kubeadm join 172.30.0.10:6443 --token k8slab.0123456789abcdef --discovery-token-unsafe-skip-ca-verification"
```

> O token de bootstrap é definido no Vagrantfile (`JOIN_TOKEN`) e criado com `--token-ttl 0` (não expira), evitando o problema de expiração em 24h.

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
├── Vagrantfile                  # Definição das 3 VMs + rede/switch/token (centralizado)
├── README.md                    # Este arquivo
├── docs/
│   ├── topology.dot             # Fonte Graphviz da topologia
│   └── topology.png             # Diagrama da topologia (gerado do .dot)
├── manifests/
│   └── network-policies.yaml    # NetworkPolicies (default-deny + allow DNS)
└── scripts/
    ├── common.sh                # IP fixo (eth1) + pré-requisitos + containerd + kubeadm
    ├── control-plane.sh         # kubeadm init + Calico + NetworkPolicies (control-plane)
    ├── worker.sh                # kubeadm join determinístico (workers)
    └── validate-cluster.sh      # Health check do cluster
```

> Para regenerar a imagem da topologia após editar o `.dot`:
> `dot -Tpng -Gdpi=120 docs/topology.dot -o docs/topology.png`

## Observações sobre Hyper-V + Kubernetes

### Rede (segregação de planos)
- **eth0** (LOCAL_NETWORK/DHCP) = management: SSH/Vagrant e saída para a internet.
- **eth1** (K8sSwitch/Internal, `172.30.0.0/24`, estático) = plano de cluster: API server, kubelet e join.
- O `node-ip` do kubelet é fixado na eth1 (`--node-ip`), garantindo que o `InternalIP` dos nós fique na rede de cluster.
- **Pod CIDR:** `10.244.0.0/16` (Calico, alinhado ao `--pod-network-cidr`). Evita a colisão que ocorria com `192.168.0.0/16` vs. a faixa do vSwitch de management.
- **Service CIDR:** `10.96.0.0/12` (padrão do kubeadm).

### Descoberta do Control Plane (determinística)

Com IP fixo e token fixo, os workers não fazem mais scan de rede nem SSH:
1. Aguardam o API Server responder em `172.30.0.10:6443` (retry).
2. Executam `kubeadm join` com o token de bootstrap fixo.
3. Isso remove o antigo mecanismo de `port-scan` + `sshpass` (senha em claro / sem verificação de host key).

> **Trade-off (lab):** o join usa `--discovery-token-unsafe-skip-ca-verification`, aceitável em rede interna isolada. Em produção, use o `--discovery-token-ca-cert-hash` real.

### NetworkPolicies

`manifests/network-policies.yaml` aplica no namespace `default`:
- `default-deny-all` — bloqueia todo ingress/egress por padrão.
- `allow-dns-egress` — libera DNS (UDP/TCP 53) para o CoreDNS.

Replique o padrão em cada namespace de workload, liberando apenas o necessário (menor privilégio). O `kube-system` não é afetado.

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
