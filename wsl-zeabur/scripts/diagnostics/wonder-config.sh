echo "=== Check wonder config ==="
ls -la /home/zeabur/.wonder/ 2>&1
ls -la /root/.wonder/ 2>&1
cat /home/zeabur/.wonder/config.yaml 2>/dev/null
cat /root/.wonder/config.yaml 2>/dev/null
echo ""
echo "=== wonder worker command help ==="
wonder worker --help 2>&1 | head -20
echo ""
echo "=== wonder version ==="
wonder version 2>&1
echo ""
echo "=== Find wonder registration in system ==="
find / -name "*.wonder*" -o -name "*wonder*" 2>/dev/null | grep -v proc | head -20
echo ""
echo "=== systemd service for wonder? ==="
systemctl list-units --all 2>&1 | grep -i wonder
ls /etc/systemd/system/ | grep -i wonder
ls /lib/systemd/system/ | grep -i wonder
