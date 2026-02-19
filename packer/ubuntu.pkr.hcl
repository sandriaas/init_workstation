packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = ">= 1.0.0"
    }
  }
}

# ── Variables (passed via -var flags from phase2.sh) ──────────────────────────
variable "vm_name"              { type = string }
variable "vm_ram_mb"            { type = number; default = 4096 }
variable "vm_vcpus"             { type = number; default = 4 }
variable "vm_disk_gb"           { type = number; default = 32 }
variable "vm_iso_path"          { type = string }
variable "vm_user"              { type = string; default = "ubuntu" }
variable "vm_ssh_port"          { type = number; default = 22 }
variable "seed_dir"             { type = string }
variable "output_dir"           { type = string }
variable "ssh_private_key_file" { type = string }
variable "ovmf_code"            { type = string; default = "/usr/share/edk2/x64/OVMF_CODE.4m.fd" }
variable "ovmf_vars"            { type = string }

# ── QEMU builder ──────────────────────────────────────────────────────────────
source "qemu" "ubuntu" {
  vm_name          = "${var.vm_name}.qcow2"
  output_directory = var.output_dir

  # Local ISO (file:// makes Packer skip download)
  iso_url      = "file://${var.vm_iso_path}"
  iso_checksum = "none"

  # Disk
  disk_size      = "${var.vm_disk_gb}G"
  disk_interface = "virtio"
  format         = "qcow2"

  # Resources
  memory = var.vm_ram_mb
  cpus   = var.vm_vcpus

  # KVM + machine type (pc = i440fx, required for legacy IGD passthrough)
  accelerator  = "kvm"
  machine_type = "pc"
  net_device   = "virtio-net"
  headless     = true

  # UEFI firmware (writable VARS copy provided by phase2.sh)
  qemuargs = [
    ["-drive", "if=pflash,format=raw,readonly=on,file=${var.ovmf_code}"],
    ["-drive", "if=pflash,format=raw,file=${var.ovmf_vars}"],
    ["-serial", "file:/tmp/packer-${var.vm_name}-serial.log"],
  ]

  # Packer's built-in HTTP server serves the seed dir (user-data + meta-data)
  http_directory = var.seed_dir
  http_port_min  = 3003
  http_port_max  = 3010

  # Boot via GRUB command line (UEFI).
  # Quotes around ds=... prevent GRUB from treating ; as a command separator.
  boot_wait = "10s"
  boot_command = [
    "c<wait5>",
    "linux /casper/vmlinuz \"ds=nocloud-net;s=http://{{.HTTPIP}}:{{.HTTPPort}}/\" autoinstall ---<enter><wait5>",
    "initrd /casper/initrd<enter><wait5>",
    "boot<enter>",
  ]

  # SSH communicator — connects after autoinstall finishes and VM reboots (~15 min)
  communicator           = "ssh"
  ssh_username           = var.vm_user
  ssh_private_key_file   = var.ssh_private_key_file
  ssh_port               = var.vm_ssh_port
  ssh_timeout            = "45m"
  ssh_handshake_attempts = 100

  shutdown_command = "sudo shutdown -P now"
  shutdown_timeout = "5m"
}

build {
  sources = ["source.qemu.ubuntu"]
}
