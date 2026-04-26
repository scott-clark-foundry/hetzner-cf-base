#!/usr/bin/env bash
# build.sh — assemble cloud-init/base.yaml from base.yaml.in + standalone source files
#
# Usage: ./cloud-init/build.sh  (run from repo root or from cloud-init/)
#
# Design:
#   base.yaml.in is the template. Three placeholder markers are replaced by
#   external content:
#     __INCLUDE_FIRSTBOOT_SH__       ← cloud-init/firstboot.sh
#     __INCLUDE_POST_INSTALL_SH__    ← cloud-init/post-install.sh
#     __INCLUDE_OPERATOR_PUBKEYS__   ← cloud-init/operator-pubkeys.txt
#
#   firstboot.sh and post-install.sh are spliced as YAML block-scalar
#   content (6-space body indent under `content: |`). operator-pubkeys.txt
#   is spliced as YAML list items (`      - <key>`); blank and #-comment
#   lines are skipped.
#
#   Idempotent: re-running with unchanged inputs produces byte-identical output.

set -euo pipefail
cd "$(dirname "$0")/.."

IN=cloud-init/base.yaml.in
OUT=cloud-init/base.yaml
PUBKEYS=cloud-init/operator-pubkeys.txt

if [[ ! -f "$PUBKEYS" ]]; then
    cat >&2 <<EOF
ERROR: $PUBKEYS not found.

Copy cloud-init/operator-pubkeys.txt.example to $PUBKEYS and replace the
example line with your SSH public key(s) — one per line. The file is
gitignored so your real key never enters git history.

    cp cloud-init/operator-pubkeys.txt.example $PUBKEYS
    \$EDITOR $PUBKEYS

Then re-run this script.
EOF
    exit 2
fi

awk '
    /__INCLUDE_FIRSTBOOT_SH__/      { while ((getline line < "cloud-init/firstboot.sh")    > 0) { printf "      %s\n", line }; close("cloud-init/firstboot.sh");          next }
    /__INCLUDE_POST_INSTALL_SH__/   { while ((getline line < "cloud-init/post-install.sh") > 0) { printf "      %s\n", line }; close("cloud-init/post-install.sh");       next }
    /__INCLUDE_OPERATOR_PUBKEYS__/  { while ((getline line < "cloud-init/operator-pubkeys.txt") > 0) {
                                        sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
                                        if (line == "" || line ~ /^#/) continue
                                        printf "      - %s\n", line
                                      }; close("cloud-init/operator-pubkeys.txt"); next }
    { print }
' "$IN" > "$OUT"

python3 -c "import yaml; yaml.safe_load(open('$OUT'))" || { echo "ERROR: generated $OUT does not parse as valid YAML" >&2; exit 1; }

# Sanity check: at least one ssh_authorized_keys entry made it in.
if ! python3 -c "
import sys, yaml
d = yaml.safe_load(open('$OUT'))
keys = d.get('users', [{}])[0].get('ssh_authorized_keys', [])
sys.exit(0 if len(keys) >= 1 else 1)
"; then
    echo "ERROR: generated $OUT has no ssh_authorized_keys entries — check $PUBKEYS" >&2
    exit 1
fi

echo "build.sh: $OUT generated and YAML-validated OK"
