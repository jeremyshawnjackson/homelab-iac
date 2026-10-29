resource "proxmox_virtual_environment_vm" "mgmt" {
  name      = "mgmt"
  node_name = var.node
  vm_id     = 200
  tags      = ["homelab", "mgmt"]

  scsi_hardware = "virtio-scsi-single"

  clone {
    vm_id = var.template_id
    full  = true
  }

  agent {
    enabled = false
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 32
    discard      = "on"
    ssd          = true
    iothread     = true
  }

  network_device {
    bridge = "vmbr0"
  }

  initialization {
    datastore_id = "local-lvm"

    ip_config {
      ipv4 {
        address = var.mgmt_lan_ip
        gateway = var.lan_gateway
      }
    }

    dns {
      servers = ["1.1.1.1"]
    }

    user_account {
      username = "admin"
      keys     = [var.ssh_public_key]
    }
  }

  operating_system {
    type = "l26"
  }

  serial_device {}
}
