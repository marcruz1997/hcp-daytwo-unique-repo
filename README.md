# HCP via ACM PolicyGenerator: provisionamento e day-2 por policies

Versão alternativa do `lab-hcp-day-two`: aqui **o próprio cluster é criado por uma Policy**.
O Argo CD só leva as policies do Git para o hub; quem cria e mantém HostedCluster, NodePools e
ManagedCluster é o ACM (`enforce` no `local-cluster`). Tudo aparece em **Governance**.

## Fluxo

```
git push clusters/<nome>/
   └─ Argo (ApplicationSet pg-clusters) renderiza a pasta com o PolicyGenerator
        └─ Policy pg-provisioning/hcp-<nome>  ->  Placement: local-cluster
             └─ ACM cria HostedCluster, NodePool(s), ManagedCluster, KAC, secrets...
                  └─ HyperShift sobe o cluster  ->  ACM importa (modo Hosted)
                       └─ labels feature.pg.lab/*  ->  policies de day-2 (pg-policies-features)
```

## Estrutura

```
bootstrap/                      # aplicar uma vez: oc apply -f bootstrap/
hub/                            # namespaces + ManagedClusterSetBindings
policies/hub/                   # copia o pull-secret do hub (hcp-pull-secret)
policies/features/              # day-2: registry, ingress, loki, logging, observability, oauth-admin
provisioning/
  base/                         # HostedCluster, NodePool worker, ManagedCluster, KAC, ssh secret
  components/
    worker-size/{demo..xlarge}  # tamanho dos workers
    infra-nodes/                # NodePool <nome>-infra (label + taint)
    infra-size/{demo..xlarge}   # tamanho da infra
    oauth-htpasswd/ ntp/ etcd-backup/
    features/{ingress,registry,observability,loki,logging}
    apply-params/               # SEMPRE o último: aplica o params.yaml
clusters/<nome>/
  kustomization.yaml            # chama o PolicyGenerator
  policyGenerator.yaml          # policy hcp-<nome> no local-cluster
  cluster/kustomization.yaml    # base + components escolhidos
  cluster/params.yaml           # nome, versão, réplicas, ssh, parâmetros das features
docs/cluster-template/          # modelo para novos clusters
scripts/chrony-b64.sh           # gera o conteúdo do NTP
```

## Criar um cluster

```bash
cp -r docs/cluster-template clusters/app01
sed -i '' 's/NOME/app01/g' clusters/app01/policyGenerator.yaml clusters/app01/cluster/params.yaml   # macOS
# edite clusters/app01/cluster/params.yaml (versão, ssh, réplicas, oauth...)
# edite clusters/app01/cluster/kustomization.yaml (components: tamanhos e features)
git add -A && git commit -m "app01" && git push
```

Acompanhar:
```bash
oc -n pg-provisioning get policy hcp-app01           # Compliant = tudo criado
oc -n clusters get hostedcluster,nodepool
oc get managedcluster app01 --show-labels
oc -n pg-policies-features get policies
```

Se a policy de provisionamento ficar `NonCompliant`, a mensagem explica o motivo:
```bash
oc -n local-cluster get policy pg-provisioning.hcp-app01 -o jsonpath='{.status.details[*].history[0].message}{"\n"}'
```
Logo após a criação é normal ela ficar NonCompliant por alguns minutos (ex.: o namespace do
KlusterletAddonConfig ainda não existe). O ACM tenta de novo sozinho.

## Components (o "cardápio")

| Component | O que faz | Precisa no params.yaml |
|---|---|---|
| `worker-size/<size>` | Tamanho dos workers | `workerReplicas` |
| `infra-nodes` + `infra-size/<size>` | NodePool de infra com label e taint | `infraReplicas` |
| `oauth-htpasswd` | IdP htpasswd + `adminUser` com cluster-admin | `oauth.adminUser`, `oauth.htpasswd` |
| `ntp` | chrony em todos os nós (**recria os nós** se ligado depois) | servidores em `components/ntp` |
| `etcd-backup` | CronJob no hub, snapshot diário do etcd | nada |
| `features/ingress` | Router nos nós de infra | `ingress.replicas` |
| `features/registry` | Image registry com PVC | nada |
| `features/observability` | Monitoring persistente + UWM + COO | `observability.*` |
| `features/loki` | Loki + bucket S3 no hub | `loki.*` |
| `features/logging` | Logging -> Loki (**já inclui o loki**) | `loki.*` |

Tamanhos (por nó), iguais para worker e infra por padrão. Para mudar, edite o arquivo do size
em `provisioning/components/worker-size/` ou `infra-size/` (são independentes):

| size | cores | memória | disco |
|---|---|---|---|
| demo | 2 | 8Gi | 32Gi |
| small | 4 | 16Gi | 64Gi |
| medium | 8 | 32Gi | 100Gi |
| large | 16 | 64Gi | 150Gi |
| xlarge | 32 | 128Gi | 200Gi |

**Ordem dos components:** worker-size → infra-nodes → infra-size → features/oauth/ntp/etcd-backup →
**apply-params por último**. `ntp` depois de `infra-nodes` (senão o pool de infra fica sem NTP).

**Tipos no params.yaml:** `workerReplicas`/`infraReplicas` são números **sem aspas**; tudo que vira
label (`ingress.replicas`, `observability.*`, `loki.*`, `oauth.adminUser`) **entre aspas**.

## Gerenciamento

- **Provisionamento:** policy `hcp-<nome>` em `enforce` + `musthave`. Alteração manual em
  HostedCluster/NodePool/ManagedCluster é revertida pelo ACM. Campos que o HyperShift completa
  (ex.: services) não brigam com a policy, porque `musthave` só exige o que está declarado.
- **Day-2:** policies em `pg-policies-features`, selecionadas pelos labels `feature.pg.lab/*`.
- Ligar uma feature depois: adicione o component, push. Desligar: remova o component; a policy
  para de gerenciar, mas **não apaga** o que criou (`pruneObjectBehavior: None`).

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
oc -n clusters delete secret sshkey-cluster-app01 htpasswd-app01 --ignore-not-found
oc -n clusters delete configmap app01-chrony --ignore-not-found
oc -n hcp-etcd-backup delete cronjob,pvc etcd-backup-app01 --ignore-not-found
oc -n pg-policies-features delete objectbucketclaim loki-app01 --ignore-not-found
```

## Bootstrap

1. Troque a URL do repo se o nome for outro:
   ```bash
   grep -rl lab-hcp-policygenerator bootstrap | xargs sed -i '' 's#marcruz1997/lab-hcp-policygenerator#SEU_ORG/SEU_REPO#'
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
