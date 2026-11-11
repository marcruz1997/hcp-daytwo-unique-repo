#!/usr/bin/env bash
# Gera o base64 do /etc/chrony.conf para colar em provisioning/components/ntp/chrony-configmap.yaml
# Uso: scripts/chrony-b64.sh ntp1.empresa.local ntp2.empresa.local
set -euo pipefail
[ $# -ge 1 ] || { echo "uso: $0 servidor1 [servidor2 ...]" >&2; exit 1; }
{
  for s in "$@"; do echo "server $s iburst"; done
  printf 'driftfile /var/lib/chrony/drift\nmakestep 1.0 3\nrtcsync\nlogdir /var/log/chrony\n'
} | base64 | tr -d '\n'
echo
