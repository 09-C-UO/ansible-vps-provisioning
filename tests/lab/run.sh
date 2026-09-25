#!/usr/bin/env bash
# Local lab: provisions a privileged Ubuntu 24.04 container through the real
# provision.sh, then re-runs site.yml and fails unless nothing changed.
#
#   tests/lab/run.sh            # all: down, up, provision, idempotence, tests
#   tests/lab/run.sh up         # fresh container only
#   tests/lab/run.sh provision  # provision.sh against the running container
#   tests/lab/run.sh site [ansible-playbook args...]   # re-run site.yml
#   tests/lab/run.sh idempotence
#   tests/lab/run.sh test       # test_deploy.sh + test_ops.sh
#   tests/lab/run.sh admin|deploy [command]            # SSH into the lab
#   tests/lab/run.sh down       # remove the container and its Docker volume
#
# Nothing is written outside tests/lab/.work and the lab inventory's vault.
set -euo pipefail

LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$LAB_DIR/../.." && pwd)"
WORK="$LAB_DIR/.work"
NAME=traefik-lab
IMAGE=traefik-lab:24.04
ROOT_PASSWORD=lab-root-password
INVENTORY="$REPO_DIR/inventories/lab"
VAULT_FILE="$INVENTORY/group_vars/vps/secrets.vault.yml"

export TRAEFIK_ANSIBLE_VAULT_PASS=lab-vault-password

lab_ip() {
    docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NAME"
}

prepare_work() {
    mkdir -p "$WORK/keys"
    chmod 700 "$WORK" "$WORK/keys"
    for key in admin deploy ci; do
        [ -f "$WORK/keys/$key" ] || ssh-keygen -q -t ed25519 -N '' -C "lab-$key" -f "$WORK/keys/$key"
    done
    touch "$WORK/known_hosts"
    docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' >"$WORK/gateway"
    # Throwaway values, encrypted like a real vault so provision.sh checks them.
    cat >"$WORK/secrets.plain.yml" <<'VAULT'
vault_admin_password: "lab-admin-password"
vault_admin_password_salt: "LabSaltLabSalt16"
traefik_basic_auth_password: "lab-basic-auth"
restic_password: "lab-restic-password-000000"
app_secrets:
  demo:
    POSTGRES_USER: demo
    POSTGRES_DB: demo
    POSTGRES_PASSWORD: lab-postgres-password
VAULT
    rm -f "$VAULT_FILE"
    ansible-vault encrypt --vault-password-file "$REPO_DIR/vault-pass.sh" \
        --output "$VAULT_FILE" "$WORK/secrets.plain.yml"
    rm -f "$WORK/secrets.plain.yml"
    chmod 600 "$VAULT_FILE"
    start_sink
}

# Fake Discord: webhook calls land in .work/webhooks.log.
start_sink() {
    [ -f "$WORK/sink.pid" ] && kill -0 "$(cat "$WORK/sink.pid")" 2>/dev/null && return
    python3 "$LAB_DIR/webhook_sink.py" "$(cat "$WORK/gateway")" 8765 "$WORK/webhooks.log" &
    echo $! >"$WORK/sink.pid"
    disown
}

down() {
    [ -f "$WORK/sink.pid" ] && kill "$(cat "$WORK/sink.pid")" 2>/dev/null || true
    rm -f "$WORK/sink.pid" "$WORK/webhooks.log"
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker volume rm "$NAME-docker" "$NAME-containerd" >/dev/null 2>&1 || true
    rm -f "$WORK/known_hosts" "$WORK/ssh_config"
}

up() {
    down
    docker build -q -t "$IMAGE" --build-arg ROOT_PASSWORD="$ROOT_PASSWORD" "$LAB_DIR" >/dev/null
    # --privileged: systemd, UFW and a nested Docker daemon need it. The host
    # kernel is shared: see host_is_container in group_vars/all/main.yml.
    # Image stores are volumes: overlayfs cannot stack on the container's own.
    docker run -d --name "$NAME" --hostname "$NAME" --privileged \
        --tmpfs /run --tmpfs /run/lock \
        -v "$NAME-docker:/var/lib/docker" \
        -v "$NAME-containerd:/var/lib/containerd" \
        "$IMAGE" >/dev/null
    prepare_work
    local ip
    ip="$(lab_ip)"
    for _ in $(seq 30); do
        if ssh-keyscan -T 2 -t ed25519 "$ip" 2>/dev/null >"$WORK/keyscan"; then
            [ -s "$WORK/keyscan" ] && break
        fi
        sleep 1
    done
    [ -s "$WORK/keyscan" ] || { echo "sshd did not start in $NAME" >&2; exit 1; }
    # Trusting the key read from a container on this machine is safe; on a real
    # VPS, provision.sh asks for the fingerprint instead.
    cat "$WORK/keyscan" >>"$WORK/known_hosts"
    rm -f "$WORK/keyscan"
    echo "Lab container $NAME is up at $ip"
}

provision() {
    prepare_work
    printf '#!/bin/sh\necho %s\n' "$ROOT_PASSWORD" >"$WORK/askpass.sh"
    chmod 700 "$WORK/askpass.sh"
    # ssh-copy-id reads the provider password from askpass instead of a prompt.
    SSH_ASKPASS="$WORK/askpass.sh" SSH_ASKPASS_REQUIRE=force \
        "$REPO_DIR/provision.sh" -i "$INVENTORY" "$(lab_ip)" </dev/null
}

site() {
    prepare_work
    (cd "$REPO_DIR" && ansible-playbook site.yml -i "$INVENTORY/hosts.ini" \
        -e "ansible_host=$(lab_ip)" --vault-password-file ./vault-pass.sh "$@")
}

idempotence() {
    local log="$WORK/idempotence.log"
    site | tee "$log"
    if grep -Eq 'changed=[1-9]' "$log"; then
        echo "FAIL: the second run changed something (see $log)" >&2
        exit 1
    fi
    echo "OK: second run changed nothing"
}

run_tests() {
    start_sink
    "$LAB_DIR/test_deploy.sh"
    "$LAB_DIR/test_ops.sh"
}

connect() {
    local account="$1"
    shift
    # One multiplexed connection: UFW's "limit" rejects a 7th new connection
    # within 30 s, which a test script reaches quickly.
    ssh -F "$WORK/ssh_config" -o ControlMaster=auto -o ControlPersist=120 \
        -o ControlPath="${XDG_RUNTIME_DIR:-/tmp}/tlab-%C" "traefik-lab-$account" "$@"
}

case "${1:-all}" in
    all) up; provision; idempotence; run_tests ;;
    test) run_tests ;;
    up) up ;;
    provision) provision ;;
    site) shift; site "$@" ;;
    idempotence) idempotence ;;
    admin|deploy) account="$1"; shift; connect "$account" "$@" ;;
    down) down ;;
    *) sed -n '2,14p' "$0" >&2; exit 2 ;;
esac
