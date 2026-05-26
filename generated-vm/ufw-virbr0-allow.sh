#!/bin/bash
# UFW DHCP/DNS allow rules for libvirt virbr0 (CRITICAL for VM networking).
#
# Symptom this fixes:
#   VMs on libvirt default network get NO DHCP lease, can't ping out, no SSH.
#   VM's tap interface shows TX (DHCPDISCOVER broadcasts) but RX is tiny.
#   dnsmasq is listening on virbr0:67 but logs show NO DHCPDISCOVER activity.
#
# Root cause:
#   UFW default INPUT policy is DROP. The default ufw-before-input chain only
#   allows UDP spt=67 dpt=68 (server→client), not client→server (spt=68 dpt=67).
#   DHCPDISCOVER from VM has dst=255.255.255.255 broadcast → falls through
#   ufw-not-local → DROP. dnsmasq never sees the packet.
#
# Fix:
#   Allow UDP 67/68 (DHCP) and 53 (DNS) inbound on virbr0.
#
# Usage: sudo bash ufw-virbr0-allow.sh

set -e
if [ "$EUID" -ne 0 ]; then
    echo "Error: must run as root"
    exit 1
fi

echo "=== Allowing DHCP+DNS on virbr0 ==="
ufw allow in on virbr0 to any port 67 proto udp
ufw allow in on virbr0 to any port 68 proto udp
ufw allow in on virbr0 to any port 53 proto udp
ufw allow in on virbr0 to any port 53 proto tcp
ufw reload

echo ""
echo "=== Verify ==="
ufw status verbose | grep virbr0 || echo "(no virbr0 rules visible — check ufw status)"

echo ""
echo "=== After applying, restart any VMs to re-DHCP ==="
echo "  virsh destroy <vm>; virsh start <vm>"
