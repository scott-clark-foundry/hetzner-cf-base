#!/usr/bin/env bash
# firstboot.sh — cf-base first-boot provisioning. See cloud-init/RATIONALE.md.

set -euo pipefail
trap 'echo "[cf-base firstboot] FAILED at line $LINENO (exit $?)" >&2' ERR

exec > >(tee -a /var/log/cf-base-firstboot.log) 2>&1

echo "[cf-base firstboot] $(date -u '+%Y-%m-%dT%H:%M:%SZ') — starting"

mkdir -p /var/lib/cf-base
if [[ -f /var/lib/cf-base/firstboot.done ]]; then
    echo "[cf-base firstboot] sentinel found — already complete, exiting 0"
    exit 0
fi

# Vendor installer pinning: where upstream supports a version-pinned URL
# (uv) or version arg (bun), use it so a re-provision months later gets
# the same binary as today's. Pinning does NOT defend against vendor
# compromise — the vendor publishes both the bad installer and the matching
# binary — but it does defend against a vendor pushing a malicious update
# to the *latest* endpoint while leaving historic releases alone, which
# is the more common compromise pattern.
#
# claude.ai/install.sh has no version-pinned URL surface — accept this
# residual curl|bash dependency on Anthropic's distribution channel.
# Operators concerned about it can substitute a different install method.

UV_VERSION=0.11.7
BUN_VERSION=1.3.13

echo "[cf-base firstboot] step 2 — installing uv ${UV_VERSION} under deploy user"
runuser -u deploy -- bash -c "
    set -euo pipefail
    curl -LsSf https://astral.sh/uv/${UV_VERSION}/install.sh | sh
"
echo "[cf-base firstboot] step 2 — uv installed"

echo "[cf-base firstboot] step 3 — installing Claude Code under deploy user"
runuser -u deploy -- bash -c '
    set -euo pipefail
    curl -fsSL https://claude.ai/install.sh | bash
'
echo "[cf-base firstboot] step 3 — Claude Code installed"

echo "[cf-base firstboot] step 4 — installing bun v${BUN_VERSION} under deploy user"
runuser -u deploy -- bash -c "
    set -euo pipefail
    curl -fsSL https://bun.sh/install | bash -s 'bun-v${BUN_VERSION}'
    mkdir -p \"\$HOME/.local/bin\"
    ln -sf \"\$HOME/.bun/bin/bun\"  \"\$HOME/.local/bin/bun\"
    ln -sf \"\$HOME/.bun/bin/bunx\" \"\$HOME/.local/bin/bunx\"
"
echo "[cf-base firstboot] step 4 — bun installed"

echo "[cf-base firstboot] step 5 — aliasing fdfind to fd in /home/deploy/.bashrc"
if ! grep -qF 'alias fd=fdfind' /home/deploy/.bashrc; then
    echo "alias fd=fdfind" >> /home/deploy/.bashrc
fi
echo "[cf-base firstboot] step 5 — fd alias in place"

echo "[cf-base firstboot] step 6 — reading tailscale auth key"
TAILSCALE_AUTHKEY="$(cat /opt/cf-base/tailscale-authkey)"
if [[ -z "${TAILSCALE_AUTHKEY}" ]]; then
    echo "[cf-base firstboot] ERROR: /opt/cf-base/tailscale-authkey is empty" >&2
    exit 1
fi
echo "[cf-base firstboot] step 6 — tailscale auth key read"

echo "[cf-base firstboot] step 7 — joining tailnet"
tailscale up --authkey="${TAILSCALE_AUTHKEY}" --accept-routes --advertise-tags=tag:server
unset TAILSCALE_AUTHKEY
echo "[cf-base firstboot] step 7 — tailnet joined"

echo "[cf-base firstboot] step 8 — unlinking tailscale auth key"
rm -f /opt/cf-base/tailscale-authkey
echo "[cf-base firstboot] step 8 — auth key unlinked"

# Scrub the consumed Tailscale auth key from cloud-init's persisted user-data
# cache. cloud-init writes user-data verbatim to /var/lib/cloud/instance/user-data.txt
# (mode 0600 root) and keeps it forever — it's exposed via the metadata service
# and survives reboots. We've already consumed the key in step 7; redact it
# here so it doesn't outlive the boot window. Targeted sed (rather than
# shred -u) preserves the rest of the file in case cloud-init re-reads it.
USER_DATA_CACHE=/var/lib/cloud/instance/user-data.txt
if [[ -f "${USER_DATA_CACHE}" ]]; then
    sed -i 's|tskey-auth-[A-Za-z0-9_-]*|<REDACTED>|g' "${USER_DATA_CACHE}"
    echo "[cf-base firstboot] step 8 — auth key scrubbed from cloud-init user-data cache"
fi

touch /var/lib/cf-base/firstboot.done
echo "[cf-base firstboot] step 9 — sentinel written: /var/lib/cf-base/firstboot.done"

echo "[cf-base firstboot] $(date -u '+%Y-%m-%dT%H:%M:%SZ') — complete"
