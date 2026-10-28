# Elemental3 + Metal3 HA cluster

3 control-plane + 2 worker RKE2 cluster on sushy-tools emulated BMHs.
OS image built with Elemental3 (raw, split mode); users/SSH keys come from
CAPRKE2 Ignition via the metal3 config drive, not from the image.

BMC emulation: sushy-tools on the hypervisor, see [sushy.md](sushy.md)
(`--net host`, `SUSHY_EMULATOR_IGNORE_BOOT_DEVICE = False`).

## Repository layout

| Path | Content |
|---|---|
| `image/install.yaml` | Elemental install config: grub, kernel cmdline (`ignition.platform.id=openstack`, consoles), raw disk size |
| `image/release.yaml` | Release manifest (`aif-uc-release-manifest:2.3.1`) and the `suse-storage` systemd extension (open-iscsi for SUSE Storage) |
| `bmh/vm-*.yaml` | BMC Secret + BareMetalHost per VM |
| `cluster/00-cluster.yaml` | `Cluster` + `Metal3Cluster` (API VIP `192.168.122.20`) |
| `cluster/10-controlplane.yaml` | `RKE2ControlPlane` (3 replicas, Butane, MetalLB/endpoint-copier VIP manifests) + Metal3 templates |
| `cluster/20-workers.yaml` | `MachineDeployment` (2 replicas) + `RKE2ConfigTemplate` + Metal3 templates |
| `scripts/teardown.sh` | Brute-force cleanup of the cluster, BMHs and Ironic nodes (lab only) |
| `scripts/create_vm_with_image.sh` | Create and start a libvirt VM from an OS image (management nodes) |
| `scripts/create_empty_vm.sh` | Create a powered-off libvirt VM with empty disks (BMHs) |
| `scripts/delete_vm.sh` | Destroy/undefine VMs and delete their disks |
| `scripts/common.sh`, `scripts/vm.env.example` | Shared helpers and optional variables for the VM scripts |
| `sushy.md` | sushy-tools (Redfish BMC emulator) setup on the hypervisor |

## Hypervisor VMs

The `scripts/*_vm*.sh` scripts (libvirt only, adapted from
[suse-edge/misc](https://github.com/suse-edge/misc/tree/main/slemicro)) run on the
hypervisor against `qemu:///system`, the URI sushy-tools uses. They need
`virt-install`, `virsh` and `qemu-img`, and write disks to `VMFOLDER`
(default `/var/lib/libvirt/images`, so run them as root). VMs are UEFI,
virtio disk/NIC, `host-passthrough` CPU. Defaults and variables:
`scripts/vm.env.example`; run any script with `-h` for the flags. Sizes below are
examples.

Management nodes from the quickstart raw image (`-s` grows the disk before the
first boot, see [Management cluster](#management-cluster)):

```bash
for i in 1 2 3; do
  scripts/create_vm_with_image.sh -n mgmt0$i -m 52:54:00:00:00:0$i \
    -i elemental.raw -s 100 -c 4 -M 16384
done
```

BMH VMs, powered off with empty disks; the MACs must match `bootMACAddress` in
`bmh/vm-*.yaml`. sushy-tools adds the virtual media cdrom itself:

```bash
for i in 1 2 3; do scripts/create_empty_vm.sh -n vm-cp-0$i -m 52:54:00:00:00:1$i -s 60 -c 4 -M 8192; done
for i in 1 2; do scripts/create_empty_vm.sh -n vm-wk-0$i -m 52:54:00:00:00:2$i -s 100 -c 4 -M 8192; done
```

Delete (only `<name>.qcow2` and `<name>-extra-disk-*.qcow2` in `VMFOLDER` are removed):

```bash
scripts/delete_vm.sh vm-cp-01 vm-cp-02 vm-cp-03 vm-wk-01 vm-wk-02
```

## Management cluster

Created with [quickstart.ai.suse.com](https://quickstart.ai.suse.com) (Elemental
image, SUSE AI Factory). Configuration used:

| Setting | Value |
|---|---|
| Topology | Multi-node HA: 3 control-plane + 0 workers |
| Nodes | `mgmt01` (init), `mgmt02`, `mgmt03`: role `server`, DHCP; MACs `52:54:00:00:00:01..03` (each node picks hostname/role from its MAC on first boot) |
| API VIP / hostname | `192.168.122.10` / `api-192-168-122-10.sslip.io` |
| Ingress IP | `192.168.122.11` |
| Rancher URL | `https://rancher-192-168-122-11.sslip.io` |
| Rancher bootstrap password | `<RANCHER_BOOTSTRAP_PASSWORD>` |
| root password / SSH keys | `<ROOT_PASSWORD>` / `<SSH_PUBLIC_KEY>` |
| Extra user / password / SSH keys | `<USERNAME>` / `<USER_PASSWORD>` / `<SSH_PUBLIC_KEY>` |
| Image type / size | raw, 12 GB (`diskSize` in `install.yaml`) |
| SUSE Application Collection | `<APPCO_USER>` / `<APPCO_TOKEN>` |
| SUSE Registry | `regcode` / `<REGISTRATION_CODE>` |
| NVIDIA NGC | `$oauthtoken` / `<NGC_API_KEY>` (GPU operator not included) |
| Components | cert-manager, SUSE Rancher Prime, SUSE AI Factory 2.3.1 (release manifest `oci://ghcr.io/suse/aif-uc-release-manifest:2.3.1`), SUSE Storage, Traefik ingress |

The raw image is 12 GB on purpose: the root partition grows on first boot to fill
the disk, so resize the disk on the hypervisor before booting
(`qemu-img resize`, ideally after converting to qcow2). Booting it as-is leaves a
12 GB root; 100 GB or more is recommended for SUSE AI.

### Metal3 and CAPI providers

Added on top of the quickstart cluster, following the
[SUSE Telco Metal3 quickstart](https://documentation.suse.com/suse-telco/3.7/html/telco/quickstart-metal3.html)
(chart versions from the SUSE Telco 3.7 release notes). Rancher 2.15 already
ships the Turtles operator; MetalLB is needed to expose Ironic on a fixed IP.

1. **MetalLB pool for the Ironic IP** (skip if an existing pool already serves
   `192.168.122.12`; it must not overlap the API VIP/ingress IPs or the
   downstream VIP `192.168.122.20`):

   ```yaml
   apiVersion: metallb.io/v1beta1
   kind: IPAddressPool
   metadata:
     name: ironic-ip-pool
     namespace: metallb-system
   spec:
     addresses:
       - 192.168.122.12/32
     serviceAllocation:
       priority: 100
       namespaces:
         - metal3-system
   ---
   apiVersion: metallb.io/v1beta1
   kind: L2Advertisement
   metadata:
     name: ironic-ip-pool-l2-adv
     namespace: metallb-system
   spec:
     ipAddressPools:
       - ironic-ip-pool
   ```

2. **Metal3** (Ironic + baremetal-operator), values used:

   ```yaml
   # metal3-values.yaml
   global:
     ironicIP: 192.168.122.12
     enable_vmedia_tls: false   # Ironic serves the IPA ISO over http://<ironicIP>:6180
   ```

   ```bash
   helm install metal3 oci://registry.suse.com/edge/charts/metal3 \
     --version 307.0.31+up0.16.0 \
     --namespace metal3-system --create-namespace \
     -f metal3-values.yaml
   ```

3. **CAPI providers** (core CAPI, RKE2 bootstrap/control plane, Metal3 + IPAM,
   created as `CAPIProvider` resources for the Turtles operator). Installed
   with the chart defaults (no custom values):

   ```bash
   helm install rancher-turtles-providers oci://registry.suse.com/edge/charts/rancher-turtles-providers \
     --version 307.0.8+up0.27.0 \
     --namespace cattle-turtles-system --create-namespace
   ```

   The chart must match the Rancher version, see
   [Management cluster versions](#0-management-cluster-versions).

Check:

```bash
kubectl get svc -n metal3-system          # Ironic service EXTERNAL-IP 192.168.122.12
kubectl get pods -n metal3-system
kubectl get capiprovider -A               # all Ready
```

The installed values can be read back without `helm` from the release secret:

```bash
S=$(kubectl get secret -n metal3-system -l owner=helm,name=metal3 -o name | sort -V | tail -1)
kubectl get -n metal3-system $S -o jsonpath='{.data.release}' | base64 -d | base64 -d | gunzip | jq .config
```

## 0. Management cluster versions

Manifests use CAPI `v1beta2` and target SUSE Telco 3.7. Rancher ≥ 2.13 embeds the
Turtles operator, but the CAPI providers (RKE2 bootstrap/control plane, Metal3) come
from the separate `rancher-turtles-providers` chart, which creates `CAPIProvider`
resources. Rancher must match that chart:

| Component | Version |
|---|---|
| Rancher | 2.15.1 (embeds Turtles v0.27.x) |
| rancher-turtles-providers chart | 307.0.8+up0.27.0 |
| CAPI core | v1.13.3 |
| CAPRKE2 (bootstrap/control-plane) | v0.25.0 |
| CAPM3 | v1.13.2 |
| RKE2 (validated) | v1.36.3+rke2r1 |

With an older Rancher (e.g. 2.14.x / Turtles 0.26.3), Turtles' automatic update
rewrites the RKE2 `CAPIProvider` version to one it knows (v0.24.4). The chart only
ships v0.25.0 component ConfigMaps, so the providers stay `Pending` with
`unable to get files for version v0.24.4`, and applying the cluster fails with
`rke2controlplanes.controlplane.cluster.x-k8s.io not found`. Fix: upgrade Rancher.

Upgrading Rancher does not reset the stale `spec.version` on the RKE2 providers;
patch it back to the chart version:

```bash
for p in rke2-bootstrap-system/rke2-bootstrap rke2-control-plane-system/rke2-control-plane; do
  kubectl patch capiprovider -n ${p%/*} ${p#*/} --type merge -p '{"spec":{"version":"v0.25.0"}}'
done
```

The core `cluster-api` provider moves to v1.13.3 once the embedded `rancher-turtles`
app finishes upgrading (it can sit in `pending-upgrade` for a few minutes).

```bash
kubectl get capiprovider -A   # all should be Ready
```

Installation: see [Metal3 and CAPI providers](#metal3-and-capi-providers).

## 1. Build image

```bash
podman run --rm --privileged \
  -v $PWD/image:/config \
  -v /run/podman/podman.sock:/var/run/docker.sock \
  registry.suse.com/elemental/elemental:3.0 \
  customize --type raw --mode split --output /config/elemental.raw
```

Elemental writes `elemental.raw.sha256` next to the image.

`--output` is a path inside the container: use `/config/...` so it lands in the
mounted directory (a relative name stays in the container). A fixed name keeps the
manifest URLs stable across rebuilds. The generated `-config/` dir is not used:
users, files and units come from the CAPRKE2 Butane in `cluster/`. That also
means `network/` content (nmstate files, `configure-network.sh`) never runs on
the nodes in this flow (see [Known issues](#known-issues)).

`image/release.yaml` adds the `suse-storage` systemd extension (open-iscsi under
`/usr`); the `iscsi-prep.service` in the Butane seeds `/etc/iscsi` and starts
`iscsid` on every boot.

Serve both files over HTTP on the hypervisor, reachable from the Ironic pod and
the VMs (see Troubleshooting), e.g.:

```bash
cd image && python3 -m http.server 8000
```

`image.url` / `image.checksum` in **both** `Metal3MachineTemplate`s
(`cluster/10-controlplane.yaml`, `cluster/20-workers.yaml`) point to
`http://192.168.122.1:8000/elemental.raw` and `elemental.raw.sha256`.

## 2. BMHs

Label control-plane hosts `cluster-role: control-plane` (vm-cp-01..03) and
worker hosts `cluster-role: worker` (vm-wk-01..02). Wait until all are `available`.

Set `rootDeviceHints` on every BMH. Without it the BMO uses the `unknown`
hardware profile default `deviceName: /dev/sda`, but libvirt virtio disks are
`/dev/vda`, so the deploy fails (see Troubleshooting). Check the inspected disk
name first:

```bash
kubectl get bmh vm-cp-01 -o jsonpath='{range .status.hardware.storage[*]}{.name}{" "}{.sizeBytes}{" "}{.type}{"\n"}{end}'
```

Disk cleaning: the `Metal3MachineTemplate`s set `automatedCleaningMode: disabled`
(CAPM3 copies it to the claimed BMH), so deprovisioning is just power off + eject.
The default `metadata` cleaning boots IPA via virtual media, adding minutes per
(de)provision. Use `metadata` on real hardware.

Manifests: `bmh/vm-*.yaml` (Secret + BMH per VM; `bmc.address` is the sushy-tools
Redfish endpoint). Set the Secret `username`/`password` to the sushy-tools
credentials (placeholder `admin`/`admin`) and check the MACs:

```bash
for v in vm-cp-01 vm-cp-02 vm-cp-03 vm-wk-01 vm-wk-02; do echo "$v $(virsh domiflist $v | awk '/network/{print $5}')"; done
kubectl apply -f bmh/
watch kubectl get bmh      # registering -> inspecting -> available
```

## 3. Fill placeholders

- Butane users in `cluster/10-controlplane.yaml` and `cluster/20-workers.yaml`
  (both files): `<ROOT_PASSWORD_HASH>`, `<USERNAME>`, `<USER_PASSWORD_HASH>`
  (`openssl passwd -6`), `<SSH_PUBLIC_KEY>`
- RKE2 `version` (control plane and MachineDeployment)
- VIP `192.168.122.20`: must be outside libvirt DHCP range and the management MetalLB pool

## 4. Deploy

```bash
kubectl apply -f cluster/
clusterctl describe cluster demo
kubectl get bmh -w
clusterctl get kubeconfig demo > demo.kubeconfig
```

## Next steps

The downstream cluster is up and, through the
`cluster-api.cattle.io/rancher-auto-import: "true"` label, imported into Rancher
by Turtles. Everything above the base cluster should therefore be delivered as
workloads through **Fleet** (Rancher Continuous Delivery) instead of being baked
into the image or the CAPI manifests:

- **NVIDIA GPU Operator**: not part of this setup (the management cluster config
  above has it disabled and the VMs have no GPUs). Needs GPU passthrough to the
  worker VMs (or real hardware), then deploy the operator to the downstream
  cluster with a Fleet bundle.
- **SUSE Storage**: the nodes already carry the `suse-storage` systemd extension
  and `iscsi-prep.service` (open-iscsi); the storage stack itself still has to be
  deployed.
- **SUSE AI components** on top (charts from the SUSE Application Collection,
  which needs registry credentials on the downstream cluster).

Outline of a Fleet `GitRepo` targeting the downstream cluster (created in the
`fleet-default` workspace on the management cluster):

```yaml
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: demo-addons
  namespace: fleet-default
spec:
  repo: https://github.com/<org>/<repo>
  branch: main
  paths:
    - gpu-operator
  targets:
    - clusterName: <rancher-cluster-name-of-demo>   # check: kubectl get clusters.fleet.cattle.io -n fleet-default
```

with a `gpu-operator/fleet.yaml` in that repo, e.g.:

```yaml
defaultNamespace: gpu-operator
helm:
  repo: https://helm.ngc.nvidia.com/nvidia
  chart: gpu-operator
  version: <version>        # pick the one validated for the SUSE AI release
  values: {}                # driver/toolkit settings depend on the OS (SLES 16) and whether drivers are preinstalled
```

Not validated yet: chart version and values for SLES 16 nodes, how the imported
cluster is named/labelled in Fleet, and registry credentials for SUSE images.

## Starting over

`scripts/teardown.sh` removes everything in the `default` namespace without
waiting on Ironic: strips finalizers and deletes the CAPI/CAPM3/CAPRKE2 objects,
the BMHs and their companion objects, deletes all Ironic nodes and restarts the
BMO, Ironic and CAPM3. Lab only.

```bash
scp scripts/teardown.sh mgmt01:
ssh mgmt01 bash teardown.sh
# optional, on the hypervisor
for v in vm-cp-01 vm-cp-02 vm-cp-03 vm-wk-01 vm-wk-02; do virsh destroy $v; done
kubectl apply -f bmh/      # re-register, wait for 'available'
kubectl apply -f cluster/
```

The clean way (delete the `Cluster`, wait for deprovisioning, then delete the
templates) also works now that sushy honours boot devices and cleaning is
disabled.

## Known issues

- **No static networking / OS hostname from Elemental:** with `--mode split`
  Elemental puts `network/` (incl. `configure-network.sh`) into the separate
  `-config/` directory, which only the Elemental firstboot (initrd) consumes.
  The Metal3 flow only attaches Ironic's `config-2` drive, so the script never
  runs: nodes use plain DHCP. Hostnames are set by `rke2-preinstall` instead
  (BMH name, see [Node names](#node-names--hostnames)). Use libvirt DHCP host
  entries for stable IPs.
- **MetalLB VIP manifests race their CRDs:** `kubernetes-vip.yaml` contains the
  MetalLB HelmChart *and* `IPAddressPool`/`L2Advertisement`; the first apply
  fails (`the server could not find the requested resource`) until the chart
  installs the CRDs. RKE2's deploy controller retries, so it converges.
- **Duplicate `tls-san`:** CAPRKE2 already adds the control plane endpoint;
  `serverConfig.tlsSan` repeats it (harmless).
- **RKE2 version:** manifests use `v1.35.8+rke2r1`; SUSE Telco 3.7 validates
  `v1.36.3+rke2r1`.
- **BMO occasionally misses Ironic state changes:** see the BMO restart rule in
  Troubleshooting.
- **Cookbook vs current CAPM3:** the Elemental cookbook Recipe 3 still uses
  `BAREMETALHOST_UUID`/`.uuid`; current CAPM3 needs `PROVIDERID`/`.providerid`
  (same as [telco-cloud-examples#106](https://github.com/suse-edge/telco-cloud-examples/pull/106)).
  Its `variant: flatcar` is required, not cosmetic (see Troubleshooting).

## Troubleshooting

### Inspection fails: `Virtual media mount failed ... Connection refused`

sushy-tools (in a podman container on the hypervisor) cannot fetch the boot ISO
from Ironic (`http://<ironic-ip>:6180/redfish/boot-*.iso`), although `curl` from the
hypervisor works.

Cause: the container is on the podman bridge (`10.88.0.0/16`, sushy logs show
`10.88.0.1` as client), so its traffic is *forwarded* into `virbr0`. libvirt's NAT
rules reject non-established forwarded traffic with `icmp-port-unreachable`,
which Python reports as `Errno 111`.

```bash
podman exec sushy-emulator python3 -c "import requests; print(requests.get('http://<ironic-ip>:6180/redfish/', timeout=5))"
iptables -nvL LIBVIRT_FWI 2>/dev/null || nft list table ip libvirt_network   # REJECT counter grows
```

Fix: run sushy-tools with `--net host` (see [sushy.md](sushy.md)). Alternative (lost on libvirt reload):
`iptables -I LIBVIRT_FWI -s 10.88.0.0/16 -d 192.168.122.0/24 -o virbr0 -j ACCEPT`.

### Cleaning/redeploy hangs: VM boots the installed OS instead of IPA

Symptoms: first inspection and first deploy work, but later cleaning
(`clean wait`) or redeploy (`wait call-back`) never progress. The VM reboots
into the previously installed OS (Elemental login), no IPA heartbeats in the
Ironic log, sushy shows `InsertMedia` + `Reset` with `204`. Ironic logs
`Inserted boot media ...` and `set to one time boot from cdrom`.

Check the domain on the hypervisor:

```bash
virsh dumpxml vm-cp-01 | grep -E "<boot|boot order"
```

`<boot dev='fd'/>` under `<os>` means sushy-tools runs with
`SUSHY_EMULATOR_IGNORE_BOOT_DEVICE = True`: it ignores Ironic's boot device
requests, so UEFI falls back to its own order. With an empty disk it reaches the
CD (IPA works); once an OS is on the disk, it boots the disk and IPA never starts.

Fix: set `SUSHY_EMULATOR_IGNORE_BOOT_DEVICE = False` in the sushy-tools config
([sushy.md](sushy.md)) and restart the container. Afterwards the cdrom gets a per-device `<boot order='1'/>`
during IPA boots.

Hosts already stuck: abort the operation in Ironic (`{"target":"abort"}` for
`clean wait`), restart the BMO; if the BMH still does not move, retry cleaning
with `manage` then `provide` (same `PUT .../states/provision` call).

### `rke2controlplanes.controlplane.cluster.x-k8s.io not found` / RKE2 providers `Pending`

See [section 0](#0-management-cluster-versions): Rancher too old for the providers
chart, or stale `spec.version` on the `CAPIProvider` after upgrading Rancher.

```bash
kubectl get capiprovider -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,VER:.spec.version,AUTO:.spec.enableAutomaticUpdate
kubectl get cm -A -l provider-components -L provider-components   # versions actually shipped
```

### `strict decoding error: unknown field ...` on apply

Manifests are CAPI/CAPRKE2 `v1beta2`. Differences from `v1beta1` (and from some docs):

| v1beta1 / docs | v1beta2 |
|---|---|
| refs with `apiVersion:` | refs with `apiGroup:` |
| `RKE2ControlPlane.spec.infrastructureRef` | `spec.machineTemplate.spec.infrastructureRef` |
| `RKE2ConfigTemplate ... agentConfig.version` | removed; version from `MachineDeployment.spec.template.spec.version` |
| `Metal3Cluster.spec.noCloudProvider: true` | `spec.cloudProviderEnabled: false` |
| `MachineDeployment ... nodeDrainTimeout: 0s` | `spec.template.spec.deletion.nodeDrainTimeoutSeconds: 0` |
| kubelet `provider-id=metal3://BAREMETALHOST_UUID` (`.uuid`) | `provider-id=metal3://PROVIDERID`, filled from `.providerid` in `meta_data.json` (`metal3://<ns>/<bmh>/<m3m>`, sed with `_` delimiter); same change as [telco-cloud-examples#106](https://github.com/suse-edge/telco-cloud-examples/pull/106). The Elemental cookbook Recipe 3 still uses the old form |

Check a field against the installed CRD:

```bash
kubectl explain rke2controlplane.spec.machineTemplate --api-version=controlplane.cluster.x-k8s.io/v1beta2
```

Make sure the copy you apply is the current one (`grep -h '^apiVersion' cluster/*.yaml | sort -u`
should only show `v1beta2`).

### `error parsing Butane config ... storage.filesystems.N: duplicate entry defined`

Butane allows a single `storage.filesystems` entry per `device` path. All
Elemental subvolumes live on the `SYSTEM` partition, so reference it through two
different paths:

- `/opt` (`subvol=/@/opt`) via `/dev/disk/by-partlabel/SYSTEM`: replaces CAPRKE2's
  default `/opt` mount, needed by the RKE2 install script
- `/home` (`subvol=/@/home`) via `/dev/disk/by-label/SYSTEM` (filesystem label):
  needed so Ignition can create home directories for non-root users

These entries only mount during the Ignition run (no persistent mount unit
unless `with_mount_unit: true`); the image's own fstab mounts them at runtime.

### `ProvisioningError ... Validation of image href ... failed`

The image URL is fetched first by the **Ironic conductor pod** (validation/caching)
and then by IPA inside the VM, so it must be reachable from both the pod network
and the libvirt network:

```bash
kubectl exec -n metal3-system deploy/metal3-metal3-ironic -c ironic -- curl -sI <image-url>
```

### BMH stuck in `provisioning`, no error

The BMH rarely shows the real error; Ironic does. First get the Ironic node state
and the conductor log for that node:

```bash
NODE=$(kubectl get bmh <bmh> -o jsonpath='{.status.provisioning.ID}')
kubectl exec -n metal3-system deploy/metal3-metal3-ironic -c ironic -- \
  curl -sk https://localhost:6385/v1/nodes/$NODE \
  | grep -o -E '"(provision_state|target_provision_state|last_error|power_state|maintenance|reservation)": *("[^"]*"|null|true|false)'
kubectl logs -n metal3-system deploy/metal3-metal3-ironic -c ironic --since=30m \
  | grep -E "$NODE" | grep -E 'ERROR|failed|moved to provision state' | tail -20
```

`last_error: null` after `deploy failed` does not mean there was no error; the
reason is in the conductor log (use a `--since` that covers the deploy). The Ironic
API answered unauthenticated from inside the pod in this setup.

Causes seen so far:

| Conductor log / state | Section |
|---|---|
| `No suitable device was found ... 's== /dev/sda'` | [root device hint](#no-suitable-device-was-found-for-deployment-using-these-hints-name-s-devsda) |
| image/checksum download errors (check **both** `image.url` and `image.checksum`, they are independent) | [image URL/checksum](#fixing-the-image-urlchecksum-of-an-in-flight-machine) |
| `deploy failed`, BMO logs `failed but error message not available` | [stale deploy failed](#bmh-stuck-in-provisioning-failed-but-error-message-not-available) |
| `wait call-back` / `clean wait`, VM running the installed OS, no heartbeats | [sushy ignores boot device](#cleaningredeploy-hangs-vm-boots-the-installed-os-instead-of-ipa) |
| `wait call-back` with the VM off | [Machine stuck in Deleting](#machine-stuck-in-deleting-bmh-stuck-in-provisioning) |

```bash
kubectl get metal3machine -o custom-columns=NAME:.metadata.name,URL:.spec.image.url,SUM:.spec.image.checksum
```

`virsh console <vm>` on the hypervisor shows IPA progress (image download, write).

### Fixing the image URL/checksum of an in-flight Machine

Editing a `Metal3MachineTemplate` does **not** update existing `Metal3Machine`s
(they copy the image spec at creation). After fixing the template, replace the
**`Machine`** (fine before the cluster is initialized), or create a renamed
template and point the owner at it:

```bash
kubectl apply -f cluster/10-controlplane.yaml -f cluster/20-workers.yaml
kubectl get metal3machinetemplate -o custom-columns=NAME:.metadata.name,URL:.spec.template.spec.image.url,SUM:.spec.template.spec.image.checksum
kubectl get machines
kubectl delete machine <name>
```

`Metal3DataTemplate` is stricter: its `spec.metaData`/`spec.networkData` are
immutable (CAPM3 webhook rejects the update). To change them on a running
cluster, create templates under new names (data template **and** the
`Metal3MachineTemplate` referencing it) and point
`RKE2ControlPlane.spec.machineTemplate.spec.infrastructureRef.name` /
`MachineDeployment.spec.template.spec.infrastructureRef.name` at them; CAPI then
rolls the Machines one by one (`maxSurge: 0`).

Delete the `Machine`, **not** the `Metal3Machine`. Deleting only the `Metal3Machine`
leaves the `Machine` orphaned (`Provisioning` forever): CAPI won't recreate the
infra object, and the control plane won't replace a Machine that still exists.
If that happened, delete the `Machine` too.

Expected sequence after deleting the Machine (a few minutes, Ironic has to abort
the in-flight deploy first):

1. Machine `Deleting`, BMH `ONLINE` flips to `false`
2. BMH `provisioning` → `deprovisioning` (cleaning) → `available`
3. Machine disappears; RKE2ControlPlane creates a new one that claims a BMH

If it is still stuck after ~10 minutes:

```bash
kubectl describe bmh <bmh> | tail -15
kubectl logs -n capm3-system deploy/capm3-controller-manager --tail=30 | grep -i error
kubectl logs -n metal3-system deploy/metal3-metal3-ironic -c ironic --since=10m | grep -i -E 'abort|clean|error|fail' | tail -20
```

### Machine stuck in `Deleting`, BMH stuck in `provisioning`

Symptoms: Machine `Deleting` for many minutes, BMH `provisioning` with
`ONLINE false`, `spec.image` empty but `consumerRef` still set, no BMH error.
CAPM3 loops on `deprovisioning BareMetalHost, requeuing` (the
`Metal3DataClaim is not found` and `<VIP>:6443 no route to host` messages are
noise before the control plane exists).

Cause: the BMO only moves a host out of `provisioning` when Ironic finishes the
deploy. Ironic keeps it in `wait call-back` until IPA reports back (never, the VM
is powered off) or the deploy callback timeout expires (default 30 min). Even
after Ironic marks it `deploy failed`, the BMO may not reconcile again on its own.

Check the Ironic node state (node ID is `status.provisioning.ID` of the BMH):

```bash
NODE=$(kubectl get bmh <bmh> -o jsonpath='{.status.provisioning.ID}')
kubectl exec -n metal3-system deploy/metal3-metal3-ironic -c ironic -- \
  curl -sk https://localhost:6385/v1/nodes/$NODE \
  | grep -o -E '"(provision_state|target_provision_state|last_error|power_state)": *("[^"]*"|null)'
```

- `wait call-back`: wait for the timeout (≈30 min after `ProvisioningStarted`).
- `deploy failed` and BMH `spec.image` empty (Machine is being deleted): restart
  the BMO to force a reconcile. If the BMO logs `failed but error message not
  available` instead, the restart will not help, use the
  [Ironic undeploy](#bmh-stuck-in-provisioning-failed-but-error-message-not-available).

  ```bash
  kubectl rollout restart -n metal3-system deploy/baremetal-operator-controller-manager
  ```

The BMH then goes `deprovisioning` → `available`, the finalizers clear and the
Machine is replaced. Do **not** remove finalizers by hand: BMH and Ironic node
state can drift and the host will not provision cleanly again.

### `No suitable device was found for deployment using these hints {'name': 's== /dev/sda'}`

Seen in the Ironic conductor log (`Deploy step deploy.write_image failed`); the
BMH itself shows no error. IPA boots and heartbeats fine, but the root device
hint does not match: the BMO defaults to `/dev/sda` (hardware profile `unknown`)
while libvirt virtio disks are `/dev/vda`.

Fix: set `spec.rootDeviceHints.deviceName: /dev/vda` on all BMHs (see section 2).
The hint is copied into `status.provisioning.rootDeviceHints` when provisioning
starts, so a host already in `provisioning` must be released and re-claimed:
patch the BMHs, delete the `Machine`, and if the BMH stays in `provisioning` use
the Ironic undeploy from the next section.

```bash
for h in vm-cp-01 vm-cp-02 vm-cp-03 vm-wk-01 vm-wk-02; do
  kubectl patch bmh $h --type merge -p '{"spec":{"rootDeviceHints":{"deviceName":"/dev/vda"}}}'
done
```

### BMH stuck in `provisioning`: `failed but error message not available`

Symptoms: BMH `provisioning`, no error, VM powered off, no `InsertMedia`/`Reset`
in the sushy log, and Ironic only shows GETs/power-sync for the node. BMO logs:

```bash
kubectl logs -n metal3-system deploy/baremetal-operator-controller-manager --since=15m \
  | grep <bmh> | grep -v -E 'HostFirmware|BMCEventSubscription' | tail -25
```

```
provisioner.ironic  current provision state  current="deploy failed" lastError=""
provisioner.ironic  checking image settings  ... "same":true
provisioner.ironic  failed but error message not available
```

Cause: the Ironic node is in `deploy failed` with an empty `last_error` (left over
from an earlier failed attempt on that host). The BMO waits for the error message
to show up before failing the host, and since the image is unchanged it does not
redeploy, so it requeues forever. Restarting the BMO does not help.

Fix: undeploy the node in Ironic (`deploy failed` → `deleting` → `clean wait` →
`available`). What happens next depends on the BMH:

- `spec.image` still set (Machine alive): the BMO starts a fresh deploy right away.
  Fix the underlying cause first (e.g. root device hint), or it fails again.
- `spec.image` empty (Machine deleting): the BMO deprovisions and the Machine is
  replaced. If the BMH stays `provisioning` or `deprovisioning` a minute after
  Ironic reaches `available`, restart the BMO.

General rule: whenever Ironic is in a final state (`available`, `deploy failed`,
`clean failed`) but the BMH does not move for a minute or more, the BMO missed
the transition; `kubectl rollout restart -n metal3-system
deploy/baremetal-operator-controller-manager` makes it re-read the node.

The IPA console sitting at `localhost login:` with Ironic `available` is normal:
IPA stays up and keeps heartbeating (fast track) until the next operation.

```bash
NODE=$(kubectl get bmh <bmh> -o jsonpath='{.status.provisioning.ID}')
kubectl exec -n metal3-system deploy/metal3-metal3-ironic -c ironic -- \
  curl -sk -X PUT -H 'Content-Type: application/json' -H 'X-OpenStack-Ironic-API-Version: 1.81' \
  -d '{"target":"deleted"}' https://localhost:6385/v1/nodes/$NODE/states/provision -w '%{http_code}\n'
# expect 202; on 401 use the plain-text Ironic credentials from the BMO secret
```

Follow it in Ironic and sushy (cleaning, then deploy: `InsertMedia` + `Reset`):

```bash
kubectl exec -n metal3-system deploy/metal3-metal3-ironic -c ironic -- curl -sk https://localhost:6385/v1/nodes/$NODE \
  | grep -o -E '"(provision_state|last_error)": *("[^"]*"|null)'
podman logs -f sushy-emulator 2>&1 | grep -E '<system-uuid>.*(InsertMedia|Reset)'   # on the hypervisor
```

### Dracut emergency shell: `waiting for devices [/dev/disk/by-partlabel/p.lxroot ...]`

`ignition-disks.service` fails after the image is written and booted:

```
disks: createFilesystems: op(1): [failed] waiting for devices [/dev/disk/by-partlabel/p.lxroot /dev/disk/by-partlabel/SYSTEM]: device unit dev-disk-by\x2dpartlabel-p.lxroot.device timeout
```

Cause: CAPRKE2's built-in Butane template (`bootstrap/internal/ignition/butane/butane.go`)
adds `/opt` on `/dev/disk/by-partlabel/p.lxroot` (KIWI/SL Micro root partition);
Elemental 3 images use `EFI`/`RECOVERY`/`SYSTEM`. CAPRKE2's `Render()` drops that
default entry **only if `additionalUserData.config` contains the string
`variant: flatcar`**. With `variant: fcos` it is kept and Ignition waits forever.

Fix: `variant: flatcar` / `version: 1.4.0` in `additionalUserData` (as in the
Elemental cookbook), and provide `/opt` yourself (see the Butane section below).

Rescue a node already stuck in the dracut shell (lab only, lost on reboot before
Ignition completes):

```bash
systemctl start systemd-udevd.service
echo 'ENV{ID_PART_ENTRY_NAME}=="SYSTEM", SYMLINK+="disk/by-partlabel/p.lxroot"' > /etc/udev/rules.d/99-lxroot.rules
udevadm control --reload; udevadm trigger --action=change /dev/vda4 && udevadm settle
systemctl is-active 'dev-disk-by\x2dpartlabel-p.lxroot.device'   # active
systemctl reset-failed; systemctl restart ignition-disks.service
exit                                                            # continue boot
```

(the initramfs has no `head`/`tail`)

### Watching progress

`kubectl get bmh,machines,metal3machines` works, but `-w` only accepts a single
resource type. Use `watch` (or one `-w` per terminal):

```bash
watch kubectl get bmh,machines,metal3machines
```

### Node names / hostnames

Node names come from `rke2-preinstall` (`node-name: .name` from the config drive
`meta_data.json`). `.name` is rendered by CAPM3 from the `Metal3DataTemplate`
`metaData.objectNames`: `object: baremetalhost` gives the BMH name (`vm-cp-01`);
`object: machine` gives CAPI Machine names (`demo-workers-qml7w-b7dj4`). The
same unit sets the OS hostname with `hostnamectl` (validated: nodes register as
`vm-cp-01..03`/`vm-wk-01..02` with matching hostnames). The BMO also always adds
`metal3-name` (BMH name) and `metal3-namespace` to the metadata.

### Node boots but never joins

Log in via `virsh console vm-cp-0X` or SSH (root or `<USERNAME>`, from the Butane config).

Boot output: `image/install.yaml` sets `console=tty0 console=ttyS0,115200`. The
kernel logs to both; the **last** one is `/dev/console` (systemd status, dracut
emergency shell), so the rescue shell is on `virsh console`. Swap the order to get
it in virt-manager instead. For a one-off boot, press `e` in the GRUB menu and edit
the `linux` line. Don't add `loglevel=3`/`quiet` while debugging.

In the dracut emergency shell, make the journal readable and filter Ignition:

```bash
dmesg -n 1; export SYSTEMD_PAGER=cat SYSTEMD_COLORS=0; stty cols 200 rows 50
systemctl --failed --no-pager
journalctl -b --no-pager -o cat -t ignition | grep -i -E 'error|fail|critical'
lsblk -o NAME,SIZE,TYPE,PARTLABEL,LABEL,FSTYPE
grep -o -E '"device":"[^"]*"[^}]*' /run/ignition.json   # filesystems Ignition waits for
```

Once booted:

```bash
journalctl -b -u rke2-preinstall -u rke2-install -u rke2-server -u rke2-agent
cat /etc/rancher/rke2/config.yaml        # PROVIDERID replaced, node-name set?
findmnt /opt; touch /opt/.w && rm /opt/.w   # RKE2 install needs a writable /opt
k get svc kubernetes-vip -o wide          # EXTERNAL-IP 192.168.122.20 (control plane)
k -n metallb-system get pods; k -n endpoint-copier-operator get pods
```

If the VM does not boot after the image write: sushy reports Secure Boot enabled
(`DeployedMode`) on the VMs, so the Elemental image must boot via a signed shim.

Management side:

```bash
clusterctl describe cluster demo --show-conditions all
kubectl get bmh,machines,metal3machines
kubectl get secret -l cluster.x-k8s.io/cluster-name=demo   # bootstrap data generated?
```
