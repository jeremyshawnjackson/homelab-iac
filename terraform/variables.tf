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
