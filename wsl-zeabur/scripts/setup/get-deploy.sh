echo "=== Get service info via GraphQL with full introspection ==="
curl -s -X POST https://api.zeabur.com/graphql \
  -H "Authorization: Bearer sk-zhw6hjoambkyva6hudyt3twsijjmz" \
  -H "Content-Type: application/json" \
  -d '{"query":"query { project(_id: \"6a2445faf1be9943f1f978dd\") { _id name services { _id name } environments { _id name } } }"}'
echo ""
echo "=== Try checking service via CLI non-interactive ==="
npx -y zeabur@latest context set project --id 6a2445faf1be9943f1f978dd -i=false 2>&1 | tail -5
npx -y zeabur@latest context set service --name storage -i=false 2>&1 | tail -5
echo ""
echo "=== Now get deployment status ==="
npx -y zeabur@latest deployment get 2>&1 | tail -30
echo ""
echo "=== Get runtime logs ==="
npx -y zeabur@latest deployment log -t=runtime 2>&1 | tail -30
