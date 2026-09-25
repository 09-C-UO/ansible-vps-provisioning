#!/bin/sh
# Vault password client used by provision.sh: prints the password it read once.
# For manual runs, prefer --ask-vault-pass.
printf '%s\n' "${TRAEFIK_ANSIBLE_VAULT_PASS:?Run through provision.sh or use --ask-vault-pass}"
