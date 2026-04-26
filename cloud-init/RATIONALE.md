# cloud-init/RATIONALE.md

Why each part of `base.yaml.in`, `firstboot.sh`, and `post-install.sh`
exists. The artifacts themselves are stripped to one line per step;
this file holds the explanations.

For the architectural picture (UFW policy, tag:server reasoning,
secret-handling convention, sentinel design), see
[`docs/specs/2026-04-24-cf-base-design.md`](../docs/specs/2026-04-24-cf-base-design.md).
This file is just for the operational facts that need to live next to
the artifact: apt-key fingerprints, gotchas, source URLs, timezones.

## base.yaml.in

### Top-level invariants

- **`#cloud-config` on line 1 is mandatory.** Cloud-init dispatches by
  this exact marker; any other first line is treated as opaque
  user-data and the file is not parsed as YAML.
- **`base.yaml` MUST NOT bake in a hostname or tailscale auth key.**
  Per-host overlay supplies both via cloud-init merge semantics.
- **The operator pubkey is INLINED in `users.ssh_authorized_keys`.**
  Relying on `hcloud --ssh-key` to inject via cloud-init default
  handling does NOT work when a `users:` block is present. Learned
  the hard way during early provisioning. The inlined pubkey is the operator's long-lived
  ed25519 — public by definition, safe to commit.
- **`packages:` includes `unzip`** because bun's official installer
  fails without it.
- **NodeSource `node_lts.x` apt source currently serves Node v18.19.1.**
  Older than expected (v22 is current LTS). Not a blocker but worth
  knowing if a host needs newer.
- **Hetzner user-data ceiling is 32 KiB raw.** gzip+base64 wrapping is
  silently accepted and never decoded. Stay under 32 KiB raw; if you
  can't, externalize content (the cf-cc skill is the existing precedent
  — see post-install.sh step 7).

### apt sources — fingerprints + key origins

All three apt-source PGP keys are inlined in `base.yaml.in` rather
than fetched via `keyserver.ubuntu.com` at provision time. Inlining
removes the keyserver as a runtime dependency and pins the trust
chain to the committed artifact.

| Source | Fingerprint | Key URL | Repo URL |
|---|---|---|---|
| Tailscale | `2596A99EAAB33821893C0A79EA3B4271135FE800` | https://pkgs.tailscale.com/stable/ubuntu/noble.gpg | https://tailscale.com/kb/1031/install-linux |
| Docker | `9DC858229FC7DD38854AE2D88D81803C0EBFCD88` | https://download.docker.com/linux/ubuntu/gpg | https://docs.docker.com/engine/install/ubuntu/ |
| NodeSource | `6F71F525282841EEDAF851B42F59B5F99B1BE0B4` | https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | https://github.com/nodesource/distributions |

To re-verify a key: `curl -s <Key URL> | gpg --show-keys --with-fingerprint`.
The fingerprint on the right side of the output should match the table.
Re-inline the armored key (under `apt.sources.<name>.key: |`) only if
the fingerprint matches; otherwise the upstream has rotated and the
operator must investigate before trusting the new key.

### unattended-upgrades drop-in

- `Automatic-Reboot "true"` ensures security patches that need a
  reboot are not silently deferred on unattended servers.
- `Automatic-Reboot-Time "11:00"` (UTC) = ~03:00 PST / 04:00 PDT —
  the west-coast operator's pre-dawn window. Hetzner Ubuntu defaults
  to UTC; this lands during operator sleep regardless of DST.
- `MinimalSteps "true"` lets unattended-upgrades make incremental
  progress under tight reboot windows.

### sshd hardening drop-in

`/etc/ssh/sshd_config.d/99-hardening.conf` makes Ubuntu's implicit
defaults explicit (`PermitRootLogin no`, `PasswordAuthentication no`,
`PubkeyAuthentication yes`) and adds `AllowUsers deploy` as the
substantive hardening over stock. The drop-in lives in `sshd_config.d/`
rather than mutating `/etc/ssh/sshd_config` so future Ubuntu upgrades
don't surface a conffile-merge prompt.

### journald persistent storage

`/etc/systemd/journald.conf.d/storage.conf` sets `Storage=persistent`
so logs survive reboots. Useful for post-incident forensics; the
default tmpfs storage loses everything on reboot.

## firstboot.sh

Runs as root via cloud-init `runcmd`. Idempotent via the sentinel
`/var/lib/cf-base/firstboot.done`. Any step failure aborts before the
sentinel is written; public SSH (22/tcp) stays open as the operator's
diagnosis escape hatch until `post-install.sh` closes it.

| Step | Why |
|---|---|
| 1 idempotency sentinel | Re-running firstboot on a provisioned host is a no-op. |
| 2 install uv (deploy) | https://docs.astral.sh/uv/getting-started/installation/ — `uv` is the project default Python toolchain. |
| 3 install Claude Code (deploy) | https://docs.anthropic.com/en/docs/claude-code/setup — operator's primary tooling on the host. |
| 4 install bun (deploy) | https://bun.sh/docs/installation — needed for any TS/JS service. Requires `unzip` (in baseline packages). |
| 5 alias `fdfind` → `fd` | Ubuntu installs fd-find as `fdfind` to avoid clashing with `fd` from the Network Manager package. The alias makes muscle-memory `fd` work. |
| 6-7 read auth key + tailscale up | Per-host overlay deposits `/opt/cf-base/tailscale-authkey` (mode 0600 root:root). `tailscale up --advertise-tags=tag:server` gives the host a stable server identity independent of the operator's user identity; tagged devices have key-expiry disabled by Tailscale's default policy — preventing the "tailscale dropped my server at 3 a.m." failure mode. **Pre-flight: `tag:server` must be declared in the Tailscale ACL `tagOwners` block before provisioning.** |
| 8 unlink auth key | Auth key never persists past the boot window (I5). |
| 9 sentinel write | Reached only on success (set -e). |
| 10 log redirect | All firstboot output goes to `/var/log/cf-base-firstboot.log` for post-mortem. |

The cf-cc skill install is **not** in firstboot.sh — it's in
`post-install.sh` step 7 to keep firstboot off the hetzner-cf-base
GitHub repo's network path (firstboot already depends on apt,
tailscale, astral.sh, claude.ai, bun.sh; no need to add a fifth).

### Why `runuser -u deploy --` and not `sudo -u deploy --`

PAM password-aging on root (Hetzner Ubuntu 24.04 cloud images ship
`lastchange=0`) blocks `sudo -u OTHER_USER` from cloud-init's TTY-less
runcmd context. `runuser` (util-linux) bypasses PAM session machinery.
Empirically verified on live hosts. `bootcmd: chage -E -1
root` and `bootcmd: chage -d <today> root` workarounds DON'T stick —
cloud-init's `cc_set_passwords` module re-applies expire after bootcmd.

## post-install.sh

Runs manually as root (`sudo /opt/cf-base/post-install.sh`) after the
operator has confirmed tailnet SSH works. Idempotent via
`/var/lib/cf-base/post-install.done`. After it runs, public ingress is
closed and tailnet is the only path in.

| Step | Why |
|---|---|
| 1 idempotency sentinel | Re-running post-install on a hardened host is a no-op. |
| 2 UFW default policy | `deny incoming, allow outgoing` — closes the public window. |
| 3 UFW allow on tailscale0 | `22/tcp` for SSH and `60000:61000/udp` for mosh, both restricted to the tailnet interface. |
| 4 `ufw --force enable` | Skips the interactive "are you sure" prompt. |
| 5 fail2ban | Default sshd jail is enabled by default on Ubuntu 24.04; no `jail.local` needed. |
| 6 unattended-upgrades | The drop-in (Automatic-Reboot + MinimalSteps) is deposited by cloud-init `write_files`, before this script runs. Stock `/etc/apt/apt.conf.d/50unattended-upgrades` already restricts to `${distro_id}:${distro_codename}-security`. |
| 7 fetch cf-cc skill | Curls SKILL.md from a tag of the hetzner-cf-base GitHub repo (default `cf-base-v1`, override via `CF_CC_SKILL_TAG`) and verifies its sha256 against `CF_CC_SKILL_SHA256`. Mismatch hard-fails. Tags are mutable — the sha256 check is the actual integrity guarantee. Externalized from cloud-init to keep `base.yaml` under the 32 KiB user-data ceiling. The repo must remain public for the unauthenticated curl to work. |
| 8 sentinel write | Reached only on success (set -e). |
| 9 log redirect | All post-install output goes to `/var/log/cf-base-post-install.log`. |

## Cloud-init merge semantics

The provision file is built by concatenating two `#cloud-config`
documents: `cloud-init/base.yaml` + the per-host overlay. Cloud-init
handles two `#cloud-config` documents in a single file using its
default merge semantics — the per-host overlay's keys override or
merge into the base. This is how the hostname and tailscale auth key
in the overlay take effect.

See https://cloudinit.readthedocs.io/en/latest/reference/merging.html
for the full merge algorithm if you need to predict how a new key
will combine.

## When you edit one of these files

| Edit | Action |
|---|---|
| `firstboot.sh` or `post-install.sh` | Run `./cloud-init/build.sh` to regenerate `base.yaml`. |
| `base.yaml.in` | Run `./cloud-init/build.sh` to regenerate `base.yaml`. |
| `skills/cf-cc/SKILL.md` | NOT regenerated into `base.yaml`. Push to GitHub and bump the `cf-base-v*` tag (or override `CF_CC_SKILL_TAG`) to roll new hosts forward. |
| Adding a new apt source | Inline the armored key in `base.yaml.in`, add the fingerprint + source URL to the apt-sources table above. Verify via `curl … | gpg --show-keys` before committing. |
| Adding a new write_files entry | If the entry's body is large (>1 KiB), check generated `base.yaml` size with `wc -c cloud-init/base.yaml` and stay under 32 KiB. Externalize via post-install.sh fetch if needed. |
