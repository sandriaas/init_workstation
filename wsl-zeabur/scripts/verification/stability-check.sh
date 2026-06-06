echo "=== Watch Tailscale stability for 90 seconds ==="
START=$(date +%s)
STABLE=0
for i in $(seq 1 18); do
  IP=$(tailscale ip -4 2>&1 | head -1)
  TS=$(date +%H:%M:%S)
  if [[ "$IP" =~ ^100\.64\.3\.1$ ]]; then
    STABLE=$((STABLE + 1))
    STATUS="STABLE"
  else
    STATUS="FLAP ($IP)"
  fi
  echo "[$TS] $STATUS (stable_count=$STABLE)"
  sleep 5
done
echo ""
echo "Total stable iterations: $STABLE / 18"
echo ""
echo "=== Check Wonder Mesh tunnel ==="
sudo tailscale ping 100.64.0.1 -c 2 2>&1 | tail -5
echo ""
echo "=== SSH from mesh IP ==="
ssh -o ConnectTimeout=5 -o BatchMode=yes zeabur@100.64.3.1 'hostname; uptime' 2>&1 | head -5
echo ""
echo "=== Zeabur API check now ==="
curl -s -X POST https://api.zeabur.com/graphql \
  -H "Authorization: Bearer sk-zhw6hjoambkyva6hudyt3twsijjmz" \
  -H "Content-Type: application/json" \
  -d '{"query":"query { server(_id: \"server-6a23cdf424701a8493345c17\") { _id name } }"}'
