curl -s -X POST https://api.zeabur.com/graphql \
  -H "Authorization: Bearer sk-zhw6hjoambkyva6hudyt3twsijjmz" \
  -H "Content-Type: application/json" \
  -d '{"query":"query { server(_id: \"server-6a23cdf424701a8493345c17\") { _id name status ipAddress region lastSeen sshTunnel tailscaleInfo } }"}'
