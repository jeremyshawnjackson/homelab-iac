variable "node" {
  type    = string
  default = "pve"
}

variable "template_id" {
  type    = number
  default = 9000
}

variable "ssh_public_key" {
  type        = string
  description = "Public key installed for the admin user on the mgmt VM"
}

variable "mgmt_lan_ip" {
  type    = string
  default = "192.168.1.20/24"
}

variable "lan_gateway" {
  type    = string
  default = "192.168.1.254"
}

variable "k3s_server_ip" {
  type    = string
  default = "192.168.1.21/24"
}

variable "gpu_node_ip" {
  type    = string
  default = "192.168.1.22/24"
}

variable "gpu_mapping" {
  type        = string
  description = "Cluster PCI resource mapping the GPU node attaches, created by ansible/roles/proxmox_host"
  default     = "gpu-3080"
}

variable "vendor_data_file_id" {
  type        = string
  description = "cloud-init vendor-data snippet, written by ansible/roles/proxmox_host"
  default     = "bulk:snippets/qga-vendor-data.yaml"
}

variable "ansible_public_key" {
  type        = string
  description = "Public key of the automation keypair on the mgmt VM, so Ansible can reach the nodes it manages"
  default     = ""
}
