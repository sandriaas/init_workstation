curl -s -X POST https://api.zeabur.com/graphql \
  -H "Authorization: Bearer sk-zhw6hjoambkyva6hudyt3twsijjmz" \
  -H "Content-Type: application/json" \
  -d '{"query":"{ a: __type(name: \"Server\") { fields { name } } b: __type(name: \"ServerStatus\") { fields { name } } }"}'
