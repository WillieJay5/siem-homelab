# ad

AD DS / AD CS build notes for `DC-01`, the structure script, and GPO backups (`gpo/`).

Placeholders: `ad.example.com` (forest, a subdomain of a domain you own), `LAB` (NetBIOS), `192.168.20.11` (`DC-01`), `192.168.20.1` (OPNsense on the Servers VLAN). Swap in the real values; don't commit them.

## Design

| Decision | Why |
|---|---|
| Forest `ad.<owned domain>` | UPNs match the domain verified in the M365 tenant, so Entra Connect (Month 2) needs no UPN suffix changes |
| Server 2025 Core, 2 GB | No GUI to patch or attack, fits the RAM budget. Managed from the console and RSAT |
| AD CS on the DC | RAM, not best practice. Enterprise root CA, **no Web Enrollment** (ESC8 relay target) |
| Clients use `DC-01` for DNS; `DC-01` forwards to OPNsense | How AD clients find DCs (SRV records). Unbound then logs `DC-01` as the client for lab endpoints; Sysmon Event 22 and DC DNS logs keep per-host visibility |
| Time: OPNsense → `DC-01` → members | Kerberos fails past 5 minutes of skew, and log timestamps have to line up across sources |
| Tier 0 / Tier 2 accounts | `adm-t0-*` (Domain Admins, Protected Users) never log on to workstations; `adm-t2-*` admins workstations; daily work uses the plain account. No Tier 1 until a Windows member server exists |
| `MachineAccountQuota` = 0, joins delegated to `T2-Workstation-Admins` | Ordinary users can't create computer objects (RBCD attack path) |

## Build

### 1. VM (Proxmox)

Same pattern as the golden image: q35, OVMF + EFI disk, VirtIO SCSI single, VirtIO NIC on `vmbr0` tag **20** (Servers), 2 cores `host`, **2048 MB, ballooning off**, 40 GB disk. Attach the Server 2025 evaluation ISO and a current virtio-win ISO. Leave `vmgenid` on (default): it's what lets AD detect a snapshot revert.

Install **Windows Server 2025 Standard Evaluation** (the option *without* Desktop Experience), loading the VirtIO storage driver from the virtio-win ISO. Then install the virtio guest tools from that ISO.

### 2. Base config (`sconfig`)

- Hostname `DC-01`, static IP `192.168.20.11/24`, gateway and DNS `192.168.20.1` (DNS switches to itself at promotion).
- Time source: `w32tm /config /manualpeerlist:"192.168.20.1,0x8" /syncfromflags:manual /update`, restart `w32time`. Servers can only reach NTP on OPNsense, and a drifting clock breaks HTTPS and Windows Update.
- Install updates; reboot until none are left. Telemetry: Required. Remote Desktop: off.
- Exclude the IP from the Servers DHCP range in OPNsense.
- **Snapshot** (`pre-promotion`). After promotion, don't revert DC snapshots casually.

### 3. Promote

```powershell
Install-WindowsFeature AD-Domain-Services, GPMC -IncludeManagementTools
Install-ADDSForest -DomainName ad.example.com -DomainNetbiosName LAB -InstallDns  # prompts for the DSRM password
```

DSRM password into the password manager. Reboots on its own; log back in as `LAB\Administrator`.

```powershell
Set-DnsServerForwarder -IPAddress 192.168.20.1
w32tm /config /manualpeerlist:"192.168.20.1,0x8" /syncfromflags:manual /reliable:yes /update
Restart-Service w32time; w32tm /resync
Stop-Service Spooler; Set-Service Spooler -StartupType Disabled  # no printing on a DC; removes a coercion path
```

### 4. AD CS

Still as `LAB\Administrator` (an Enterprise CA needs Enterprise Admins):

```powershell
Install-WindowsFeature ADCS-Cert-Authority -IncludeManagementTools
Install-AdcsCertificationAuthority -CAType EnterpriseRootCA -CACommonName 'Lab Root CA' `
    -KeyLength 4096 -HashAlgorithmName SHA256 -ValidityPeriod Years -ValidityPeriodUnits 5 -Force
certutil -setreg CA\AuditFilter 127  # log every CA event; also needs the Certification Services subcategory below
Restart-Service certsvc
```

### 5. OUs and accounts

Copy [`New-LabStructure.ps1`](New-LabStructure.ps1) over and run it: `.\New-LabStructure.ps1 -UserName <you>`. Give the built-in `Administrator` a long random password, store it, and keep it as break-glass only.

Then prepare Windows LAPS (still as `LAB\Administrator`; the schema update needs Schema Admins). Every clone of the golden image shares one local admin password, so one stolen hash opens every workstation; LAPS gives each machine its own, rotated and stored in AD:

```powershell
Update-LapsADSchema
Set-LapsADComputerSelfPermission -Identity 'OU=Workstations,OU=Lab,DC=ad,DC=example,DC=com'  # lets each computer write its own password
```
### 6. Firewall (OPNsense, Endpoints interface)

Aliases: `DC_01` (host; alias names allow no hyphens), `AD_TCP` = `53 88 135 389 445 464 636 3268 3269 49152:65535`, `AD_UDP` = `53 88 123 389 464`.

| Seq | Action | Proto | Source | Destination | Port | Description |
|---|---|---|---|---|---|---|
| 267 | pass | TCP | Endpoints net | `DC_01` | `AD_TCP` | Allow Endpoints to DC (TCP) |
| 268 | pass | UDP | Endpoints net | `DC_01` | `AD_UDP` | Allow Endpoints to DC (UDP) |

They must sit above *Block Endpoints to Private Networks* (280). `DC-01` ↔ `elk01` is same-VLAN and never crosses the firewall; `DC-01`'s own DNS, NTP and HTTP(S) out are already allowed on Servers.

Then point Endpoints DHCP at the DC: DNS server `192.168.20.11`, domain/search `ad.example.com`.

### 7. Join `win11-01`

```powershell
ipconfig /renew
Resolve-DnsName _ldap._tcp.dc._msdcs.ad.example.com -Type SRV   # must return DC-01
Add-Computer -DomainName ad.example.com -Credential LAB\adm-t2-<you> -Restart
```

### 8. GPOs

On `win11-01`, log on with its **local** admin (`adm-t2-<you>` isn't a local admin until the tiering GPO below applies) and install RSAT (`Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0`, same for `Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0`). Open GPMC with the Tier 0 account **without** an interactive logon, so its credentials never get cached on the workstation:

```powershell
runas /netonly /user:LAB\adm-t0-<you> "mmc gpmc.msc"
```

**`Lab - Audit Policy`**, linked to the domain root (applies to `DC-01` and every member).

Computer Configuration → Policies → Windows Settings → Security Settings → **Advanced Audit Policy Configuration**:

| Category | Subcategory | Audit | Key events |
|---|---|---|---|
| Account Logon | Credential Validation | S/F | 4776 NTLM auth, spraying |
| Account Logon | Kerberos Authentication Service | S/F | 4768 TGTs, AS-REP roasting |
| Account Logon | Kerberos Service Ticket Operations | S/F | 4769 Kerberoasting |
| Account Management | Computer Account Management | S | 4741 computer created |
| Account Management | Security Group Management | S | 4728/4732/4756 group changes |
| Account Management | User Account Management | S/F | 4720 created, 4724 reset, 4738 changed |
| Detailed Tracking | Process Creation | S | 4688 |
| DS Access | Directory Service Access | S/F | 4662 (DCSync), needs SACLs |
| DS Access | Directory Service Changes | S | 5136 object/GPO/ACL changes |
| Logon/Logoff | Logon | S/F | 4624/4625 |
| Logon/Logoff | Logoff | S | 4634 |
| Logon/Logoff | Account Lockout | F | 4625 on locked accounts |
| Logon/Logoff | Special Logon | S | 4672 admin logons |
| Logon/Logoff | Other Logon/Logoff Events | S/F | 4778/4779 RDP |
| Logon/Logoff | Group Membership | S | 4627 |
| Object Access | Certification Services | S/F | 4886/4887 cert requests (AD CS abuse) |
| Object Access | Other Object Access Events | S/F | 4698 scheduled task created |
| Policy Change | Audit Policy Change | S | 4719 auditing tampered with |
| Policy Change | Authentication Policy Change | S | 4706/4713 |
| Policy Change | Authorization Policy Change | S | 4704 user rights assigned |
| System | Security State Change | S | 4616 time changed |
| System | Security System Extension | S | 4697 service installed |
| System | System Integrity | S/F | 4612 audit events dropped |

Also in this GPO:
- Security Options → *Audit: Force audit policy subcategory settings … to override audit policy category settings*: **Enabled**
- Event Log → *Maximum security log size*: **1048576 KB**
- Administrative Templates → System → Audit Process Creation → *Include command line in process creation events*: **Enabled** (tokens on command lines now reach the SIEM; revoke them after use)
- Administrative Templates → Windows Components → Windows PowerShell → *Turn on PowerShell Script Block Logging*: **Enabled** (4104)

**`Lab - Workstation Tiering`**, linked to `Lab/Workstations`:
- User Rights Assignment → *Deny log on locally*, *Deny log on through Remote Desktop Services*, *Deny log on as a batch job*, *Deny log on as a service*: `Domain Admins`, `Enterprise Admins`, `Schema Admins`
- Preferences → Control Panel Settings → Local Users and Groups → `Administrators (built-in)`, action **Update**, add `LAB\T2-Workstation-Admins`

**`Lab - LAPS`**, linked to `Lab/Workstations`. Computer Configuration → Policies → Administrative Templates → System → **LAPS**:
- *Configure password backup directory*: **Active Directory**
- *Password Settings*: complexity large+small letters+numbers+specials, length **20**, age **30** days
- *Enable password encryption*: **Enabled** (only Domain Admins can decrypt by default)
- *Post-authentication actions*: reset the password and log off managed account, grace period **8** hours (a password that was used gets rotated)

Back up all three (PowerShell started with the same `runas /netonly`), then copy `C:\Temp\gpo` into the repo's `ad/gpo/`:

```powershell
New-Item -ItemType Directory -Force C:\Temp\gpo | Out-Null
'Lab - Audit Policy', 'Lab - Workstation Tiering', 'Lab - LAPS' | ForEach-Object { Backup-GPO -Name $_ -Path C:\Temp\gpo }
```

## Verify

- `dcdiag /q` on `DC-01`: no errors
- `w32tm /query /source`: `192.168.20.1` on `DC-01`, `DC-01.ad.example.com` on `win11-01`
- `certutil -CAInfo name`: `Lab Root CA`
- `auditpol /get /category:*` on `DC-01` and `win11-01` matches the table
- `gpresult /r /scope computer` on `win11-01` lists all three GPOs
- LAPS: `Invoke-LapsPolicyProcessing` on `win11-01`, then `Get-LapsADPassword win11-01 -AsPlainText` (Tier 0 session) returns a password, and the old shared one no longer works
- Logging on to `win11-01` as `adm-t0-<you>` is refused; `adm-t2-<you>` is a local admin
- `Get-ADObject (Get-ADDomain).DistinguishedName -Properties ms-DS-MachineAccountQuota`: `0`
