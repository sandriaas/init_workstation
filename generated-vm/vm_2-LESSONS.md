# Lessons Learned: vm_2 Clean OS Install (2026-05-26)

## TL;DR

What seemed like a 15-minute task took hours due to autoinstall debugging.
The breakthrough: **vm_1 already used the cloud-image pattern** (see
`generated-vm/vm_1.conf`), and that pattern works in ~30s. Always check the
existing repo's working examples first.

---

## What We Tried (and Why It Failed)

### Attempt 1: Subiquity autoinstall via cloud-init seed ISO

**Approach:** Empty 32GB qcow2 + `ubuntu-24.04.3-live-server-amd64.iso` + a
seed ISO with `cidata` label containing `user-data` (autoinstall YAML) and
`meta-data`.

**Failure:** Disk grew to ~2.5GB then stalled forever. Subiquity partitioned the
disk and booted the installer, but **stopped at the install-confirmation prompt**.

**Root cause:** Per Ubuntu docs (canonical-subiquity), when the autoinstall
config is on a separate seed volume (not the kernel cmdline), Subiquity prompts
for confirmation **unless** the kernel command line includes `autoinstall`.
The default GRUB entry on the live-server ISO does NOT pass `autoinstall`.

### Attempt 2: Direct kernel boot with `autoinstall` cmdline

**Approach:** Extract `/casper/vmlinuz` and `/casper/initrd` from the ISO,
configure libvirt `<kernel>`, `<initrd>`, `<cmdline>` to inject `autoinstall`.

**Failure:** Disk wrote ~2.5GB (partitioning) then stalled. No further writes.
DHCP lease never appeared.

**Root cause:** Direct kernel boot bypasses GRUB's `casper` setup. The kernel
boots without proper hardware initialization parameters; network may not come
up correctly inside the live installer environment.

### Attempt 3: Custom ISO with `autoinstall` baked into GRUB cfg

**Approach:** Use `xorriso` to clone the Ubuntu ISO with a patched `grub.cfg`
that adds `autoinstall` to the kernel line for the default menu entry.

**Failure:** ISO built successfully and booted, but install still stalled.

**Root cause:** Unclear. Possibly a quirk in how Subiquity 24.04.3 handles
autoinstall when the seed ISO is at `/dev/sdb` rather than the network or the
ISO root.

### Attempt 4: VNC keyboard injection (Python RFB) + virsh send-key + QEMU monitor sendkey

**Approach:** Inject keystrokes into the VM via VNC RFB protocol, libvirt's
`virsh send-key`, and QEMU monitor's `sendkey` command to navigate the
interactive Subiquity installer or edit GRUB inline.

**Failure:** Keys reached the VM (verified by serial pty changes for some
attempts) but timing was unreliable; nothing produced a clean install.

**Root cause:** GRUB-edit-then-boot timing is fragile and version-specific.
Headless keyboard injection without a display feedback loop is brittle.

---

## What Actually Worked: Cloud Image + Cloud-Init Seed (vm_1's Pattern)

```
vm_2.qcow2 = qemu-img convert from noble-server-cloudimg-amd64.img + resize 32G
vm_2-seed.iso = cloud-localds(user-data, meta-data, network-config)
virt-install --import --disk vm_2.qcow2 --disk vm_2-seed.iso (cdrom)
→ Boots in ~30s, cloud-init reads seed, configures user/hostname/SSH/network
```

### Why This Works

- **Cloud image is pre-installed Ubuntu** — no installer at all.
- Cloud-init runs on **first boot**, applies user-data deterministically.
- No interactive prompts, no GRUB edits, no autoinstall complexity.
- Same pattern already proven by `vm_1` (look at `vm_1.conf`).

---

## Other Sub-Issues Hit Along the Way

### Issue A: vm_2 sysprep'd from vm_1, kept vm_1's static IP

After cloning vm_1.qcow2 → vm_2.qcow2 + virt-sysprep, vm_2 still had
`/etc/netplan/50-cloud-init.yaml` configured for `192.168.122.50` (vm_1's IP).
Two VMs with the same IP = ARP conflict.

**Fix:** virt-customize the disk to overwrite netplan with `dhcp4: true`.

### Issue B: cloud-init regenerates netplan on first boot

After fixing netplan offline, cloud-init detects the seed ISO and rewrites
`/etc/netplan/50-cloud-init.yaml` from `network-config`. To force DHCP, the
seed ISO's `network-config` must specify DHCP.

### Issue C: Stale DHCP reservation in libvirt's hostsfile

`/var/lib/libvirt/dnsmasq/default.hostsfile` had a stale entry
`52:54:00:b1:19:94 → 192.168.122.50` from a prior VM. Neither vm_1 nor vm_2
matched, so neither got the reserved IP.

**Fix:** Use `virsh net-update default add ip-dhcp-host ...` for both VMs'
current MAC addresses.

### Issue D: UFW blocks DHCP on virbr0 (CRITICAL)

This was the most time-consuming finding. With UFW active and INPUT default
DROP, the default ufw-before-input chain only allows `spt=67 dpt=68`
(server-to-client). DHCPDISCOVER from a guest is `spt=68 dpt=67` broadcast.
It traverses ufw-not-local → BROADCAST → RETURN, then falls through to
ufw-user-input → DROP. dnsmasq never sees the packet.

**Symptom:** VM tap shows TX (DHCPDISCOVER) but RX never increases.
`virsh net-dhcp-leases` stays empty. Ping fails.

**Fix:**
```bash
ufw allow in on virbr0 to any port 67 proto udp
ufw allow in on virbr0 to any port 68 proto udp
ufw allow in on virbr0 to any port 53 proto udp
ufw allow in on virbr0 to any port 53 proto tcp
ufw reload
```
See `ufw-virbr0-allow.sh`.

### Issue E: PAM faillock locking sandriaas user from sudo failures

Multiple parallel `sudo -S` calls competed for stdin and triggered PAM faillock
(3 failed attempts → temporary lockout). Symptom: previously-working passwords
suddenly fail with "Sorry, try again."

**Fix:** `faillock --user sandriaas --reset`. Don't run `sudo -S` in parallel
calls — pipe the password once into a single sudo invocation that runs a
script.

### Issue F: VM has no display device → no screenshot

When XML is rebuilt without `<graphics>` and `<video>` elements, `virsh
screenshot` fails with "no screens to take screenshot from." Always include
`<graphics type='vnc'>` and `<video><model type='virtio'/></video>` for
serviceable VMs.

---

## Tools Installed During the Session

```bash
sudo pacman -S cloud-image-utils   # cloud-localds
sudo pacman -S guestfs-tools       # virt-customize, virt-cat, virt-ls, virt-sysprep
sudo pacman -S sshpass             # password-based SSH for testing
# whois (mkpasswd) was already present
```

---

## Recipes

### Generate SHA-512 password hash
```bash
mkpasswd --method=SHA-512 --rounds=4096 'YOUR_PASSWORD'
```

### Build cloud-init seed ISO
```bash
cloud-localds --network-config=network-config seed.iso user-data meta-data
```

### Inspect VM disk offline (when VM is stopped)
```bash
virt-cat -a /var/lib/libvirt/images/vm_2.qcow2 /var/log/cloud-init.log
virt-ls -a /var/lib/libvirt/images/vm_2.qcow2 /etc/netplan/
```

### Modify VM disk offline
```bash
virt-customize -a /path/to.qcow2 \
    --upload local-file:/remote/path \
    --run-command 'systemctl enable foo'
```

### Sysprep (wipe identity from cloned VM)
```bash
virt-sysprep -a /path/to.qcow2 \
    --hostname new-name \
    --password user:password:'NEW_PASSWORD'
```

### Find DHCP/Network problems
```bash
# 1. Check VM is sending DHCP
TAP=$(virsh domiflist <vm> | awk 'NR>2 && /vnet/ {print $1}')
ip -s link show "$TAP"            # TX should grow if VM is broadcasting

# 2. Check dnsmasq is receiving
journalctl -t dnsmasq-dhcp -n 30 | grep DHCP

# 3. If TX grows but dnsmasq sees nothing: firewall/UFW issue
iptables -L INPUT -n -v
```

---

## Key Takeaways

1. **Read existing repo conventions first.** `generated-vm/vm_1.conf` revealed
   the cloud-image pattern. Hours of autoinstall debugging avoided.

2. **Subiquity autoinstall is finicky.** Without `autoinstall` on the kernel
   command line, the seed-ISO method prompts for confirmation. Cloud images
   are simpler and faster.

3. **UFW + virbr0 = silent DHCP failures.** Always check INPUT firewall rules
   when libvirt VMs can't get IPs. Symptoms point at libvirt but the cause is
   the host firewall.

4. **Don't parallelize `sudo -S` calls.** stdin contention triggers PAM
   faillock. Wrap multi-step sudo work in a single script.

5. **`virt-customize` and `virt-cat` are powerful** for offline VM disk editing
   and inspection. Use them liberally instead of trying to interact with a
   running VM via VNC.

6. **VNC keyboard injection is a last resort.** Cloud-init handles
   first-boot configuration deterministically; reach for it before keystroke
   automation.
