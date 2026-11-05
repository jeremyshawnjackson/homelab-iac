output "mgmt_ip" {
  value = split("/", var.mgmt_lan_ip)[0]
}

output "k3s_node_ips" {
  value = {
    for name, node in local.k3s_nodes : name => split("/", node.ip)[0]
  }
}
