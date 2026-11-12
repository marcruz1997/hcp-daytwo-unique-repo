# Manual: criar um cluster e configurar o day-2

Este manual cobre o dia a dia: criar um cluster, escolher o que ele tem, mudar depois e destruir.
Para entender e investigar as policies, veja [LEITURA-POLICIES.md](LEITURA-POLICIES.md).

---

## 1. Antes do primeiro cluster (uma vez só)

| O quê | Onde | Como |
|---|---|---|
| Chave SSH pública padrão | `provisioning/base/params-defaults.yaml` → `sshPublicKey` | `cat ~/.ssh/hcp-clusters.pub` |
| Servidores NTP | `provisioning/features/ntp/chrony-configmap.yaml` | `scripts/chrony-b64.sh ntp1 ntp2` e cole o resultado na linha `source:` |
| Horário e retenção do backup do etcd | `provisioning/features/etcd-backup/resources.yaml` | `schedule` e `RETENTION_DAYS` |
| S3 para o Loki (só se usar loki/logging) | Hub | `oc get sc \| grep noobaa` e `oc -n openshift-storage get route s3` devem existir (ODF com MCG). Endpoint e CA são descobertos automaticamente pela policy `loki-s3-endpoint` |

> Os valores em `params-defaults.yaml` valem para **todos** os clusters que não os sobrescreverem.
> Senha de admin: defina **uma por cluster** (seção 3). Não dependa do padrão.

---

## 2. Criar a pasta do cluster

Nome: minúsculas, números e `-` (ex.: `app01`, `hml-pagamentos`).

```bash
scripts/new-cluster.sh app01
```

Isso cria `clusters/app01/` a partir de `docs/cluster-template/`:

```
clusters/app01/
  cluster/kustomization.yaml   <- VOCÊ EDITA SÓ ESTE
  policy.yaml                  <- fixo, igual em todos (o nome vem da PASTA)
  kustomization.yaml           <- fixo
```

Sem o script (VS Code): copie `docs/cluster-template` para `clusters/app01` e troque `NOME` por
`app01` em `cluster/kustomization.yaml` (o `name:` do patch).

> **O nome da pasta TEM que ser igual ao `name:` do patch.** O nome da policy (`hcp-<pasta>`),
> do binding e o label `pg.lab/cluster` vêm da pasta, preenchidos pelo ApplicationSet; o nome
> do HostedCluster/ManagedCluster vem do `name:`. Se forem diferentes, a policy fica com um nome
> e o cluster com outro.

---

## 3. Declarar o cluster

Abra `clusters/app01/cluster/kustomization.yaml`. São três blocos:

### 3.1 `components`: o que o cluster tem

Uma linha por item. **A ordem não importa.**

| Linha | Efeito |
|---|---|
| `workers/<size>` | Tamanho dos workers (obrigatório ter um) |
| `infra/<size>` | Cria o NodePool de infra já no tamanho |
| `features/oauth-htpasswd` | Login htpasswd + cluster-admin para o `adminUser` |
| `features/ntp` | chrony em todos os nós |
| `features/etcd-backup` | Snapshot diário do etcd (no hub) |
| `features/ingress` | Router nos nós de infra |
| `features/registry` | Image registry interno com PVC |
| `features/observability` | Prometheus/Alertmanager persistentes + user workload + COO |
| `features/logging` | Logging (app, infra, audit) → Loki. **Já inclui o loki** (tamanho: `loki.size`, ver 3.1.1) |
| `features/loki` | Só o Loki (use apenas sem `logging`; tamanho: `loki.size`) |

Tamanhos (`demo` só para lab):

| size | cores | memória | disco |
|---|---|---|---|
| demo | 2 | 8Gi | 120Gi |
| small | 4 | 16Gi | 120Gi |
| medium | 8 | 32Gi | 120Gi |
| large | 16 | 64Gi | 120Gi |
| xlarge | 32 | 128Gi | 120Gi |

#### 3.1.1 Tamanho do Loki (`loki.size`)

Com `features/logging` ou `features/loki`, o tamanho da instância vem de `loki.size` no patch
(padrão: `1x.demo`, em `provisioning/base/params-defaults.yaml`).

| `loki.size` | Uso | Alta disponibilidade | Suporte Red Hat | Nós de infra sugeridos |
|---|---|---|---|---|
| `1x.demo` (padrão) | Lab/demonstração | Não | **Não** (só testes) | `infra/small` ou maior |
| `1x.pico` | Produção pequena | Sim | Sim | `infra/medium` ou maior |
| `1x.extra-small` | Produção pequena | Sim | Sim | `infra/medium` ou maior |
| `1x.small` | Produção média | Sim | Sim | `infra/large` ou maior |
| `1x.medium` | Produção grande | Sim | Sim | `infra/xlarge` |

```yaml
spec:
  name: app01
  loki: {size: "1x.small", retentionDays: "30"}   # ENTRE aspas
```

> Os tamanhos disponíveis dependem da versão do Loki Operator; confira na documentação do
> Logging da sua versão. Retenção (`loki.retentionDays`) é independente do tamanho.

### 3.2 `patches`: só o que muda em relação ao padrão

Tudo que **não** estiver no patch vem de `provisioning/base/params-defaults.yaml`.
Exemplo com **todos** os campos possíveis:

```yaml
patches:
  - target: {kind: ClusterParams}
    patch: |-
      kind: ClusterParams
      metadata: {name: params}
      spec:
        # --- identidade ---
        name: app01                                   # OBRIGATÓRIO
        env: prd
        # --- versão ---
        releaseImage: quay.io/openshift-release-dev/ocp-release:4.18.60-multi
        # --- rede ---
        clusterNetwork: 10.140.0.0/14
        serviceNetwork: 172.32.0.0/16
        # --- nós (números, SEM aspas) ---
        workerReplicas: 3
        infraReplicas: 3
        # --- acesso ---
        sshPublicKey: "ssh-rsa AAAA... app01"
        oauth:
          adminUser: "admin"
          htpasswd: |
            admin:$2y$05$...
            dev1:$2y$05$...
        # --- day-2 (valores ENTRE aspas) ---
        ingress: {replicas: "3"}
        observability:
          prometheusRetention: "15d"
          prometheusStorage: "100Gi"
          alertmanagerStorage: "5Gi"
          uwmRetention: "7d"
          uwmStorage: "50Gi"
        loki:
          size: "1x.small"
          retentionDays: "15"
          bucketStorageClass: "openshift-storage.noobaa.io"
```

#### 3.2.1 Referência completa dos parâmetros

| Campo | Padrão | Formato | Muda depois de criado? | Usado por |
|---|---|---|---|---|
| `name` | (obrigatório) | minúsculas, números, `-` | **Não** (é a identidade do cluster) | tudo |
| `env` | `dev` | texto | Sim (só label) | label `env` no ManagedCluster |
| `releaseImage` | `...ocp-release:4.18.60-multi` | imagem | Sim = **upgrade** | HostedCluster e NodePools |
| `clusterNetwork` | `10.132.0.0/14` | CIDR | **Não** (imutável) | rede de pods (seção 3.2.2) |
| `serviceNetwork` | `172.31.0.0/16` | CIDR | **Não** (imutável) | rede de services (seção 3.2.2) |
| `workerReplicas` | `2` | número, **sem aspas** | Sim (adiciona/remove nós) | NodePool de workers |
| `infraReplicas` | `3` | número, **sem aspas** | Sim | NodePool de infra (`infra/<size>`) |
| `sshPublicKey` | chave da base | texto | Sim (pode **recriar os nós**) | Secret `sshkey-cluster-<nome>` |
| `oauth.adminUser` | `admin` | texto, entre aspas | Sim | cluster-admin (`features/oauth-htpasswd`) |
| `oauth.htpasswd` | hash da base | linhas `usuario:hash` | Sim (sem impacto nos nós) | IdP htpasswd |
| `ingress.replicas` | `"2"` | **entre aspas** | Sim | routers (`features/ingress`) |
| `observability.prometheusRetention` | `7d` | entre aspas | Sim | Prometheus |
| `observability.prometheusStorage` | `20Gi` | entre aspas | Só **aumentar** (PVC) | PVC do Prometheus |
| `observability.alertmanagerStorage` | `5Gi` | entre aspas | Só aumentar | PVC do Alertmanager |
| `observability.uwmRetention` | `7d` | entre aspas | Sim | Prometheus de user workload |
| `observability.uwmStorage` | `20Gi` | entre aspas | Só aumentar | PVC do user workload |
| `loki.size` | `1x.demo` | entre aspas | Sim (recria pods do Loki) | LokiStack (seção 3.1.1) |
| `loki.retentionDays` | `"7"` | número **entre aspas** | Sim | retenção dos logs |
| `loki.bucketStorageClass` | `openshift-storage.noobaa.io` | StorageClass do hub | Só antes de criar o bucket | ObjectBucketClaim |

> Por que aspas em uns e não em outros? Réplicas de NodePool vão direto num campo numérico.
> Os demais viram **labels** do ManagedCluster (lidos pelas policies), e label é sempre texto.

#### 3.2.2 Rede de cada cluster

```yaml
      spec:
        name: app01
        clusterNetwork: 10.140.0.0/14   # pods
        serviceNetwork: 172.32.0.0/16   # services
```

| Regra | Por quê |
|---|---|
| **Não pode sobrepor as redes do hub** (pods, services, máquinas) | os nós do cluster são VMs dentro do hub |
| **Pode repetir entre clusters filhos** | cada hosted cluster tem a rede encapsulada e isolada |
| **Não muda depois de criado** | campos imutáveis: a policy fica NonCompliant com `... is immutable` |
| Pods: `/14` recomendado; services: no mínimo `/23` | espaço para nós e services |

Redes do hub (para não sobrepor):
```bash
oc get network.config cluster -o jsonpath='pods: {.spec.clusterNetwork[*].cidr}{"\n"}services: {.spec.serviceNetwork[*]}{"\n"}'
oc get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'
```
Padrão do OpenShift no hub: pods `10.128.0.0/14`, services `172.30.0.0/16` (por isso os padrões
do repo são `10.132.0.0/14` e `172.31.0.0/16`).

O tipo de rede é fixo em `OVNKubernetes` e os nós usam a rede padrão de pods do hub
(`attachDefaultNetwork: true`). Redes secundárias/VLAN para os nós: ver seção 9.

#### 3.2.3 Versão

```bash
oc get clusterimagesets          # versões conhecidas pelo hub
```
Use uma versão suportada pelo MCE/HyperShift do hub. Mudar `releaseImage` num cluster existente é
**upgrade**: primeiro o control plane, depois os nós são substituídos um a um.

#### 3.2.4 Acesso

- **SSH**: chave **pública**. Padrão para todos em `params-defaults.yaml`; por cluster com
  `sshPublicKey`. Acesso: `ssh -i ~/.ssh/<chave> core@<ip-do-nó>`.
- **Login**: com `features/oauth-htpasswd`, cada linha de `oauth.htpasswd` é um usuário
  (`htpasswd -nbB <usuario> '<senha>'`). Só o `oauth.adminUser` recebe cluster-admin; os outros
  entram sem permissões (dê RBAC a eles como quiser). Recomendado: **uma senha por cluster**.
- **kubeconfig de admin** (sempre existe): `oc -n clusters extract secret/<nome>-admin-kubeconfig --to=-`.

**Regras rápidas**
- `workerReplicas` / `infraReplicas`: números **sem** aspas.
- Tudo de `ingress`, `observability`, `loki`, `oauth.adminUser`: **entre aspas**.
- `ingress.replicas` ≤ `infraReplicas` (1 router por nó). Sem infra: ≤ `workerReplicas`.
- Indentação dentro do `patch: |-` igual ao exemplo (é o erro de build mais comum).

### 3.3 `transformers`: não mexa

```yaml
transformers: [../../../provisioning/apply-params]
```

Exemplo completo com tudo ligado: [README → Criar um cluster](../README.md) e o template em
`docs/cluster-template/cluster/kustomization.yaml`.

---

## 4. Publicar

```bash
git add clusters/app01
git commit -m "cria cluster app01"
git push
```

## 5. Acompanhar a criação

| Tempo | Comando | Esperado |
|---|---|---|
| ~1 min | `oc -n openshift-gitops get applications.argoproj.io pg-app01` | `Synced` |
| ~1 min | `oc -n pg-provisioning get policy hcp-app01` | existe (NonCompliant no começo é normal) |
| 2–5 min | `oc -n clusters get hostedcluster,nodepool \| grep app01` | HostedCluster + NodePools |
| 15–30 min | `oc get managedcluster app01` | `JOINED=True AVAILABLE=True` |
| depois | `oc -n app01 get policies` | features `Compliant` |

App no Argo **Degraded** = policy NonCompliant. Nos primeiros minutos é esperado (o namespace
do KlusterletAddonConfig só existe depois do registro). Se passar de ~15 min, veja
[LEITURA-POLICIES.md → Troubleshooting](LEITURA-POLICIES.md#5-troubleshooting).

Acesso ao cluster:
```bash
oc -n clusters extract secret/app01-admin-kubeconfig --to=- > /tmp/app01.kubeconfig
oc --kubeconfig /tmp/app01.kubeconfig get nodes
# ou login com o admin do htpasswd:
API=$(oc -n clusters get hostedcluster app01 -o jsonpath='{.status.controlPlaneEndpoint.host}')
oc login https://$API:6443 -u admin
```

---

## 6. Mudar um cluster existente

Edite `clusters/app01/cluster/kustomization.yaml` e faça push. O ACM aplica sozinho.

| Mudança | Impacto |
|---|---|
| Ligar `ingress`, `registry`, `observability`, `logging`, `loki` | Sem impacto nos nós |
| Ligar `infra/<size>` | Cria VMs novas; router/registry/monitoring/loki migram para a infra |
| Trocar `workers/<size>` ou `infra/<size>` | **Recria os nós** do pool (um por vez) |
| Mudar `workerReplicas` / `infraReplicas` | Adiciona/remove nós |
| Ligar ou mudar `ntp` | **Recria todos os nós** |
| Trocar senha (`oauth.htpasswd`) | OAuth recarrega, nós intactos |
| Mudar `releaseImage` | **Upgrade** do cluster (control plane, depois workers) |
| Tirar uma feature da lista | A policy para de gerenciar, mas **não apaga** o que já criou |

---

## 7. Destruir um cluster (manual, nesta ordem)

```bash
# 1. tira do Git: remove o app e a policy (o cluster CONTINUA, de propósito)
git rm -r clusters/app01 && git commit -m "remove app01" && git push
oc -n pg-provisioning get policy hcp-app01        # esperar sumir

# 2. desanexar do ACM e esperar (o cluster precisa estar vivo para limpar os addons)
oc delete managedcluster app01
oc get ns app01 -w

# 3. destruir
oc -n clusters delete hostedcluster app01

# 4. sobras
oc -n clusters delete secret sshkey-cluster-app01 htpasswd-app01 --ignore-not-found
oc -n clusters delete configmap app01-chrony --ignore-not-found
oc -n hcp-etcd-backup delete cronjob,pvc etcd-backup-app01 --ignore-not-found
oc -n pg-policies-features delete objectbucketclaim loki-app01 --ignore-not-found
```

> Nunca destrua o HostedCluster antes do ManagedCluster sair: o ACM fica preso em finalizers.

---

## 8. Mudar padrões para todos os clusters

Mudanças aqui afetam **todos** os clusters que usam o item, no próximo sync.

| Quero mudar | Arquivo | Campo |
|---|---|---|
| Padrões dos parâmetros (versão, rede, réplicas, ssh, admin, retenções, Loki) | `provisioning/base/params-defaults.yaml` | `spec.*` |
| O que é cada tamanho de worker | `provisioning/workers/<size>/kustomization.yaml` | `cores`, `memory`, disco |
| O que é cada tamanho de infra | `provisioning/infra/<size>/kustomization.yaml` | `cores`, `memory`, disco |
| Labels/taints dos nós de infra | `provisioning/infra/_common/nodepool-infra.yaml` | `nodeLabels`, `taints` |
| Upgrade e reparo dos nós | `provisioning/base/nodepool-worker.yaml` e `infra/_common/nodepool-infra.yaml` | `management.upgradeType`, `autoRepair` |
| etcd do control plane (tamanho, StorageClass) | `provisioning/base/hostedcluster.yaml` | `spec.etcd.managed.storage` |
| Alta disponibilidade do control plane | `provisioning/base/hostedcluster.yaml` | `controllerAvailabilityPolicy`, `infrastructureAvailabilityPolicy` |
| Como os serviços do control plane são publicados | `provisioning/base/hostedcluster.yaml` | `spec.services` |
| Servidores NTP | `provisioning/features/ntp/chrony-configmap.yaml` | linha `source:` (`scripts/chrony-b64.sh`) |
| Horário, retenção, tamanho do backup do etcd | `provisioning/features/etcd-backup/resources.yaml` | `schedule`, `RETENTION_DAYS`, PVC |
| Tamanho do PVC do registry | `policies/features/manifests/registry/01-pvc.yaml` | `storage` |
| Onde rodam router/registry/monitoring/Loki | `policies/features/manifests/*` | `nodeSelector` / `tolerations` |
| Componentes do monitoring na infra | `policies/features/manifests/observability/01-cluster-monitoring-config.yaml` | blocos por componente |
| O que o logging coleta e para onde | `policies/features/manifests/logging/04-clusterlogforwarder.yaml` | `pipelines`, `outputs` |
| StorageClass dos PVCs do Loki no cluster filho | `policies/features/manifests/loki/05-lokistack.yaml` | `storageClassName` |
| Plugin de logs no console | `policies/features/manifests/logging-ui/uiplugin.yaml` | `logsLimit`, `timeout` |
| Catálogo/canal dos operators | `policies/features/manifests/{loki,logging}/02-operator.yaml` | sempre `redhat-operators`, canal padrão mais atual |

## 9. O que ainda não é configurável (e como seria)

| Item | Situação hoje | Como adicionar |
|---|---|---|
| Rede secundária / VLAN para os nós | nós só na rede padrão de pods do hub | component `network/<nome>` com NetworkAttachmentDefinition + `additionalNetworks` no NodePool |
| Segundo pool de workers (GPU, AAP...) | um pool de workers + infra opcional | component `workers-extra/<nome>` |
| Autoscaling de nós | réplicas fixas | campo `autoScaling` no NodePool via component |
| Proxy de saída | não configurado | `spec.configuration.proxy` no HostedCluster via component |
| Certificado próprio no ingress | certificado padrão | Secret + `defaultCertificate` na policy de ingress |
| Tipo de rede | fixo `OVNKubernetes` | não recomendado mudar |

Para criar um component novo, veja README → "Criar um component novo".
