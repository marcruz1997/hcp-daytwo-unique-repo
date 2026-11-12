#!/usr/bin/env bash
# =====================================================================
# Verifica um cluster de ponta a ponta: provisionamento, policies e cada
# feature ligada (no hub e DENTRO do cluster, via túnel port-forward).
# Uso:  scripts/check-cluster.sh <nome-do-cluster>
# Precisa: estar logado no HUB com oc.
# =====================================================================
set -uo pipefail
C=${1:?uso: $0 <nome-do-cluster>}
PORT=${PORT:-16443}
OK=0; FAIL=0; WARN=0
g=$'\e[32m'; r=$'\e[31m'; y=$'\e[33m'; b=$'\e[1m'; n=$'\e[0m'
ok()   { echo "  ${g}OK${n}     $*"; OK=$((OK+1)); }
fail() { echo "  ${r}FALHA${n}  $*"; FAIL=$((FAIL+1)); }
warn() { echo "  ${y}AVISO${n}  $*"; WARN=$((WARN+1)); }
sec()  { echo; echo "${b}== $*${n}"; }
check(){ # check "<descrição>" "<valor obtido>" "<valor esperado>"
  if [ "$2" = "$3" ]; then ok "$1 ($2)"; else fail "$1 (obtido: '${2:-vazio}', esperado: '$3')"; fi; }

# ---------------------------------------------------------------- HUB
sec "Provisionamento (hub)"
check "Policy hcp-$C" "$(oc -n pg-provisioning get policy hcp-$C -o jsonpath='{.status.compliant}' 2>/dev/null)" "Compliant"
hc=$(oc -n clusters get hostedcluster $C -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
check "HostedCluster disponível" "$hc" "True"
check "ManagedCluster disponível" "$(oc get managedcluster $C -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' 2>/dev/null)" "True"
while read -r np want have; do
  [ -z "$np" ] && continue
  check "NodePool $np (nós prontos)" "${have:-0}/$want" "$want/$want"
done < <(oc -n clusters get nodepool -o jsonpath='{range .items[?(@.spec.clusterName=="'"$C"'")]}{.metadata.name} {.spec.replicas} {.status.replicas}{"\n"}{end}' 2>/dev/null)

FEATS=$(oc get managedcluster $C -o jsonpath='{.metadata.labels}' 2>/dev/null | tr ',' '\n' | sed -n 's/.*"feature\.pg\.lab\/\([a-z-]*\)":"true".*/\1/p' | sort | tr '\n' ' ')
echo "  Features ligadas: ${b}${FEATS:-nenhuma}${n}"
has(){ [[ " $FEATS " == *" $1 "* ]]; }

# ------------------------------------------------------- POLICIES DAY-2
sec "Policies no cluster (day-2)"
while read -r pol st; do
  [ -z "$pol" ] && continue
  short=${pol#pg-policies-features.}
  if [ "$st" = "Compliant" ]; then ok "$short"
  else
    fail "$short ($st)"
    oc -n $C get policy $pol -o jsonpath='{range .status.details[*]}{.templateMeta.name}{"|"}{.compliant}{"|"}{.history[0].message}{"\n"}{end}' 2>/dev/null \
      | awk -F'|' '$2!="Compliant"{printf "           - %s [%s] %s\n",$1,$2,substr($3,1,160)}'
  fi
done < <(oc -n $C get policies -o jsonpath='{range .items[*]}{.metadata.name} {.status.compliant}{"\n"}{end}' 2>/dev/null)

# ------------------------------------------------------- TÚNEL P/ CLUSTER
KC=$(mktemp)
oc -n clusters extract secret/$C-admin-kubeconfig --to=- > "$KC" 2>/dev/null
oc -n clusters-$C port-forward svc/kube-apiserver $PORT:6443 >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null; rm -f "$KC"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  oc --kubeconfig "$KC" --server https://127.0.0.1:$PORT --insecure-skip-tls-verify get --raw /readyz >/dev/null 2>&1 && break; sleep 1; done
K(){ oc --kubeconfig "$KC" --server https://127.0.0.1:$PORT --insecure-skip-tls-verify "$@" 2>/dev/null; }

sec "Cluster (de dentro)"
nodes_nr=$(K get nodes --no-headers | awk '$2!="Ready"' | wc -l | tr -d ' ')
check "Nós NotReady" "$nodes_nr" "0"
co_bad=$(K get co --no-headers | awk '$3!="True" || $5=="True"{print $1}' | tr '\n' ' ')
if [ -z "$co_bad" ]; then ok "Cluster operators saudáveis"; else fail "Cluster operators com problema: $co_bad"; fi
bad_pods=$(K get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers | wc -l | tr -d ' ')
if [ "$bad_pods" = "0" ]; then ok "Nenhum pod Pending/Failed"; else
  warn "$bad_pods pod(s) fora de Running:"; K get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers | head -8 | sed 's/^/           /'; fi
INFRA_NODES=$(K get nodes -l node-role.kubernetes.io/infra -o jsonpath='{.items[*].metadata.name}')

# ------------------------------------------------------- FEATURES
if has infra-nodes; then sec "infra-nodes"
  want=$(oc -n clusters get nodepool $C-infra -o jsonpath='{.spec.replicas}' 2>/dev/null)
  check "Nós com role infra" "$(echo $INFRA_NODES | wc -w | tr -d ' ')" "${want:-?}"
  tainted=$(K get nodes -l node-role.kubernetes.io/infra -o jsonpath='{range .items[*]}{.spec.taints[?(@.key=="node-role.kubernetes.io/infra")].effect}{"\n"}{end}' | grep -c NoSchedule)
  check "Nós infra com taint" "$tainted" "${want:-?}"
fi

on_infra(){ # on_infra <ns> <label-selector> <nome>
  local nodes total off=0
  nodes=$(K -n "$1" get pods -l "$2" --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}')
  total=$(echo "$nodes" | grep -c . )
  if [ "$total" = "0" ]; then fail "$3: nenhum pod Running"; return; fi
  if has infra-nodes; then
    for nd in $nodes; do [[ " $INFRA_NODES " == *" $nd "* ]] || off=$((off+1)); done
    if [ "$off" = "0" ]; then ok "$3: $total pod(s) Running nos nós de infra"; else fail "$3: $off de $total pod(s) FORA dos nós de infra"; fi
  else ok "$3: $total pod(s) Running"; fi
}

if has oauth-htpasswd; then sec "oauth-htpasswd"
  check "IdP htpasswd no HostedCluster" "$(oc -n clusters get hostedcluster $C -o jsonpath='{.spec.configuration.oauth.identityProviders[*].type}' 2>/dev/null)" "HTPasswd"
  admin=$(K get clusterrolebinding hcp-lab-oauth-admin -o jsonpath='{.roleRef.name}:{.subjects[0].name}')
  if [ -n "$admin" ]; then ok "cluster-admin para ${admin#*:}"; else fail "ClusterRoleBinding hcp-lab-oauth-admin não existe"; fi
fi

if has ntp; then sec "ntp"
  if oc -n clusters get configmap $C-chrony >/dev/null 2>&1; then ok "ConfigMap $C-chrony no hub"; else fail "ConfigMap $C-chrony não existe"; fi
  for np in $(oc -n clusters get nodepool -o jsonpath='{range .items[?(@.spec.clusterName=="'"$C"'")]}{.metadata.name}{" "}{end}'); do
    cfg=$(oc -n clusters get nodepool $np -o jsonpath='{.spec.config[*].name}')
    upd=$(oc -n clusters get nodepool $np -o jsonpath='{.status.conditions[?(@.type=="UpdatingConfig")].status}')
    if [[ "$cfg" == *"$C-chrony"* ]]; then
      if [ "$upd" = "True" ]; then warn "NodePool $np: aplicando NTP (nós sendo recriados)"; else ok "NodePool $np com NTP aplicado"; fi
    else fail "NodePool $np sem o chrony"; fi
  done
fi

if has etcd-backup; then sec "etcd-backup"
  if oc -n hcp-etcd-backup get cronjob etcd-backup-$C >/dev/null 2>&1; then ok "CronJob etcd-backup-$C ($(oc -n hcp-etcd-backup get cronjob etcd-backup-$C -o jsonpath='{.spec.schedule}'))"
    last=$(oc -n hcp-etcd-backup get cronjob etcd-backup-$C -o jsonpath='{.status.lastSuccessfulTime}')
    if [ -n "$last" ]; then ok "Último backup com sucesso: $last"
    else warn "Ainda não rodou. Teste agora: oc -n hcp-etcd-backup create job --from=cronjob/etcd-backup-$C teste-\$(date +%s)"; fi
    failed=$(oc -n hcp-etcd-backup get jobs -l batch.kubernetes.io/cronjob-name=etcd-backup-$C -o jsonpath='{range .items[?(@.status.failed)]}{.metadata.name}{" "}{end}' 2>/dev/null)
    [ -n "$failed" ] && warn "Jobs com falha: $failed (veja: oc -n hcp-etcd-backup logs job/<nome>)"
  else fail "CronJob etcd-backup-$C não existe"; fi
  check "PVC do backup" "$(oc -n hcp-etcd-backup get pvc etcd-backup-$C -o jsonpath='{.status.phase}' 2>/dev/null)" "Bound"
fi

if has ingress; then sec "ingress"
  want=$(oc get managedcluster $C -o jsonpath='{.metadata.labels.config\.pg\.lab/ingress-replicas}')
  check "Réplicas do IngressController" "$(K -n openshift-ingress-operator get ingresscontroller default -o jsonpath='{.status.availableReplicas}')" "$want"
  on_infra openshift-ingress ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default "Routers"
fi

if has registry; then sec "registry"
  check "Registry Managed" "$(K get configs.imageregistry.operator.openshift.io cluster -o jsonpath='{.spec.managementState}')" "Managed"
  check "PVC image-registry-storage" "$(K -n openshift-image-registry get pvc image-registry-storage -o jsonpath='{.status.phase}')" "Bound"
  on_infra openshift-image-registry docker-registry=default "Registry"
fi

if has observability; then sec "observability"
  if K -n openshift-monitoring get pvc --no-headers | grep -q .; then
    nb=$(K -n openshift-monitoring get pvc --no-headers | awk '$2!="Bound"' | wc -l | tr -d ' ')
    check "PVCs do monitoring Bound (pendentes)" "$nb" "0"; else fail "Monitoring sem PVC (não está persistente)"; fi
  on_infra openshift-monitoring app.kubernetes.io/name=prometheus "Prometheus"
  on_infra openshift-monitoring app.kubernetes.io/name=alertmanager "Alertmanager"
  uwm=$(K -n openshift-user-workload-monitoring get pods -l app.kubernetes.io/name=prometheus --field-selector=status.phase=Running --no-headers | wc -l | tr -d ' ')
  if [ "$uwm" -gt 0 ]; then ok "User workload monitoring ($uwm Prometheus)"; else fail "User workload monitoring sem Prometheus"; fi
  check "Cluster Observability Operator" "$(K -n openshift-cluster-observability-operator get csv -o jsonpath='{.items[0].status.phase}')" "Succeeded"
fi

if has loki; then sec "loki"
  check "Loki Operator" "$(K -n openshift-operators-redhat get csv -o jsonpath='{range .items[?(@.spec.displayName=="Loki Operator")]}{.status.phase}{end}')" "Succeeded"
  echo "         canal: $(K -n openshift-operators-redhat get sub loki-operator -o jsonpath='{.spec.source}/{.spec.channel}')"
  check "Bucket no hub (OBC)" "$(oc -n pg-policies-features get objectbucketclaim loki-$C -o jsonpath='{.status.phase}' 2>/dev/null)" "Bound"
  check "LokiStack Ready" "$(K -n openshift-logging get lokistack logging-loki -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" "True"
  degr=$(K -n openshift-logging get lokistack logging-loki -o jsonpath='{.status.conditions[?(@.status=="True")].type}' | tr ' ' '\n' | grep -E "Degraded|Failed")
  [ -n "$degr" ] && fail "LokiStack $degr: $(K -n openshift-logging get lokistack logging-loki -o jsonpath='{.status.conditions[?(@.type=="Degraded")].message}')"
  on_infra openshift-logging app.kubernetes.io/instance=logging-loki "Pods do Loki"
fi

if has logging; then sec "logging"
  check "Cluster Logging Operator" "$(K -n openshift-logging get csv -o jsonpath='{range .items[?(@.spec.displayName=="Red Hat OpenShift Logging")]}{.status.phase}{end}')" "Succeeded"
  echo "         canal: $(K -n openshift-logging get sub cluster-logging -o jsonpath='{.spec.source}/{.spec.channel}')"
  check "ClusterLogForwarder Ready" "$(K -n openshift-logging get clusterlogforwarder logging -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" "True"
  want=$(K get nodes --no-headers | wc -l | tr -d ' ')
  check "Collectors Running (1 por nó)" "$(K -n openshift-logging get pods -l app.kubernetes.io/component=collector --field-selector=status.phase=Running --no-headers | wc -l | tr -d ' ')" "$want"
  if has observability; then
    check "Plugin de logs no console (UIPlugin)" "$(K get uiplugin logging -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')" "True"
  fi
fi

# ------------------------------------------------------- RESUMO
echo
echo "${b}Resumo $C:${n} ${g}$OK OK${n}  ${y}$WARN aviso(s)${n}  ${r}$FAIL falha(s)${n}"
[ "$FAIL" = "0" ]
