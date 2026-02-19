# =============================================================================
# phase3-client.ps1 — Rev5.7.2 Phase 3: VM Client Setup (Windows)
# Run this on any Windows machine to connect to the KVM VM via Cloudflare tunnel
# Usage: irm https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase3-client.ps1 | iex
# =============================================================================

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Info  { Write-Host "[INFO] $args" -ForegroundColor Cyan }
function Ok    { Write-Host "[OK]   $args" -ForegroundColor Green }
function Warn  { Write-Host "[WARN] $args" -ForegroundColor Yellow }
function Ask   { Write-Host "[?]    $args" -ForegroundColor Yellow -NoNewline }

# ─── Install Scoop ────────────────────────────────────────────────────────────
function Install-Scoop {
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        Ok "Scoop already installed"; return
    }
    Info "Installing Scoop..."
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    irm get.scoop.sh | iex
    Ok "Scoop installed"
}

# ─── Install websocat ─────────────────────────────────────────────────────────
function Install-Websocat {
    if (Get-Command websocat -ErrorAction SilentlyContinue) {
        Ok "websocat already installed"; return
    }
    Info "Installing websocat from GitHub releases..."
    $binDir = "$env:USERPROFILE\bin"
    if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir | Out-Null }
    $dest = "$binDir\websocat.exe"
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/vi/websocat/releases/latest" -UseBasicParsing
    $asset   = $release.assets | Where-Object { $_.name -like "websocat.x86_64*windows*.exe" } | Select-Object -First 1
    if (-not $asset) { $asset = $release.assets | Where-Object { $_.name -like "*windows*.exe" } | Select-Object -First 1 }
    $url = $asset.browser_download_url
    Info "Downloading websocat from $url ..."
    (New-Object System.Net.WebClient).DownloadFile($url, $dest)
    $userPath = [System.Environment]::GetEnvironmentVariable("PATH","User")
    if ($userPath -notlike "*$binDir*") {
        [System.Environment]::SetEnvironmentVariable("PATH", "$userPath;$binDir", "User")
    }
    $env:PATH += ";$binDir"
    if (-not (Test-Path $dest)) { Warn "websocat download failed"; exit 1 }
    Ok "websocat installed to $dest"
}

# ─── Install OpenSSH client ───────────────────────────────────────────────────
function Install-OpenSSH {
    if (Get-Command ssh -ErrorAction SilentlyContinue) {
        Ok "ssh already installed"; return
    }
    Info "Installing OpenSSH client..."
    $feature = Get-WindowsCapability -Online -Name "OpenSSH.Client*" -ErrorAction SilentlyContinue
    if ($feature -and $feature.State -ne "Installed") {
        Add-WindowsCapability -Online -Name "OpenSSH.Client~~~~0.0.1.0" | Out-Null
        Ok "OpenSSH client installed via Windows feature"
    } else {
        winget install --id Microsoft.OpenSSH.Beta -e --source winget
        Ok "OpenSSH client installed via winget"
    }
}

# ─── Write ~/.ssh/config ──────────────────────────────────────────────────────
function Setup-SshConfig {
    $sshDir    = "$env:USERPROFILE\.ssh"
    $sshConfig = "$sshDir\config"
    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }

    Write-Host ""
    Info "You need the VM tunnel hostname from the phase3 summary."
    Ask "VM tunnel hostname (e.g. vm-abc123.yourdomain.com): "
    $script:VmTunnelHost = Read-Host
    Ask "VM SSH username (e.g. sandriaas): "
    $script:VmUser = Read-Host

    # Derive short alias from hostname prefix
    $script:VmAlias = $script:VmTunnelHost.Split('.')[0]
    Ask "SSH alias to use (press Enter for '$($script:VmAlias)'): "
    $aliasInput = Read-Host
    if ($aliasInput -ne "") { $script:VmAlias = $aliasInput }

    if ((Test-Path $sshConfig) -and (Select-String -Path $sshConfig -Pattern "Host $($script:VmAlias)$" -Quiet)) {
        Ok "~\.ssh\config already has 'Host $($script:VmAlias)'. Skipping."
        return
    }

    $ws = Get-Command websocat -ErrorAction SilentlyContinue
    $websocat = if ($ws) { $ws.Source } else { "$env:USERPROFILE\bin\websocat.exe" }

    $entry = @"

# KVM VM via Cloudflare Tunnel (phase3-client)
Host $($script:VmAlias)
  HostName $($script:VmTunnelHost)
  ProxyCommand "$websocat" -E --binary - wss://%h
  User $($script:VmUser)
"@
    Add-Content -Path $sshConfig -Value $entry
    Ok "Written to ~\.ssh\config — alias: $($script:VmAlias)"
}

# ─── Test connection ──────────────────────────────────────────────────────────
function Test-VmConnection {
    Info "Testing SSH via Cloudflare tunnel ($($script:VmAlias))..."
    try {
        $result = & ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 `
                        -o BatchMode=yes $script:VmAlias true 2>&1
        Ok "Connection test passed!"
    } catch {
        Warn "Connection test failed — tunnel may still be propagating DNS (try again in 1-2 min)"
        Warn "Manual: ssh -o `"ProxyCommand=$($script:websocat) -E --binary - wss://%%h`" $($script:VmUser)@$($script:VmTunnelHost)"
    }
}

# =============================================================================
# MAIN
# =============================================================================
Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Rev5.7.2 — Phase 3 Client Setup (Windows) ║" -ForegroundColor Cyan
Write-Host "║   VM access via Cloudflare tunnel            ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

Install-Scoop
Install-OpenSSH
Install-Websocat
Setup-SshConfig
Test-VmConnection

Write-Host ""
Write-Host "╔════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║   Done! Connect to VM with:                    ║" -ForegroundColor Green
Write-Host "║                                                ║" -ForegroundColor Green
Write-Host "║   ssh $($script:VmAlias)                       ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Full tunnel command (no config needed):" -ForegroundColor Gray
Write-Host "  ssh -o `"ProxyCommand=websocat -E --binary - wss://%%h`" $($script:VmUser)@$($script:VmTunnelHost)" -ForegroundColor Gray
Write-Host ""
