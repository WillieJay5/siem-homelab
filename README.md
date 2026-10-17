# Security Engineering Homelab

A homelab built like a Microsoft-centric enterprise SOC: Elastic SIEM, Microsoft Defender XDR, n8n SOAR, Jira case management, OPNsense + Suricata on the network edge, all on Proxmox. Every tool feeds the SIEM or drives a detection or response.

See [ROADMAP.md](ROADMAP.md) for the full plan, stack, and month-by-month build.

## Architecture

*Diagram coming in `docs/`.*

## What's built

- [x] Proxmox host
- [x] Windows 11 golden template
- [ ] Elastic SIEM (`elk01`)
- [ ] Active Directory (`dc01`)
- [ ] OPNsense / Suricata log shipping
- [ ] Intune + hybrid identity
- [ ] Defender suite (MDE, MDI, MDO, MDCA)
- [ ] n8n SOAR workflow
- [ ] Detection-as-code CI

## Write-ups

*One per scenario in [`writeups/`](writeups/): Objective → Setup → Attack → Detection → Response → Gaps.*

## Lab hygiene

Dedicated lab tenant only; no real accounts or data. Configs are sanitized before commit, and secrets live in `.env` files that are never tracked (`.env.example` only).
