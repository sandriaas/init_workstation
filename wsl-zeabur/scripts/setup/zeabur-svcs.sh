echo "=== List services in most recent project (untitled-2) ==="
npx -y zeabur@latest service ls --project-id 6a2445faf1be9943f1f978dd 2>&1 | tail -30
echo ""
echo "=== List services in untitled ==="
npx -y zeabur@latest service ls --project-id 6a23ded7e957fb053c553ba4 2>&1 | tail -30
