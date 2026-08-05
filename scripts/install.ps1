#Requires -Version 5.1
<#
.SYNOPSIS
    Windows front door for the /revue Claude Code skill (REVUE-561).

.DESCRIPTION
    Revue publishes per-OS Nuitka-compiled wheels for macOS ARM64 and Linux
    x86_64 only. There is NO native Windows wheel, so this script does not
    install anything on Windows itself — it routes you into WSL2, where your
    machine reports "linux x86_64" and the real Linux x86_64 build installs and
    runs natively.

    It deliberately does NOT run 'wsl --install' for you: that enables Windows
    features and usually forces a reboot, which is your decision, not ours.

.PARAMETER Key
    Your Revue licence key. Passed through to install.sh --key. If omitted, the
    install is keyless and you can run 'revue activate <key>' later.

.EXAMPLE
    # Keyless install
    irm https://raw.githubusercontent.com/Revue-sh/revue/main/scripts/install.ps1 | iex

.EXAMPLE
    # With a licence key. `iex` cannot forward arguments, so wrap the fetched
    # text in a scriptblock — this is the standard PowerShell one-liner idiom.
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Revue-sh/revue/main/scripts/install.ps1))) -Key lic_your_key_here
#>
[CmdletBinding()]
param(
    [string]$Key = $env:REVUE_LICENSE_KEY,

    # REVUE-567: consent to run `wsl --install` without prompting. Interactive
    # runs are asked instead. It is never silent, because it needs admin rights
    # and forces a reboot — see Install-Wsl2.
    [switch]$InstallWsl
)

$ErrorActionPreference = 'Stop'

$InstallShUrl = 'https://raw.githubusercontent.com/cbscd/revue-installer-preview/main/scripts/install.sh'
$InstallPageUrl = 'https://github.com/Revue-sh/revue/blob/main/docs/guides/install.md'

# Mirrors revue_core.platform_support.WSL2_GUIDANCE verbatim; pinned by
# tests/test_supported_platforms_consistency.py so it cannot drift from the
# policy module or from the message scripts/install.sh prints under Git Bash.
$Wsl2Guidance = "On Windows x86_64, install WSL2 with 'wsl --install', then re-run this installer inside your WSL2 shell: it reports linux x86_64, so Revue's Linux x86_64 build installs and runs there natively"

function Write-Err ([string]$m) { Write-Host "error: $m" -ForegroundColor Red }
function Write-Ok  ([string]$m) { Write-Host "* $m"      -ForegroundColor Green }

function Write-CiFallback {
    Write-Host ""
    Write-Host "Alternative: run Revue in your CI pipeline via the revue-ci integration"
    Write-Host "(github/gitlab/bitbucket) instead. See $InstallPageUrl"
}

# `wsl --install` enables Windows features, so it needs an elevated shell.
# Detecting that ourselves turns an obscure inner failure into a clear
# instruction (REVUE-567 AC4).
function Test-Administrator {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        # Non-Windows pwsh has no such identity model. The caller already
        # refused non-Windows before reaching here; treat unknown as "not
        # elevated" so we never attempt a privileged operation on a guess.
        return $false
    }
}

# Install WSL2 on the user's behalf — with consent, never silently.
#
# This CANNOT be seamless, and pretending otherwise would mislead:
#   * it needs administrator rights;
#   * it enables Windows features and forces a REBOOT;
#   * after that reboot the Revue install is still not done — the user must
#     run this installer again.
# So the honest contract is: ask, run it, then say plainly what happens next
# and exit non-zero, because the install did NOT complete.
function Install-Wsl2 {
    if (-not (Test-Administrator)) {
        Write-Err "Installing WSL2 requires administrator rights, and this shell is not elevated."
        Write-Host "Close this window, open PowerShell as Administrator (right-click > 'Run as administrator'),"
        Write-Host "and run this installer again. Or install WSL2 yourself with:"
        Write-Host "  wsl --install"
        Write-CiFallback
        exit 1
    }

    Write-Host "Installing WSL2 (this enables Windows features and will require a reboot)…"
    & wsl.exe --install
    $wslExit = $LASTEXITCODE
    if ($wslExit -ne 0) {
        Write-Err "'wsl --install' failed (exit code $wslExit)."
        Write-Host "Install WSL2 manually, then re-run this installer:"
        Write-Host "  wsl --install"
        Write-CiFallback
        exit $wslExit
    }

    # Deliberately non-zero: WSL2 is installed, Revue is not.
    Write-Host ""
    Write-Ok "WSL2 installed."
    Write-Host "Reboot this machine, then re-run this installer to finish installing Revue."
    exit 1
}

# PowerShell 5.1 (Desktop edition) leaves $IsWindows undefined, and Desktop only
# ever runs on Windows — so an undefined value means Windows, not "unknown".
function Test-OnWindows {
    if ($null -ne $IsWindows) { return [bool]$IsWindows }
    return $true
}

# Returns the name of the first WSL *version 2* distro, or $null.
#
# `wsl.exe -l -v` historically emits UTF-16LE, which surfaces in PowerShell as
# text with interleaved NULs; WSL_UTF8 fixes it on current builds and the NUL
# strip keeps older ones working.
function Get-Wsl2DistroName {
    $previous = $env:WSL_UTF8
    $env:WSL_UTF8 = '1'
    try {
        $raw = & wsl.exe -l -v 2>&1
        if ($LASTEXITCODE -ne 0) { return $null }
    } catch {
        return $null
    } finally {
        $env:WSL_UTF8 = $previous
    }

    foreach ($line in ($raw -split "`r?`n")) {
        $clean = ($line -replace "`0", '').Trim()
        if (-not $clean) { continue }
        # "* Ubuntu    Running    2" — default distro carries a leading asterisk.
        if ($clean -match '^\*?\s*(?<name>\S+)\s+\S+\s+(?<version>\d+)\s*$') {
            if ($Matches['version'] -eq '2') { return $Matches['name'] }
        }
    }
    return $null
}

# ── Guard: this script is Windows-only ───────────────────────────────────────
if (-not (Test-OnWindows)) {
    Write-Err "install.ps1 is the Windows entry point, but this is not Windows."
    Write-Host "Use the shell installer instead:"
    Write-Host "  curl -fsSL $InstallShUrl | bash"
    exit 1
}

# ── Guard: Windows on ARM has no route, not even through WSL2 ────────────────
# WSL2 on an ARM host reports linux aarch64, and Revue publishes no aarch64
# wheel — so sending an ARM user through WSL2 would strand them one step later.
$arch = $env:PROCESSOR_ARCHITECTURE
if (-not $arch) { $arch = '' }
if ($arch -match 'ARM64') {
    Write-Err "Revue does not publish a wheel for Windows on ARM64."
    Write-Host "WSL2 on an ARM64 host reports linux aarch64, which Revue does not publish,"
    Write-Host "so WSL2 will not help here."
    Write-CiFallback
    exit 1
}

Write-Host "Revue has no native Windows build. Installing through WSL2, where the"
Write-Host "Linux x86_64 build runs natively."
Write-Host ""

# ── Guard: WSL must be present ───────────────────────────────────────────────
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Write-Err "WSL is not available on this machine."
    Write-Host $Wsl2Guidance
    Write-Host ""

    # REVUE-567: offer to do it rather than hand the user homework. Consent is
    # required — explicit via -InstallWsl, or asked here. Never silent.
    if ($InstallWsl) {
        Install-Wsl2
    }

    # Read-Host needs a console. Under `irm | iex` there is one; under full
    # automation there may not be, so a failed read is treated as "no" rather
    # than as consent.
    $answer = ""
    try {
        $answer = Read-Host "Install WSL2 now? This needs admin rights and will require a reboot [y/N]"
    } catch {
        $answer = ""
    }
    if ($answer -match '^(y|yes)$') {
        Install-Wsl2
    }

    Write-Host "Run this in an elevated PowerShell, reboot if prompted, then re-run this installer:"
    Write-Host "  wsl --install"
    Write-Host "(or re-run this installer with -InstallWsl to have it done for you)"
    Write-CiFallback
    exit 1
}

# ── Guard: a version-2 distro must exist ─────────────────────────────────────
# WSL1 does not provide the Linux kernel ABI the compiled wheel targets.
$distro = Get-Wsl2DistroName
if (-not $distro) {
    Write-Err "No WSL version 2 distribution was found."
    Write-Host $Wsl2Guidance
    Write-Host ""
    Write-Host "If WSL is installed but you have no distro yet:"
    Write-Host "  wsl --install -d Ubuntu"
    Write-Host "If your distro is still on version 1, upgrade it:"
    Write-Host "  wsl --set-version <distro> 2"
    Write-CiFallback
    exit 1
}

Write-Ok "Using WSL2 distribution: $distro"

# ── Bootstrap the canonical installer inside WSL2 ────────────────────────────
# install.sh stays the single implementation — this script is a router, not a
# second installer. The key is passed as a bash positional so it is never
# interpolated into the command string.
if ($Key) {
    $bashCommand = 'curl -fsSL "$0" | bash -s -- --key "$1"'
    $wslArgs = @('-d', $distro, '--', 'bash', '-c', $bashCommand, $InstallShUrl, $Key)
} else {
    $bashCommand = 'curl -fsSL "$0" | bash'
    $wslArgs = @('-d', $distro, '--', 'bash', '-c', $bashCommand, $InstallShUrl)
}

& wsl.exe @wslArgs
$innerExit = $LASTEXITCODE

# Never report success the inner installer did not earn.
if ($innerExit -ne 0) {
    Write-Host ""
    Write-Err "The Revue installer failed inside WSL2 (exit code $innerExit)."
    Write-Host "Re-run it directly in your WSL2 shell to see the full output:"
    Write-Host "  curl -fsSL $InstallShUrl | bash"
    exit $innerExit
}

Write-Host ""
Write-Ok "Revue installed inside WSL2 ($distro)."
Write-Host "Run Claude Code from your WSL2 shell so it picks up the /revue skill."
exit 0
