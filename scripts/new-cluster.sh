#!/usr/bin/env bash
# Cria clusters/<nome>/ a partir de docs/cluster-template e já preenche o mínimo:
#   - nome do cluster
#   - chave SSH pública (arquivo do 2º argumento, ou ~/.ssh/hcp-clusters.pub, id_ed25519.pub, id_rsa.pub)
#   - senha do usuário admin (pedida no terminal, ou variável ADMIN_PASSWORD; precisa do comando
#     htpasswd: sudo dnf install httpd-tools)
# Uso: scripts/new-cluster.sh <nome> [chave-publica.pub]
set -euo pipefail
die() { echo "ERRO: $*" >&2; exit 1; }

n=${1:?uso: $0 <nome-do-cluster> [chave-publica.pub]}
[[ $n =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "nome inválido (minúsculas, números e '-')"
[ ${#n} -le 20 ] || echo "AVISO: nome com mais de 20 caracteres pode estourar limites de DNS/labels" >&2
cd "$(dirname "$0")/.."
[ -e "clusters/$n" ] && die "clusters/$n já existe"

pub=${2:-}
if [ -z "$pub" ]; then
  for f in ~/.ssh/hcp-clusters.pub ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
    [ -f "$f" ] && { pub=$f; break; }
  done
fi

cp -r docs/cluster-template "clusters/$n"
for f in "clusters/$n/policy.yaml" "clusters/$n/cluster/kustomization.yaml" "clusters/$n/cluster/params.yaml"; do
  sed "s/NOME/$n/g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
P="clusters/$n/cluster/params.yaml"
pendente=()

# chave SSH pública
if [ -n "$pub" ] && [ -f "$pub" ]; then
  key=$(head -n1 "$pub")
  [[ $key =~ ^(ssh-|ecdsa-) ]] || die "$pub não parece uma chave pública"
  awk -v k="$key" '/^  sshPublicKey:/{print "  sshPublicKey: \"" k "\""; next} {print}' "$P" > "$P.tmp" && mv "$P.tmp" "$P"
  echo "chave SSH: $pub"
else
  pendente+=("sshPublicKey (cole a saída de: cat ~/.ssh/<sua-chave>.pub)")
fi

# senha do admin (htpasswd)
if command -v htpasswd >/dev/null; then
  pw=${ADMIN_PASSWORD:-}
  if [ -z "$pw" ]; then
    read -rsp "Senha do usuário admin de $n: " pw; echo
    read -rsp "Repita a senha: " pw2; echo
    [ "$pw" = "$pw2" ] || { rm -rf "clusters/$n"; die "as senhas não conferem"; }
  fi
  [ ${#pw} -ge 12 ] || echo "AVISO: senha com menos de 12 caracteres" >&2
  line=$(htpasswd -nbBC 12 admin "$pw")
  awk -v l="$line" '/TROQUE-PELO-HASH/{print "      " l; next} {print}' "$P" > "$P.tmp" && mv "$P.tmp" "$P"
  echo "senha do admin: gravada (hash bcrypt)"
else
  pendente+=("oauth.htpasswd (instale httpd-tools e rode: htpasswd -nbBC 12 admin 'SenhaForte')")
fi

echo
echo "Criado clusters/$n com os módulos padrão (workers small, login htpasswd, NTP, backup do etcd, router)."
if [ ${#pendente[@]} -gt 0 ]; then
  echo "Falta preencher em $P:"; printf '  - %s\n' "${pendente[@]}"
fi
echo "Opcional: ligar/desligar módulos em clusters/$n/cluster/kustomization.yaml e ajustar valores em $P."
echo "Publicar:  git add clusters/$n && git commit -m \"cria cluster $n\" && git push"
