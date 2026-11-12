#!/usr/bin/env bash
# Cria clusters/<nome>/ a partir de docs/cluster-template.
# Uso: scripts/new-cluster.sh app01
set -euo pipefail
n=${1:?uso: $0 <nome-do-cluster>}
[[ $n =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "nome inválido (minúsculas, números e '-')" >&2; exit 1; }
cd "$(dirname "$0")/.."
[ -e "clusters/$n" ] && { echo "clusters/$n já existe" >&2; exit 1; }
cp -r docs/cluster-template "clusters/$n"
for f in "clusters/$n/policy.yaml" "clusters/$n/cluster/kustomization.yaml"; do
  sed "s/NOME/$n/g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
echo "Criado clusters/$n. Edite clusters/$n/cluster/kustomization.yaml e faça commit/push."
