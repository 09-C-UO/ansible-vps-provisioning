# Shared by the backup-* scripts. Managed by Ansible.
set -euo pipefail
set -a
. /etc/restic/env
set +a
. /etc/restic/backup.conf

# Container id of a running compose service.
service_container() {
    docker ps -q --filter "label=com.docker.compose.project=$1" \
        --filter "label=com.docker.compose.service=$2" | head -n 1
}
