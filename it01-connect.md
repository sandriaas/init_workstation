# `it01` Connect Commands

Current public hostname: `6geczk4.easyrentbali.com`

Use these commands when you want the SSH config written from a file block instead of a long one-liner.

## Android Termux

Install the client tools:

```bash
pkg update -y
pkg install -y openssh websocat
```

Write the SSH config block:

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
sed -i '/# BEGIN it01 host/,/# END it01 host/d' ~/.ssh/config 2>/dev/null || true
cat >> ~/.ssh/config <<'EOF'
# BEGIN it01 host
Host it01
    HostName 6geczk4.easyrentbali.com
    User it01
    ProxyCommand websocat -E --binary - wss://%h
# END it01 host
EOF
chmod 600 ~/.ssh/config
```

Connect:

```bash
ssh it01
```

## Another Linux or macOS Computer

If this repo exists on that machine, use the helper script:

```bash
bash scripts/it01-client.sh --host 6geczk4.easyrentbali.com
ssh it01
```

If you want the manual file-based setup instead:

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
sed -i.bak '/# BEGIN it01 host/,/# END it01 host/d' ~/.ssh/config 2>/dev/null || true
cat >> ~/.ssh/config <<'EOF'
# BEGIN it01 host
Host it01
    HostName 6geczk4.easyrentbali.com
    User it01
    ProxyCommand websocat -E --binary - wss://%h
# END it01 host
EOF
chmod 600 ~/.ssh/config
```

Install `websocat` if needed:

```bash
# Arch
sudo pacman -S --needed websocat

# Ubuntu/Debian
curl -fsSL https://github.com/vi/websocat/releases/latest/download/websocat.x86_64-unknown-linux-musl -o /tmp/websocat
sudo install -m 0755 /tmp/websocat /usr/local/bin/websocat

# macOS
brew install websocat
```

Then connect:

```bash
ssh it01
```
