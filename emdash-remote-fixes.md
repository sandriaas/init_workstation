# Emdash Remote Development Fixes

## Problem Summary
Running Emdash on laptop, connecting to this machine (remote server) via SSH for remote development. Issues: agents not showing, connection drops, ForwardAgent confusion.

---

## Verified State (This Machine = Remote Server)

### Agents Installed ✓
| Agent | Path |
|-------|------|
| opencode | `/home/sandriaas/.opencode/bin/opencode` |
| claude | `/home/sandriaas/.local/bin/claude` |
| codex | `/usr/bin/codex` |
| cursor | ❌ Not installed |
| gemini | ❌ Not installed |

### SSH Config ✓
```bash
# /etc/ssh/sshd_config
MaxSessions 500
# MaxStartups 10:30:100 (default, fine)
```
No session limit bottleneck.

### PATH Verified ✓
Both login and non-login shells include agent paths:
```bash
PATH includes:
  /home/sandriaas/.opencode/bin
  /home/sandriaas/.local/bin
  /usr/bin
  /home/sandriaas/.npm-global/bin
```

---

## Fixes Applied / Verified

### 1. Agents Not Showing in Emdash
**Cause:** Emdash scans remote host for agents on connect. Agents must be installed **on remote**, not laptop.

**Fix:** Already installed. If still not showing:
- Disconnect/reconnect SSH project in Emdash
- Restart Emdash completely
- Toggle "tmux sessions" off/on in Project Settings
- Remove and re-add remote project

**Verify from laptop:**
```bash
ssh myserver 'which opencode claude codex; echo "PATH=$PATH"'
```

---

### 2. Connection Drops / "SSH Channel Unavailable"
**Cause:** SSH `MaxSessions` too low for concurrent terminals + agents + SFTP + Git.

**Fix:** Already set to `MaxSessions 500` on remote. If issues persist:
```bash
# On remote, check current:
grep MaxSessions /etc/ssh/sshd_config

# If needed, increase:
echo "MaxSessions 500" | sudo tee -a /etc/ssh/sshd_config
echo "MaxStartups 50:30:100" | sudo tee -a /etc/ssh/sshd_config
sudo systemctl reload sshd
```

---

### 3. ForwardAgent Setting (Cannot Enable / Confusion)

**What it does:** Forwards **laptop's SSH agent** (with your local keys) to remote. Needed only when remote must use *your* keys (Git push to GitHub, nested SSH).

**When you CAN'T enable:**
- No SSH agent running on laptop → `eval $(ssh-agent) && ssh-add`
- Using password auth instead of key auth
- SSH config has `ForwardAgent no` or `IdentityAgent none`
- Emdash process lacks `SSH_AUTH_SOCK` env var

**When you DON'T need it:**
- Using Emdash's built-in GitHub token (it rewrites SSH→HTTPS for Git)
- Remote doesn't need your local keys

**To enable in Emdash:**
1. **Manual connection:** Toggle "ForwardAgent" in form
2. **SSH config alias:** Add `ForwardAgent yes` to `~/.ssh/config` on laptop, re-select alias

**Test from laptop:**
```bash
ssh -A myserver 'ssh-add -l'  # Should show YOUR laptop's keys
```

---

### 4. Recommended Remote Setup (Complete)

```bash
# On remote (this machine):
sudo apt-get update && sudo apt-get install -y git tmux openssh-server

# Agents (already done):
# opencode: curl -fsSL https://opencode.ai/install | bash
# claude: npm install -g @anthropic-ai/claude-code
# codex: npm install -g @openai/codex
# cursor: curl https://cursor.sh/install.sh | bash
# gemini: npm install -g @google/gemini-cli

# SSH limits (already done):
echo "MaxSessions 500" | sudo tee -a /etc/ssh/sshd_config
echo "MaxStartups 50:30:100" | sudo tee -a /etc/ssh/sshd_config
sudo systemctl reload sshd

# PATH persistence (if needed):
echo 'export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"' >> ~/.bashrc
echo 'export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"' >> ~/.zshrc
```

---

### 5. Laptop SSH Config (Recommended)

```ssh
# ~/.ssh/config on laptop
Host minipc
  HostName <remote-ip-or-hostname>
  User sandriaas
  IdentityFile ~/.ssh/id_ed25519
  ForwardAgent yes
  # ProxyJump bastion  # if needed
```

Then in Emdash: select `minipc` from SSH Config dropdown.

---

## Troubleshooting Checklist

If agents still not detected:
- [ ] Restart Emdash completely
- [ ] Reconnect SSH project (disconnect → connect)
- [ ] Run `ssh minipc 'which opencode claude codex'` from laptop — verify output
- [ ] Check Emdash logs for SSH connection errors
- [ ] Verify remote shell is bash/zsh (not minimal sh)

If connection unstable:
- [ ] Check `ssh -v minipc` for disconnect reasons
- [ ] Verify `MaxSessions` applied: `ssh minipc 'grep MaxSessions /etc/ssh/sshd_config'`
- [ ] Ensure tmux installed on remote: `ssh minipc 'which tmux'`

---

## Key Links
- [Remote Projects](https://emdash.sh/docs/remote-development/remote-projects)
- [SSH Connections](https://emdash.sh/docs/remote-development/ssh-connections)
- [Remote Tasks](https://emdash.sh/docs/remote-development/remote-tasks)