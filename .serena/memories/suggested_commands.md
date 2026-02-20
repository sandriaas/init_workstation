# Suggested Commands

## Running scripts
```bash
sudo bash scripts/phase1.sh    # Host setup
sudo bash scripts/phase2.sh    # VM provisioning  
sudo bash scripts/phase3.sh    # VM internal setup
bash scripts/check.sh          # Verification
```

## Git
```bash
git --no-pager status
git --no-pager diff
git add -A && git commit -m "message"
git push origin main
```

## System
```bash
uname -r                        # Check kernel
dkms status                     # DKMS modules
virsh list --all                # VMs
systemctl status cloudflared    # Tunnel status
lspci | grep -i vga             # GPU devices
```
