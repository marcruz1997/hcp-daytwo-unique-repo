# HCP via ACM PolicyGenerator: provisionamento e day-2 por policies

Aqui **o próprio cluster é criado por uma Policy**. O Argo CD só leva as policies do Git para o hub;
quem cria e mantém HostedCluster, NodePools e ManagedCluster é o ACM (`enforce` no `local-cluster`).
Tudo aparece em **Governance**.

Este repo guarda **os clusters**. As peças reutilizáveis (base, tamanhos, features e as policies de
day-2) ficam no catálogo versionado **[hcp-modules-policies](https://github.com/marcruz1997/hcp-modules-policies)**, e cada
cluster escolhe os módulos por URL + versão.

## Como funciona (GitOps)

| O quê | Onde fica |
|---|---|
| Quais módulos o cluster tem | `clusters/<nome>/cluster/kustomization.yaml` (uma linha por módulo, com `?ref=<versão>`) |
| Valores do cluster | `clusters/<nome>/cluster/params.yaml` |
| Catálogo de módulos e policies de day-2 | repo [hcp-modules-policies](https://github.com/marcruz1997/hcp-modules-policies), versionado por tag |
| Ver o que vai mudar | diff da Application `pg-<nome>` no Argo CD |
| Aplicar | `git push`: o Argo sincroniza e o ACM aplica só a diferença |
| Estado real | o próprio cluster: o ACM compara o desejado (Git) com o que está rodando e corrige |

Ligar um módulo = descomentar a linha. Desligar = comentar. Mudar um valor = editar o `params.yaml`.
Atualizar um módulo = trocar o `?ref=`. Um push aplica tudo, no hub e dentro do cluster.

## Manuais

- [docs/MANUAL-CRIACAO.md](docs/MANUAL-CRIACAO.md): criar, configurar o day-2, mudar e destruir clusters
- [docs/LEITURA-POLICIES.md](docs/LEITURA-POLICIES.md): ler as policies por cluster, dependências e troubleshooting
- [hcp-modules-policies → README](https://github.com/marcruz1997/hcp-modules-policies): catálogo, parâmetros de cada módulo e versionamento

## Fluxo

```
git push clusters/<nome>/
   └─ Argo (ApplicationSet pg-clusters) renderiza a pasta com o PolicyGenerator
        │   (baixa os módulos do hcp-modules-policies na versão do ?ref=)
        └─ Policy pg-provisioning/hcp-<nome>  ->  Placement: local-cluster
             └─ ACM cria HostedCluster, NodePool(s), ManagedCluster, KAC, secrets...
                  └─ HyperShift sobe o cluster  ->  ACM importa (modo Hosted)
                       └─ labels feature.pg.lab/*  ->  policies de day-2 (pg-policies-features,
                                                       publicadas do hcp-modules-policies/policies)
```

## Estrutura

```
clusters/<nome>/                 # <- O QUE VOCÊ EDITA
  cluster/kustomization.yaml     # quais módulos (URL + ?ref=)
  cluster/params.yaml            # valores do cluster
  policy.yaml                    # fixo (só o nome em 2 linhas)
  kustomization.yaml             # fixo
docs/cluster-template/           # modelo de cluster novo (usado pelo scripts/new-cluster.sh)
policies/hub/                    # policies do hub (pull-secret, endpoint S3 do Loki)
hub/  bootstrap/  scripts/
```

## Criar um cluster

O mínimo (o resto já vem com valores que funcionam):

```bash
scripts/new-cluster.sh app01          # preenche nome, chave SSH (~/.ssh/*.pub) e pede a senha do admin
git add clusters/app01 && git commit -m "cria cluster app01" && git push
```

Isso cria um cluster com os módulos padrão: workers `small` (2 nós), login htpasswd, NTP, backup do
etcd e router. Para mudar algo, os dois arquivos vêm comentados linha a linha (o que preencher,
formato, o que é imutável e o que recria nós):

`clusters/app01/cluster/kustomization.yaml` (exemplo com mais módulos ligados):

```yaml
resources:
  - https://github.com/marcruz1997/hcp-modules-policies//base?ref=v1.0.0
  - params.yaml
components:
  - https://github.com/marcruz1997/hcp-modules-policies//workers/medium?ref=v1.0.0
  - https://github.com/marcruz1997/hcp-modules-policies//infra/small?ref=v1.0.0
  - https://github.com/marcruz1997/hcp-modules-policies//features/oauth-htpasswd?ref=v1.0.0
  - https://github.com/marcruz1997/hcp-modules-policies//features/oauth-entraid?ref=v1.0.0   # liga Entra ID
  - https://github.com/marcruz1997/hcp-modules-policies//features/ntp?ref=v1.0.0
  - https://github.com/marcruz1997/hcp-modules-policies//features/ingress?ref=v1.0.0
  # - https://github.com/marcruz1997/hcp-modules-policies//features/logging?ref=v1.0.0      # desligado
transformers:
  - https://github.com/marcruz1997/hcp-modules-policies//apply-params?ref=v1.0.0
```

`clusters/app01/cluster/params.yaml` (trecho):

```yaml
spec:
  name: app01
  workerReplicas: 3              # número, sem aspas
  infraReplicas: 3
  oauth: {adminUser: "admin", htpasswd: "admin:$2y$05$..."}
  entraid: {tenantId: "...", clientId: "...", adminGroup: "..."}
  ingress: {replicas: "3"}       # vira label: entre aspas
```

Regras: `base` e `apply-params` são obrigatórios; `infra/<size>` antes de `features/ntp`; só as
seções do `params.yaml` dos módulos ligados são lidas.

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

## Módulos disponíveis (v1.0.0)

`workers/<size>`, `infra/<size>`, `features/oauth-htpasswd`, `features/oauth-entraid`, `features/proxy`, `features/ntp`,
`features/etcd-backup`, `features/ingress`, `features/registry`, `features/observability`,
`features/loki`, `features/logging`. O que cada um faz e quais parâmetros pede:
[catálogo no hcp-modules-policies](https://github.com/marcruz1997/hcp-modules-policies#catálogo).

## Versões dos módulos

- Cada linha do cluster aponta para uma tag do hcp-modules-policies (`?ref=v1.0.0`). Uma tag nova **não muda
  nenhum cluster** até alguém trocar o `?ref=` dele.
- Para atualizar: leia o `CHANGELOG.md` do hcp-modules-policies, troque o `?ref=` no cluster (PR) e acompanhe a
  policy `hcp-<nome>`.
- No mesmo cluster, misture só versões da **mesma versão maior** (ex.: `v1.0.0` com `v1.2.0`).
- As policies de day-2 são publicadas uma vez para todos os clusters por
  `bootstrap/40-policies-features.yaml` (`targetRevision`). Mantenha-a na maior versão em uso.

## Gerenciamento

- **Provisionamento:** policy `hcp-<nome>` em `enforce` + `musthave`. Alteração manual em
  HostedCluster/NodePool/ManagedCluster é revertida pelo ACM. Campos que o HyperShift completa
  (ex.: services) não brigam com a policy, porque `musthave` só exige o que está declarado.
- **Day-2:** policies em `pg-policies-features`, selecionadas pelos labels `feature.pg.lab/*`.
- Ligar uma feature depois: descomente o módulo, push. Desligar: comente; o label
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

1. O bootstrap aponta para `marcruz1997/hcp-lab-day-two-policies` (clusters, hub) e
   `marcruz1997/hcp-modules-policies` (policies de day-2). Se mudar algum repo, troque a URL em `bootstrap/` e
   nos `clusters/*/cluster/kustomization.yaml`.
2. Pré-requisitos no hub: OpenShift GitOps com o plugin do PolicyGenerator, ACM/MCE com HyperShift,
   OpenShift Virtualization, MetalLB (APIServer LoadBalancer). O repo-server do Argo baixa os módulos
   do hcp-modules-policies no build (repo privado: cadastre a credencial em Argo → Settings → Repositories).
3. `oc apply -f bootstrap/`

**Mesmo hub do `lab-hcp-day-two`?** Os nomes deste repo são isolados (prefixo `pg-`, labels
`feature.pg.lab/*`), mas os dois gerenciam o namespace `clusters` e o `hcp-etcd-backup`.
Use **um repo por vez** no mesmo hub. Para desligar o outro sem apagar nada:
```bash
oc -n openshift-gitops delete applicationset hosted-clusters
oc -n openshift-gitops delete applications.argoproj.io hub-base policies-hub policies-features
```
