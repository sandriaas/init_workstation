echo "=== Get deployment status of storage (a system service) ==="
npx -y zeabur@latest deployment get --project-id 6a2445faf1be9943f1f978dd --service-name storage 2>&1 | tail -30
echo ""
echo "=== Get deployment log of auth ==="
npx -y zeabur@latest deployment get --project-id 6a2445faf1be9943f1f978dd --service-name auth 2>&1 | tail -30
echo ""
echo "=== Check if server is the same (use GraphQL with project owner) ==="
curl -s -X POST https://api.zeabur.com/graphql \
  -H "Authorization: Bearer sk-zhw6hjoambkyva6hudyt3twsijjmz" \
  -H "Content-Type: application/json" \
  -d '{"query":"query { project(_id: \"6a2445faf1be9943f1f978dd\") { _id name region serverID server { _id name } } }"}'
echo ""
echo "=== Check project untitled too ==="
curl -s -X POST https://api.zeabur.com/graphql \
  -H "Authorization: Bearer sk-zhw6hjoambkyva6hudyt3twsijjmz" \
  -H "Content-Type: application/json" \
  -d '{"query":"query { project(_id: \"6a23ded7e957fb053c553ba4\") { _id name region serverID server { _id name } } }"}'
