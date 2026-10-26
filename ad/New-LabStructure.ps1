<#
.SYNOPSIS
    Creates the lab's OU layout, tiered admin accounts and workstation-join delegation. Run elevated on dc01 as a
    Domain Admin, after promotion. Safe to rerun: existing OUs, groups and users are left alone.
.EXAMPLE
    .\New-LabStructure.ps1 -UserName gage
    # creates gage (daily), adm-t2-gage (workstation admin), adm-t0-gage (Domain Admin); prompts for each password
#>
[CmdletBinding()]
param(
    # Your name, not the account running the script. sAMAccountName max is 20 characters, and adm-t0- takes 7.
    # (?-i): ValidatePattern ignores case by default, which let 'Administrator' through.
    [Parameter(Mandatory)][ValidatePattern('(?-i)^[a-z0-9.]{1,13}$')][ValidateScript({ $_ -ne 'administrator' })][string]$UserName
)
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory
$domain = Get-ADDomain

function New-LabOU([string]$Name, [string]$Path) {
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$Name'" -SearchBase $Path -SearchScope OneLevel)) {
        New-ADOrganizationalUnit -Name $Name -Path $Path  # protected from accidental deletion by default
    }
    "OU=$Name,$Path"
}

function New-LabUser([string]$Sam, [string]$Path, [string[]]$MemberOf = @()) {
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$Sam'")) {
        New-ADUser -Name $Sam -SamAccountName $Sam -UserPrincipalName "$Sam@$($domain.DNSRoot)" -Path $Path -Enabled $true `
            -AccountPassword (Read-Host "Password for $Sam" -AsSecureString)
    } else {
        Write-Warning "$Sam already exists; left as is."
    }
    foreach ($g in $MemberOf) { Add-ADGroupMember $g -Members $Sam }  # no-op if already a member
}

# --- OUs ---
# No Tier 1 yet: the only member servers (elk01, n8n01) are Linux. Add Tier1 when a Windows member server shows up.
$lab = New-LabOU 'Lab' $domain.DistinguishedName
$t0 = New-LabOU 'Tier0' $lab
$t2 = New-LabOU 'Tier2' $lab
$t0Accounts = New-LabOU 'Accounts' $t0
$t2Accounts = New-LabOU 'Accounts' $t2
$t2Groups = New-LabOU 'Groups' $t2
$workstations = New-LabOU 'Workstations' $lab
$users = New-LabOU 'Users' $lab

# --- Groups ---
# Made a local admin on workstations by the "Lab - Workstation Tiering" GPO.
if (-not (Get-ADGroup -Filter "Name -eq 'T2-Workstation-Admins'")) {
    New-ADGroup -Name 'T2-Workstation-Admins' -GroupScope Global -GroupCategory Security -Path $t2Groups
}

# --- Accounts: daily user, workstation admin, domain admin ---
New-LabUser $UserName $users
New-LabUser "adm-t2-$UserName" $t2Accounts @('T2-Workstation-Admins')
# Protected Users: Kerberos only (no NTLM, no cached creds), 4-hour TGTs, never delegated.
New-LabUser "adm-t0-$UserName" $t0Accounts @('Domain Admins', 'Protected Users')
Set-ADUser "adm-t2-$UserName" -AccountNotDelegated $true
Set-ADUser "adm-t0-$UserName" -AccountNotDelegated $true

# --- Computer joins ---
# Default is 10 per user, which lets any account create computer objects (the start of RBCD attacks).
Set-ADDomain $domain -Replace @{ 'ms-DS-MachineAccountQuota' = 0 }
# Joins land in Workstations (where the GPOs are linked), and only T2 admins can create them there.
redircmp.exe $workstations
if ($LASTEXITCODE -ne 0) { throw "redircmp exited with $LASTEXITCODE" }
dsacls.exe $workstations /G "$($domain.NetBIOSName)\T2-Workstation-Admins:CCDC;computer" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "dsacls exited with $LASTEXITCODE" }

Write-Host "Done. Join workstations with $($domain.NetBIOSName)\adm-t2-$UserName."
