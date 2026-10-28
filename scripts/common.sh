#!/usr/bin/env bash
# Shared helpers for the libvirt VM scripts. Sourced, not executed.
# Based on https://github.com/suse-edge/misc/tree/main/slemicro (libvirt only).

# sushy-tools talks to qemu:///system; plain virsh as non-root would use the session URI
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

die() {
  echo "ERROR: $1" >&2
  exit "${2:-1}"
}

require() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "$c not found" 2
  done
}

# Source the variables file: -f argument, else <scriptdir>/.env if present.
load_env() {
  local f="${1:-${BASEDIR}/.env}"
  if [[ -f "$f" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$f"
    set +a
  elif [[ -n "${1:-}" ]]; then
    die "Variables file $1 not found" 2
  fi
}

# Precedence: command line > variables file > defaults
set_defaults() {
  VMNAME="${OPT_VMNAME:-${VMNAME:-}}"
  VMFOLDER="${VMFOLDER:-/var/lib/libvirt/images}"
  CPUS="${OPT_CPUS:-${CPUS:-2}}"
  MEMORY="${OPT_MEMORY:-${MEMORY:-4096}}"
  DISKSIZE="${OPT_DISKSIZE:-${DISKSIZE:-}}"
  MACADDRESS="${OPT_MACADDRESS:-${MACADDRESS:-}}"
  EXTRADISKS="${OPT_EXTRADISKS:-${EXTRADISKS:-}}"
  VM_NETWORK="${VM_NETWORK:-default}"
  OSINFO="${OSINFO:-sle-unknown}"
  LIBVIRT_DISK_SETTINGS="${LIBVIRT_DISK_SETTINGS:-bus=virtio}"

  [[ -n "$VMNAME" ]] || die "VM name required (-n or VMNAME)" 2
  [[ "$CPUS" =~ ^[0-9]+$ ]] || die "CPUS must be a number: $CPUS" 2
  [[ "$MEMORY" =~ ^[0-9]+$ ]] || die "MEMORY must be a number (MiB): $MEMORY" 2
  [[ -z "$DISKSIZE" || "$DISKSIZE" =~ ^[0-9]+$ ]] || die "Disk size must be a number (GB): $DISKSIZE" 2
  [[ -z "$EXTRADISKS" || "$EXTRADISKS" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "EXTRADISKS must be a comma separated list of sizes in GB: $EXTRADISKS" 2
  if [[ -z "$MACADDRESS" ]]; then
    MACADDRESS="$(generate_mac)"
  fi
  [[ "$MACADDRESS" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || die "Invalid MAC address: $MACADDRESS" 2
}

# Random MAC with the QEMU/KVM OUI
generate_mac() {
  local octets
  read -r -a octets < <(od -An -N3 -tx1 /dev/urandom)
  printf '52:54:00:%s:%s:%s\n' "${octets[@]}"
}

vm_exists() {
  virsh dominfo "$1" >/dev/null 2>&1
}

check_new_vm() {
  require virsh virt-install qemu-img
  vm_exists "$VMNAME" && die "VM $VMNAME already exists" 2
  [[ -e "${VMFOLDER}/${VMNAME}.qcow2" ]] && die "Disk ${VMFOLDER}/${VMNAME}.qcow2 already exists (leftover? run delete_vm.sh ${VMNAME})" 2
  mkdir -p "$VMFOLDER"
}

extra_disk_path() {
  echo "${VMFOLDER}/${VMNAME}-extra-disk-$1.qcow2"
}

create_extra_disks() {
  local i=0 size
  [[ -n "$EXTRADISKS" ]] || return 0
  for size in ${EXTRADISKS//,/ }; do
    qemu-img create -q -f qcow2 "$(extra_disk_path "$i")" "${size}G"
    i=$((i + 1))
  done
}

# $1: start the VM after defining it (true|false)
create_vm() {
  local start="${1:-true}" i=0 size xml
  local disks=(--disk "path=${VMFOLDER}/${VMNAME}.qcow2,format=qcow2,${LIBVIRT_DISK_SETTINGS}")
  for size in ${EXTRADISKS//,/ }; do
    disks+=(--disk "path=$(extra_disk_path "$i"),format=qcow2,${LIBVIRT_DISK_SETTINGS}")
    i=$((i + 1))
  done

  # Define first, start later: virt-install has no "define only" mode besides --print-xml.
  # --events: older virt-install emits on_reboot=destroy, which powers the VM off on the
  # first reboot (https://bugzilla.redhat.com/show_bug.cgi?id=1792411)
  xml="$(mktemp)"
  virt-install --name "$VMNAME" \
    --memory "$MEMORY" \
    --vcpus "$CPUS" \
    --cpu host-passthrough \
    "${disks[@]}" \
    --import \
    --network "network=${VM_NETWORK},model=virtio,mac=${MACADDRESS}" \
    --osinfo "$OSINFO" \
    --boot uefi \
    --rng /dev/urandom \
    --sound none \
    --events on_reboot=restart \
    --print-xml >"$xml"
  virsh define "$xml" >/dev/null
  rm -f "$xml"
  echo "VM ${VMNAME} defined (MAC ${MACADDRESS})"

  [[ "$start" == true ]] || return 0
  virsh start "$VMNAME" >/dev/null
  echo "VM ${VMNAME} started. Serial console: virsh console ${VMNAME}"
}

# Prints the first IPv4 address of the VM from the DHCP leases (empty if none)
vm_ip() {
  virsh domifaddr "$1" --source lease 2>/dev/null | awk '/ipv4/ {split($4, a, "/"); print a[1]; exit}'
}

# $1: VM name, $2: timeout in seconds
wait_for_ip() {
  local count=0 ip=""
  echo -n "Waiting for IP: " >&2
  while [[ -z "$ip" && $count -lt ${2:-180} ]]; do
    sleep 1
    count=$((count + 1))
    echo -n "." >&2
    ip="$(vm_ip "$1")"
  done
  echo >&2
  echo "$ip"
}
