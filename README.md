# Security Engineering Homelab

A homelab built like a Microsoft-centric enterprise SOC: Elastic SIEM, Microsoft Defender XDR, n8n SOAR, Jira case management, OPNsense + Suricata on the network edge, all on Proxmox. Every tool feeds the SIEM or drives a detection or response.

## Architecture

*Diagram coming in `docs/`.*

## What's built

- [x] Proxmox host
- [x] Windows 11 golden template
- [x] Elastic SIEM (`elk01`): Elasticsearch, Kibana and Fleet Server with TLS
- [x] Endpoint telemetry: Elastic Agent + Sysmon on `win11-01`, prebuilt rules enabled
- [x] OPNsense VLAN segmentation for lab VMs
- [ ] Active Directory (`dc01`)
- [ ] Suricata + OPNsense log shipping to Elastic
- [ ] Intune + hybrid identity
- [ ] Defender suite (MDE, MDI, MDO, MDCA)
- [ ] n8n SOAR workflow
- [ ] Detection-as-code CI

## Write-ups

- [01 — Windows 11 golden image on Proxmox](writeups/01-golden-image/)
- [02 — Elastic Stack (SIEM) on Docker Compose](writeups/02-elastic-stack/)
- [03 — Endpoint telemetry: Elastic Agent + Sysmon on `win11-01`](writeups/03-endpoint-telemetry/)
