curl -s -X POST https://api.zeabur.com/graphql \
  -H "Authorization: Bearer sk-zhw6hjoambkyva6hudyt3twsijjmz" \
  -H "Content-Type: application/json" \
  -d '{"query":"{ __type(name: \"Server\") { name fields { name type { name kind ofType { name kind } } } } }"}'
