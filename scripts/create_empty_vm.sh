#!/usr/bin/env bash
# Create a powered-off libvirt VM with an empty disk (e.g. a Metal3 BareMetalHost
# behind sushy-tools). sushy-tools adds the virtual media cdrom on its own.
set -euo pipefail
BASEDIR="$(dirname "$0")"
# shellcheck source=common.sh
source "${BASEDIR}/common.sh"

usage() {
  cat <<EOF
Usage: $0 -n <vmname> [-s <disk_GB>] [-m <mac>] [-c <cpus>] [-M <memory_MiB>]
          [-e <extra_disks_GB,...>] [-f <variables_file>]

  -s  Disk size in GB (default 20)
  -m  MAC address (default: random 52:54:00:xx:xx:xx)
  -e  Extra empty disks, comma separated sizes in GB (e.g. 50,50)
  -f  Variables file (default: ${BASEDIR}/.env if present)
EOF
}

ENVFILE=""
while getopts 'f:n:s:m:c:M:e:h' OPTION; do
  case "$OPTION" in
    f) ENVFILE="$OPTARG" ;;
    n) OPT_VMNAME="$OPTARG" ;;
    s) OPT_DISKSIZE="$OPTARG" ;;
    m) OPT_MACADDRESS="$OPTARG" ;;
    c) OPT_CPUS="$OPTARG" ;;
    M) OPT_MEMORY="$OPTARG" ;;
    e) OPT_EXTRADISKS="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

load_env "$ENVFILE"
set_defaults
DISKSIZE="${DISKSIZE:-20}"
check_new_vm

qemu-img create -q -f qcow2 "${VMFOLDER}/${VMNAME}.qcow2" "${DISKSIZE}G"
create_extra_disks
create_vm false
