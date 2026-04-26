#!/usr/bin/env bash
# post-install.sh — cf-base hardening + cf-cc skill fetch. See cloud-init/RATIONALE.md.

set -euo pipefail
trap 'echo "[cf-base post-install] FAILED at line $LINENO (exit $?)" >&2' ERR

exec > >(tee -a /var/log/cf-base-post-install.log) 2>&1

echo "[cf-base post-install] $(date -u '+%Y-%m-%dT%H:%M:%SZ') — starting"

mkdir -p /var/lib/cf-base
if [[ -f /var/lib/cf-base/post-install.done ]]; then
    echo "[cf-base post-install] sentinel found — already complete, exiting 0"
    exit 0
fi

echo "[cf-base post-install] step 2 — applying UFW default policy"
ufw default deny incoming
ufw default allow outgoing
echo "[cf-base post-install] step 2 — UFW default policy applied"

echo "[cf-base post-install] step 3 — adding UFW allow rules for tailscale0"
ufw allow in on tailscale0 to any port 22 proto tcp
ufw allow in on tailscale0 to any port 60000:61000 proto udp
echo "[cf-base post-install] step 3 — UFW allow rules added"

echo "[cf-base post-install] step 4 — enabling UFW with --force"
ufw --force enable
echo "[cf-base post-install] step 4 — UFW enabled"

echo "[cf-base post-install] step 5 — enabling fail2ban"
systemctl enable --now fail2ban
echo "[cf-base post-install] step 5 — fail2ban enabled"

echo "[cf-base post-install] step 6 — enabling unattended-upgrades"
systemctl enable --now unattended-upgrades
echo "[cf-base post-install] step 6 — unattended-upgrades enabled"

CF_CC_SKILL_TAG="${CF_CC_SKILL_TAG:-cf-base-v1}"
CF_CC_SKILL_SHA256="${CF_CC_SKILL_SHA256:-4963992932ef87fc1f57e74f5c4787042714480a267bb55d635230d03d2ac8a1}"
CF_CC_SKILL_URL="https://raw.githubusercontent.com/scott-clark-foundry/hetzner-cf-base/${CF_CC_SKILL_TAG}/skills/cf-cc/SKILL.md"
SKILL_DEST=/home/deploy/.claude/skills/cf-cc/SKILL.md
echo "[cf-base post-install] step 7 — fetching cf-cc skill from ${CF_CC_SKILL_URL}"
runuser -u deploy -- mkdir -p /home/deploy/.claude/skills/cf-cc
runuser -u deploy -- curl --fail --silent --show-error --location \
    --retry 3 --retry-delay 5 \
    -o "${SKILL_DEST}" \
    "${CF_CC_SKILL_URL}"
ACTUAL_SHA="$(sha256sum "${SKILL_DEST}" | awk '{print $1}')"
if [[ "${ACTUAL_SHA}" != "${CF_CC_SKILL_SHA256}" ]]; then
    echo "[cf-base post-install] ERROR: SKILL.md sha256 mismatch — refusing to install" >&2
    echo "  url:      ${CF_CC_SKILL_URL}" >&2
    echo "  expected: ${CF_CC_SKILL_SHA256}" >&2
    echo "  got:      ${ACTUAL_SHA}" >&2
    rm -f "${SKILL_DEST}"
    exit 1
fi
chmod 0644 "${SKILL_DEST}"
chown deploy:deploy "${SKILL_DEST}"
echo "[cf-base post-install] step 7 — cf-cc skill installed (sha256 ${ACTUAL_SHA})"

touch /var/lib/cf-base/post-install.done
echo "[cf-base post-install] step 8 — sentinel written: /var/lib/cf-base/post-install.done"

echo "[cf-base post-install] $(date -u '+%Y-%m-%dT%H:%M:%SZ') — complete"
