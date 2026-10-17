# Security Engineering Homelab — Roadmap

**Goal:** A homelab built like a real Microsoft-centric enterprise SOC. One SIEM (Elastic), one EDR per endpoint (MDE), one SOAR (n8n), one case-management system, with every tool feeding the SIEM or driving a detection or response. Operated with runbooks and measured with metrics.

> Items marked *(verify)* are pricing, trial lengths or free tiers that change often. Check them before you depend on them.

---

## Stack

### Core — always on (local, Proxmox)

| Function | Tool | Cost |
|---|---|---|
| Hypervisor | Proxmox VE | Free |
| SIEM | Elastic (Elasticsearch + Kibana + Fleet), Basic license | Free |
| Log collection | Elastic Agent + Sysmon (sysmon-modular) on Windows; auditd on Linux | Free |
| Identity (on-prem) | Windows Server 2025 eval: AD DS + AD CS + DNS, Server Core (`dc01`) | Free eval (180 days) |
| SOAR | n8n (self-hosted) | Free |
| DFIR | Velociraptor server (co-hosted on `n8n01`) | Free |
| Attack simulation | Atomic Red Team | Free |

### Network — existing, separate hardware

| Function | Tool | Cost |
|---|---|---|
| Firewall / segmentation | OPNsense (VLANs already running) | Free |
| IDS/IPS | Suricata on OPNsense, ET Open rules | Free |
| DNS logging | OPNsense Unbound query logs | Free |
| Containment action | OPNsense API → block alias (driven by n8n) | Free |

### SaaS — no local RAM

| Function | Tool | Cost |
|---|---|---|
| EDR / XDR | Microsoft Defender for Endpoint P2 + Defender XDR | Paid (see Licensing) |
| Identity threat detection | Microsoft Defender for Identity | Paid (E5 Security) |
| Email security | Defender for Office 365 P2 (incl. Attack Simulation Training) | Paid (E5 Security) |
| CASB | Defender for Cloud Apps | Paid (E5 Security) |
| Endpoint mgmt / cloud identity | Intune + Entra ID P1/P2 (incl. PIM) | Paid |
| Case management / ticketing | Jira Service Management free tier | Free *(verify agent limit)* |
| Zero Trust access | Cloudflare Zero Trust free tier (Kibana, n8n) | Free *(verify)* |
| CSPM | Defender for Cloud, foundational CSPM (free Azure subscription) | Free *(verify)* |
| AppSec / supply chain | GitHub Advanced Security on public repo (CodeQL, secret scanning, Dependabot) | Free |
| Threat intel | Elastic TI integrations (abuse.ch, AlienVault OTX) + VirusTotal, AbuseIPDB, GreyNoise APIs for enrichment | Free *(verify)* |
| Detection-as-code CI | GitHub Actions | Free |

### Rotating — power on per phase

| Tool | RAM | Notes |
|---|---|---|
| Tenable Nessus Essentials (16 IPs) | 4 GB | Power off `win11-01` during scan windows |

### Stretch only (if ahead of schedule)

- Okta Integrator free account as a federated IdP (an edge case, not typical for a Microsoft shop)
- Rebuild the main n8n workflow in Tines Community Edition for comparison

### Needs a RAM upgrade (next step after 32–64 GB)

Security Onion, Wazuh, TheHive + Cortex, MISP, OpenCTI.

### Dropped (and why)

| Tool | Reason |
|---|---|
| Microsoft Sentinel | One SIEM only. Elastic covers it, and KQL practice comes from Defender Advanced Hunting |
| Splunk | Duplicate SIEM |
| FortiGate-VM | OPNsense already fills the firewall/IDS role |
| LimaCharlie | Real SOCs run one EDR per endpoint |
| Logstash | Elastic Agent replaces it |

### EDR conflict: Elastic Defend vs. MDE

By default, Elastic Defend registers as the Windows antivirus, which pushes Microsoft Defender into **passive mode**. On MDE-managed endpoints, run Elastic Agent for **log collection only** (Windows + Sysmon integrations, no Elastic Defend), or turn off "Register as antivirus" in the Elastic Defend policy. Elastic Defend can still run on the Linux hosts, where MDE isn't deployed.

---

## Licensing (small monthly budget)

- **Base, from Month 2:** Microsoft 365 Business Premium. Includes Intune, Entra ID P1, Defender for Business and Defender for Office P1.
- **Add from Month 3:** the Microsoft 365 E5 Security add-on. Brings MDE P2 (Advanced Hunting), Defender for Identity, Defender for Office P2, Defender for Cloud Apps and Entra ID P2 (PIM).
- **Expected cost:** roughly $30–40 per month for 1 user *(verify current pricing and SKU contents)*.
- **Free Azure subscription:** for Defender for Cloud's free CSPM tier only *(verify)*.
- Defender for Business alone has **no Advanced Hunting**, so the E5 Security add-on is required for the KQL hunting work.

---

## Proxmox resource budget (16 GB RAM / 8 cores / 500 GB)

| VM / CT | RAM | vCPU | Disk | Notes |
|---|---|---|---|---|
| Proxmox host | 1.5 GB | — | — | |
| `elk01` (Ubuntu 24.04, Docker) | 6 GB | 4 | 150 GB | Ballooning **off**, ES heap 2–3 GB |
| `win11-01` (clone of template) | 4 GB | 2 | 80 GB | Full clone |
| `dc01` (Server 2025 Core) | 2 GB | 2 | 40 GB | AD DS + AD CS + DNS |
| `n8n01` (LXC: n8n + Velociraptor) | 1.5 GB | 1 | 20 GB | |
| **Total, core** | **15 GB** | | **290 GB** | |
| Rotating slot | ~1 GB free | | ~200 GB free | Power off `win11-01` for Nessus windows |

OPNsense runs on separate hardware and isn't counted.

---

## Network layout (map onto existing OPNsense VLANs; names are placeholders)

| VLAN | Members | Policy |
|---|---|---|
| Mgmt | Proxmox UI, OPNsense UI | Admin workstation only |
| Servers | `elk01`, `dc01`, `n8n01` | From Endpoints, allow only Fleet 8220, ES 9200, AD/DNS ports and n8n 5678 |
| Endpoints | `win11-01` + clones | Outbound internet for Microsoft/SaaS; no access to Mgmt |
| Attack / quarantine | Atomic and attack clones; isolation target | Deny all except Elastic and Velociraptor |

- Home LAN → lab: denied by default.
- Remote access: Cloudflare Zero Trust for web apps (Kibana, n8n); Tailscale for admin/SSH.
- Nothing exposed publicly.
- NTP: every host syncs time (DC → OPNsense → pool) so log timestamps line up across sources.

---

## Data flows into Elastic

| Source | Elastic integration | Shows |
|---|---|---|
| `win11-01` | Elastic Agent: Windows, Sysmon (incl. Event 22 DNS) | Process, network, file and DNS telemetry |
| `dc01` | Elastic Agent: Windows Security log, AD CS events, DNS server logs | Logons, Kerberos, group changes, certificate requests, DNS queries |
| `elk01`, `n8n01` | Elastic Agent: auditd / System + Elastic Defend | Linux server activity — the SOC monitors its own infrastructure |
| OPNsense firewall | pfSense/OPNsense integration (syslog `filterlog`) *(verify OPNsense support)* | Allowed/blocked flows across VLANs |
| OPNsense Suricata | Suricata integration (EVE JSON) | Network IDS alerts |
| OPNsense Unbound | Syslog | DNS queries per client |
| Defender XDR | Microsoft Defender XDR / M365 Defender integration | MDE, MDI, MDO alerts and incidents |
| M365 | Office 365 integration (Management Activity API) | Audit log: mailbox, SharePoint, admin actions |
| Entra ID | Python/n8n poller on Graph `auditLogs/signIns` + `directoryAudits` → Elastic | Sign-ins, risky sign-ins, directory changes (avoids Event Hub cost) |
| Threat intel | Elastic TI integrations (abuse.ch, OTX) | Indicator-match detection rules |
| n8n | Writes case documents to an Elastic index | Response actions taken, approvals, timings |

---

## SOC operations (runs alongside every month)

- **Case management:** every alert worth triaging becomes a Jira ticket (opened by n8n). Each write-up links to its ticket.
- **Runbooks:** one per alert type in `runbooks/`: triage → scope → escalate → contain → eradicate → close.
- **Metrics dashboard (Kibana):** MTTD, MTTR, alert volume by rule, false-positive rate, top noisy rules.
- **Detection lifecycle:** each rule has an ATT&CK ID, a test (Atomic), a tuning log and an owner. Coverage shown in ATT&CK Navigator or DeTT&CT.
- **Pipeline health:** alert when any log source goes silent for more than X minutes. ILM policies (hot → delete) sized to the 150 GB disk.
- **Privileged access:** separate `adm-` accounts for admin work; Entra PIM for just-in-time roles (from Month 3).
- **Vulnerability management loop:** scan (Nessus / Defender Vulnerability Management) → ticket → patch via Intune → rescan to verify.

---

## Month 1 (weeks 1–4): Foundations, SIEM, AD, network — no tenant

- [x] Proxmox installed
- [x] Windows 11 golden template (sysprep issues fixed: reserved storage `0x800F0975`, per-user Appx `0x80073cf2`)
- [ ] Clone `win11-01` from the template
- [ ] `elk01`: Elasticsearch + Kibana + Fleet Server in Docker Compose, TLS enabled; ILM policies
- [ ] Elastic Agent + Sysmon on `win11-01` (log collection only, so it won't conflict with MDE later); enable prebuilt detection rules
- [ ] `dc01`: AD DS + AD CS + DNS on Server Core; domain-join `win11-01`; GPO advanced audit policy; tiered `adm-` accounts
- [ ] Elastic Agent on `dc01`, `elk01` and `n8n01`
- [ ] Velociraptor server on `n8n01`; client on `win11-01`
- [ ] OPNsense: put lab VMs on the VLANs above; back up the config first
- [ ] OPNsense: enable Suricata (ET Open, IDS mode); ship firewall, Suricata and Unbound logs to Elastic
- [ ] Elastic TI integrations (abuse.ch, OTX) + indicator match rule
- [ ] Log-source-silent alert
- [ ] Jira Service Management free site; ticket template for incidents
- [ ] Atomic Red Team baseline: 3–5 techniques, including a network one (port scan / C2-like beaconing)
- [ ] PowerShell: objects and the pipeline, modules, error handling, JSON, `Invoke-RestMethod`
- [ ] Python: venv, `requests`, JSON parsing, API authentication patterns
- [ ] KQL practice in Microsoft's public Log Analytics demo environment *(verify still available)*
- [ ] Public GitHub repo; `.gitignore`, gitleaks and GitHub secret scanning from day one

**Deliverable:** Working Elastic SIEM receiving endpoint, AD, Linux, DNS and network telemetry; golden-image write-up; 2–3 custom detections (one correlated across Suricata and Sysmon), each with a runbook.

## Month 2 (weeks 5–8): Intune + hybrid identity — start Business Premium

- [ ] Dedicated lab tenant (never real accounts)
- [ ] Entra Connect: sync `dc01` to Entra; hybrid-join `win11-01`
- [ ] Intune enrollment; compliance policies and configuration profiles
- [ ] Security baselines, BitLocker, Windows LAPS, firewall policy
- [ ] Deploy a script and a packaged Win32 app
- [ ] Conditional Access requiring device compliance
- [ ] Cloudflare Zero Trust in front of Kibana and n8n
- [ ] M365 audit log to Elastic
- [ ] Entra sign-in/audit log poller (Graph API → Elastic)
- [ ] Graph PowerShell SDK reporting
- [ ] Export policies (sanitized JSON) to the repo

**Deliverable:** Script reporting non-compliant devices; policy-design write-up; hybrid identity diagram; Entra log poller in `scripts/`.

## Month 3 (weeks 9–13): Defender suite — add E5 Security

- [ ] Onboard MDE through Intune; EDR and tamper protection; confirm Defender is in **active** mode
- [ ] ASR rules in audit mode, then enforce
- [ ] Generate safe test detections; work the incident queue as Jira tickets
- [ ] Device isolation and Live Response
- [ ] Advanced Hunting queries mapped to MITRE ATT&CK
- [ ] Defender for Identity sensor on `dc01`
- [ ] AD attack scenario (Kerberoasting or an AD CS ESC1 case), detected by MDI **and** Elastic
- [ ] Defender for Office P2: Attack Simulation Training phishing campaign
- [ ] Defender for Cloud Apps: connect M365; one session/app policy
- [ ] Entra PIM for admin roles
- [ ] Defender XDR alerts to Elastic
- [ ] Vulnerability management loop: Nessus scan window + Defender Vulnerability Management → ticket → Intune patch → rescan

**Deliverable:** KQL hunting pack with ATT&CK mappings; MDE vs. MDI vs. Elastic detection comparison; AD attack write-up; vulnerability-management write-up.

## Month 4 (weeks 14–17): SOAR + API automation

- [ ] Self-host n8n (`n8n01`)
- [ ] App registration with least-privilege Graph/MDE permissions; credentials stored securely
- [ ] Workflow: Defender/Kibana alert → **open Jira ticket** → enrich (VirusTotal / AbuseIPDB / GreyNoise) → Teams or Slack → **human approval** → contain → update ticket → write the case to Elastic
- [ ] Containment: MDE device isolation **plus** an OPNsense API block (dedicated API user, limited to the lab block alias)
- [ ] Velociraptor triage collection as an automated response step
- [ ] Python for enrichment logic n8n can't handle natively
- [ ] Kibana SOC metrics dashboard (MTTD / MTTR from ticket and case timestamps)

**Deliverable:** Exported n8n workflow JSON; architecture diagram; documented approval flow; metrics dashboard screenshot.

## Month 5 (weeks 18–22): Integration + detection engineering

- [ ] End-to-end simulation: Atomic Red Team → detect in Defender, Elastic and Suricata → Jira ticket → n8n workflow → remediate → close with metrics
- [ ] Detection-as-code: Elastic and Sigma rules plus KQL hunting queries in Git, validated in GitHub Actions CI; CodeQL and Dependabot on the repo
- [ ] ATT&CK coverage map (Navigator layer) committed to the repo
- [ ] Defender for Cloud free CSPM on the Azure subscription
- [ ] Optional: switch Suricata to IPS mode after tuning
- [ ] Stretch: Okta federation; Tines comparison

**Deliverable:** Full demo; tool-coverage matrix (which tool caught which technique, and which missed); ATT&CK coverage map.

## Month 6 (weeks 23–26): Portfolio + job readiness

- [ ] Polish READMEs; record a 2–3 minute demo video
- [ ] Resume bullets built on measurable outcomes (e.g. "detected 8/10 Atomic techniques; MTTR under 5 minutes with automated containment")
- [ ] Interview practice on each tool; start applying

---

## Repo layout

```
README.md      architecture diagram, skills shown, links to write-ups
infra/         Proxmox/VM build notes (later: Terraform/Ansible/Packer)
network/       sanitized OPNsense config export, VLAN/rule docs, Suricata tuning notes
ad/            GPO exports, AD/AD CS build notes
elk/           docker-compose.yml, .env.example, Fleet policies, ILM policies
detections/    Elastic + Sigma rules and KQL hunting queries, ATT&CK-mapped, CI-validated
runbooks/      one per alert type: triage → scope → escalate → contain → eradicate → close
intune/        exported policies (sanitized)
n8n/           exported workflows
scripts/       PowerShell + Python (incl. Entra log poller)
comparisons/   tool-vs-tool write-ups, coverage matrix, ATT&CK Navigator layer
writeups/      one per scenario: Objective → Setup → Attack → Detection → Response → Gaps (with Jira ticket link)
```

## Safeguards

- **Buffer:** Treat the last week of each month as slack, since tenant and licensing issues usually take longer than planned.
- **Lab hygiene:** Dedicated tenant only. Attack simulations (including AD attacks) only against lab VMs. Snapshot before every simulation.
- **OPNsense runs the home network too:** back up its config before lab changes, change lab VLAN rules only, and scope the n8n API user to the lab block alias.
- **Secrets:** Nothing real in Git — `.env.example` only, and scrub tenant IDs and keys from screenshots.
- **Trial expiry:** Capture screenshots, exports and recordings before the Windows Server eval (180 days) ends.
- **If you fall behind, cut in this order:** stretch items → Defender for Cloud CSPM → Defender for Cloud Apps → Velociraptor automation. Core path = Elastic + AD + OPNsense + Intune + Defender + n8n + Jira + scripting.
