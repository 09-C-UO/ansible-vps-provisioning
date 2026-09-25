#!/usr/bin/env bash
# Provision a fresh Ubuntu server, from any provider, in one pass.
# You will be asked, in this order:
#   1. the Ansible vault password (once, reused for every step);
#   2. "yes" to trust the server's SSH fingerprint (first contact);
#   3. the provider's root (or ubuntu) password, once, for ssh-copy-id.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: ./provision.sh [-u bootstrap_user] [-c trusted_ssh_cidr] <server-ip>

  -u  account created by the provider (default: root; AWS/OVH: ubuntu)
  -c  only allow SSH from this CIDR, e.g. 198.51.100.40/32

Example: ./provision.sh 203.0.113.25
EOF
    exit 2
}

BOOTSTRAP_USER=root
TRUSTED_CIDR=""
while getopts ":u:c:h" opt; do
    case "$opt" in
        u) BOOTSTRAP_USER="$OPTARG" ;;
        c) TRUSTED_CIDR="$OPTARG" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
[ "$#" -eq 1 ] || usage
TARGET_HOST="$1"

[[ "$TARGET_HOST" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "Expected an IPv4 address: $TARGET_HOST" >&2; usage; }
[[ "$BOOTSTRAP_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || usage
if [ -n "$TRUSTED_CIDR" ]; then
    [[ "$TRUSTED_CIDR" =~ ^[A-Fa-f0-9.:]+/[0-9]{1,3}$ ]] || usage
fi

for required_command in ansible-galaxy ansible-playbook ansible-vault ssh-copy-id; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "Missing required command: $required_command" >&2
        exit 1
    fi
done

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

KEY_DIR="$HOME/.ssh/ansible-linode/traeffik-forward-proxy"
VAULT_FILE="group_vars/all/secrets.vault.yml"

for key in admin deploy; do
    for file in "$KEY_DIR/$key" "$KEY_DIR/$key.pub"; do
        [ -f "$file" ] || { echo "Missing SSH key: $file" >&2; exit 1; }
    done
    perms="$(stat -c '%a' "$KEY_DIR/$key")"
    [ "$perms" = "600" ] || { echo "$KEY_DIR/$key must be chmod 600 (is $perms)" >&2; exit 1; }
done

if ! head -n 1 "$VAULT_FILE" 2>/dev/null | grep -q '^\$ANSIBLE_VAULT'; then
    echo "Missing or unencrypted $VAULT_FILE. Create it with:" >&2
    echo "  ansible-vault create $VAULT_FILE" >&2
    echo "and paste the keys from secrets.example.yml with real values." >&2
    exit 1
fi

# The vault password is typed once and handed to every ansible command through
# vault-pass.sh, which only echoes this environment variable.
read -rsp "Ansible vault password: " TRAEFIK_ANSIBLE_VAULT_PASS
echo
export TRAEFIK_ANSIBLE_VAULT_PASS
VAULT_ARGS=(--vault-password-file ./vault-pass.sh)

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

ANSIBLE_EXTRA_VARS=(
    -e "ansible_host=$TARGET_HOST"
    -e "bootstrap_user=$BOOTSTRAP_USER"
)
if [ -n "$TRUSTED_CIDR" ]; then
    ANSIBLE_EXTRA_VARS+=(-e "{\"ssh_allowed_cidrs\":[\"$TRUSTED_CIDR\"]}")
fi

echo "==> Installing required Ansible collections..."
ansible-galaxy collection install -r requirements.yml </dev/null

echo "==> Copying the admin key to $BOOTSTRAP_USER@$TARGET_HOST (provider password asked once)..."
echo "    If the fingerprint changed because the VPS was recreated, run:"
echo "    ssh-keygen -R $TARGET_HOST && ssh-keygen -R '[$TARGET_HOST]:22222'"
ssh-copy-id -i "$KEY_DIR/admin.pub" -p 22 "$BOOTSTRAP_USER@$TARGET_HOST"

# ssh-copy-id can exit 0 without installing anything (e.g. interrupted), so
# prove that key login works before going further.
if ! ssh -i "$KEY_DIR/admin" -o IdentitiesOnly=yes -o BatchMode=yes \
        -o ConnectTimeout=10 -p 22 "$BOOTSTRAP_USER@$TARGET_HOST" true; then
    echo "Key login as $BOOTSTRAP_USER failed: the admin key is not installed." >&2
    exit 1
fi

echo "==> Bootstrap: admin/deploy accounts, SSH moved to port 22222, root closed..."
ansible-playbook bootstrap.yml "${VAULT_ARGS[@]}" "${ANSIBLE_EXTRA_VARS[@]}"

echo "==> Hardening and Traefik..."
ansible-playbook site.yml "${VAULT_ARGS[@]}" "${ANSIBLE_EXTRA_VARS[@]}"

echo
echo "Provisioning complete."
echo "  Admin:  ssh traefik-test-admin"
echo "  Deploy: ssh traefik-test-deploy"
echo "  Page:   the URL printed by the last task (BasicAuth)"
