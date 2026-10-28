#!/usr/bin/env bash
# Destroy and undefine libvirt VMs and delete all their storage (virsh --remove-all-storage),
# including attached media such as a sushy-tools virtual media ISO. Leftover
# <VMFOLDER>/<vmname>.qcow2 and <vmname>-extra-disk-*.qcow2 files are removed as well.
set -euo pipefail
BASEDIR="$(dirname "$0")"
# shellcheck source=common.sh
source "${BASEDIR}/common.sh"

usage() {
  cat <<EOF
Usage: $0 [-f <variables_file>] [-y|--yes] <vmname> [<vmname> ...]

  -f         Variables file (default: ${BASEDIR}/.env if present), for VMFOLDER
  -y, --yes  Do not ask for confirmation
EOF
}

ENVFILE=""
YES=false
VMS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f) [[ $# -ge 2 ]] || { usage; exit 2; }; ENVFILE="$2"; shift 2 ;;
    -y|--yes) YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; VMS+=("$@"); break ;;
    -*) usage; exit 2 ;;
    *) VMS+=("$1"); shift ;;
  esac
done
[[ ${#VMS[@]} -gt 0 ]] || { usage; exit 2; }

load_env "$ENVFILE"
VMFOLDER="${VMFOLDER:-/var/lib/libvirt/images}"
require virsh

leftover_disks() {
  local disk
  for disk in "${VMFOLDER}/$1.qcow2" "${VMFOLDER}/$1"-extra-disk-*.qcow2; do
    [[ -f "$disk" ]] && echo "$disk"
  done
  return 0
}

if [[ "$YES" != true ]]; then
  echo "The following VMs and storage will be deleted:"
  for VMNAME in "${VMS[@]}"; do
    attached=""
    if vm_exists "$VMNAME"; then
      echo "  ${VMNAME}"
      attached="$(virsh domblklist "$VMNAME" --details | awk 'NR > 2 && $4 != "-" && NF {print $2 " " $4}')"
      [[ -z "$attached" ]] || awk '{print "    " $1 ": " $2}' <<<"$attached"
    else
      echo "  ${VMNAME} (VM not found)"
    fi
    leftover_disks "$VMNAME" | { grep -vxF -f <(awk '{print $2}' <<<"$attached") || true; } | sed 's/^/    file: /'
  done
  read -r -p "Continue? [y/N] " answer || answer=""
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] || die "Aborted" 1
fi

# --remove-all-storage only deletes volumes libvirt knows about; refresh the pools so
# disks created with qemu-img (e.g. in the default pool directory) are found
for pool in $(virsh pool-list --name); do
  virsh pool-refresh "$pool" >/dev/null
done

for VMNAME in "${VMS[@]}"; do
  if vm_exists "$VMNAME"; then
    if [[ "$(virsh domstate "$VMNAME" 2>/dev/null)" != "shut off" ]]; then
      virsh destroy "$VMNAME" >/dev/null
    fi
    virsh undefine "$VMNAME" --nvram --remove-all-storage
  else
    echo "VM ${VMNAME} not found"
  fi

  # Disks outside any storage pool are only reported by virsh, not removed
  while read -r disk; do
    rm -f "$disk"
    echo "Deleted ${disk}"
  done < <(leftover_disks "$VMNAME")
done
