# =============================================================================
# phase1-client.ps1 — Rev5.7.2 Phase 1: Client Setup (Windows)
# Run this on any Windows machine you want to SSH from
# Installs: Scoop · winget · websocat · OpenSSH client · writes ~/.ssh/config
# =============================================================================
# Run with:
#   irm https://raw.githubusercontent.com/sandriaas/init_workstation/main/scripts/phase1-client.ps1 | iex
# =============================================================================

$ErrorActionPreference = "Stop"

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

# ─── Install winget ───────────────────────────────────────────────────────────
function Install-Winget {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Ok "winget already installed"; return
    }
    Info "Installing winget (App Installer)..."
    $url = "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
    $out = "$env:TEMP\AppInstaller.msixbundle"
    Invoke-WebRequest -Uri $url -OutFile $out
    Add-AppxPackage -Path $out
    Ok "winget installed"
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
    $url  = "https://github.com/vi/websocat/releases/latest/download/websocat.x86_64-pc-windows-msvc.exe"
    Invoke-WebRequest -Uri $url -OutFile $dest
    # Add ~/bin to user PATH if not already there
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
    # Try Windows optional feature first (works without winget)
    $feature = Get-WindowsCapability -Online -Name "OpenSSH.Client*" -ErrorAction SilentlyContinue
    if ($feature -and $feature.State -ne "Installed") {
        Add-WindowsCapability -Online -Name "OpenSSH.Client~~~~0.0.1.0" | Out-Null
        Ok "OpenSSH client installed via Windows feature"
    } else {
        # Fallback: winget
        winget install --id Microsoft.OpenSSH.Beta -e --source winget
        Ok "OpenSSH client installed via winget"
    }
}

# ─── Write ~/.ssh/config ──────────────────────────────────────────────────────
function Setup-SshConfig {
    $sshDir    = "$env:USERPROFILE\.ssh"
    $sshConfig = "$sshDir\config"
    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }

    Ask "Tunnel hostname (e.g. abc123.yourdomain.com): "
    $tunnelHost = Read-Host
    Ask "Server username (e.g. sandriaas): "
    $serverUser = Read-Host

    if ((Test-Path $sshConfig) -and (Select-String -Path $sshConfig -Pattern $tunnelHost -Quiet)) {
        Ok "~\.ssh\config already has entry for $tunnelHost. Skipping."; return
    }

    # Resolve full path to websocat.exe for ProxyCommand
    $ws = Get-Command websocat -ErrorAction SilentlyContinue
    $websocat = if ($ws) { $ws.Source } else { "$env:USERPROFILE\bin\websocat.exe" }

    $entry = @"

# MiniPC via Cloudflare Tunnel
Host minipc
  HostName $tunnelHost
  ProxyCommand "$websocat" -E --binary - wss://%h
  User $serverUser
"@
    Add-Content -Path $sshConfig -Value $entry
    Ok "Written to ~\.ssh\config"
}

# =============================================================================
# MAIN
# =============================================================================
Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Rev5.7.2 — Phase 1 Client Setup (Windows) ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

Install-Scoop
Install-Winget
Install-OpenSSH
Install-Websocat
Setup-SshConfig

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║   Done! Connect with:                        ║" -ForegroundColor Green
Write-Host "║                                              ║" -ForegroundColor Green
Write-Host "║   ssh minipc                                 ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
