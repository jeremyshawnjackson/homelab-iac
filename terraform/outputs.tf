output "mgmt_ip" {
  value = split("/", var.mgmt_lan_ip)[0]
}
