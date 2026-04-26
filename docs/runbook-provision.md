# cf-base Provisioning Runbook

**Audience:** operator provisioning a new Hetzner host from the cf-base cloud-init artifacts.

**Scope:** full operator flow from auth-key generation through post-install hardening and final disposition. Execute this document top to bottom on every fresh provision.

**Related artifacts:**
- `cloud-init/base.yaml` — reusable baseline cloud-init (all hosts)
- `user-data/template.yaml` — per-host overlay template (hostname + tailscale auth key)
- `docs/journeys/J01-firstboot-tailnet.md` — verification checklist after firstboot
- `docs/journeys/J02-post-install-hardening.md` — verification checklist after hardening

**Reference documentation:**
- Cloud-init canonical docs: https://docs.cloud-init.io/en/latest/
- Hetzner basic-cloud-config tutorial: https://community.hetzner.com/tutorials/basic-cloud-config
- Tailscale auth keys: https://tailscale.com/kb/1085/auth-keys

---

## Pre-flight: account hygiene (one-time, do once before any cf-base host runs)

Two operator-side configurations that should exist before any cf-base host is provisioned. Both are one-time setups via web admin consoles; neither is in cf-base code.

**1. Hetzner account 2FA.** Enable TOTP (mobile authenticator) or a hardware key (YubiKey/Token2) at console.hetzner.cloud → Security. A compromised Hetzner account means an attacker can attach a new cloud-init configuration to your server at next boot. Hetzner's 2FA recovery requires postal mail — keep a printed/sealed copy of the recovery key.

**2. Tailscale ACL `tagOwners` for `tag:server`.** Edit the ACL HuJSON at login.tailscale.com → Access Controls. The minimal addition cf-base requires:
```jsonc
{
  "tagOwners": {
    "tag:server": ["<your-tailscale-email>"]
  }
}
```
Without this, generating a tagged auth key (Step 1) and `tailscale up --advertise-tags=tag:server` in firstboot will fail. For ACL examples including server-to-laptop egress restriction (recommended once a cf-base host runs public services), see the Tailscale ACL samples reference at the end of this runbook.

---

## Pre-flight: one-time Hetzner Cloud Firewall setup

The Hetzner Cloud Firewall sits at the network edge and is unaffected by Docker's iptables manipulation, providing the perimeter that UFW alone cannot guarantee. Create a reusable `cf-base-default` firewall once; apply it to each cf-base host **after tailnet SSH is confirmed working (Step 7) and before `post-install.sh` runs (Step 9)**. Provision-time public SSH is the operator's diagnostic escape hatch if firstboot fails — applying the firewall at provision time eliminates that escape hatch and is a layering bug.

**One-time setup** (skip if `hcloud firewall list` already shows `cf-base-default`):
```
hcloud firewall create --name cf-base-default
# No inbound rules — pure deny-all inbound by default.
# Outbound is permissive by default (Hetzner doesn't filter outbound).
# Tailscale data plane (UDP 41641) and DERP relays (TCP 443) traverse this
# happily because they're stateful outbound flows.
```
Verify: `hcloud firewall describe cf-base-default` shows zero inbound rules.

**When you need public ports later** (e.g., HTTP/HTTPS for a service layered on top), append inbound rules:
```
hcloud firewall add-rule cf-base-default --direction in --protocol tcp --port 80 --source-ips 0.0.0.0/0 --source-ips ::/0
hcloud firewall add-rule cf-base-default --direction in --protocol tcp --port 443 --source-ips 0.0.0.0/0 --source-ips ::/0
```
cf-base itself is tailnet-only — no public ports.

---

## Pre-flight checklist

Before starting, confirm all three conditions below. Do not proceed until they are met.

**1. `hcloud` CLI authenticated.**
```
hcloud context list
```
Expected: at least one context shown with a `*` indicating it is active. If not, run `hcloud context create <name>` and follow the token prompt.

If this fails: visit https://console.hetzner.cloud → API Tokens → Generate API Token (read+write), then `hcloud context create`.

**2. SSH agent has the operator key loaded.**
```
ssh-add -l
```
Expected: the ed25519 key fingerprint listed (the same key listed in `cloud-init/operator-pubkeys.txt`). If not, `ssh-add ~/.ssh/id_ed25519` (or the appropriate key path).

If this fails: confirm the key path and passphrase; the key must match an entry in `cloud-init/operator-pubkeys.txt`.

**3. `cloud-init/base.yaml` exists.**
```
test -f cloud-init/base.yaml
```
If not present, complete the first-time setup: `cp cloud-init/operator-pubkeys.txt.example cloud-init/operator-pubkeys.txt`, paste your SSH public key(s) into `operator-pubkeys.txt`, then run `./cloud-init/build.sh` to generate `cloud-init/base.yaml`.

---

## Step 1: Generate a tailscale auth key

Pre-flight required: complete the 'account hygiene' and 'Hetzner Cloud Firewall' subsections above before this step.

**Goal:** produce a reusable, tagged, pre-authorized, non-ephemeral auth key for this host's tailnet join.

**Where:**
1. Open the Tailscale admin console: https://login.tailscale.com/admin/settings/keys
2. Click **Generate auth key**.
3. Set the following options:
   - **reusable=true** (multiple cf-base hosts may use the same key — tailnet node identity comes from each host's unique node key generated by tailscaled on first registration, not from the auth key)
   - **tag=tag:server** (gives the host a stable server identity independent of the operator's user identity; Tailscale's default policy disables key-expiry for tagged devices — preventing the 'tailscale dropped my server at 3 a.m.' failure mode)
   - **pre-authorized=true** (skips the manual authorization step in the admin console — required for unattended firstboot)
   - **ephemeral=false** (the host is persistent; ephemeral=true auto-removes the node from the tailnet after the first offline period, which is wrong for a long-lived server)
4. Set expiry to 90 days (or the longest available). Store the key in 1Password — it is shown only once but can be regenerated if lost.

Note: the `tag:server` ACL entry in `tagOwners` must be declared (see account-hygiene pre-flight) before a tagged key can be generated. If the tag option is greyed out, complete that pre-flight first.

Reference: https://tailscale.com/kb/1085/auth-keys

If this fails: confirm you have Owner or Admin role on the tailnet. Tagged + pre-authorized keys require Admin.

---

## Step 2: Copy template and fill in hostname + auth key

**Goal:** produce a filled `user-data/<hostname>.yaml` overlay for this host.

```
cp user-data/template.yaml user-data/<hostname>.yaml
```

Then open `user-data/<hostname>.yaml` and replace:
- `<hostname>` (two occurrences: `hostname:` and `fqdn:`) with the intended host name, e.g. `cf-proof`.
- `<ONE_TIME_TAILSCALE_AUTH_KEY>` with the auth key from Step 1.

Verify no placeholders remain:
```
grep '<' user-data/<hostname>.yaml
```
Expected: no output. Any output means a placeholder was missed.

Note: `user-data/<hostname>.yaml` is gitignored (`user-data/.gitignore` excludes `cf-*.yaml`). It should never be committed — it contains a live tailscale auth key.

If this fails: open `user-data/template.yaml` as the reference and confirm the two substitution sites are present.

---

## Step 3: Merge base + per-host into provision file

**Goal:** produce a single cloud-init file that combines the reusable baseline with the per-host overlay.

**Build base.yaml first** if you've edited `firstboot.sh` or `post-install.sh` since the last commit: `./cloud-init/build.sh`. The locally-generated `cloud-init/base.yaml` is regenerated from `base.yaml.in` + the two standalone scripts; running build.sh ensures the generated YAML matches your standalone edits before you provision. `skills/cf-cc/SKILL.md` is **not** assembled into base.yaml — it is fetched at post-install time from a tag of this repo (default `cf-base-v1`, override via `CF_CC_SKILL_TAG`) and verified against `CF_CC_SKILL_SHA256` baked into post-install.sh. Editing SKILL.md needs a new sha256 baked into post-install.sh, a new tag pushed to GitHub, and a corresponding update to `CF_CC_SKILL_TAG` — all in one commit, or the integrity check fails at provision time.

```
python3 cloud-init/merge.py user-data/<hostname>.yaml > /tmp/<hostname>.yaml
```

`merge.py` does an explicit merge: scalars from the overlay override the base; the overlay's `write_files` list is appended to the base's. **Do NOT use `cat base.yaml overlay.yaml`** — two `#cloud-config` shebangs in one file are read as a single YAML document, the overlay's `write_files:` clobbers the base's under "last key wins", and the host boots without firstboot.sh, post-install.sh, or any other system file.

Sanity check:
```
head -1 /tmp/<hostname>.yaml
python3 -c "import yaml; d=yaml.safe_load(open('/tmp/<hostname>.yaml')); print('write_files paths:', [w['path'] for w in d['write_files']])"
```
Expected: first command prints `#cloud-config`; second lists six paths — the five system files (firstboot.sh, post-install.sh, sshd hardening drop-in, journald drop-in, unattended-upgrades drop-in) plus the per-host tailscale-authkey.

---

## Step 4: Create the Hetzner server

**Goal:** provision the host; cloud-init will complete within 2-5 minutes.

```
hcloud server create \
  --image ubuntu-24.04 \
  --location hel1 \
  --type <cpx-size> \
  --name <hostname> \
  --user-data-from-file /tmp/<hostname>.yaml
```

Substitute `<cpx-size>` with the intended server type (e.g., `cpx22` for a small proof run, `cpx32` or larger for production workloads). Substitute `<hostname>` with the same name used in Steps 2-3.

**Note:** the Hetzner Cloud Firewall (`cf-base-default`) is **not** applied here. It's applied later in Step 8, after Step 7 confirms tailnet SSH works. Provision-time public SSH is the operator's diagnostic escape hatch if firstboot fails — see Step 5's public-SSH window callout and §Pre-flight: one-time Hetzner Cloud Firewall setup at the top of this runbook.

Expected output: Hetzner acknowledges the server creation and prints the server ID and public IP. Cloud-init then runs automatically over the next 2-5 minutes. The `hcloud server create` command returns as soon as the server exists in Hetzner's API — cloud-init continues in the background.

If this fails: check `hcloud context list` to confirm the active context has write permission. If the server type is unavailable, `hcloud server-type list` shows available types in hel1.

---

## Step 5: Wait and verify tailnet join

**Goal:** confirm cloud-init completed and the host joined the tailnet.

> **Public-SSH window.** Between cloud-init completion (firstboot.sh sentinel written) and the operator applying the Hetzner Cloud Firewall in Step 8, port 22/tcp is publicly open on the host's public IP. This is the operator's intentional escape hatch — if tailnet join fails, public SSH key auth is the only diagnostic path in. Mitigations: sshd's hardening drop-in (`/etc/ssh/sshd_config.d/99-hardening.conf`) rejects password auth and disallows root login (only `deploy` user with key auth is permitted); fail2ban is installed by cloud-init but only enabled by post-install in Step 9. Apply the cloud firewall in Step 8 as soon as tailnet SSH is confirmed (Step 7) to close the window.

Wait 2-5 minutes after Step 4 returns. Then:

1. Open the Tailscale admin console: https://login.tailscale.com/admin/machines
2. Confirm the new node appears with the correct hostname.

If the node does not appear after 5 minutes:

The public SSH port (22/tcp) is open at this stage — UFW has not yet been applied. Use the public IP to SSH for diagnosis:
```
ssh deploy@<public-ip>
```
Then check the firstboot log:
```
sudo cat /var/log/cf-base-firstboot.log
```
Look for the `FAILED at line` error message or missing steps. Common failures: network connectivity during package installation (`apt` transient errors), missing tailscale auth key content (check `user-data/<hostname>.yaml` was filled correctly).

---

## Step 6: SSH over tailnet

**Goal:** confirm tailnet SSH works as the deploy user before closing public ingress.

```
ssh deploy@<hostname>
```

Tailscale MagicDNS resolves `<hostname>` to the host's tailnet IP — no need to look up the IP manually. This confirms the host is reachable via the tailnet path that will remain after post-install closes the public port.

Expected: you land at a bash prompt as `deploy` on the remote host.

If this fails: confirm Tailscale is running on your local machine (`tailscale status`). Confirm the node appears in the admin console (Step 5). If MagicDNS isn't resolving, try `ssh deploy@$(tailscale ip -4 <hostname>)` as a fallback.

---

## Step 7: Run the J01 firstboot + tailnet checklist

**Goal:** verify all firstboot expectations against the live host before proceeding to hardening.

Execute every item in `docs/journeys/J01-firstboot-tailnet.md` against the live host. Do not proceed to Step 8 until all checklist items pass.

The journey file is the authoritative checklist. Common items include: sentinel file present, tooling commands (`which uv`, `which claude`, `which node`, `which bun`, `which rg`, `which fd`) all resolve, `docker ps` succeeds as deploy, `sudo -n true` succeeds, tailscale auth key unlinked. (The cf-cc skill is fetched in J02, not J01.)

If any J01 item fails: diagnose via `sudo cat /var/log/cf-base-firstboot.log` on the host. If the firstboot script aborted mid-run, the sentinel `/var/lib/cf-base/firstboot.done` will be absent and the failing step will be logged.

---

## Step 8: Apply the Hetzner Cloud Firewall

**Goal:** close the network-edge perimeter now that tailnet SSH is confirmed working. After this step, public IPs are unreachable; tailnet is the only remaining path in.

Run from your laptop (NOT the proof host — keep the hcloud token local):
```
hcloud firewall apply-to-resource cf-base-default --type server --server <hostname>
```

Expected output: `Firewall <id> applied to server <id>` (or similar acknowledgement). Tailnet SSH continues to work because tailscale0 traffic uses the WireGuard data plane; the cloud firewall filters only public-interface ingress.

Verify the perimeter is closed:
```
ssh -o ConnectTimeout=5 deploy@<public-ip>
```
Expected: connection times out or is refused. (Tailnet `ssh deploy@<hostname>` should still work.)

If this fails: confirm `cf-base-default` exists (`hcloud firewall list`) and the server name resolves (`hcloud server list`). The cloud firewall apply is reversible with `hcloud firewall remove-from-resource cf-base-default --type server --server <hostname>` if you need to reopen public SSH for diagnosis.

---

## Step 9: Run the post-install hardening script

**Goal:** apply UFW firewall policy, enable fail2ban, enable unattended-upgrades. The cloud firewall (Step 8) already closed the perimeter; this step adds the host-level UFW backstop and brings up the post-install services.

From your active tailnet SSH session (from Step 6):
```
sudo /opt/cf-base/post-install.sh
```

Expected: completes in approximately 30-60 seconds. All output is logged to both the console and `/var/log/cf-base-post-install.log`.

After this script completes:
- UFW is active with deny-incoming default.
- Only tailscale0-sourced connections on 22/tcp and 60000-61000/udp are permitted.
- Public ingress is zero. Tailnet is the only remaining path in.

If this fails: check `/var/log/cf-base-post-install.log` for the `FAILED at line` message. The script is idempotent — if it aborted mid-run, re-running it after fixing the cause is safe. The sentinel (`/var/lib/cf-base/post-install.done`) is only written on successful completion; its absence means the script can be re-run.

---

## Step 10: Run the J02 post-install + hardening checklist

**Goal:** verify all hardening expectations, including the critical public-IP ingress check.

Execute every item in `docs/journeys/J02-post-install-hardening.md` against the live host. Do not declare the host ready until all items pass.

The journey file is the authoritative checklist. Key items include:
- The Hetzner Cloud Firewall (`cf-base-default`) is applied (Step 8) — verify with `hcloud server describe <hostname> | grep Firewall`.
- UFW status shows the expected rules (Step 9).
- **Public-IP ingress check:** from your laptop (no need to leave tailnet), `ssh -o ConnectTimeout=5 deploy@<public-ip>` times out or is refused. Both layers deny: cloud firewall at the network edge (packet doesn't reach the host), UFW as host backstop (defense in depth). Use `hcloud server describe <hostname>` to look up the public IP.
- Existing tailnet SSH session remains responsive throughout the check.
- `fail2ban` and `unattended-upgrades` services are active.
- `/cf-cc` invoked in a Claude Code session as the deploy user generates `/home/deploy/.claude/CLAUDE.md`.

If any J02 item fails: the host is not hardened. Do not use it as a production host until all items pass.

---

## Public port exposure (Docker bypasses UFW)

**Important: Docker manipulates iptables independently of UFW.** Containers started with `-p 80:80` (binding to `0.0.0.0`) become publicly reachable regardless of `ufw default deny incoming`. Future service specs (Specs C, D, E) that run public-facing containers must choose one of the following:

- **Option A (recommended):** bind containers to `127.0.0.1`; put a host reverse proxy (Caddy/nginx) on `0.0.0.0:80/443`; UFW gates the proxy port:
  ```
  docker run -p 127.0.0.1:3000:3000 myapp
  ```
- **Option B:** bind containers to the tailscale IP; unreachable publicly:
  ```
  docker run -p 100.x.x.x:8080:8080 myapp
  ```
- **Option C:** allow Docker to own iptables; never bind to `0.0.0.0` you do not intend public.

cf-base itself does not expose any public ports beyond SSH-via-tailscale. This section exists so the operator and downstream service specs are aware of the layering.

---

## Step 11: Final disposition

**Goal:** either delete the proof host (if this was a test run) or retain it as the intended production/dev host.

### If this is a proof run

```
hcloud server delete <hostname>
```

Expected: server deleted; Hetzner billing stops. The Tailscale node will be automatically removed from the tailnet (ephemeral key behavior). Only the git artifacts persist — they are the canonical baseline.

### If this is a production or development host

Keep the server. It is ready to receive whatever services you intend to layer on top — install application packages, drop docker-compose files, configure systemd units, etc. cf-base has done its job.

Update the host's `hostname` in your records and confirm the tailnet admin console shows it as a persistent (non-ephemeral) node if you intend it to persist across reboots. Note: ephemeral auth keys cause the tailnet node to be removed when the host shuts down — if that is not desired for a persistent host, reprovision with a non-ephemeral key or re-authenticate via `tailscale up` after the fact.

---

## Appendix: Diagnostic quick reference

| Symptom | First check |
|---|---|
| Node not in tailnet after 5 min | `sudo cat /var/log/cf-base-firstboot.log` on host via public IP SSH |
| `ssh deploy@<hostname>` refused via tailnet | `tailscale status` on laptop; confirm node in admin console |
| post-install.sh errors | `sudo cat /var/log/cf-base-post-install.log` |
| UFW locked operator out | Hetzner console (emergency access) → add a temporary tailnet0-bypass rule: `sudo ufw insert 1 allow from <your-public-ip>/32 to any port 22 proto tcp comment 'TEMP recovery'`. Remove the rule after recovery: `sudo ufw status numbered`, then `sudo ufw delete <num>`. Avoid `sudo ufw disable` — that drops the host firewall entirely, including the tailscale0 rules, leaving the host wide open until UFW is re-enabled. |
| firstboot.sh needs to re-run | Remove sentinel: `sudo rm /var/lib/cf-base/firstboot.done`, then re-run |
| post-install.sh needs to re-run | Remove sentinel: `sudo rm /var/lib/cf-base/post-install.done`, then re-run |

### `/opt/cf-base/tailscale-authkey` left on disk after partial firstboot

If firstboot.sh fails between `tailscale up` (step 8) and the unlink (step 9), the auth key file remains on disk. The file is mode 0600 root:root (deploy user cannot read it). The key is reusable but already consumed by the successful `tailscale up` call — if extracted, it could register an additional node on the tailnet, so the cleanup is worthwhile. To clean up manually: `sudo rm -f /opt/cf-base/tailscale-authkey`. The next firstboot run (after sentinel removal — `sudo rm /var/lib/cf-base/firstboot.done`) can reuse the same auth key (reusable key) or a freshly generated one.

---

## References

- Cloud-init canonical docs: https://docs.cloud-init.io/en/latest/
- Hetzner basic-cloud-config tutorial: https://community.hetzner.com/tutorials/basic-cloud-config
- Tailscale auth keys: https://tailscale.com/kb/1085/auth-keys
- Tailscale ACL samples (server-to-laptop egress restriction and more): https://tailscale.com/kb/1192/acl-samples
- Hetzner Cloud Firewall docs: https://docs.hetzner.com/cloud/firewalls/getting-started/
