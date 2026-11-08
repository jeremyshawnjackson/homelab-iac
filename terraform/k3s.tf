# The two k3s nodes differ in size, storage and whether they get the GPU, so
# they are one resource driven by a map rather than two blocks that drift apart.
locals {
  k3s_nodes = {
    "k3s-server" = {
      vm_id     = 201
      cores     = 2
      memory    = 6144
      ip        = var.k3s_server_ip
      gpu       = null
      data_disk = 0
      tags      = ["homelab", "k3s", "server"]
    }
    "gpu-node" = {
      vm_id     = 202
      cores     = 4
      memory    = 20480
      ip        = var.gpu_node_ip
      gpu       = var.gpu_mapping
      data_disk = 200
      tags      = ["homelab", "k3s", "gpu"]
    }
  }
}

resource "proxmox_virtual_environment_vm" "k3s" {
  for_each = local.k3s_nodes

  name      = each.key
  node_name = var.node
  vm_id     = each.value.vm_id
  tags      = each.value.tags

  scsi_hardware = "virtio-scsi-single"
  machine       = "q35"

  # Passthrough needs OVMF (Phase 3). Nodes without a GPU stay on the
  # template's firmware.
  bios = each.value.gpu == null ? "seabios" : "ovmf"

  clone {
    vm_id = var.template_id
    full  = true
  }

  agent {
    enabled = true # installed on first boot by the vendor-data snippet
    timeout = "5m" # a bootstrap that has not finished by then has failed
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  # Ballooning is incompatible with passthrough, and vfio pins the whole guest
  # address space anyway: a GPU node's memory is resident from boot rather than
  # allocated on demand. The GPU node's 20 GB is therefore a hard reservation
  # against the host's 32 GB, which is what sizes the other two nodes.
  memory {
    dedicated = each.value.memory
    floating  = 0
  }

  dynamic "efi_disk" {
    for_each = each.value.gpu == null ? [] : [1]
    content {
      datastore_id      = "local-lvm"
      type              = "4m"
      pre_enrolled_keys = false # Secure Boot off
    }
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 32
    discard      = "on"
    ssd          = true
    iothread     = true
  }

  # Model weights and container images go on the SSHD. They are large, mostly
  # read sequentially, and must not compete with the OS SSD's thin pool.
  dynamic "disk" {
    for_each = each.value.data_disk == 0 ? [] : [each.value.data_disk]
    content {
      datastore_id = "bulk"
      interface    = "scsi1"
      size         = disk.value
      discard      = "on"
      file_format  = "qcow2"
    }
  }

  # By mapping name, not PCI address: this is what the non-root API token is
  # allowed to attach, and it survives the bus renumbering a new card causes.
  dynamic "hostpci" {
    for_each = each.value.gpu == null ? [] : [each.value.gpu]
    content {
      device  = "hostpci0"
      mapping = hostpci.value
      pcie    = true
    }
  }

  network_device {
    bridge = "vmbr0"
  }

  initialization {
    datastore_id = "local-lvm"
    interface    = "scsi2" # not ide2: q35 with OVMF wants the drive on SCSI

    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = var.lan_gateway
      }
    }

    dns {
      servers = ["1.1.1.1"]
    }

    user_account {
      username = "admin"
      # The workstation key is for people; the mgmt key is how Ansible gets in.
      keys = compact([var.ssh_public_key, var.ansible_public_key])
    }

    # Written by ansible/roles/proxmox_host, merged with the user-data above.
    # The guest agent therefore exists before anything waits on it.
    vendor_data_file_id = var.vendor_data_file_id
  }

  operating_system {
    type = "l26"
  }

  serial_device {}
}
