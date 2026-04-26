# cf-base — Hetzner baseline server template

**Status:** Released
**Date:** 2026-04-24

---

## Context

cf-base is a reusable Hetzner baseline server configuration: a version-controlled cloud-init + firstboot script + post-install script + per-host user-data template + `cf-cc` Claude Code skill, usable to provision any new Hetzner host from scratch.

The baseline is captured as in-git cloud-init configuration + shell scripts. No Hetzner snapshot is produced: the YAML and scripts are the canonical artifact, and every provision boots a fresh Ubuntu LTS image and applies the cf-base configuration from scratch. Provisioning a new host is `hcloud server create --image ubuntu-24.04 --user-data-from-file <per-host.yaml>` plus the documented runbook.

cf-base contains zero service code — only OS hardening, tailnet membership, and opinionated baseline tooling. Anything beyond the baseline (web servers, data pipelines, application stacks) layers on top of a freshly-provisioned cf-base host.

## Goals

- **G1.** A repository containing the cloud-init template, firstboot script, post-install script, per-host user-data template, `cf-cc` Claude Code skill, and operator runbook — all version-controlled as the canonical cf-base definition.
- **G2.** Proof journey J01 executed on a temporary CPX32: `hcloud server create --image ubuntu-24.04 --user-data-from-file …` with the cf-base cloud-init. Verify tailnet join, deploy user configured, tooling installed, `cf-cc` skill in place.
- **G3.** Proof journey J02 executed on the same temporary CPX32: manual post-install script applied, UFW policy enforced (public denied, tailscale0 allows 22/tcp + 60000-61000/udp), fail2ban and unattended-upgrades running, `/cf-cc` skill generates `/home/deploy/.claude/CLAUDE.md`. Delete the CPX32. Only git artifacts persist.
- **G4.** Every future provision from the cf-base cloud-init produces a host with fresh identity (fresh Ubuntu → unique SSH host keys, machine-id, tailnet identity) and current baseline security patches (apt pulls latest at provision time).
- **G5.** A `README.md` and a provisioning runbook explain the full operator flow from auth-key generation through post-install hardening.

## Non-goals

- **NG1.** No snapshot artifact. Cloud-init YAML is the source of truth; no Hetzner image to maintain.
- **NG2.** No service code. cf-base is baseline only; application services are layered on top.
- **NG3.** No host-role specialization in this artifact. Each consumer of cf-base owns its own per-host configuration.
- **NG4.** Full CIS hardening audit — targeted hardening only (ufw + sshd key-only + fail2ban + unattended-upgrades).
- **NG5.** Centralized secrets management (Vault, AWS Secrets Manager) — per-host user-data YAML (gitignored) suffices at this scale. Runtime secrets for services layered on top are owned by those services.
- **NG6.** Configuration management tooling (Ansible, Terraform) — `hcloud` CLI + cloud-init suffices at this scale. Re-evaluate if host count exceeds ~5.
- **NG7.** Monitoring/alerting stack — deferred until a specific need arises.

## Design

### Requirements

Provisioning contract: `hcloud server create --image ubuntu-24.04 --location hel1 --type <cpx-size> --name <hostname> --user-data-from-file <per-host.yaml>` produces a host that, within ~2-5 minutes, has completed cloud-init, has joined the tailnet, and is reachable via SSH as `deploy@<hostname>` from any tailnet member. After the manual post-install step, UFW enforces tailnet-only ingress.

firstboot.sh and post-install.sh are both idempotent via sentinel files — re-invocation after success is a no-op.

### Project layout

```
hetzner-cf-base/
├── README.md
├── CLAUDE.md
├── docs/
│   ├── specs/
│   │   └── 2026-04-24-cf-base-design.md
│   └── runbook-provision.md
├── cloud-init/
│   ├── base.yaml
│   ├── firstboot.sh
│   └── post-install.sh
├── user-data/
│   ├── template.yaml
│   └── .gitignore
└── skills/
    └── cf-cc/
        └── SKILL.md
```

`user-data/.gitignore` excludes `cf-*.yaml` (real per-host files with auth keys) but tracks `template.yaml`.

### Baseline tooling inventory

Installed by cloud-init's `packages:` directive plus firstboot.sh (for tools with non-apt installers):

| Category | Installed |
|---|---|
| Remote access | `openssh-server`, `mosh`, `tailscale` (tailscale apt repo added by cloud-init) |
| Firewall | `ufw` |
| Automatic updates | `unattended-upgrades` (security channel only) |
| Intrusion protection | `fail2ban` (default sshd jail) |
| Containers | `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-compose-plugin` (docker apt repo) |
| General | `git`, `nano`, `tmux`, `screen`, `jq`, `sqlite3`, `htop`, `curl`, `wget`, `rsync`, `tree`, `unzip` (required by bun's official installer) |
| Search | `ripgrep`, `fd-find` (binary `fdfind`; aliased to `fd` in deploy shell rc) |
| Debugging | `lsof`, `strace`, `tcpdump`, `dnsutils` (for `dig`), `ncdu`, `dmidecode` (used by the `cf-cc` skill's procedure to discover system-product-name) |
| Languages | `node` (nodesource LTS apt repo), `bun` (installed via its official script) |
| Python tooling | `uv` (installed via its official installer under deploy user at `~/.local/bin/uv`) |
| AI ops | Claude Code (installed via its official installer, under deploy user) |

Explicitly NOT installed (install per-specialization if needed): `vim`, `nvim`, `emacs`, `deno`, `go`, `rust`, bare `python`/`pip`, `gh`, `zstd`, `iftop`, `nethogs`.

### UFW firewall policy

```
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0 to any port 22 proto tcp
ufw allow in on tailscale0 to any port 60000:61000 proto udp
ufw enable
```

Identical to CPX22's current policy. UFW is applied by `post-install.sh` AFTER tailscale has joined, so the `tailscale0` interface exists when the rule is set.

### Hetzner Cloud Firewall

Network-edge perimeter, deployed alongside UFW for defense-in-depth: cloud firewall = network edge (Docker iptables cannot bypass it); UFW = host backstop. Both layers close together at hardening time.

A reusable `cf-base-default` firewall is created once via `hcloud firewall create --name cf-base-default` (deny-all-inbound default; outbound permissive). It is **not** applied at provision time — applying it at provision time eliminates the operator's diagnostic escape hatch when firstboot fails. Instead the operator applies it after J01 verifies tailnet SSH is working and before running `post-install.sh`:

```
hcloud firewall apply-to-resource cf-base-default --type server --server <hostname>
```

This sequence — provision → cloud-init runs firstboot → operator confirms tailnet SSH (J01) → operator applies cloud firewall → operator runs post-install (UFW + fail2ban + unattended-upgrades) — closes both perimeter and host-level layers in order. Until step 3, public SSH on port 22 remains open as the diagnostic path; after step 4 it is denied at the network edge before reaching the host.

When public service ports land later (Specs C, D, E), inbound rules are appended to `cf-base-default` (e.g., `hcloud firewall add-rule cf-base-default --direction in --protocol tcp --port 80 --source-ips 0.0.0.0/0 --source-ips ::/0`).

### Deploy user

- Username: `deploy`; UID/GID unpinned; shell `/bin/bash`; home `/home/deploy`
- Groups: `sudo` (passwordless), `docker`
- `authorized_keys`: operator's public key(s), baked into `cloud-init/base.yaml` via the `users:` directive
- `~/.claude/skills/cf-cc/`: `cf-cc` skill fetched by post-install.sh from a tag of the hetzner-cf-base repo and verified against a baked-in sha256
- `~/.claude/CLAUDE.md`: generated on demand by invoking `/cf-cc` in Claude Code

### Cloud-init shape

The `cloud-init/base.yaml` contains `#cloud-config` with top-level keys:

- `hostname` — overridden by per-host user-data
- `users` — creates `deploy` with `authorized_keys`
- `apt:` — adds tailscale, docker, and nodesource apt repositories
- `packages:` — the apt-installable portion of the baseline tooling
- `write_files:` — writes `firstboot.sh`, `post-install.sh`, the sshd hardening drop-in, the journald persistent-storage drop-in, and the unattended-upgrades drop-in to their target paths. The `cf-cc` skill is **not** embedded here — `post-install.sh` fetches it from a tag of the `hetzner-cf-base` GitHub repo and verifies it against a baked-in sha256 (see _The cf-cc Claude Code skill_ below). Hetzner's user-data ceiling is 32 KiB raw (gzip+base64 is silently dropped); externalizing SKILL.md keeps the artifact comfortably under that cap as new apt sources or write_files entries are added.
- `runcmd:` — final command runs `firstboot.sh`

Per-host user-data overlays on top via cloud-init's default merge semantics.

### User-data contract

Per-host `user-data/<hostname>.yaml` — gitignored, short-lived:

```yaml
#cloud-config
hostname: <hostname>
fqdn: <hostname>
preserve_hostname: false
write_files:
  - path: /opt/cf-base/tailscale-authkey
    permissions: '0600'
    owner: root:root
    content: |
      <ONE_TIME_TAILSCALE_AUTH_KEY>
```

The tailscale auth key is a **reusable, tagged (`tag:server`), pre-authorized, non-ephemeral** key. Generated once from the Tailscale admin console (Settings → Keys), stored in 1Password, and pasted into the per-host user-data overlay at provision time. Reusability lets the same key provision multiple cf-base hosts; tagging gives each host a stable identity (`tag:server`) independent of the operator's user identity, and tagged devices have key-expiry disabled by default — preventing the 'tailscale dropped my server at 3 a.m.' failure mode. The key may have a long expiry (90 days is typical) since it's stored in a password manager, not in code; rotation is via re-generation in the admin console. `firstboot.sh` reads the file, consumes the key, and unlinks the file on success.

### firstboot.sh responsibilities

Runs automatically via cloud-init `runcmd`, as root. Contract (what it does, not how):

1. Check sentinel `/var/lib/cf-base/firstboot.done` — if present, exit 0
2. Install `uv` under the `deploy` user
3. Install Claude Code under the `deploy` user
4. Install `bun` under the `deploy` user (via its official installer)
5. Alias `fd-find`'s binary to `fd` in deploy's shell rc
6. Read tailscale auth key from `/opt/cf-base/tailscale-authkey`
7. Run `tailscale up --authkey=<key> --accept-routes`
8. Unlink `/opt/cf-base/tailscale-authkey` on success
9. Write sentinel `/var/lib/cf-base/firstboot.done`
10. All output logged to `/var/log/cf-base-firstboot.log`

The `cf-cc` skill install is moved to `post-install.sh` (see below); firstboot keeps zero dependency on the hetzner-cf-base GitHub repo so first-boot tailnet-up does not depend on a third-party network being reachable beyond what's already required (apt, tailscale, astral.sh, claude.ai, bun.sh).

Any step failure aborts without writing the sentinel. Public SSH remains open (UFW not yet enabled) as the operator's escape hatch for diagnosis.

### post-install.sh responsibilities

Runs manually by the deploy user after confirming tailnet SSH works. Invoked as `sudo /opt/cf-base/post-install.sh`. Contract:

1. Check sentinel `/var/lib/cf-base/post-install.done` — if present, exit 0
2. Apply UFW policy (see UFW firewall policy section)
3. `ufw --force enable`
4. Configure fail2ban (default sshd jail, defaults otherwise) and enable
5. Configure unattended-upgrades for security channel only, enable
6. Fetch the `cf-cc` skill SKILL.md from the `hetzner-cf-base` tag (`CF_CC_SKILL_TAG`, default `cf-base-v1`), verify its sha256 against `CF_CC_SKILL_SHA256` (hard-fail on mismatch), and install to `/home/deploy/.claude/skills/cf-cc/SKILL.md` owned `deploy:deploy`
7. Write sentinel `/var/lib/cf-base/post-install.done`
8. All output logged to `/var/log/cf-base-post-install.log`

After this script runs, public ingress is closed. Tailnet is the only remaining path in.

### The cf-cc Claude Code skill

Installed at `/home/deploy/.claude/skills/cf-cc/SKILL.md`. Invoked as `/cf-cc` in a Claude Code session running as the deploy user. Generates (or overwrites) `/home/deploy/.claude/CLAUDE.md` to reflect the host's current state. Replaces the approach of shipping a static CLAUDE.md file.

**Distribution mechanism.** The skill body lives at `skills/cf-cc/SKILL.md` in the `hetzner-cf-base` repo on GitHub. `post-install.sh` curls a tag of that file (default `cf-base-v1`, override via `CF_CC_SKILL_TAG`) and verifies its sha256 against `CF_CC_SKILL_SHA256` baked into the script. **Tags are mutable**, so the sha256 check is what actually defends against a tampered or rebased tag. Mismatch is a hard fail: the file is removed and post-install.sh exits non-zero before the skill ever runs under deploy's passwordless sudo. This externalization is what keeps the assembled `cloud-init/base.yaml` under the Hetzner 32 KiB user-data ceiling; it also means the skill body can grow independently of the cloud-init artifact, and a re-run of `post-install.sh` re-pulls and re-verifies. The repo must be public for the unauthenticated curl to succeed; if it is ever made private, the fetch step needs an injected deploy token instead and this section needs updating.

Skill content outline:

- **Purpose**: generate the deploy-user CLAUDE.md for this host, reflecting current live state
- **Constants** (cf-base invariants the skill embeds verbatim): baseline tooling inventory, "NOT installed" list, UFW policy summary, secret-handling convention, baseline operational guardrails, standard one-liner recipes
- **Procedure** (live-state discovery commands): `hostname -s`, `dmidecode -s system-product-name`, hardware summary from `/proc/cpuinfo` + `free -h`, `tailscale status --json | jq`, `systemctl list-units --type=service --state=running`, `ls /opt/`, `docker ps`
- **Template**: CLAUDE.md skeleton with sections for Identity / Services / Tooling / Layout / Guardrails / One-liners, with placeholders for each procedure-derived fact
- **Invocation guidance**: when to re-run (after new service install, hardware resize, cf-base artifact update)

The skill is self-contained in its `SKILL.md`. The claude-code agent reads the skill, runs the procedure, fills the template, writes the output file.

Target CLAUDE.md skeleton (produced by the skill; shown here as a contract shape, not the full content):

```
# Host context — <hostname>

## Identity
<operator, host, specs, network, remote-access notes>

## Services
<baseline services list; specialization services appended here when added>

## Tooling on this host
<baseline tooling table; "NOT installed" list>

## Layout
<filesystem layout notable dirs>

## Operational guardrails
<per-host sudo policy, secret-handling, network policy>

## Handy one-liners
<tailscale status, ufw status, systemctl, etc.>
```

### Journeys

#### J01 — Automatic firstboot + tailnet

Pre-conditions:
- Reusable, tagged (`tag:server`), pre-authorized, non-ephemeral tailscale auth key (see runbook Step 1 + pre-flights)
- `user-data/<proof-hostname>.yaml` copied from `template.yaml` with hostname + auth key filled in
- Operator's SSH public key in `cloud-init/base.yaml`
- `cf-base-default` Hetzner Cloud Firewall created (see runbook Cloud Firewall pre-flight)

Steps:
- [ ] `hcloud server create --image ubuntu-24.04 --location hel1 --type cpx32 --name <proof-hostname> --user-data-from-file user-data/<proof-hostname>.yaml` (cloud firewall is NOT applied here — applied in J02 after tailnet SSH is confirmed; provision-time public SSH is the operator's escape hatch if firstboot fails)
- [ ] Wait 2-5 minutes for provision + cloud-init
- [ ] Tailscale admin console shows the new node
- [ ] `ssh deploy@<proof-hostname>` over tailnet succeeds
- [ ] `/var/lib/cf-base/firstboot.done` exists
- [ ] `which uv && which claude && which node && which bun && which rg && which fd` all succeed
- [ ] `docker ps` succeeds as deploy user
- [ ] `sudo -n true` succeeds (passwordless sudo)
- [ ] `ls /home/deploy/.claude/skills/cf-cc/SKILL.md` exists
- [ ] `ls /opt/cf-base/tailscale-authkey` does NOT exist

#### J02 — Manual post-install + hardening

Pre-conditions: J01 complete, operator has an active tailnet SSH session.

Steps:
- [ ] `hcloud firewall apply-to-resource cf-base-default --type server --server <proof-hostname>` (closes the network-edge perimeter; tailnet SSH still works because tailscale0 traffic is not subject to the cloud firewall)
- [ ] `sudo /opt/cf-base/post-install.sh` runs to completion (closes the host-level UFW backstop)
- [ ] `/var/lib/cf-base/post-install.done` exists
- [ ] `sudo ufw status verbose` shows deny incoming, allow outgoing, tailscale0 rules for 22/tcp + 60000-61000/udp
- [ ] From the operator's laptop (no need to leave tailnet): `ssh -o ConnectTimeout=5 deploy@<public-ip>` times out or is refused. Both layers deny: Hetzner Cloud Firewall at the network edge (packet doesn't reach the host), UFW as host backstop (defense in depth).
- [ ] Existing tailnet SSH session still responsive
- [ ] `systemctl is-active fail2ban` = active; `fail2ban-client status sshd` shows the jail
- [ ] `systemctl is-active unattended-upgrades` = active
- [ ] In claude-code on the host, `/cf-cc` generates `/home/deploy/.claude/CLAUDE.md` reflecting current host state
- [ ] `hcloud server delete <proof-hostname>` — proof complete

### Invariants

- **I1.** cf-base artifacts contain zero service code.
- **I2.** Every provisioned host has a unique tailnet identity (each cloud-init provisions a fresh Ubuntu image whose tailscaled generates its own node key on first registration; auth-key reuse across `tag:server`-tagged hosts is permissible).
- **I3.** After both the cloud firewall is applied (`hcloud firewall apply-to-resource cf-base-default …`) AND post-install runs, public ingress is zero at both the perimeter and the host. Until the cloud firewall is applied, public SSH on port 22 remains open as the operator's diagnostic escape hatch.
- **I4.** cf-base cloud-init + firstboot.sh + post-install.sh are the sole source of baseline truth. No out-of-band host modifications form part of the baseline.
- **I5.** Tailscale auth key is consumed and unlinked by firstboot.sh; never persists on disk beyond that window.
- **I6.** firstboot.sh and post-install.sh are idempotent via sentinel files.

### Layering with downstream services

cf-base provides only the OS baseline. Downstream services (web servers, data pipelines, application stacks) layer on top of a freshly-provisioned cf-base host by:

- adding apt or docker-compose services on top of the existing baseline tooling,
- editing the host-level firewall (`cf-base-default` cloud firewall + UFW) to admit any new public ports they need,
- and managing their own per-service `.env` / secrets out-of-band.

cf-base itself never grows to know about specific downstream services.

## Design decisions (resolved during brainstorm)

| # | Question | Decision |
|---|---|---|
| Q1 | Snapshot approach | None. Cloud-init YAML is source of truth. Image-rebuild overhead + staleness outweigh boot-speed for infrequent provisioning. |
| Q2 | First-boot automation | Automated firstboot until tailnet-join; hardening gated behind manual post-install. Operator confirms tailnet SSH works before closing public ingress. |
| Q3 | Per-host auth model | Three layers: baked (SSH keys), provision-time (tailscale auth key + hostname via user-data), service-time (per-service `.env`, out of scope here). |
| Q4 | Tailscale auth key | Reusable, tagged (`tag:server`), pre-authorized, non-ephemeral; long expiry (~90 days). Stored in a password manager. Tagged-device key expiry is disabled by Tailscale's default policy. Pre-flight: declare `tag:server` in the Tailscale ACL's `tagOwners` block before generating the key. |
| Q5 | Deploy-user CLAUDE.md source | Dynamic via `cf-cc` Claude Code skill. Skill inspects live host + embeds constants + fills template → writes CLAUDE.md. Replaces a static file. |
| Q6 | Editor | `nano`. Vim excluded from baseline. |
| Q7 | Languages at baseline | node (nodesource LTS), bun (official installer); ripgrep + fd for search. No go, rust, deno in baseline. |
| Q8 | Debugging tools | lsof, strace, tcpdump, dnsutils (dig), ncdu, rsync, tree in baseline. |

## Testing strategy

- **Unit-tested:** N/A — this spec defines infrastructure, not code.
- **Journey-tested:** J01 and J02 executed end-to-end against real Hetzner + real Tailscale. Pass = all checklist items satisfied.
- **Not explicitly tested:** declarative assertions (fail2ban default jail timing, unattended-upgrades cron, docker compose plugin operability, cloud-init merge semantics) — proven by running unchanged vendor defaults.
- **Re-runnability:** Every future provision of any cf-base host re-exercises the same code path; real-world provisioning is an ongoing test.

## Forward-compatibility notes

- Ubuntu LTS rollover (24.04 → 26.04) requires review of apt-repo entries (docker, tailscale, nodesource), package names, and uv/claude-code/bun installer URLs. Plan ~2-year maintenance cadence.
- Tailscale auth flow changes (e.g., OAuth replaces keys) → firstboot.sh's `tailscale up` invocation updates. Minor.
- Hetzner image catalog changes → user-data compatibility re-verification needed.
- The `cf-cc` skill's procedure assumes `jq`, `systemctl`, `dmidecode`, `/proc` introspection. If Ubuntu removes any, skill updates.

## Security considerations

- **Trust boundary**: after post-install, tailnet is the only ingress. Public internet reaches zero open ports.
- **Secret lifetime**: tailscale auth key exists on disk for seconds between write_files consumption and unlink. Never logged. Never persisted in a snapshot (no snapshot exists).
- **Passwordless sudo on deploy**: acceptable given SSH key gate + tailnet-only post-install + single-operator infra. Not appropriate for multi-tenant hosts.
- **firstboot.sh runs as root via cloud-init**: script content is baked into cloud-init `write_files` at provision time, not downloaded at runtime — no remote-tampering vector.
- **Public-SSH window**: between firstboot completion and the operator applying the Hetzner Cloud Firewall (post-J01, pre-post-install), public ingress on 22/tcp is open. This is **deliberate** — it is the operator's diagnostic escape hatch when firstboot fails. Mitigations: Ubuntu's default sshd rejects password auth (and the `99-hardening.conf` drop-in makes that explicit + restricts to user `deploy`); operator's typical turnaround from `hcloud server create` to firewall-apply is 5-10 minutes; fail2ban runs after post-install. Applying the cloud firewall at provision time would eliminate the escape hatch and was rejected for that reason.
- **Cloud firewall + UFW layering**: cloud firewall is the network-edge perimeter (`cf-base-default`, deny-all-inbound), unaffected by Docker's iptables manipulation. UFW is the host-level backstop. Both close together at hardening time (cloud firewall applied → post-install runs UFW). See §Hetzner Cloud Firewall.
- **sshd hardening drop-in**: `/etc/ssh/sshd_config.d/99-hardening.conf` makes Ubuntu's implicit defaults explicit (no root, no password auth) and adds `AllowUsers deploy` as the substantive hardening over defaults.

## Deployment notes

- **Region**: hel1. Changing regions means re-verifying Hetzner image IDs and tailnet ACL coverage.
- **Server type**: cf-base is size-agnostic. Each provision picks an appropriate `cpx-*` size for the workload it'll host.
- **Resize direction**: Hetzner supports in-place size-up but not size-down. Start appropriately sized.
- **MagicDNS naming**: Tailscale MagicDNS uses the OS hostname. Per-host user-data's `hostname` field becomes the tailnet address.

## References

- Tailscale install-linux: https://tailscale.com/kb/1031/install-linux
- Tailscale auth keys: https://tailscale.com/kb/1085/auth-keys
- Ubuntu unattended-upgrades: https://help.ubuntu.com/community/AutomaticSecurityUpdates
- Hetzner hcloud CLI: https://github.com/hetznercloud/cli
- Cloud-init docs: https://cloudinit.readthedocs.io/
