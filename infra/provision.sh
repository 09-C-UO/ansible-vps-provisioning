#!/usr/bin/env bash
# Collage OpenTofu -> provision.sh : applique infra/ puis lance le provisioning
# Ansible avec l'adresse rendue par Tofu.
# Usage : infra/provision.sh <env> [options de provision.sh]
#   infra/provision.sh prod
#   infra/provision.sh prod -c 198.51.100.40/32
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: infra/provision.sh <env> [options de provision.sh]
  <env>  environnement Ansible : inventories/<env> (test, prod, lab)
Applique d'abord infra/ avec <env>.tfvars (ou prod.tfvars), puis provision.sh
avec l'IP rendue par "tofu output -raw vps_ip".
EOF
    exit 2
}

[ "$#" -ge 1 ] || usage
ENV="$1"
shift

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

command -v tofu >/dev/null 2>&1 || { echo "Missing required command: tofu" >&2; exit 1; }

INVENTORY_DIR="inventories/$ENV"
[ -f "$INVENTORY_DIR/hosts.ini" ] || { echo "Missing inventory: $INVENTORY_DIR/hosts.ini" >&2; exit 1; }

TFVARS="$ENV.tfvars"
[ -f "infra/$TFVARS" ] || TFVARS="prod.tfvars"
if [ ! -f "infra/$TFVARS" ]; then
    echo "Missing infra/$TFVARS. Create it from infra/prod.tfvars.example:" >&2
    echo "  cp infra/prod.tfvars.example infra/prod.tfvars" >&2
    exit 1
fi

echo "==> tofu apply -var-file=$TFVARS"
tofu -chdir=infra apply -var-file="$TFVARS"

IP="$(tofu -chdir=infra output -raw vps_ip)"
echo "==> VPS prêt : $IP"

exec ./provision.sh -i "$INVENTORY_DIR" "$@" "$IP"
