# vm_2 Clean OS Install — Cloud-init Unattended

## Date: 2026-05-26

## Decisions
- Disk: Empty 32GB qcow2 (replaces cloned vm_1 OS)
- Install: Cloud-init unattended (Subiquity autoinstall)
- Hostname: vm-2
- User: sandriaas
- Password: SHA-512 hashed in seed ISO
- Installer: ubuntu-24.04.3-live-server-amd64.iso (already on disk)

## Execution Phases

### Phase 0: Pre-flight
- Verify tools: cloud-localds, mkpasswd
- Verify Ubuntu ISO, vm_2 is shut off
- Capture disk baseline

### Phase 1: Install missing tools
- cloud-image-utils (cloud-localds)
- whois (mkpasswd)

### Phase 2: Replace vm_2 disk
- Delete cloned vm_2.qcow2
- Create empty 32GB qcow2
- Set libvirt-qemu ownership

### Phase 3: Generate password hash
- mkpasswd SHA-512 '<VM_PASSWORD>'

### Phase 4: Author cloud-init user-data + meta-data
- /tmp/vm_2-cloud-init/user-data (autoinstall YAML)
- /tmp/vm_2-cloud-init/meta-data

### Phase 5: Build seed ISO
- cloud-localds → vm_2-seed.iso

### Phase 6: Update vm_2 XML
- Boot order: cdrom → hd
- CD-ROM 1: ubuntu-24.04.3-live-server-amd64.iso
- CD-ROM 2: vm_2-seed.iso

### Phase 7: Trigger install
- virsh start vm_2
- 10-15 min unattended install
- VM powers off when done

### Phase 8: Post-install cleanup
- Detach installer ISO + seed ISO
- Reset boot order to hd only
- Start vm_2

### Phase 9: OOM protection
- Apply -900 to all QEMU PIDs

### Phase 10: Verify
- domifaddr → get IP
- Test SSH: sandriaas@<ip>, password from cloud-init seed
- Confirm hostname vm-2, clean machine-id
