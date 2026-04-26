#!/usr/bin/env python3
"""merge.py — combine cloud-init/base.yaml + a per-host overlay into a provision file.

`cat cloud-init/base.yaml user-data/<host>.yaml` does NOT work. Two `#cloud-config`
shebangs in one file are read as a single YAML document by every YAML parser; the
overlay's top-level keys collide with the base's under "last key wins" semantics,
and cloud-init's default merge strategy for lists is `replace`. Concretely: the
overlay's `write_files: [tailscale-authkey]` clobbers the base's
`write_files: [firstboot.sh, post-install.sh, …]` and the host boots without any
of the system files.

This helper does the merge cloud-init's documentation implies but doesn't actually
deliver: scalars from the overlay override the base; `write_files` lists
concatenate; everything else takes the overlay's value.

Usage:
    python3 cloud-init/merge.py user-data/<host>.yaml > /tmp/<host>.yaml

Run from the repo root (the script reads cloud-init/base.yaml relative to cwd).
"""
import pathlib
import sys
import yaml


def merge(base: dict, overlay: dict) -> dict:
    # Shallow-copy `base` and explicitly copy any list values we'll mutate,
    # so the merge doesn't accidentally extend the caller's `base` in place.
    out = dict(base)
    for k, v in overlay.items():
        if k == "write_files" and isinstance(v, list):
            out["write_files"] = list(out.get("write_files") or []) + v
        else:
            out[k] = v
    return out


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: merge.py <overlay.yaml>", file=sys.stderr)
        return 2
    overlay_path = pathlib.Path(sys.argv[1])
    base_path = pathlib.Path("cloud-init/base.yaml")
    if not base_path.exists():
        print(f"error: {base_path} not found (run from repo root)", file=sys.stderr)
        return 2
    base = yaml.safe_load(base_path.read_text())
    overlay = yaml.safe_load(overlay_path.read_text())
    merged = merge(base, overlay)

    # Self-check: assert no write_files entries silently dropped. If the merge
    # logic ever regresses (or someone restores the cat-merge bug), this fires
    # before a broken provision file reaches hcloud server create.
    base_count = len(base.get("write_files", []) or [])
    overlay_count = len(overlay.get("write_files", []) or [])
    merged_count = len(merged.get("write_files", []) or [])
    if merged_count != base_count + overlay_count:
        print(
            f"error: write_files length mismatch — base has {base_count}, "
            f"overlay has {overlay_count}, merged has {merged_count} "
            f"(expected {base_count + overlay_count})",
            file=sys.stderr,
        )
        return 1

    sys.stdout.write("#cloud-config\n")
    yaml.dump(merged, sys.stdout, default_flow_style=False, sort_keys=False, width=4096)
    return 0


if __name__ == "__main__":
    sys.exit(main())
