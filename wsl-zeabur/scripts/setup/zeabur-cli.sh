echo "=== Login with API token ==="
npx -y zeabur@latest auth login --token sk-zhw6hjoambkyva6hudyt3twsijjmz 2>&1 | tail -10
echo ""
echo "=== Current workspace ==="
npx -y zeabur@latest workspace current 2>&1 | tail -10
echo ""
echo "=== List projects ==="
npx -y zeabur@latest project ls 2>&1 | tail -30
