# Infrastructure Scaleway (OpenTofu) pour un VPS provisionné ensuite par Ansible.
# Collage avec provision.sh : tofu output -raw vps_ip.

terraform {
  required_version = ">= 1.8.0"

  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.52"
    }
  }

  # Décommenter pour un state distant (recommandé : verrouillage + chiffrement).
  # backend "s3" {
  #   bucket                      = "mon-tfstate"
  #   key                         = "vps.tfstate"
  #   region                      = "fr-par"
  #   endpoint                    = "https://s3.fr-par.scw.cloud"
  #   skip_credentials_validation = true
  #   skip_region_validation      = true
  #   skip_metadata_api_check     = true
  #   skip_requesting_account_id  = true
  # }
}

provider "scaleway" {
  zone            = var.scaleway_zone
  region          = var.scaleway_region
  organization_id = var.scaleway_organization_id
  project_id      = var.scaleway_project_id
}

# -----------------------------------------------------------------------------
# Réseau : IP publique fixe et pare-feu cloud (première couche de défense).
# Le port 22 n'est ouvert que pour le bootstrap : provision.sh y copie la clé
# admin, bootstrap.yml déplace sshd sur ssh_port et verrouille root, puis
# `just close-ssh-22 <env>` retire le 22 du pare-feu (ssh_22_open = false).
# -----------------------------------------------------------------------------

resource "scaleway_instance_ip" "vps" {
  type = "routed_ipv4"
}

resource "scaleway_instance_security_group" "vps" {
  name        = "${var.name}-sg"
  description = "22 (bootstrap), ${var.ssh_port}, 80, 443"

  inbound_rule {
    action   = var.ssh_22_open ? "accept" : "drop"
    port     = 22
    ip_range = var.trusted_ssh_cidr != "" ? var.trusted_ssh_cidr : "0.0.0.0/0"
    protocol = "TCP"
  }

  inbound_rule {
    action   = "accept"
    port     = var.ssh_port
    ip_range = var.trusted_ssh_cidr != "" ? var.trusted_ssh_cidr : "0.0.0.0/0"
    protocol = "TCP"
  }

  inbound_rule {
    action   = "accept"
    port     = 80
    ip_range = "0.0.0.0/0"
    protocol = "TCP"
  }

  inbound_rule {
    action   = "accept"
    port     = 443
    ip_range = "0.0.0.0/0"
    protocol = "TCP"
  }
}

resource "scaleway_instance_server" "vps" {
  name              = var.name
  zone              = var.scaleway_zone
  type              = var.instance_type
  image             = data.scaleway_image.ubuntu.id
  ip_id             = scaleway_instance_ip.vps.id
  security_group_id = scaleway_instance_security_group.vps.id

  root_volume {
    size       = var.root_volume_size
    volume_type = "b_ssd"
  }
}

data "scaleway_image" "ubuntu" {
  name       = var.ubuntu_image
  zone       = var.scaleway_zone
  arch       = var.instance_arch
  most_recent = true
}

# -----------------------------------------------------------------------------
# Sauvegardes : bucket S3-compatible + paire de clés dédiée pour restic.
# La secret key ne connaît pas de "write-only" chez Scaleway : le policy ne
# donne que les permissions objet sur ce bucket, pas l'administration.
# -----------------------------------------------------------------------------

resource "scaleway_object_bucket" "restic" {
  count  = var.backup_enabled ? 1 : 0
  name   = "${var.name}-restic"
  region = var.scaleway_region

  versioning {
    enabled = true
  }
}

resource "scaleway_iam_application" "restic" {
  count       = var.backup_enabled ? 1 : 0
  name        = "${var.name}-restic"
  description = "Accès restic au bucket de sauvegardes"
}

resource "scaleway_iam_policy" "restic" {
  count = var.backup_enabled ? 1 : 0
  name  = "${var.name}-restic-objects"

  application_id = scaleway_iam_application.restic[0].id

  rule {
    project_ids          = [var.scaleway_project_id]
    permission_set_names = [
      "ObjectStorageObjectsWrite",
      "ObjectStorageObjectsRead",
      "ObjectStorageObjectsList",
    ]
  }
}

resource "scaleway_iam_api_key" "restic" {
  count         = var.backup_enabled ? 1 : 0
  application_id = scaleway_iam_application.restic[0].id
  description    = "Identifiants restic de ${var.name}"
}

locals {
  restic_repository = var.backup_enabled ? "s3:${var.scaleway_region}.scw.cloud/${scaleway_object_bucket.restic[0].name}" : ""
}

# -----------------------------------------------------------------------------
# Sorties : le point de collage avec provision.sh et le vault Ansible.
# -----------------------------------------------------------------------------

output "vps_ip" {
  description = "Adresse IPv4 publique du VPS (provision.sh <ip>)"
  value       = scaleway_instance_ip.vps.address
}

output "vps_id" {
  description = "Identifiant du serveur Scaleway"
  value       = scaleway_instance_server.vps.id
}

output "restic_repository" {
  description = "À coller dans group_vars/vps/main.yml (restic_repository)"
  value       = local.restic_repository
}

output "restic_access_key" {
  description = "À coller dans secrets.vault.yml (restic_s3_access_key)"
  value       = var.backup_enabled ? scaleway_iam_api_key.restic[0].access_key : ""
}

output "restic_secret_key" {
  description = "À coller dans secrets.vault.yml (restic_s3_secret_key)"
  value       = var.backup_enabled ? scaleway_iam_api_key.restic[0].secret_key : ""
  sensitive   = true
}
