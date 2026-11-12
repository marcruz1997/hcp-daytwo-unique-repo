# Manual: criar um cluster e configurar o day-2

Este manual cobre o dia a dia: criar um cluster, escolher o que ele tem, mudar depois e destruir.
Para entender e investigar as policies, veja [LEITURA-POLICIES.md](LEITURA-POLICIES.md).

---

## 1. Antes do primeiro cluster (uma vez só)

| O quê | Onde | Como |
|---|---|---|
| Chave SSH pública padrão | `docs/cluster-template/cluster/params.yaml` → `sshPublicKey` (vale para os clusters criados depois) | `cat ~/.ssh/hcp-clusters.pub` |
| Servidores NTP | repo **hcp-modules-policies**: `features/ntp/chrony-configmap.yaml` (nova versão do catálogo) | `scripts/chrony-b64.sh ntp1 ntp2` (no hcp-modules-policies) e cole na linha `source:` |
| Horário e retenção do backup do etcd | repo **hcp-modules-policies**: `features/etcd-backup/resources.yaml` (nova versão do catálogo) | `schedule` e `RETENTION_DAYS` |
| S3 para o Loki (só se usar loki/logging) | Hub | `oc get sc \| grep noobaa` e `oc -n openshift-storage get route s3` devem existir (ODF com MCG). Endpoint e CA são descobertos automaticamente pela policy `loki-s3-endpoint` |

> O `params.yaml` do template é o ponto de partida de **todo cluster novo**: ajuste ali os valores comuns.
> Senha de admin: defina **uma por cluster** (seção 3.2). Não dependa do valor do template.

---

## 2. Criar a pasta do cluster

Nome: minúsculas, números e `-` (ex.: `app01`, `hml-pagamentos`).

```bash
scripts/new-cluster.sh app01                 # usa ~/.ssh/hcp-clusters.pub, id_ed25519.pub ou id_rsa.pub
scripts/new-cluster.sh app01 ~/chave.pub     # ou indique a chave pública
```

O script já preenche o **nome**, a **chave SSH** e pede a **senha do admin** (gera o hash com
`htpasswd`, pacote `httpd-tools`). Se não achar a chave ou o `htpasswd`, ele avisa o que falta.
O cluster sai com os módulos padrão (workers `small`, login htpasswd, NTP, backup do etcd, router):
se for isso que você quer, pule direto para a seção 4.

Isso cria `clusters/app01/` a partir de `docs/cluster-template/`:

```
clusters/app01/
  cluster/kustomization.yaml   <- VOCÊ EDITA: quais módulos o cluster tem
  cluster/params.yaml          <- VOCÊ EDITA: os valores do cluster
  policy.yaml                  <- fixo (nome já preenchido)
  kustomization.yaml           <- fixo
```

Sem o script (VS Code): copie `docs/cluster-template` para `clusters/app01` e troque `NOME` por
`app01` só dentro dessa pasta (Search & Replace com "files to include" = `clusters/app01`).

---

## 3. Declarar o cluster

São dois arquivos em `clusters/app01/cluster/`: `kustomization.yaml` (o que o cluster tem) e
`params.yaml` (os valores). Os módulos vêm do catálogo [hcp-modules-policies](https://github.com/marcruz1997/hcp-modules-policies), sempre com versão (`?ref=`).

### 3.1 `kustomization.yaml`: os módulos

Uma linha por módulo; comente para desligar. **A ordem não importa**, exceto: `infra/<size>` antes de
`features/ntp`.

```yaml
resources:
  - https://github.com/marcruz1997/hcp-modules-policies//base?ref=v1.0.0          # obrigatório
  - params.yaml
components:
  - https://github.com/marcruz1997/hcp-modules-policies//workers/small?ref=v1.0.0
  - https://github.com/marcruz1997/hcp-modules-policies//infra/small?ref=v1.0.0
  - https://github.com/marcruz1997/hcp-modules-policies//features/oauth-htpasswd?ref=v1.0.0
  - https://github.com/marcruz1997/hcp-modules-policies//features/ingress?ref=v1.0.0
transformers:
  - https://github.com/marcruz1997/hcp-modules-policies//apply-params?ref=v1.0.0  # obrigatório, não mexa
```

| Módulo | Efeito |
|---|---|
| `workers/<size>` | Tamanho dos workers (obrigatório ter um) |
| `infra/<size>` | Cria o NodePool de infra já no tamanho |
| `features/oauth-htpasswd` | Login htpasswd + cluster-admin para o `adminUser` |
| `features/oauth-entraid` | Login Microsoft Entra ID + cluster-admin para um grupo (ver 3.1.2). Pode ficar junto com o htpasswd |
| `features/proxy` | Proxy corporativo de saída (`proxy.*` no `params.yaml`). **Faz rollout dos nós** |
| `features/ntp` | chrony em todos os nós (depois de `infra/<size>`) |
| `features/etcd-backup` | Snapshot diário do etcd (no hub) |
| `features/ingress` | Router nos nós de infra |
| `features/registry` | Image registry interno com PVC |
| `features/observability` | Prometheus/Alertmanager persistentes + user workload + COO |
| `features/logging` | Logging (app, infra, audit) → Loki. **Já inclui o loki** (tamanho: `loki.size`, ver 3.1.1) |
| `features/loki` | Só o Loki (use apenas sem `logging`; tamanho: `loki.size`) |

Detalhes de cada módulo e parâmetros: README do [hcp-modules-policies](https://github.com/marcruz1997/hcp-modules-policies).

Tamanhos (`demo` só para lab):

| size | cores | memória | disco |
|---|---|---|---|
| demo | 2 | 8Gi | 120Gi |
| small | 4 | 16Gi | 120Gi |
| medium | 8 | 32Gi | 120Gi |
| large | 16 | 64Gi | 120Gi |
| xlarge | 32 | 128Gi | 120Gi |

**Versões:** use a mesma versão em todas as linhas, ou versões da **mesma versão maior**
(ex.: `base?ref=v1.0.0` com `features/oauth-entraid?ref=v1.2.0`). O que mudou em cada versão está no
`CHANGELOG.md` do hcp-modules-policies.

#### 3.1.1 Tamanho do Loki (`loki.size`)

Com `features/logging` ou `features/loki`, o tamanho da instância vem de `loki.size` no `params.yaml`
(no `params.yaml`; o template vem com `1x.demo`).

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

#### 3.1.2 Login com Microsoft Entra ID (`features/oauth-entraid`)

1. No Entra ID, registre uma aplicação (App registrations → New registration):
   - **Redirect URI** (Web): `https://<host-oauth>/oauth2callback/entraid`. O host sai de
     ```bash
     oc -n clusters-app01 get route oauth -o jsonpath='{.spec.host}{"\n"}'
     ```
     (o cluster precisa existir: dá para ligar o módulo depois de criado)
   - **Token configuration** → *Add groups claim* → *Security groups*.
   - **Certificates & secrets** → *New client secret* (copie o *Value*).
2. Crie o Secret no hub (**fora do Git**):
   ```bash
   oc -n clusters create secret generic entraid-app01 --from-literal=clientSecret='<valor>'
   ```
3. No `params.yaml`:
   ```yaml
   entraid:
     tenantId: "<Directory (tenant) ID>"
     clientId: "<Application (client) ID>"
     adminGroup: "<Object ID do grupo que vira cluster-admin>"   # ENTRE aspas
   ```
4. Descomente `features/oauth-entraid` e faça push. Na tela de login aparecem `entraid` e, se
   ligado, `htpasswd` (bom como acesso de emergência).

### 3.2 `params.yaml`: os valores

O template já vem com **todos os campos comentados linha a linha**: o que é, formato, como descobrir o
valor (ex.: as redes do hub para não sobrepor pod/service network), o que é imutável e o que recria
os nós. O `kustomization.yaml` do template também traz o impacto de ligar cada módulo. Ajuste o que for
deste cluster:

```yaml
spec:
  name: app01                       # OBRIGATÓRIO (já preenchido pelo script)
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

Só as seções dos módulos ligados são lidas. Todos os campos: `examples/params.yaml` do hcp-modules-policies.

**Regras rápidas**
- `workerReplicas` / `infraReplicas`: números **sem** aspas.
- Tudo de `ingress`, `observability`, `loki`, `oauth.adminUser`, `entraid`: **entre aspas** (viram labels).
- `ingress.replicas` ≤ `infraReplicas` (1 router por nó). Sem infra: ≤ `workerReplicas`.
- Módulo ligado sem a sua seção no `params.yaml` = erro de build (`fieldPath ... is missing`).

### 3.3 `transformers`: não mexa

```yaml
transformers:
  - https://github.com/marcruz1997/hcp-modules-policies//apply-params?ref=v1.0.0
```

Exemplo completo: `docs/cluster-template/cluster/`.

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

Edite `clusters/app01/cluster/kustomization.yaml` (módulos) ou `params.yaml` (valores) e faça push.
O ACM aplica sozinho.

| Mudança | Impacto |
|---|---|
| Ligar `ingress`, `registry`, `observability`, `logging`, `loki` | Sem impacto nos nós |
| Ligar `infra/<size>` | Cria VMs novas; router/registry/monitoring/loki migram para a infra |
| Trocar `workers/<size>` ou `infra/<size>` | **Recria os nós** do pool (um por vez) |
| Mudar `workerReplicas` / `infraReplicas` | Adiciona/remove nós |
| Ligar ou mudar `ntp` | **Recria todos os nós** |
| Trocar senha (`oauth.htpasswd`) | OAuth recarrega, nós intactos |
| Ligar `oauth-entraid` | OAuth recarrega com o login do Entra ID, nós intactos |
| Trocar a versão (`?ref=`) | O que a versão muda está no `CHANGELOG.md` do hcp-modules-policies (leia antes) |
| Mudar `releaseImage` | **Upgrade** do cluster (control plane, depois workers) |
| Tirar uma feature da lista | O label volta a `"false"` e a policy de day-2 sai do cluster, mas **não apaga** o que já criou |

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
oc -n clusters delete secret sshkey-cluster-app01 htpasswd-app01 entraid-app01 --ignore-not-found
oc -n clusters delete configmap app01-chrony --ignore-not-found
oc -n hcp-etcd-backup delete cronjob,pvc etcd-backup-app01 --ignore-not-found
oc -n pg-policies-features delete objectbucketclaim loki-app01 --ignore-not-found
```

> Nunca destrua o HostedCluster antes do ManagedCluster sair: o ACM fica preso em finalizers.

---

## 8. Mudar padrões para todos os clusters

| Quero mudar | Onde |
|---|---|
| Valores iniciais de clusters novos (versão, rede, réplicas, ssh, admin) | `docs/cluster-template/cluster/params.yaml` |
| O que é um "medium", servidores NTP, horário do backup, o que uma feature aplica | repo **hcp-modules-policies** → PR + `CHANGELOG.md` + tag nova |
| Usar a versão nova do catálogo | trocar `?ref=` nos clusters (e o `targetRevision` de `bootstrap/40-policies-features.yaml` se a versão mexer em `policies/`) |

Uma tag nova no hcp-modules-policies **não muda nenhum cluster** até alguém trocar o `?ref=` dele.
