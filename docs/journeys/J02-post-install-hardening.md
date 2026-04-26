# J02 — Manual post-install + hardening

## Pre-conditions

J01 complete, operator has an active tailnet SSH session.

## Steps

- [ ] `sudo /opt/cf-base/post-install.sh` runs to completion
- [ ] `/var/lib/cf-base/post-install.done` exists
- [ ] `sudo ufw status verbose` shows deny incoming, allow outgoing, tailscale0 rules for 22/tcp + 60000-61000/udp
- [ ] From your laptop (no need to leave tailnet): `ssh -o ConnectTimeout=5 deploy@<public-ip>` times out or is refused. UFW denies the packet because it arrives on the public interface, not `tailscale0` — laptop tailnet membership is irrelevant to this check.
- [ ] Existing tailnet SSH session still responsive
- [ ] `systemctl is-active fail2ban` = active; `fail2ban-client status sshd` shows the jail
- [ ] `systemctl is-active unattended-upgrades` = active
- [ ] `ls /home/deploy/.claude/skills/cf-cc/SKILL.md` exists (fetched from pinned tag by post-install.sh)
- [ ] In claude-code on the host, `/cf-cc` generates `/home/deploy/.claude/CLAUDE.md` reflecting current host state
- [ ] `hcloud server delete <proof-hostname>` — proof complete

**Pass criterion:** All checklist items satisfied. Capture verification output (commands and their results) in the session log.
