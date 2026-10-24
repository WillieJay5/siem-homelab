<#
.SYNOPSIS
    Enrolls Elastic Agent into Fleet and installs Sysmon (sysmon-modular config). Run elevated on the endpoint.
.EXAMPLE
    .\Install-LabAgent.ps1 -FleetUrl https://elk01.example.lan:8220 -EnrollmentToken <token> -CaCert C:\Temp\ca.crt
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FleetUrl,
    [Parameter(Mandatory)][string]$EnrollmentToken,
    [Parameter(Mandatory)][ValidateScript({ Test-Path $_ })][string]$CaCert,
    [string]$AgentVersion = '9.5.5',  # must match the stack version on elk01
    [string]$SysmonConfigRelease = 'configs-a45dedb13a43'  # sysmon-modular release tag; bump deliberately
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest is very slow with the progress bar on
$work = Join-Path $env:TEMP 'lab-agent'
New-Item -ItemType Directory -Force $work | Out-Null

# --- Elastic Agent ---
# Runs before Sysmon so the install command line (with the enrollment token) never lands in Sysmon Event 1.
if (Get-Service 'Elastic Agent' -ErrorAction SilentlyContinue) {
    Write-Host 'Elastic Agent already installed; skipping enrollment (run "elastic-agent uninstall" first to re-enroll).'
} else {
    # The agent stores the CA's path, not its contents. Program Files is admin-write only, so a standard
    # user can't pre-create the folder (as they could in ProgramData) and later swap in their own CA.
    $ca = "$env:ProgramFiles\LabCA\ca.crt"
    New-Item -ItemType Directory -Force (Split-Path $ca) | Out-Null
    Copy-Item $CaCert $ca -Force

    $name = "elastic-agent-$AgentVersion-windows-x86_64"
    $base = "https://artifacts.elastic.co/downloads/beats/elastic-agent/$name.zip"
    Invoke-WebRequest $base -OutFile "$work\$name.zip"
    Invoke-WebRequest "$base.sha512" -OutFile "$work\$name.zip.sha512"
    $expected = (Get-Content "$work\$name.zip.sha512" -Raw).Split(' ')[0]
    if ((Get-FileHash "$work\$name.zip" -Algorithm SHA512).Hash -ne $expected) { throw "SHA-512 mismatch for $name.zip" }
    Expand-Archive "$work\$name.zip" $work -Force

    & "$work\$name\elastic-agent.exe" install --non-interactive `
        --url $FleetUrl --enrollment-token $EnrollmentToken --certificate-authorities $ca
    if ($LASTEXITCODE -ne 0) { throw "elastic-agent install exited with $LASTEXITCODE" }
}

# --- Sysmon ---
Invoke-WebRequest https://download.sysinternals.com/files/Sysmon.zip -OutFile "$work\Sysmon.zip"
Expand-Archive "$work\Sysmon.zip" "$work\sysmon" -Force
$sysmon = "$work\sysmon\Sysmon64.exe"
$sig = Get-AuthenticodeSignature $sysmon
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    throw "Sysmon64.exe signature check failed: $($sig.Status) $($sig.SignerCertificate.Subject)"
}

# sysmon-modular publishes built configs as release assets (balanced profile, for Sysmon 15.x) with a SHA256SUMS manifest.
$rel = "https://github.com/olafhartong/sysmon-modular/releases/download/$SysmonConfigRelease"
Invoke-WebRequest "$rel/sysmonconfig.xml" -OutFile "$work\sysmonconfig.xml"
Invoke-WebRequest "$rel/SHA256SUMS" -OutFile "$work\SHA256SUMS"
$line = Get-Content "$work\SHA256SUMS" | Where-Object { $_ -match '\s\*?sysmonconfig\.xml$' }
if (-not $line -or (Get-FileHash "$work\sysmonconfig.xml").Hash -ne ($line -split '\s+')[0]) { throw 'SHA-256 mismatch for sysmonconfig.xml' }

if (Get-Service Sysmon64 -ErrorAction SilentlyContinue) {
    & $sysmon -c "$work\sysmonconfig.xml"            # already installed: update the config only
} else {
    & $sysmon -accepteula -i "$work\sysmonconfig.xml"
}
if ($LASTEXITCODE -ne 0) { throw "Sysmon exited with $LASTEXITCODE" }
Write-Host 'Done. Check Fleet -> Agents in Kibana.'
$duckScript = Join-Path $work 'duck.cmd'

@'
@echo off
title YOU'VE BEEN QUACKED!
color 0E
cls
echo.
echo           __
echo       ___( o)^>
echo       \      /
echo        \____/
echo         /  \
echo.
echo     QUACK QUACK!
echo.
echo   YOU'VE BEEN QUACKED!
echo.
pause
'@ | Set-Content -Path $duckScript -Encoding ASCII

if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
    Start-Process wt.exe -ArgumentList "-f -- cmd.exe /k `"`"$duckScript`"`""
} else {
    Start-Process cmd.exe -ArgumentList "/k `"`"$duckScript`"`"" -WindowStyle Maximized
}