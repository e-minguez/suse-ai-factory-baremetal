#!/usr/bin/env bash
# Create and start a libvirt VM from a raw/qcow2 OS image (e.g. the quickstart
# Elemental image for the management nodes). The image is copied, not modified.
set -euo pipefail
BASEDIR="$(dirname "$0")"
# shellcheck source=common.sh
source "${BASEDIR}/common.sh"

usage() {
  cat <<EOF
Usage: $0 -n <vmname> -i <image> [-s <disk_GB>] [-m <mac>] [-c <cpus>] [-M <memory_MiB>]
          [-e <extra_disks_GB,...>] [-f <variables_file>] [-o]

  -i  Source image, raw or qcow2
  -s  Grow the disk to this size in GB (default: image size)
  -m  MAC address (default: random 52:54:00:xx:xx:xx)
  -e  Extra empty disks, comma separated sizes in GB (e.g. 50,50)
  -f  Variables file (default: ${BASEDIR}/.env if present)
  -o  Define the VM but leave it powered off
EOF
}

ENVFILE=""
IMAGE=""
START=true
while getopts 'f:n:i:s:m:c:M:e:oh' OPTION; do
  case "$OPTION" in
    f) ENVFILE="$OPTARG" ;;
    n) OPT_VMNAME="$OPTARG" ;;
    i) IMAGE="$OPTARG" ;;
    s) OPT_DISKSIZE="$OPTARG" ;;
    m) OPT_MACADDRESS="$OPTARG" ;;
    c) OPT_CPUS="$OPTARG" ;;
    M) OPT_MEMORY="$OPTARG" ;;
    e) OPT_EXTRADISKS="$OPTARG" ;;
    o) START=false ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n "$IMAGE" ]] || { usage; die "-i <image> required" 2; }
[[ -f "$IMAGE" ]] || die "Image $IMAGE not found" 2

load_env "$ENVFILE"
set_defaults
check_new_vm

DISK="${VMFOLDER}/${VMNAME}.qcow2"
qemu-img convert -p -O qcow2 "$IMAGE" "$DISK"
# The Elemental root partition grows to fill the disk on first boot, so resize before booting
if [[ -n "$DISKSIZE" ]]; then
  qemu-img resize -q "$DISK" "${DISKSIZE}G"
fi
create_extra_disks
create_vm "$START"

if [[ "$START" == true ]]; then
  VMIP="$(wait_for_ip "$VMNAME" 180)"
  echo "VM IP: ${VMIP:-not found (check: virsh domifaddr ${VMNAME})}"
fi
