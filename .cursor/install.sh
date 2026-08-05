#!/usr/bin/env bash
# Idempotent Cloud Agent bootstrap for the ves-verify PowerShell suite.
#
# The scripts target Windows PowerShell 5.1, but a Linux Cloud Agent can still
# edit, lint, and exercise the core capture/verify logic under PowerShell 7
# (pwsh) plus Pester 5.x. Windows-only integration tests (which spawn
# powershell.exe and use robocopy / CIM) still require a real Windows host.
set -euo pipefail

# --- PowerShell 7 (pwsh) ------------------------------------------------------
if ! command -v pwsh >/dev/null 2>&1; then
    echo "Installing PowerShell 7..."
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -qq
    sudo apt-get install -y -qq wget apt-transport-https software-properties-common ca-certificates
    # shellcheck disable=SC1091
    . /etc/os-release
    tmpdeb="$(mktemp --suffix=.deb)"
    wget -q "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" -O "$tmpdeb"
    sudo dpkg -i "$tmpdeb"
    rm -f "$tmpdeb"
    sudo apt-get update -qq
    sudo apt-get install -y -qq powershell
fi
pwsh --version

# --- Pester 5.x ---------------------------------------------------------------
# Invoke-Tests.ps1 needs Pester >= 5.5.0. Pin 5.7.1 to match the repo's 5.x
# target rather than pulling the newer 6.x line.
pwsh -NoProfile -Command '
    $ErrorActionPreference = "Stop"
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    $have = Get-Module -ListAvailable Pester |
        Where-Object { $_.Version -ge [version]"5.5.0" -and $_.Version -lt [version]"6.0.0" }
    if (-not $have) {
        Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
    }
    $v = (Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1).Version
    Write-Host "Pester $v"
'

echo "ves-verify environment ready."
