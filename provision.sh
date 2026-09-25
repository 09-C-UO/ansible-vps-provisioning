#!/usr/bin/env bash
# Provision a fresh Ubuntu server, from any provider, in one pass.
# You will be asked, in this order:
#   1. the Ansible vault password (once, reused for every step);
#   2. "yes" to trust the server's SSH fingerprint (first contact);
#   3. the provider's root (or ubuntu) password, once, for ssh-copy-id.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: ./provision.sh [-i inventory] [-u bootstrap_user] [-c trusted_ssh_cidr] <server-ip>

  -i  inventory directory (default: inventories/test)
  -u  account created by the provider (default: bootstrap_user from the
      inventory, else root; AWS/OVH: ubuntu)
  -c  only allow SSH from this CIDR, e.g. 198.51.100.40/32

Example: ./provision.sh -i inventories/prod 203.0.113.25
EOF
    exit 2
}

INVENTORY_DIR=inventories/test
BOOTSTRAP_USER=""
TRUSTED_CIDR=""
while getopts ":i:u:c:h" opt; do
    case "$opt" in
        i) INVENTORY_DIR="${OPTARG%/}" ;;
        u) BOOTSTRAP_USER="$OPTARG" ;;
        c) TRUSTED_CIDR="$OPTARG" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
[ "$#" -eq 1 ] || usage
TARGET_HOST="$1"

[[ "$TARGET_HOST" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "Expected an IPv4 address: $TARGET_HOST" >&2; usage; }
if [ -n "$BOOTSTRAP_USER" ]; then
    [[ "$BOOTSTRAP_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || usage
fi
if [ -n "$TRUSTED_CIDR" ]; then
    [[ "$TRUSTED_CIDR" =~ ^[A-Fa-f0-9.:]+/[0-9]{1,3}$ ]] || usage
fi

for required_command in ansible ansible-galaxy ansible-playbook ansible-vault ssh-copy-id; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "Missing required command: $required_command" >&2
        exit 1
    fi
done

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

[ -f "$INVENTORY_DIR/hosts.ini" ] || { echo "Missing inventory: $INVENTORY_DIR/hosts.ini" >&2; exit 1; }
VAULT_FILE="$INVENTORY_DIR/group_vars/vps/secrets.vault.yml"

if ! head -n 1 "$VAULT_FILE" 2>/dev/null | grep -q '^\$ANSIBLE_VAULT'; then
    echo "Missing or unencrypted $VAULT_FILE. Create it with:" >&2
    echo "  ansible-vault create $VAULT_FILE" >&2
    echo "and paste the keys from secrets.example.yml with real values." >&2
    exit 1
fi

# The vault password is typed once and handed to every ansible command through
# scripts/vault-pass.sh, which only echoes this environment variable.
# Already set by an automated caller (tests/lab/run.sh): not asked again.
if [ -z "${TRAEFIK_ANSIBLE_VAULT_PASS:-}" ]; then
    read -rsp "Ansible vault password: " TRAEFIK_ANSIBLE_VAULT_PASS
    echo
fi
export TRAEFIK_ANSIBLE_VAULT_PASS
VAULT_ARGS=(--vault-password-file ./scripts/vault-pass.sh)

if ! ansible-vault view "${VAULT_ARGS[@]}" "$VAULT_FILE" >/dev/null 2>&1; then
    echo "Wrong vault password." >&2
    exit 1
fi

# Checks the decrypted YAML and its keys without ever printing a secret value.
if ! ansible-vault view "${VAULT_ARGS[@]}" "$VAULT_FILE" 2>/dev/null | python3 -c '
import re, sys, yaml
try:
    data = yaml.safe_load(sys.stdin)
except yaml.YAMLError as error:
    mark = getattr(error, "problem_mark", None)
    where = f" at line {mark.line + 1}, column {mark.column + 1}" if mark else ""
    sys.exit(f"Invalid YAML in the vault{where}. Quote values containing \": \" or \" #\".")
if not isinstance(data, dict):
    sys.exit("The vault must contain key: value lines.")
missing = [k for k in ("vault_admin_password", "vault_admin_password_salt",
                       "traefik_basic_auth_password") if not data.get(k)]
if missing:
    sys.exit("Missing vault keys: " + ", ".join(missing))
if len(str(data["vault_admin_password"])) < 12:
    sys.exit("vault_admin_password must be at least 12 characters.")
if not re.fullmatch(r"[a-zA-Z0-9./]{16}", str(data["vault_admin_password_salt"])):
    sys.exit("vault_admin_password_salt must be exactly 16 characters from [a-zA-Z0-9./].")
'; then
    echo "Fix it with: ansible-vault edit $VAULT_FILE" >&2
    exit 1
fi

ANSIBLE_EXTRA_VARS=(-i "$INVENTORY_DIR/hosts.ini" -e "ansible_host=$TARGET_HOST")
[ -z "$BOOTSTRAP_USER" ] || ANSIBLE_EXTRA_VARS+=(-e "bootstrap_user=$BOOTSTRAP_USER")
if [ -n "$TRUSTED_CIDR" ]; then
    ANSIBLE_EXTRA_VARS+=(-e "{\"ssh_allowed_cidrs\":[\"$TRUSTED_CIDR\"]}")
fi

echo "==> Installing required Ansible collections..."
ansible-galaxy collection install -r requirements.yml </dev/null

# Values resolved by Ansible itself (inventory + group_vars), so this script
# and the playbooks can never disagree on key paths or ports.
INVENTORY_VARS="$(ANSIBLE_LOAD_CALLBACK_PLUGINS=1 ANSIBLE_STDOUT_CALLBACK=ansible.builtin.json \
    ansible 'vps[0]' --playbook-dir . "${VAULT_ARGS[@]}" "${ANSIBLE_EXTRA_VARS[@]}" \
    -m ansible.builtin.debug -a 'msg={{ [ssh_key_dir, ssh_known_hosts_file, bootstrap_user, bootstrap_ssh_port, ssh_port, ssh_alias_prefix] | join("\t") }}' \
    | python3 -c 'import json, sys
hosts = json.load(sys.stdin)["plays"][0]["tasks"][0]["hosts"]
print(next(iter(hosts.values()))["msg"])')"
IFS=$'\t' read -r KEY_DIR KNOWN_HOSTS BOOTSTRAP_USER BOOTSTRAP_PORT SSH_PORT ALIAS_PREFIX <<<"$INVENTORY_VARS"

for key in admin deploy; do
    for file in "$KEY_DIR/$key" "$KEY_DIR/$key.pub"; do
        [ -f "$file" ] || { echo "Missing SSH key: $file" >&2; exit 1; }
    done
    perms="$(stat -c '%a' "$KEY_DIR/$key")"
    [ "$perms" = "600" ] || { echo "$KEY_DIR/$key must be chmod 600 (is $perms)" >&2; exit 1; }
done

SSH_OPTS=(-o "UserKnownHostsFile=$KNOWN_HOSTS")

echo "==> Copying the admin key to $BOOTSTRAP_USER@$TARGET_HOST (provider password asked once)..."
echo "    If the fingerprint changed because the VPS was recreated, run:"
echo "    ssh-keygen -f '$KNOWN_HOSTS' -R $TARGET_HOST && ssh-keygen -f '$KNOWN_HOSTS' -R '[$TARGET_HOST]:$SSH_PORT'"
ssh-copy-id -i "$KEY_DIR/admin.pub" -p "$BOOTSTRAP_PORT" "${SSH_OPTS[@]}" "$BOOTSTRAP_USER@$TARGET_HOST"

# ssh-copy-id can exit 0 without installing anything (e.g. interrupted), so
# prove that key login works before going further.
if ! ssh -i "$KEY_DIR/admin" -o IdentitiesOnly=yes -o BatchMode=yes "${SSH_OPTS[@]}" \
        -o ConnectTimeout=10 -p "$BOOTSTRAP_PORT" "$BOOTSTRAP_USER@$TARGET_HOST" true; then
    echo "Key login as $BOOTSTRAP_USER failed: the admin key is not installed." >&2
    exit 1
fi

echo "==> Bootstrap: admin/deploy accounts, SSH moved to port $SSH_PORT, root closed..."
ansible-playbook bootstrap.yml "${VAULT_ARGS[@]}" "${ANSIBLE_EXTRA_VARS[@]}"

echo "==> Hardening and Traefik..."
ansible-playbook site.yml "${VAULT_ARGS[@]}" "${ANSIBLE_EXTRA_VARS[@]}"

echo
echo "Provisioning complete."
echo "  Admin:  ssh $ALIAS_PREFIX-admin"
echo "  Deploy: ssh $ALIAS_PREFIX-deploy"
echo "  Page:   the URL printed by the last task (BasicAuth)"
