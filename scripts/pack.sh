#!/bin/zsh
# Packs a stopped VM bundle into one file for another Mac: scripts/pack.sh BUNDLE OUT.tar.gz
# The disk is sparse, and bsdtar keeps it sparse both ways (pax format), so the archive holds
# only what the guest has written. Unpack it there with scripts/setup-mac.sh --from OUT.tar.gz.
set -euo pipefail
(( $# == 2 )) || { echo "usage: scripts/pack.sh BUNDLE OUT.tar.gz" >&2; exit 2 }
bundle=${1:A} out=${2:A}
[[ -f $bundle/config.json ]] || { echo "no VM at $bundle (missing config.json)" >&2; exit 1 }
[[ ! -e $out ]] || { echo "$out already exists" >&2; exit 1 }
# Holding the bundle's lock (the one sandbox-vm run takes) for the whole copy refuses a running VM
# and keeps one from starting mid-copy. -k keeps lockf from deleting config.json afterwards.
lockf -k -t 0 "$bundle/config.json" \
  tar --format pax -C "${bundle:h}" -czf "$out.partial" --options gzip:compression-level=1 "${bundle:t}" \
  || { rm -f "$out.partial"; echo "couldn't pack $bundle; is the VM running?" >&2; exit 1 }
mv "$out.partial" "$out"
ls -lh "$out"
