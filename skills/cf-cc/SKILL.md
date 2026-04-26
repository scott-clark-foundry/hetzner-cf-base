---
name: cf-cc
description: Use when generating or refreshing /home/deploy/.claude/CLAUDE.md to reflect the cf-base host's current live state
---

## Purpose

This skill generates `/home/deploy/.claude/CLAUDE.md` for the cf-base host the skill is running on. It combines two sources of truth: (1) the baseline invariants captured in the Constants section below, which are stable across all cf-base hosts and never need to be re-discovered, and (2) live host state gathered via the Procedure commands below, which varies by host, hardware, and installed services. The result is a complete, current CLAUDE.md that a fresh Claude Code session can read to understand the host without further exploration.

## Constants

These values are invariants of the cf-base baseline. Embed them verbatim in the generated CLAUDE.md.

### Baseline tooling inventory

Installed by cloud-init `packages:` plus firstboot.sh:

| Category | Installed |
|---|---|
| Remote access | `openssh-server`, `mosh`, `tailscale` (tailscale apt repo) |
| Firewall | `ufw` |
| Automatic updates | `unattended-upgrades` (security channel only) |
| Intrusion protection | `fail2ban` (default sshd jail) |
| Containers | `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-compose-plugin` (docker apt repo) |
| General | `git`, `nano`, `tmux`, `screen`, `jq`, `sqlite3`, `htop`, `curl`, `wget`, `rsync`, `tree` |
| Search | `ripgrep`, `fd-find` (binary `fdfind`; aliased to `fd` in deploy shell rc) |
| Debugging | `lsof`, `strace`, `tcpdump`, `dnsutils` (for `dig`), `ncdu`, `dmidecode` |
| Languages | `node` (nodesource LTS apt repo), `bun` (official installer) |
| Python tooling | `uv` (official installer, at `~/.local/bin/uv`) |
| AI ops | Claude Code (official installer, under deploy user) |

### Explicitly NOT installed

`vim`, `nvim`, `emacs`, `deno`, `go`, `rust`, bare `python`/`pip`, `gh`, `zstd`, `iftop`, `nethogs`. Install per-specialization if needed.

### Firewall layering (Hetzner Cloud Firewall + UFW)

Two layers of firewall, deliberately separated by application timing:

**Hetzner Cloud Firewall (`cf-base-default`)** — network-edge perimeter. Deny-all-inbound by default; outbound permissive. Unaffected by Docker's iptables manipulation. Applied by the operator from the laptop AFTER J01 verifies tailnet SSH works and BEFORE post-install runs:
```
hcloud firewall apply-to-resource cf-base-default --type server --server <hostname>
```
Provision-time public SSH is the operator's diagnostic escape hatch if firstboot fails — applying this firewall at provision time would eliminate the escape hatch.

**UFW (host backstop)** — applied by `post-install.sh` after tailscale has joined (so `tailscale0` exists):

```
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0 to any port 22 proto tcp
ufw allow in on tailscale0 to any port 60000:61000 proto udp
ufw enable
```

After both layers close (cloud firewall applied + UFW enabled), public ingress is zero at both perimeter and host. Tailnet is the only remaining path in.

### Secret-handling convention

Runtime secrets for services live in per-service `.env` files (not tracked in git). Tailscale auth keys are reusable tagged (`tag:server`) pre-authorized non-ephemeral keys; the per-host user-data overlay deposits the key at `/opt/cf-base/tailscale-authkey` (mode 0600) and firstboot.sh unlinks it immediately after `tailscale up`.

### Operational guardrails

- `deploy` user has passwordless sudo (`sudo -n` works); acceptable given SSH key gate + tailnet-only post-install + single-operator infra.
- After `post-install.sh` runs: no public ingress. All SSH and mosh access via `tailscale0` only.
- firstboot.sh and post-install.sh are idempotent via sentinel files (`/var/lib/cf-base/firstboot.done`, `/var/lib/cf-base/post-install.done`). Re-running a completed script is a no-op.
- cf-base artifacts (cloud-init YAML, firstboot.sh, post-install.sh, this skill) are the sole source of baseline truth. No out-of-band host modifications.

### Standard one-liner recipes

```bash
# Tailscale status
tailscale status

# UFW status
sudo ufw status verbose

# Running services
systemctl list-units --type=service --state=running

# Follow a service log
journalctl -fu <service-name>

# Docker containers
docker ps

# Disk usage by directory
sudo ncdu /

# Live resource view
htop
```

## Procedure

Run each command below in order to discover the host's current live state. Capture the output — it fills the placeholders in the Template.

**Sudo guardrail:** the only `sudo` invocation in the Procedure is `sudo dmidecode -s system-product-name` at step 2. Do not extend this Procedure with additional `sudo` commands without explicit operator confirmation. The skill body runs under the deploy user's passwordless sudo grant, so any new privileged command added here would execute root unattended on every cf-base host that re-runs `/cf-cc`.

1. **Hostname** — fills `<hostname>`:
   ```bash
   hostname -s
   ```

2. **Hardware product name** — fills `<product-name>` (e.g., `Hetzner CPX32`):
   ```bash
   sudo dmidecode -s system-product-name
   ```

3. **CPU and memory summary** — fills `<cpu-summary>` and `<memory-summary>`:
   ```bash
   grep -m1 'model name' /proc/cpuinfo
   nproc
   free -h
   ```

4. **Tailscale network identity** — fills `<tailscale-ip>`, `<tailnet-name>`, and `<tailscale-peers>`:
   ```bash
   tailscale status --json | jq '{self: .Self, peers: (.Peer | to_entries | map(.value | {hostname: .HostName, ip: .TailscaleIPs[0], online: .Online}))}'
   ```

5. **Running systemd services** — fills `<running-services>`:
   ```bash
   systemctl list-units --type=service --state=running
   ```

6. **Contents of /opt** — fills `<opt-layout>` (shows installed service directories):
   ```bash
   ls /opt/
   ```

7. **Docker containers** — fills `<docker-containers>`:
   ```bash
   docker ps
   ```

After running all seven commands, fill the Template below and write the result to `/home/deploy/.claude/CLAUDE.md`. Overwrite any existing file.

## Template

Write the following to `/home/deploy/.claude/CLAUDE.md`, substituting each `<placeholder>` with the value gathered from the corresponding Procedure command:

```markdown
# Host context — <hostname>

Generated by `/cf-cc`. Re-run after service installs, hardware resizes, or cf-base artifact updates.

## Identity

- **Hostname:** `<hostname>` (← `hostname -s`)
- **Hardware:** `<product-name>` (← `dmidecode -s system-product-name`)
- **CPU:** `<cpu-summary>` (`<nproc>` cores) (← `/proc/cpuinfo` + `nproc`)
- **Memory:** `<memory-summary>` (← `free -h`)
- **Tailscale IP:** `<tailscale-ip>` (← `tailscale status --json | jq .Self`)
- **Tailnet:** `<tailnet-name>`
- **Tailscale peers:** `<tailscale-peers>` (← `tailscale status --json | jq .Peer`)
- **Operating system:** Ubuntu 24.04 LTS
- **Deploy user:** `deploy` (passwordless sudo; groups: sudo, docker)
- **Remote access:** SSH and mosh via tailnet only (post-install); SSH key auth only

## Services

Baseline services always running after post-install:

- `fail2ban` — intrusion protection (default sshd jail)
- `unattended-upgrades` — automatic security updates
- `tailscaled` — tailnet membership
- `docker` — container runtime

Specialization services on this host (discovered from running services + /opt layout):

```
<running-services>
```

/opt layout:

```
<opt-layout>
```

Docker containers:

```
<docker-containers>
```

## Tooling on this host

| Category | Installed |
|---|---|
| Remote access | `openssh-server`, `mosh`, `tailscale` (tailscale apt repo) |
| Firewall | `ufw` |
| Automatic updates | `unattended-upgrades` (security channel only) |
| Intrusion protection | `fail2ban` (default sshd jail) |
| Containers | `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-compose-plugin` (docker apt repo) |
| General | `git`, `nano`, `tmux`, `screen`, `jq`, `sqlite3`, `htop`, `curl`, `wget`, `rsync`, `tree` |
| Search | `ripgrep`, `fd-find` (binary `fdfind`; aliased to `fd` in deploy shell rc) |
| Debugging | `lsof`, `strace`, `tcpdump`, `dnsutils` (for `dig`), `ncdu`, `dmidecode` |
| Languages | `node` (nodesource LTS apt repo), `bun` (official installer) |
| Python tooling | `uv` (official installer, at `~/.local/bin/uv`) |
| AI ops | Claude Code (official installer, under deploy user) |

**Explicitly NOT installed:** `vim`, `nvim`, `emacs`, `deno`, `go`, `rust`, bare `python`/`pip`, `gh`, `zstd`, `iftop`, `nethogs`. Install per-specialization if needed.

## Layout

```
/home/deploy/
    .claude/
        CLAUDE.md               ← this file (generated by /cf-cc)
        skills/cf-cc/SKILL.md   ← the skill that generated this file

/opt/
    cf-base/                    ← firstboot.sh, post-install.sh (sentinels in /var/lib/cf-base/)
    <service-dirs>/             ← per-specialization service installations

/var/lib/cf-base/
    firstboot.done              ← sentinel: firstboot.sh completed successfully
    post-install.done           ← sentinel: post-install.sh completed successfully

/var/log/
    cf-base-firstboot.log       ← firstboot.sh output
    cf-base-post-install.log    ← post-install.sh output
```

## Operational guardrails

- **Sudo:** `deploy` has passwordless sudo. `sudo -n <cmd>` works. Acceptable given SSH key gate + tailnet-only post-install + single-operator infra.
- **Network policy:** after both the cloud firewall is applied and post-install runs, public ingress is zero at perimeter and host (defense in depth):
  - **Hetzner Cloud Firewall** (`cf-base-default`, network edge): deny-all-inbound; applied by operator post-J01 / pre-post-install via `hcloud firewall apply-to-resource ...` from the laptop.
  - **UFW** (host backstop, applied by post-install.sh): `ufw default deny incoming` + `ufw default allow outgoing` + `ufw allow in on tailscale0 to any port 22 proto tcp` + `ufw allow in on tailscale0 to any port 60000:61000 proto udp`.
- **Secrets:** runtime service secrets in per-service `.env` files (not git-tracked). Tailscale auth keys are reusable tagged (`tag:server`) non-ephemeral; deposited per-host at `/opt/cf-base/tailscale-authkey` (mode 0600) and unlinked by firstboot.sh after `tailscale up`.
- **Idempotency:** firstboot.sh and post-install.sh are idempotent via sentinel files in `/var/lib/cf-base/`. Re-running a completed script is a no-op.
- **Baseline source of truth:** cf-base git artifacts are the only canonical source. Do not make out-of-band baseline changes without updating the git artifacts.

## Handy one-liners

```bash
# Tailscale status
tailscale status

# UFW policy
sudo ufw status verbose

# Running services
systemctl list-units --type=service --state=running

# Follow a service log
journalctl -fu <service-name>

# Docker containers
docker ps

# Disk usage by directory
sudo ncdu /

# Live resource view
htop

# Check firstboot / post-install sentinel
ls /var/lib/cf-base/

# cf-base firstboot log
sudo tail -f /var/log/cf-base-firstboot.log

# cf-base post-install log
sudo tail -f /var/log/cf-base-post-install.log
```
```

## Invocation guidance

Re-run `/cf-cc` (invoke this skill in a Claude Code session as the deploy user) whenever:

- A new service has been installed on this host (updates the Services section)
- The host has been resized (updates the Identity hardware fields)
- cf-base artifacts have been updated (updated constants, new guardrails, revised tooling table)
- The Tailscale IP or peer list has changed meaningfully
- The `/opt` layout or running Docker containers have changed significantly

Re-running is safe and idempotent — the skill overwrites `/home/deploy/.claude/CLAUDE.md` in place each time.
