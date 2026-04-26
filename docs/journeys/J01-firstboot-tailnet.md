# J01 — Automatic firstboot + tailnet

## Pre-conditions

- Reusable, tagged (`tag:server`), pre-authorized, non-ephemeral Tailscale auth key from the admin console (see runbook for ACL pre-flight)
- `user-data/<proof-hostname>.yaml` copied from `template.yaml` with hostname + auth key filled in
- Operator's SSH public key in `cloud-init/base.yaml`

## Steps

- [ ] `hcloud server create --image ubuntu-24.04 --location hel1 --type cpx32 --name <proof-hostname> --user-data-from-file user-data/<proof-hostname>.yaml`
- [ ] Wait 2-5 minutes for provision + cloud-init
- [ ] Tailscale admin console shows the new node
- [ ] `ssh deploy@<proof-hostname>` over tailnet succeeds
- [ ] `/var/lib/cf-base/firstboot.done` exists
- [ ] `which uv && which claude && which node && which bun && which rg` all succeed (uv + claude under `~/.local/bin`; bun symlinked into `~/.local/bin` by firstboot.sh; node + rg system-installed)
- [ ] `type fd` reports `fd is aliased to 'fdfind'` (`fd` is an alias defined in deploy's `~/.bashrc`, not a binary on PATH; `which fd` will not see it)
- [ ] `docker ps` succeeds as deploy user
- [ ] `sudo -n true` succeeds (passwordless sudo)
- [ ] `ls /opt/cf-base/tailscale-authkey` does NOT exist

**Pass criterion:** All checklist items satisfied. Capture verification output (commands and their results) in the session log.
