#!/usr/bin/env bash
# Applies the retention policy from the workstation, with a key that is
# allowed to delete. Only needed when backup_prune_on_server is false (the
# server's own key cannot delete, so a compromised server cannot erase history).
#
#   RESTIC_REPOSITORY=s3:https://.../bucket/app-prod \
#   AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
#   scripts/backup-prune.sh            # asks for the repository password
set -euo pipefail
: "${RESTIC_REPOSITORY:?set RESTIC_REPOSITORY}"
command -v restic >/dev/null || { echo "restic is required on this machine (sudo apt install restic)" >&2; exit 1; }
restic unlock
restic forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6
restic check
