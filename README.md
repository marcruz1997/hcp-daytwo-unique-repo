# HCP via ACM PolicyGenerator: provisionamento e day-2 por policies

Versão alternativa do `lab-hcp-day-two`: aqui **o próprio cluster é criado por uma Policy**.
O Argo CD só leva as policies do Git para o hub; quem cria e mantém HostedCluster, NodePools e
ManagedCluster é o ACM (`enforce` no `local-cluster`). Tudo aparece em **Governance**.

## Como Terraform

| Terraform | Aqui |
|---|---|
| módulo (`module "ntp" { source = ... }`) | component em `provisioning/` (ex.: `provisioning/features/ntp`) |
| `main.tf` + `terraform.tfvars` | **um arquivo por cluster**: `clusters/<nome>/cluster/kustomization.yaml` (lista `components` = módulos ligados; `patches` = valores) |
| defaults do `variables.tf` | `provisioning/base/params-defaults.yaml` |
| `terraform plan` | diff da Application `pg-<nome>` no Argo CD |
| `terraform apply` | `git push` (o Argo sincroniza e o ACM aplica só a diferença) |
| state | o próprio cluster: o ACM compara o desejado com o que está rodando |

Ligar um módulo = descomentar a linha. Desligar = comentar. Mudar um valor = editar o patch.
Um push aplica tudo, no hub e dentro do cluster.

## Manuais

- [docs/MANUAL-CRIACAO.md](docs/MANUAL-CRIACAO.md): criar, configurar o day-2, mudar e destruir clusters
- [docs/LEITURA-POLICIES.md](docs/LEITURA-POLICIES.md): ler as policies por cluster, dependências e troubleshooting

## Fluxo

```
git push clusters/<nome>/
   └─ Argo (ApplicationSet pg-clusters) renderiza a pasta com o PolicyGenerator
        └─ Policy pg-provisioning/hcp-<nome>  ->  Placement: local-cluster
             └─ ACM cria HostedCluster, NodePool(s), ManagedCluster, KAC, secrets...
                  └─ HyperShift sobe o cluster  ->  ACM importa (modo Hosted)
                       └─ labels feature.pg.lab/*  ->  policies de day-2 (pg-policies-features)
```

## Estrutura: declaração separada da parte verbosa

```
clusters/<nome>/                 # <- O QUE VOCÊ EDITA
  cluster/kustomization.yaml     # a declaração do cluster (o que ele tem + o que muda)
  policy.yaml                    # fixo (só o nome em 2 linhas)
  kustomization.yaml             # fixo
provisioning/                    # <- PARTE VERBOSA (raramente mexe)
  base/                          # HostedCluster, NodePool, ManagedCluster, KAC, ssh
    params-defaults.yaml         # DEFAULTS de todos os clusters (versão, rede, ssh, admin...)
  workers/{demo..xlarge}         # tamanho dos workers
  infra/{demo..xlarge}           # nós de infra JÁ no tamanho (inclui o NodePool)
  features/                      # oauth-htpasswd, ntp, etcd-backup, ingress, registry,
                                 # observability, loki, logging
  apply-params/                  # transformer final: aplica os parâmetros em tudo
policies/hub/  policies/features/   # policies do hub e de day-2
hub/  bootstrap/  docs/cluster-template/  scripts/
```

## Criar um cluster

```bash
scripts/new-cluster.sh app01
# edite clusters/app01/cluster/kustomization.yaml
git add clusters/app01 && git commit -m "app01" && git push
```

A declaração inteira de um cluster:

```yaml
# clusters/app01/cluster/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: [../../../provisioning/base]
components:                                   # a ORDEM NÃO IMPORTA
  - ../../../provisioning/workers/medium
  - ../../../provisioning/infra/small
  - ../../../provisioning/features/oauth-htpasswd
  - ../../../provisioning/features/ntp
  - ../../../provisioning/features/ingress
  - ../../../provisioning/features/observability
patches:
  - target: {kind: ClusterParams}
    patch: |-
      kind: ClusterParams
      metadata: {name: params}
      spec:
        name: app01                           # obrigatório
        workerReplicas: 3                     # só o que for diferente do padrão
        ingress: {replicas: "3"}
transformers: [../../../provisioning/apply-params]
```

Tudo que não estiver no patch vem de `provisioning/base/params-defaults.yaml`
(versão, redes, chave SSH, usuário/senha admin, retenções...). Para mudar o padrão de
**todos** os clusters, edite esse arquivo.

Acompanhar:
```bash
oc -n pg-provisioning get policy hcp-app01           # Compliant = tudo criado
oc -n clusters get hostedcluster,nodepool
oc get managedcluster app01 --show-labels
```
Motivo de NonCompliant:
```bash
oc -n local-cluster get policy pg-provisioning.hcp-app01 \
  -o jsonpath='{.status.details[*].history[0].message}{"\n"}'
```
Logo após criar é normal ficar NonCompliant alguns minutos (o namespace do
KlusterletAddonConfig só existe depois que o ACM registra o cluster).

## O cardápio

| Linha em `components` | O que faz | Parâmetro (no patch, opcional) |
|---|---|---|
| `workers/<size>` | Tamanho dos workers | `workerReplicas` |
| `infra/<size>` | NodePool de infra (label + taint) já no tamanho | `infraReplicas` |
| `features/oauth-htpasswd` | Login htpasswd + cluster-admin | `oauth.adminUser`, `oauth.htpasswd` |
| `features/oauth-entraid` | Login Microsoft Entra ID + cluster-admin para um grupo (soma com o htpasswd) | `entraid.*` + Secret no hub ([manual 3.1.2](docs/MANUAL-CRIACAO.md)) |
| `features/ntp` | chrony em todos os nós (**recria os nós** se ligado depois) | servidores em `features/ntp/` |
| `features/etcd-backup` | CronJob no hub com snapshot diário do etcd | horário em `features/etcd-backup/` |
| `features/ingress` | Router nos nós de infra | `ingress.replicas` (entre aspas) |
| `features/registry` | Image registry com PVC | - |
| `features/observability` | Monitoring persistente + UWM + COO | `observability.*` |
| `features/loki` | Loki + bucket S3 no hub | `loki.*` |
| `features/logging` | Logging -> Loki (**já inclui o loki**) | `loki.*` |

Tamanhos (por nó; edite em `provisioning/workers/` e `provisioning/infra/`, que são independentes):

| size | cores | memória | disco |
|---|---|---|---|
| demo | 2 | 8Gi | 120Gi |
| small | 4 | 16Gi | 120Gi |
| medium | 8 | 32Gi | 120Gi |
| large | 16 | 64Gi | 120Gi |
| xlarge | 32 | 128Gi | 120Gi |

**Aspas no patch:** réplicas de NodePool (`workerReplicas`, `infraReplicas`) são números; o
resto que vira label (`ingress.replicas`, `loki.retentionDays`) vai **entre aspas**.

### Criar um component novo
1. Pasta em `provisioning/features/<nome>/` com `kind: Component` (recursos e patches).
2. Recursos que precisam do nome do cluster usam `CLUSTER` + um label `pg.lab/role=<x>`.
3. Adicione o replacement em `provisioning/apply-params/replacements.yaml` selecionando
   pelo label (assim, se a feature não estiver ligada, o alvo é simplesmente ignorado).
4. Label `feature.pg.lab/<nome>: "false"` em `provisioning/base/managedcluster.yaml` e o component
   troca para `"true"` com `op: add` (é isso que faz "tirar da lista" desligar a feature).
5. Parâmetros novos com valor padrão em `provisioning/base/params-defaults.yaml`.
6. Component **acrescenta**, não substitui: listas com `/-` (como os `oauth-*` em
   `identityProviders`). Segredo nunca no Git.

## Gerenciamento

- **Provisionamento:** policy `hcp-<nome>` em `enforce` + `musthave`. Alteração manual em
  HostedCluster/NodePool/ManagedCluster é revertida pelo ACM. Campos que o HyperShift completa
  (ex.: services) não brigam com a policy, porque `musthave` só exige o que está declarado.
- **Day-2:** policies em `pg-policies-features`, selecionadas pelos labels `feature.pg.lab/*`.
- Ligar uma feature depois: adicione o component, push. Desligar: remova o component; o label
  `feature.pg.lab/<feature>` volta a `"false"`, a policy de day-2 sai do cluster, mas **não apaga**
  o que criou (`pruneObjectBehavior: None`).

## Destruir um cluster (manual, nesta ordem)

```bash
# 1. tire do Git: remove o Application e a Policy (o cluster CONTINUA, de propósito)
git rm -r clusters/app01 && git commit -m "remove app01" && git push
oc -n pg-provisioning get policy hcp-app01        # esperar sumir
# 2. desanexar do ACM e esperar sumir (o cluster precisa estar vivo para os addons limparem)
oc delete managedcluster app01 && oc get ns app01 -w
# 3. destruir
oc -n clusters delete hostedcluster app01
# 4. limpar sobras
oc -n clusters delete secret sshkey-cluster-app01 htpasswd-app01 entraid-app01 --ignore-not-found
oc -n clusters delete configmap app01-chrony --ignore-not-found
oc -n hcp-etcd-backup delete cronjob,pvc etcd-backup-app01 --ignore-not-found
oc -n pg-policies-features delete objectbucketclaim loki-app01 --ignore-not-found
```

## Bootstrap

1. Troque a URL do repo se o nome for outro:
   ```bash
   grep -rl hcp-lab-day-two-policies bootstrap | xargs sed -i '' 's#marcruz1997/hcp-lab-day-two-policies#SEU_ORG/SEU_REPO#'
   ```
2. Pré-requisitos no hub (iguais ao outro repo): OpenShift GitOps com o plugin do PolicyGenerator,
   ACM/MCE com HyperShift, OpenShift Virtualization, MetalLB (APIServer LoadBalancer).
3. `oc apply -f bootstrap/`

**Mesmo hub do `lab-hcp-day-two`?** Os nomes deste repo são isolados (prefixo `pg-`, labels
`feature.pg.lab/*`), mas os dois gerenciam o namespace `clusters` e o `hcp-etcd-backup`.
Use **um repo por vez** no mesmo hub. Para desligar o outro sem apagar nada:
```bash
oc -n openshift-gitops delete applicationset hosted-clusters
oc -n openshift-gitops delete applications.argoproj.io hub-base policies-hub policies-features
```
