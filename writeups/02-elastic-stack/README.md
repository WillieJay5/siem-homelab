# 02 — Elastic Stack (SIEM) on Docker Compose

**Objective → Setup → Build → Problems → Hardening → Verification → Gaps**

## Objective

Stand up the lab's SIEM: a single-node Elasticsearch, Kibana and Fleet Server on `elk01`, with TLS on every connection, so endpoints can enroll Elastic Agent through Fleet and ship logs straight to Elasticsearch. Everything is declared in [`elk/docker-compose.yml`](../../elk/docker-compose.yml) so the stack can be rebuilt from the repo plus one `.env` file.

**Why Fleet + Elastic Agent instead of Beats:** one agent per host instead of Winlogbeat + Filebeat + Auditbeat, policies managed centrally from Kibana, and several planned sources (Elastic Defend on Linux, Defender XDR, M365, threat intel) ship as Agent integrations. Beats remain supported, but new integrations target Agent.

## Setup

| Setting | Value | Why |
|---|---|---|
| VM | `elk01`, Debian 13.7 netinst (SSH server + standard utilities only) | Minimal attack surface; no desktop |
| CPU / RAM | 4 vCPU (`host`), 6 GB, ballooning **off** | Elasticsearch sizes its heap at start; ballooning would take memory back from the JVM |
| Disk | 150 GB, VirtIO SCSI, discard on | Retention is sized to this disk (see ILM) |
| Network | Servers VLAN (20), static DHCP reservation, local DNS record | Endpoints and Fleet reach it by FQDN; the FQDN is in the TLS certs |
| Elastic | 9.1.0, Basic license | Free tier covers SIEM, detection rules and Fleet |
| Memory split | ES 3 GB (2 GB heap), Kibana 1 GB, Fleet Server + OS the rest | Fits the 6 GB budget in the roadmap |

**Firewall rules this depends on** (OPNsense, inbound to Servers): Endpoints and the Atomic Red VLAN → `elk01` TCP 8220 (Fleet) and 9200 (Elasticsearch); Admin PC and VPN → 5601 (Kibana) and 22. Servers itself only gets DNS and NTP to the firewall plus HTTP/HTTPS out (package mirrors, Docker and Elastic registries).

## Build

1. Install Docker and raise the mmap limit Elasticsearch needs:

   ```bash
   curl -fsSL https://get.docker.com | sudo sh
   echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-elasticsearch.conf && sudo sysctl --system
   ```

2. Copy `elk/` to `/opt/elk`, then create `.env` from [`.env.example`](../../elk/.env.example): passwords (letters and digits), `ENCRYPTION_KEY` (`openssl rand -hex 32`), and `ELK_FQDN`/`ELK_IP`, which go into the certificates.
3. `docker compose config -q && docker compose up -d`. Startup is a chain of dependencies:

   | Service | Type | Does |
   |---|---|---|
   | `certs` | one-shot | Creates the CA and per-service certs (SANs: service name, hostname, FQDN, IP) |
   | `es01` | long-running | Elasticsearch, HTTPS on 9200 |
   | `setup` | one-shot, after `es01` is healthy | Sets the `kibana_system` password; creates Fleet Server's service token |
   | `kibana` | long-running, after `setup` completes | HTTPS on 5601; [`kibana.yml`](../../elk/kibana.yml) preconfigures the Fleet Server policy and host |
   | `fleet-server` | long-running, after Kibana is healthy | Elastic Agent in Fleet Server mode on 8220 |

4. In Kibana → **Fleet → Settings → Outputs**, point the default output at `https://<ELK_FQDN>:9200` with the CA's SHA-256 fingerprint, so agents verify Elasticsearch's certificate.
5. Apply the retention policies from [`elk/ilm/`](../../elk/ilm/README.md) in Dev Tools.

## Problems

Most of the time went into the network, not Elastic: the Servers VLAN had never carried traffic, so nothing on OPNsense was serving it.

### 1. No DHCP, no ARP entry: interface disabled

**Symptom:** the Debian installer couldn't get a DHCP lease; with a static IP, the mirror still failed, and OPNsense's ARP table had no entry for the VM.
**Cause:** the Servers interface was assigned to VLAN 20 but never enabled, so it had no IP and answered nothing.
**Fix:** enable it with a static `/24`, then enable dnsmasq DHCP on the interface with a range.
**Lesson:** ping is a bad test here. Firewall rules block ICMP from Servers to the firewall, so a ping fails even on a healthy network. The ARP table and a packet capture on UDP 67 separate "frames never arrive" from "DHCP isn't answering".

### 2. DHCP works, mirror still fails: DNS not listening

**Symptom:** `wget` reported *failed to resolve host*. (`nslookup` isn't in the Debian installer shell; `ping <name>` works as a resolver test because it resolves before sending.)
**Cause:** Unbound listened on a fixed interface list that didn't include Servers.
**Fix:** add Servers to Unbound's network interfaces. Bringing up a new VLAN on OPNsense means checking each service: interface, DHCP, DNS, NTP, outbound NAT.

### 3. `docker compose up` hung on Kibana

**Symptom:** Kibana was up (logins succeeded in its log) but stayed `health: starting`, so Fleet Server never started.
**Cause:** the health check grepped for `HTTP/1.1 302 Found`. Kibana 9 negotiates HTTP/2 when TLS is on and answers `HTTP/2 302`.
**Fix:** match either version: `grep -qE '^HTTP/[0-9.]+ 302'`.

### 4. Every `up` after the first failed: *dependency failed to start*

**Symptom:** `container elk-setup-1 exited (0)` → `dependency failed to start`.
**Cause:** Elastic's reference compose makes Elasticsearch wait for the setup container to be *healthy*. That works only while setup is still running; once it exits, Docker never reports it healthy again.
**Fix:** split setup into two one-shot jobs (`certs` before Elasticsearch, `setup` after it) and make dependents wait on `service_completed_successfully`.

### 5. Fleet Server stuck on *Waiting on default policy with Fleet Server integration*

**Cause:** recent Kibana versions no longer create a Fleet Server policy automatically, so the agent waited for one forever.
**Fix:** Fleet preconfiguration in `kibana.yml` (a `fleet-server-policy` agent policy with the `fleet_server` package, plus the Fleet Server host URL), and `FLEET_SERVER_POLICY_ID` on the container. A related slip: editing the repo copy doesn't change the VM. The first retry ran the old file because it hadn't been copied over.

### 6. Certificates issued for the wrong hostname

**Cause:** `ELK_FQDN` didn't match the record actually published in local DNS. Agents connecting by the real name would fail TLS hostname verification.
**Fix:** correct `ELK_FQDN`, delete only the service certs and rerun `certs`. The CA was kept, so the fingerprint configured in Fleet stayed valid.

### 7. Duplicate Fleet Server agents

**Cause:** each fresh enrollment (after clearing the agent's state volume) registers a new agent; the old records remain as *Offline*.
**Fix:** unenroll the stale ones with **Remove agents immediately**, which also revokes their API keys. `hostname: fleet-server` gives future enrollments a readable name instead of a container ID.

## Hardening

A security review of the first working version found two weaknesses. Neither was exploitable on its own, but both made a single container compromise worse:

| Finding | Risk | Change |
|---|---|---|
| CA private key world-readable (644) and mounted into Kibana and Fleet Server | Compromising either container yields the key every agent trusts, enough to impersonate Elasticsearch or Fleet Server to all endpoints | CA key moved to its own `ca` volume mounted only by the `certs` job. Each service mounts just `ca.crt` and its own cert/key (read-only volume subpaths, Docker Engine 26+). Files 640, directories 750, `root:root`. Leftover `ca.zip`/`certs.zip` deleted |
| `elastic` superuser password in Fleet Server's environment | Visible in `docker inspect`; Fleet Server had superuser rights it never needed | `setup` creates a scoped `elastic/fleet-server` service token, written to a volume only Fleet Server mounts (mode 600) and passed by path. Tokens from the old setup are revoked by hand (see Verification) |

A second review of the hardened files found no remaining vulnerabilities.

## Verification

- [x] `docker compose ps -a`: `certs` and `setup` exited 0; `es01` and `kibana` healthy; `fleet-server` running
- [x] Fleet → Agents: one Fleet Server, **Healthy**; stale enrollments removed
- [x] Kibana reachable over HTTPS by FQDN from the Admin PC
- [ ] `docker compose exec kibana ls config/certs/ca` lists only `ca.crt`
- [ ] `GET _security/service/elastic/fleet-server/credential` lists only the `compose` token
- [ ] `GET _ilm/policy/lab-logs` returns the policy

## Gaps

- **Single node.** No replicas, so a failed disk loses the data. Acceptable for a lab; snapshots to another host would be the next step.
- **Retention is a guess.** 30 days of logs and 14 of metrics until real ingest rates are known; check `GET _cat/allocation?v` weekly.
- **Self-signed CA.** Browsers and agents trust it only after `ca.crt` is imported. A lab CA from AD CS (`dc01`) could replace it later.
- **Secrets in container environments.** `ELASTIC_PASSWORD`, `KIBANA_PASSWORD` and `ENCRYPTION_KEY` are visible to anyone with Docker access on `elk01`, which is already root-equivalent.
- **Manual deploy.** Files reach the VM by `scp`, which is how the stale-file mistake in problem 5 happened. A `git pull` on the VM, or Ansible in `infra/`, would remove that step.
- **No log shipping from OPNsense yet.** The firewall's local logging is off and nothing is forwarded; covered by the Month 1 log-shipping item.
- **Screenshots.** None captured yet. Fleet agent list and Kibana login are worth adding to `img/`.
