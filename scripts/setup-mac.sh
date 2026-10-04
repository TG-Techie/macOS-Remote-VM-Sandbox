#!/bin/zsh
# Sets up vm-sandbox on a Mac in one command, run by its owner from this repo:
#
#   scripts/setup-mac.sh --from VM.tar.gz [--vms DIR]   use a VM packed on another Mac
#   scripts/setup-mac.sh --fresh NAME [--vms DIR]       install macOS into a new VM, then open its window
#
# Both build and ad-hoc sign vmsandbox first. Everything stays inside this folder: the build in dist/, and the restore image, VMs and
# snapshots in vms/ (git-ignored), unless --vms DIR says otherwise.
# --fresh downloads the newest restore image this Mac supports (about 15-20 GB) and opens the VM's
# window for Setup Assistant: create admin/admin and turn on Remote Login (docs/setup.md, step 4).
set -euo pipefail
cd "${0:A:h}/.."
from= fresh= vms=$PWD/vms
while (( $# )); do
  case $1 in
    --from) from=${2:A}; shift 2 ;;
    --fresh) fresh=$2; shift 2 ;;
    --vms) vms=${2:A}; shift 2 ;;
    *) echo "unknown option $1; see the top of $0" >&2; exit 2 ;;
  esac
done
[[ -n $from$fresh && -z ${from:+$fresh} ]] || { echo "give exactly one of --from VM.tar.gz or --fresh NAME" >&2; exit 2 }

scripts/build.sh
scripts/sign.sh >/dev/null
mkdir -p "$vms"
xattr -w 'com.apple.fileprovider.ignore#P' 1 "$vms"   # never synced, wherever it is

if [[ -n $from ]]; then
  name=$(tar -tzf "$from" | head -1) name=${name%%/*}
  [[ $name == *.vmbundle ]] || { echo "$from doesn't hold a .vmbundle" >&2; exit 1 }
  [[ ! -e $vms/$name ]] || { echo "$vms/$name already exists; move it aside first" >&2; exit 1 }
  echo "unpacking $name into $vms"
  tar -C "$vms" -xzf "$from"
  bundle=$vms/$name
  # Verify before offering to free the archive's space: every file is there and the config reads.
  for f in config.json aux.img disk.img; do
    [[ -s $bundle/$f ]] || { echo "unpacked VM is missing $f; keeping $from" >&2; exit 1 }
  done
  plutil -convert xml1 -o /dev/null "$bundle/config.json" || { echo "unpacked config.json doesn't parse; keeping $from" >&2; exit 1 }
  if read -q "?Unpacked and verified. Delete $from to free its space? [y/N] "; then
    echo; rm -f "$from" && echo "deleted $from"
  else
    echo; echo "kept $from"
  fi
else
  bundle=$vms/$fresh.vmbundle
  # First setup runs faster with more memory: half the Mac's RAM, between 4 and 16 GiB. Later boots
  # choose their own with run --memory-gb.
  setup_gb=$(( $(sysctl -n hw.memsize) / 2 / 1024**3 ))
  (( setup_gb < 4 )) && setup_gb=4
  (( setup_gb > 16 )) && setup_gb=16
  if [[ -f $bundle/config.json ]]; then
    # Rerunning after an install reopens the window. A failed install shows up as a failed boot;
    # then delete the bundle and run this again.
    echo "$bundle is already installed; opening its window"
  else
    url=$(dist/vmsandbox ipsw-url | sed 's/.*: //')
    ipsw=$vms/${url:t}
    if [[ ! -f $ipsw ]]; then
      curl -fL -C - -o "$ipsw.partial" "$url"
      mv -f "$ipsw.partial" "$ipsw"
    fi
    dist/vmsandbox create "$bundle" --ipsw "$ipsw" --memory-gb $setup_gb
  fi
  echo "Opening the VM's window. In Setup Assistant create user admin, password admin, then in"
  echo "System Settings > General > Sharing turn on Remote Login. Leave the window open and run,"
  echo "in another terminal in this folder:  scripts/finalize-mac.sh $fresh"
  mkdir -p "$vms/empty-share"
  exec dist/vmsandbox run "$bundle" --share "$vms/empty-share" --memory-gb $setup_gb --gui
fi

echo
echo "Ready. Run it with your project shared and the RAM you want, for example:"
echo "  dist/vmsandbox run $bundle --share /path/to/project --memory-gb 4"
echo "MCP is then at http://127.0.0.1:8765/mcp on this Mac only."
