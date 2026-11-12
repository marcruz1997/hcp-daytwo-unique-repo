# Manual: ler e investigar as policies

Como saber o que está aplicado em cada cluster, se está conforme, o que depende do quê e por
que algo está NonCompliant. Para criar/alterar clusters, veja [MANUAL-CRIACAO.md](MANUAL-CRIACAO.md).

---

## 1. Mapa das policies

| Namespace (hub) | Policy | Roda em | Modo | Para que serve |
|---|---|---|---|---|
| `pg-provisioning` | `hcp-<nome>` (uma por cluster) | **local-cluster** (hub) | enforce | Cria/mantém HostedCluster, NodePools, ManagedCluster, KAC, secrets, NTP, backup etcd, bucket Loki |
| `pg-policies-hub` | `hcp-pull-secret` | local-cluster | enforce | Copia o pull-secret do hub para `clusters/hcp-pull-secret` |
| | `loki-s3-endpoint` | local-cluster | enforce | Descobre a Route S3 do NooBaa e a CA do ingress do hub e publica em `pg-policies-features/loki-s3-endpoint` |
| `pg-policies-features` | `feature-oauth-htpasswd` | clusters com a feature | enforce | cluster-admin para o `adminUser` |
| | `feature-oauth-entraid` | " | enforce | cluster-admin para o grupo do Entra ID (`entraid.adminGroup`) |
| | `feature-ingress` | " | enforce | Router: réplicas + nós de infra |
| | `feature-registry` | " | enforce | Image registry + PVC |
| | `feature-observability` | " | enforce | Monitoring persistente, UWM, COO |
| | `feature-loki` | " | enforce | Loki Operator + LokiStack + credenciais S3 |
| | `feature-logging` | " | enforce | Cluster Logging + forwarder → Loki |
| | `feature-logging-ui` | logging **e** observability | enforce | Plugin de logs no console |
| | `verify-infra-nodes` | clusters com infra | **inform** | Confere de dentro do cluster que os nós de infra existem com label e taint |

**Por que o provisionamento aparece no `local-cluster` e não no cluster filho?**
HostedCluster, NodePool e ManagedCluster são objetos **do hub** (o control plane do filho roda
no hub). Por isso a `hcp-<nome>` é aplicada no hub e carrega o label `pg.lab/cluster=<nome>`
para você filtrar.

**enforce x inform**
- `enforce`: cria e corrige. Se alguém mudar na mão, volta ao Git.
- `inform`: só reporta Compliant/NonCompliant. Nunca altera nada.

---

## 2. Como uma feature chega num cluster

```
clusters/app01/cluster/kustomization.yaml  ->  features/ingress
        └─ policy hcp-app01 cria o ManagedCluster com labels:
              feature.pg.lab/ingress=true
              config.pg.lab/ingress-replicas=3
                    └─ Placement pl-feature-ingress seleciona app01 (pelo label feature.*)
                          └─ policy feature-ingress é copiada para o namespace app01
                                └─ lê config.pg.lab/ingress-replicas (hub template) e aplica no cluster
```

Ver os labels que ligam as features:
```bash
oc get managedcluster app01 --show-labels | tr ',' '\n' | grep pg.lab
```

---

## 3. No console do ACM (Governance)

**Visão por policy**: Governance → **Policies** → clique na policy → aba **Results**
→ lista cada cluster com status e a última mensagem.

**Visão por cluster**
- Day-2 do cluster: em Policies, filtre por **Cluster = app01**.
- Provisionamento: filtre por **Label `pg.lab/cluster=app01`** (aparece no cluster `local-cluster`).

**Histórico**: dentro da policy → Results → **View history** do cluster: cada vez que o ACM
corrigiu algo ou encontrou violação.

**Dependências**: policies com várias etapas (loki, logging, observability, registry) aplicam em
ordem: namespace → operator → recurso. Uma etapa esperando a anterior aparece como **Pending**
("Dependencies were not satisfied"). Isso é normal durante a instalação de operators.

---

## 4. Pelo terminal

```bash
# Tudo de um cluster
oc -n local-cluster get policy pg-provisioning.hcp-app01        # provisionamento
oc -n app01 get policies                                         # day-2 + verificações

# Uma feature em todos os clusters
oc -n pg-policies-features get policy feature-logging \
  -o jsonpath='{range .status.status[*]}{.clustername}: {.compliant}{"\n"}{end}'

# Resumo geral
oc -n pg-provisioning get policies
oc -n pg-policies-features get policies

# Quais clusters cada Placement escolheu
oc -n pg-policies-features get placementdecisions \
  -o 'custom-columns=PLACEMENT:.metadata.labels.cluster\.open-cluster-management\.io/placement,CLUSTERS:.status.decisions[*].clusterName'

# Etapas de uma policy num cluster (mostra Pending por dependência)
oc -n app01 get policy pg-policies-features.feature-logging \
  -o jsonpath='{range .status.details[*]}{.templateMeta.name}: {.compliant} | {.history[0].message}{"\n"}{end}'

# Motivo de NonCompliant do provisionamento (uma linha por recurso)
oc -n local-cluster get policy pg-provisioning.hcp-app01 \
  -o jsonpath='{.status.details[*].history[0].message}{"\n"}' | tr ';' '\n'

# O que a policy de provisionamento contém (ex.: OAuth dentro do HostedCluster)
oc -n pg-provisioning get policy hcp-app01 -o json | jq '.spec["policy-templates"][0]
  .objectDefinition.spec["object-templates"][] | select(.objectDefinition.kind=="HostedCluster")
  | .objectDefinition.spec.configuration'
```

> Cópias das policies: o ACM replica cada policy no namespace de cada cluster alvo com o nome
> `<namespace-original>.<nome>` (ex.: `pg-policies-features.feature-ingress` em `app01`).
> O status detalhado fica nessas cópias.

---

## 5. Troubleshooting

### App no Argo com erro (não chega a criar a policy)
| Mensagem | Causa | Correção |
|---|---|---|
| `authentication required` / `Repository not found` | URL do repo errada ou repo privado sem credencial | `bootstrap/*` com a URL certa; credencial em Argo → Settings → Repositories |
| erro de YAML / `mapping values are not allowed` | Indentação no `params.yaml` | Alinhar como no template |
| `fieldPath ... is missing for replacement source` | Módulo ligado sem a sua seção no `params.yaml` | Copiar a seção do template / `examples/params.yaml` do hcp-modules-policies |
| `failed to run git ... ` / `unknown revision` | Tag do `?ref=` não existe no hcp-modules-policies | Conferir as tags (`git ls-remote --tags`) |
| `may not add resource with an already registered id` | Item listado duas vezes (ex.: `logging` + `loki`) | Remover o duplicado |
| `nothing selected by ...` / `fieldPath not found` | Módulo novo sem label/replacement correto | README do hcp-modules-policies → Criar um módulo novo |

### App no Argo **Degraded** (policy NonCompliant)
Leia o motivo (seção 4). Mensagens comuns:

| Mensagem | Significado |
|---|---|
| `namespaces "<nome>" not found` (KlusterletAddonConfig) | Normal nos primeiros minutos; some após o registro no ACM |
| `namespaces "clusters-<nome>" not found` (Role do backup) | Normal até o control plane subir |
| `cannot unmarshal number ... labels of type string` | Valor de label sem aspas no patch (ex.: `ingress: {replicas: 3}`) |
| `Services is immutable` / `... is immutable` | Mudou no Git um campo que não pode mudar depois de criado (rede, platform...) |

### Feature não aparece no cluster
1. O label está no ManagedCluster? (`--show-labels`, seção 2)
2. A Placement escolheu o cluster? (`placementdecisions`, seção 4)
3. A cópia existe em `oc -n app01 get policies`? Se não, o cluster pode estar `AVAILABLE=Unknown`.
4. Está Pending? Veja as etapas (dependência de operator ainda instalando).

### Loki não sobe / erro de S3
```bash
oc -n pg-policies-features get configmap loki-s3-endpoint -o jsonpath='{.data.endpoint}{"\n"}'   # Route do NooBaa
oc -n pg-policies-features get objectbucketclaim loki-<nome>                                       # Bound
oc --kubeconfig /tmp/<nome>.kubeconfig -n openshift-logging get lokistack logging-loki -o jsonpath='{.status.conditions}'
```
`endpoint` vazio ou `https://<no value>`: o hub não tem a Route `s3` (ODF sem MCG).

### `verify-infra-nodes` NonCompliant
Não existe nó com label `node-role.kubernetes.io/infra` **e** os taints `reserved`. Confira o
NodePool `<nome>-infra` no hub (`oc -n clusters get nodepool`) e se os nós já entraram.

### O que não dá para verificar de dentro do cluster
NTP (não há MachineConfig num hosted cluster) e OAuth (o servidor de login roda no hub). A
fonte da verdade desses dois é a policy `hcp-<nome>` (filtre por `pg.lab/cluster=<nome>`).
