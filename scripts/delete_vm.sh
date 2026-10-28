#!/usr/bin/env bash
# Destroy and undefine libvirt VMs and delete the disks created by the create_* scripts.
# Only <VMFOLDER>/<vmname>.qcow2 and <vmname>-extra-disk-*.qcow2 are removed, never
# other attached media (e.g. the sushy-tools virtual media ISO).
set -euo pipefail
BASEDIR="$(dirname "$0")"
# shellcheck source=common.sh
source "${BASEDIR}/common.sh"

usage() {
  cat <<EOF
Usage: $0 [-f <variables_file>] <vmname> [<vmname> ...]

  -f  Variables file (default: ${BASEDIR}/.env if present), for VMFOLDER
EOF
}

ENVFILE=""
while getopts 'f:h' OPTION; do
  case "$OPTION" in
    f) ENVFILE="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -gt 0 ]] || { usage; exit 2; }

load_env "$ENVFILE"
VMFOLDER="${VMFOLDER:-/var/lib/libvirt/images}"
require virsh

for VMNAME in "$@"; do
  if vm_exists "$VMNAME"; then
    if [[ "$(virsh domstate "$VMNAME" 2>/dev/null)" != "shut off" ]]; then
      virsh destroy "$VMNAME" >/dev/null
    fi
    virsh undefine "$VMNAME" --nvram >/dev/null
    echo "VM ${VMNAME} undefined"
  else
    echo "VM ${VMNAME} not found"
  fi

  for disk in "${VMFOLDER}/${VMNAME}.qcow2" "${VMFOLDER}/${VMNAME}"-extra-disk-*.qcow2; do
    [[ -f "$disk" ]] || continue
    rm -f "$disk"
    echo "Deleted ${disk}"
  done
done
