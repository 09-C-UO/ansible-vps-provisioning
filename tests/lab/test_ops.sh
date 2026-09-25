#!/usr/bin/env bash
# Operations test against a provisioned lab: backup, restore test, repository
# check, AIDE detection, rkhunter run, and the alerts they produce.
set -euo pipefail

LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORK="$LAB_DIR/.work"
RUN="$LAB_DIR/run.sh"
FAILURES=0

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
as_root() {
    # The script travels base64-encoded in the command line; stdin carries the
    # sudo password (sudo keeps no credential cache between non-tty commands).
    local script
    script="$(base64 -w0)"
    "$RUN" admin "printf '%s\n' lab-admin-password | sudo -S -p '' bash -c \"\$(echo $script | base64 -d)\""
}

echo "== Backups"
as_root <<'SCRIPT' >/dev/null
docker exec -u postgres "$(docker ps -q --filter label=com.docker.compose.project=demo --filter label=com.docker.compose.service=db)" \
    psql -U demo -d demo -c 'create table if not exists canary (id int); insert into canary values (42);'
SCRIPT
check "backup-run succeeds" "echo 'systemctl start backup-run.service' | as_root"
check "a snapshot exists" "echo '. /usr/local/lib/backup-lib.sh; restic snapshots --json' | as_root | grep -q '\"paths\"'"
check "the restore test succeeds" "echo 'systemctl start backup-restore-test.service' | as_root"
check "the restored database has the canary table" \
    "echo 'journalctl -u backup-restore-test.service -n 20 -o cat' | as_root | grep -q 'OK, [1-9][0-9]* tables'"
check "the repository check succeeds" "echo 'systemctl start backup-check.service' | as_root"

echo "== Integrity"
as_root <<'SCRIPT' >/dev/null
echo "planted by test_ops.sh" > /etc/lab-intruder
systemctl start aide-check.service
SCRIPT
check "AIDE reports the planted file" "grep -q 'AIDE' '$WORK/webhooks.log' && grep -q 'lab-intruder' '$WORK/webhooks.log'"
check "the alert went to the security channel" "grep 'lab-intruder' '$WORK/webhooks.log' | grep -q '\"channel\": \"security\"'"
echo 'rm -f /etc/lab-intruder' | as_root
check "rkhunter runs without error" "echo 'systemctl start rkhunter-check.service' | as_root"

echo "== Decoy secrets"
check "the decoy exists, root-only" \
    "echo 'stat -c \"%U %a\" /root/.aws/credentials' | as_root | grep -qx 'root 600'"
check "deploy cannot read it" "! '$RUN' deploy 'cat /root/.aws/credentials' >/dev/null 2>&1"
check "AIDE does not report it" "! echo 'aide --config /etc/aide/aide.conf --check' | as_root | grep -q '/root/.aws'"

echo "== Server monitoring"
check "an admin SSH login alerts the security channel" \
    "grep 'Connexion SSH : admin' '$WORK/webhooks.log' | grep -q '\"channel\": \"security\"'"
check "no alert for deploy logins" "! grep -q 'Connexion SSH : deploy' '$WORK/webhooks.log'"
as_root <<'SCRIPT' >/dev/null
cp /etc/server-health.conf /root/server-health.conf.saved
sed -i 's/^DISK_MAX=.*/DISK_MAX=1/' /etc/server-health.conf
systemctl start server-health.service
cp /root/server-health.conf.saved /etc/server-health.conf
systemctl start server-health.service
SCRIPT
sleep 2
check "a crossed disk threshold alerts the infra channel" "grep -q 'Serveur : seuil dépassé' '$WORK/webhooks.log'"
check "the return to normal is reported" "grep -q 'Serveur : retour à la normale' '$WORK/webhooks.log'"

echo "== Failure alerts"
as_root <<'SCRIPT' >/dev/null || true
mv /etc/restic/password /etc/restic/password.moved
systemctl start backup-run.service
mv /etc/restic/password.moved /etc/restic/password
SCRIPT
sleep 3
check "a failed backup alerts the infra channel" "grep -q 'backup-run.service' '$WORK/webhooks.log'"

echo
[ "$FAILURES" -eq 0 ] && echo "All operations tests passed." || { echo "$FAILURES operations test(s) failed."; exit 1; }
