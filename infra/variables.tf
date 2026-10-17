# Variables de l'infrastructure Scaleway. Un tfvars par environnement :
#   tofu -chdir=infra apply -var-file=prod.tfvars
# Les tfvars réels sont ignorés par git.

variable "scaleway_organization_id" {
  type        = string
  description = "Organization ID Scaleway (SCW_DEFAULT_ORGANIZATION_ID)"
}

variable "scaleway_project_id" {
  type        = string
  description = "Project ID Scaleway (SCW_DEFAULT_PROJECT_ID)"
}

variable "scaleway_region" {
  type        = string
  default     = "fr-par"
  description = "Région Scaleway (fr-par, nl-ams, pl-waw)"
}

variable "scaleway_zone" {
  type        = string
  default     = "fr-par-1"
  description = "Zone Scaleway (fr-par-1, fr-par-2, nl-ams-3...)"
}

variable "name" {
  type        = string
  default     = "vps"
  description = "Préfixe des ressources Scaleway (serveur, bucket, policy)"
}

variable "instance_type" {
  type        = string
  default     = "PLAY2-PICO15"
  description = "Type d'instance (PLAY2-PICO15, PLAY2-NANO15, COPARM1-S...)"
}

variable "instance_arch" {
  type        = string
  default     = "x86_64"
  description = "Architecture (x86_64, ou arm64 pour les types COPARM/COP)"
}

variable "ubuntu_image" {
  type        = string
  default     = "Ubuntu 24.04"
  description = "Image marketplace Ubuntu (l'OS est ensuite durci par site.yml)"
}

variable "root_volume_size" {
  type        = number
  default     = 20
  description = "Taille du disque racine en Go"
}

variable "ssh_port" {
  type        = number
  default     = 22222
  description = "Doit valoir ssh_port de l'inventaire Ansible (group_vars/vps/main.yml)"
}

variable "ssh_22_open" {
  type        = bool
  default     = true
  description = "false ferme le port 22 du pare-feu, après le bootstrap Ansible"
}

variable "trusted_ssh_cidr" {
  type        = string
  default     = ""
  description = "Restreint SSH (22 et ssh_port) à ce CIDR, ex. 198.51.100.40/32. Vide : partout."
}

variable "backup_enabled" {
  type        = bool
  default     = true
  description = "Crée le bucket restic et la paire de clés S3 dédiée"
}
