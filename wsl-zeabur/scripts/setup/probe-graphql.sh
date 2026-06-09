echo "=== Try different GraphQL queries to find the server ==="
for query in \
  '{"query":"query { me { _id username email } }"}' \
  '{"query":"query { me { servers { _id name } } }"}' \
  '{"query":"query { servers { _id name } }"}' \
  '{"query":"query { myServers { _id name } }"}' \
  '{"query":"{ __schema { queryType { fields { name } } } }"}'; do
  echo "--- Query: $query"
  curl -s -X POST https://api.zeabur.com/graphql \
    -H "Authorization: Bearer sk-zhw6hjoambkyva6hudyt3twsijjmz" \
    -H "Content-Type: application/json" \
    -d "$query" 2>&1 | head -c 500
  echo ""
done
