#!/usr/bin/env bash
# End-to-end test of the deploy mechanism, against a provisioned lab
# (tests/lab/run.sh all). Builds images in a registry inside the lab, then
# deploys them as deploy, as the CI key, and tries the known attacks.
set -euo pipefail

LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORK="$LAB_DIR/.work"
RUN="$LAB_DIR/run.sh"
IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' traefik-lab)"
DOMAIN="demo.${IP//./-}.sslip.io"
FAILURES=0

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

as_root() {   # stdin: script run as root in the lab, through admin + sudo
    # The script travels base64-encoded in the command line; stdin carries the
    # sudo password (sudo keeps no credential cache between non-tty commands).
    local script
    script="$(base64 -w0)"
    "$RUN" admin "printf '%s\n' lab-admin-password | sudo -S -p '' bash -c \"\$(echo $script | base64 -d)\""
}
as_deploy() { "$RUN" deploy "$@"; }
as_ci() {
    ssh -i "$WORK/keys/ci" -o IdentitiesOnly=yes -o UserKnownHostsFile="$WORK/known_hosts" \
        -o BatchMode=yes -o ControlMaster=auto -o ControlPersist=120 -o ControlPath="${XDG_RUNTIME_DIR:-/tmp}/tlab-ci-%C" \
        -p 22222 "deploy@$IP" "$@"
}
page() { curl -sk --max-time 10 "https://$DOMAIN/"; }
state() { as_deploy deploy-request status demo | sed -n 's/^state: //p'; }

echo "== Building demo images in the lab registry"
as_root >"$WORK/digests" <<'SCRIPT'
set -euo pipefail
docker inspect registry >/dev/null 2>&1 \
    || docker run -d --name registry --network host --restart unless-stopped registry:2 >/dev/null
for _ in $(seq 20); do curl -fs http://localhost:5000/v2/ >/dev/null && break; sleep 1; done
build() {  # tag, Dockerfile line
    printf 'FROM nginxinc/nginx-unprivileged:1.28-alpine\nUSER root\n%s\nUSER 101\n' "$2" \
        | docker build -q -t "localhost:5000/demo:$1" - >/dev/null
    docker push -q "localhost:5000/demo:$1" >/dev/null
    printf '%s=%s\n' "$1" "$(docker inspect -f '{{index .RepoDigests 0}}' "localhost:5000/demo:$1")"
}
build v1 'RUN echo "demo v1" > /usr/share/nginx/html/index.html'
build v2 'RUN echo "demo v2" > /usr/share/nginx/html/index.html'
# No index page: nginx answers 403, the health check fails.
build broken 'RUN rm /usr/share/nginx/html/index.html'
SCRIPT
. "$WORK/digests"
echo "   v1=$v1"

echo "== Nominal deploy and automatic rollback"
check "deploy v1 succeeds" "as_deploy deploy-request demo '$v1' >/dev/null"
check "the site serves v1" "page | grep -q 'demo v1'"
check "a broken image is refused" "! as_deploy deploy-request demo '$broken' >/dev/null"
check "state is rolled_back" "[ \"\$(state)\" = rolled_back ]"
check "the site still serves v1" "page | grep -q 'demo v1'"

echo "== CI key (forced command)"
check "CI deploys v2" "as_ci deploy-request demo '$v2' >/dev/null"
check "the site serves v2" "page | grep -q 'demo v2'"
check "CI key cannot open a shell" "! as_ci 'id' 2>/dev/null | grep -q uid="
check "CI key cannot forward ports" \
    "! timeout 15 ssh -i '$WORK/keys/ci' -o IdentitiesOnly=yes -o UserKnownHostsFile='$WORK/known_hosts' -o BatchMode=yes -o ExitOnForwardFailure=yes -p 22222 -N -L 18080:127.0.0.1:80 deploy@$IP 2>/dev/null"

echo "== Refused requests"
check "repository outside the allow list" \
    "! as_deploy deploy-request demo docker.io/library/nginx@sha256:$(printf '0%.0s' $(seq 64)) >/dev/null"
check "state is refused" "[ \"\$(state)\" = refused ]"
check "tag without digest (client side)" "! as_deploy deploy-request demo localhost:5000/demo:v1 2>/dev/null"
check "app name with a path (client side)" "! as_deploy deploy-request ../etc '$v1' 2>/dev/null"

as_deploy 'ln -sf /etc/shadow /var/lib/app-deploy/inbox/demo.request'
for _ in $(seq 15); do
    as_deploy deploy-request status demo | grep -q 'not a regular file' && break
    sleep 1
done
check "symlink to /etc/shadow is refused" "as_deploy deploy-request status demo | grep -q 'not a regular file'"
check "no shadow content leaks into the status" "! as_deploy deploy-request status demo | grep -q 'root:'"

as_deploy 'f=$(mktemp /var/lib/app-deploy/inbox/.x.XXXXXX); printf "id=0123456789abcdef\nimage=x\nextra=1\n" >"$f"; mv "$f" /var/lib/app-deploy/inbox/demo.request'
sleep 4
check "request with an extra line is refused" "as_deploy deploy-request status demo | grep -q 'exactly one'"
check "the site still serves v2" "page | grep -q 'demo v2'"

echo "== deploy stays unprivileged"
check "no Docker access" "! as_deploy 'docker ps' >/dev/null 2>&1"
check "no sudo" "! as_deploy 'sudo -n true' >/dev/null 2>&1"
check "cannot read the deploy worker's config" "! as_deploy 'cat /etc/app-deploy/demo.json' >/dev/null 2>&1"
check "cannot read the application secrets" "! as_deploy 'cat /opt/apps/demo/.env' >/dev/null 2>&1"

echo "== Alerts"
check "success reached the infra webhook" "grep -q 'demo : success' '$WORK/webhooks.log'"
check "rollback reached the infra webhook" "grep -q 'demo : rolled_back' '$WORK/webhooks.log'"
check "refusal reached the infra webhook" "grep -q 'demo refusé' '$WORK/webhooks.log'"

echo
[ "$FAILURES" -eq 0 ] && echo "All deploy tests passed." || { echo "$FAILURES deploy test(s) failed."; exit 1; }
