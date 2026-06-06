echo "=== wonder binary status ==="
/usr/local/bin/wonder --help 2>&1 | head -20
echo ""
echo "=== wonder status / register info ==="
/usr/local/bin/wonder status 2>&1 | head -20
echo ""
echo "=== wonder with no args ==="
/usr/local/bin/wonder 2>&1 | head -30
