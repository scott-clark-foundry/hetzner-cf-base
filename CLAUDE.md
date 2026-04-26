# CLAUDE.md — hetzner-cf-base

## Purpose

cf-base is a reusable Hetzner baseline server configuration: cloud-init
template, firstboot/post-install shell scripts, per-host user-data
template, and a `cf-cc` Claude Code skill that provisioned hosts use to
generate their own deploy-user `CLAUDE.md`. Anyone can clone, drop their
SSH pubkey, and provision a hardened tailnet-joined Ubuntu 24.04 host.

## Where things live

- **Operator entry point:** [`README.md`](README.md) — prerequisites + 9-step Quickstart.
- **Full provisioning runbook:** [`docs/runbook-provision.md`](docs/runbook-provision.md) — pre-flight, every step expanded, diagnostic appendix.
- **Canonical design (the why):** [`docs/specs/2026-04-24-cf-base-design.md`](docs/specs/2026-04-24-cf-base-design.md).
- **Operational rationale (apt-key fingerprints, PAM gotcha, 32 KiB ceiling, etc.):** [`cloud-init/RATIONALE.md`](cloud-init/RATIONALE.md).
- **Verification journeys:** [`docs/journeys/J01-firstboot-tailnet.md`](docs/journeys/J01-firstboot-tailnet.md), [`docs/journeys/J02-post-install-hardening.md`](docs/journeys/J02-post-install-hardening.md).

## Load-bearing invariants

These hold across the project. Don't break them, and flag if a change
proposes to.

1. **`cloud-init/base.yaml` is gitignored.** It is a *built artifact* generated locally from `base.yaml.in` + `operator-pubkeys.txt`. Never `git add` it, never commit it, never propose tracking it. Each operator builds their own with their own pubkey.
2. **`cloud-init/operator-pubkeys.txt` is gitignored.** Operator's actual SSH public key(s); never enters git history. Only the `.example` template is tracked.
3. **`sandbox/` (if present) is gitignored.** Local iteration scratch, not project artifacts.
4. **The cf-cc skill is fetched from a tag and verified by SHA256.** `cloud-init/post-install.sh` curls `SKILL.md` from `https://raw.githubusercontent.com/scott-clark-foundry/hetzner-cf-base/<CF_CC_SKILL_TAG>/skills/cf-cc/SKILL.md` and then verifies its sha256 against the baked-in `CF_CC_SKILL_SHA256`. **The tag is mutable** (anyone with push access can re-point it); the sha256 check is what actually guarantees the skill body executed under passwordless sudo on every cf-base host hasn't been tampered with. Moving or deleting the tag breaks new provisions; tampering with skill content while leaving the tag alone fails the sha256 check at provision time. **Bumping SKILL.md = compute new sha256 + update `CF_CC_SKILL_SHA256` in `post-install.sh` + create a new tag + update `CF_CC_SKILL_TAG` default — all in one commit.**
5. **`./cloud-init/build.sh` is the only correct way to regenerate `base.yaml`.** Run it after any edit to `base.yaml.in`, `firstboot.sh`, `post-install.sh`, or `operator-pubkeys.txt`. Hand-editing `base.yaml` is wasted work — the next `build.sh` overwrites it.
6. **Combining `base.yaml` with a per-host overlay uses `python3 cloud-init/merge.py`, never `cat`.** Two `#cloud-config` shebangs in one file are read as a single YAML document; the overlay's `write_files:` clobbers the base's under "last key wins" and the host boots without firstboot.sh / post-install.sh / any other system file. The runbook spells this out; resist any "simpler with cat" suggestions.
7. **Hetzner user-data ceiling is 32 KiB raw.** gzip+base64 wrapping is silently dropped. If `base.yaml` approaches 32 KiB, externalize content (the `cf-cc` skill is the existing precedent — see `post-install.sh` step 7) rather than compress.
8. **`runuser -u deploy --` is required, not `sudo -u deploy`.** PAM password-aging on root in Hetzner Ubuntu 24.04 cloud images blocks `sudo -u OTHER_USER` from cloud-init's TTY-less runcmd context. RATIONALE.md captures this in detail.

## Project posture

- **Stand-alone, public-portfolio-quality.** No references to other projects, internal hostnames, operator-specific paths, or cross-repo coupling. If a change introduces such a reference, scrub it.
- **Don't pitch config-management CLIs / framework abstractions.** cf-base is intentionally minimal — `hcloud` CLI + cloud-init + a Python merge helper. Re-evaluate scale only if host count exceeds ~5.
- **Don't add features the spec doesn't call for.** The non-goals list in the spec is load-bearing.

## Status

Released. Tag `cf-base-v1` is the current `cf-cc` skill source, paired
with the `CF_CC_SKILL_SHA256` value baked into `cloud-init/post-install.sh`.
The repo's `main` may move ahead of `cf-base-v1` for doc/script changes
without retagging — the tag plus its expected sha256 specifically
identify the SKILL.md that `post-install.sh` will install on a new host,
not the latest revision of the repo.
