echo "=== List workspaces ==="
npx -y zeabur@latest workspace list 2>&1
echo ""
echo "=== Try server query in current workspace ==="
curl -s -X POST https://api.zeabur.com/graphql \
  -H "Authorization: Bearer sk-zhw6hjoambkyva6hudyt3twsijjmz" \
  -H "Content-Type: application/json" \
  -d '{"query":"query { server(_id: \"server-6a23cdf424701a8493345c17\") { _id name } }"}'
echo ""
echo "=== Try alternative: with project on server field ==="
curl -s -X POST https://api.zeabur.com/graphql \
  -H "Authorization: Bearer sk-zhw6hjoambkyva6hudyt3twsijjmz" \
  -H "Content-Type: application/json" \
  -d '{"query":"{ a: server(_id: \"server-6a23cdf424701a8493345c17\") { _id } b: servers { _id } }"}'
echo ""
echo "=== Try with team query ==="
curl -s -X POST https://api.zeabur.com/graphql \
  -H "Authorization: Bearer sk-zhw6hjoambkyva6hudyt3twsijjmz" \
  -H "Content-Type: application/json" \
  -d '{"query":"query { me { username _id teams { _id name } } }"}'
