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
| Bucket S3 do Loki (só se usar loki/logging) | Hub | `oc get sc \| grep -i rgw` deve mostrar `ocs-external-storagecluster-ceph-rgw` |

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
  policy.yaml                  <- fixo (nome já preenchido)
  kustomization.yaml           <- fixo
```

Sem o script (VS Code): copie `docs/cluster-template` para `clusters/app01` e troque `NOME` por
`app01` só dentro dessa pasta (Search & Replace com "files to include" = `clusters/app01`).

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
| `features/logging` | Logging (app, infra, audit) → Loki. **Já inclui o loki** |
| `features/loki` | Só o Loki (use apenas sem `logging`) |

Tamanhos (`demo` só para lab):

| size | cores | memória | disco |
|---|---|---|---|
| demo | 2 | 8Gi | 120Gi |
| small | 4 | 16Gi | 120Gi |
| medium | 8 | 32Gi | 120Gi |
| large | 16 | 64Gi | 120Gi |
| xlarge | 32 | 128Gi | 120Gi |

### 3.2 `patches`: só o que muda em relação ao padrão

```yaml
patches:
  - target: {kind: ClusterParams}
    patch: |-
      kind: ClusterParams
      metadata: {name: params}
      spec:
        name: app01                       # OBRIGATÓRIO
        env: prd
        releaseImage: quay.io/openshift-release-dev/ocp-release:4.18.60-multi
        workerReplicas: 3                 # número, SEM aspas
        infraReplicas: 3                  # número, SEM aspas
        oauth:
          htpasswd: |                     # htpasswd -nbB admin 'senha-forte'
            admin:$2y$05$...
        ingress: {replicas: "3"}          # ENTRE aspas
        observability: {prometheusRetention: "15d", prometheusStorage: "100Gi"}
        loki: {size: "1x.small", retentionDays: "15"}
```

Todos os campos possíveis e seus padrões: `provisioning/base/params-defaults.yaml`.

**Regras rápidas**
- `workerReplicas` / `infraReplicas`: números **sem** aspas.
- Tudo de `ingress`, `observability`, `loki`, `oauth.adminUser`: **entre aspas** (viram labels).
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

| Quero mudar | Arquivo |
|---|---|
| Versão/rede/réplicas/ssh/admin padrão | `provisioning/base/params-defaults.yaml` |
| O que é um "medium" | `provisioning/workers/medium/` ou `provisioning/infra/medium/` |
| Servidores NTP | `provisioning/features/ntp/chrony-configmap.yaml` |
| O que uma feature de day-2 aplica | `policies/features/manifests/<feature>/` |

Mudanças aqui afetam **todos** os clusters que usam aquele item no próximo sync.
