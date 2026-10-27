#!/usr/bin/env bash
# Brute-force teardown of the demo cluster and all BMHs (lab only).
# Strips finalizers, deletes Ironic nodes, restarts metal3 controllers.
# Re-apply the BMH manifests afterwards to re-register the hosts.
set -uo pipefail

NS=default
IRONIC="kubectl exec -n metal3-system deploy/metal3-metal3-ironic -c ironic -- curl -sk -H Content-Type:application/json -H X-OpenStack-Ironic-API-Version:1.81"

nuke() {
  local r o
  for r in "$@"; do
    for o in $(kubectl get "$r" -n "$NS" -o name 2>/dev/null); do
      kubectl patch "$o" -n "$NS" --type merge -p '{"metadata":{"finalizers":null}}'
      kubectl delete "$o" -n "$NS" --wait=false --ignore-not-found
    done
  done
}

echo "== CAPI / CAPM3 / CAPRKE2 objects"
nuke \
  clusters.cluster.x-k8s.io \
  machinedeployments.cluster.x-k8s.io \
  machinesets.cluster.x-k8s.io \
  machines.cluster.x-k8s.io \
  rke2controlplanes.controlplane.cluster.x-k8s.io \
  rke2configs.bootstrap.cluster.x-k8s.io \
  rke2configtemplates.bootstrap.cluster.x-k8s.io \
  metal3clusters.infrastructure.cluster.x-k8s.io \
  metal3machines.infrastructure.cluster.x-k8s.io \
  metal3machinetemplates.infrastructure.cluster.x-k8s.io \
  metal3dataclaims.infrastructure.cluster.x-k8s.io \
  metal3datas.infrastructure.cluster.x-k8s.io \
  metal3datatemplates.infrastructure.cluster.x-k8s.io

echo "== BMHs and companion objects"
nuke \
  baremetalhosts.metal3.io \
  hardwaredata.metal3.io \
  hostfirmwaresettings.metal3.io \
  hostfirmwarecomponents.metal3.io \
  bmceventsubscriptions.metal3.io \
  preprovisioningimages.metal3.io \
  dataimages.metal3.io

echo "== Ironic nodes"
for u in $($IRONIC 'https://localhost:6385/v1/nodes?fields=uuid' | grep -o -E '"uuid": *"[^"]*"' | cut -d'"' -f4); do
  $IRONIC -X PUT -d '{"reason":"cleanup"}' "https://localhost:6385/v1/nodes/$u/maintenance" -o /dev/null -w "maintenance $u %{http_code}\n"
  $IRONIC -X DELETE "https://localhost:6385/v1/nodes/$u" -o /dev/null -w "delete $u %{http_code}\n"
done

echo "== restart controllers"
kubectl rollout restart -n metal3-system deploy/baremetal-operator-controller-manager deploy/metal3-metal3-ironic
kubectl rollout restart -n capm3-system deploy/capm3-controller-manager
kubectl rollout status -n metal3-system deploy/metal3-metal3-ironic --timeout=180s

echo "== leftovers (should be empty)"
kubectl get cluster,machines,metal3machines,bmh -n "$NS" 2>&1
$IRONIC https://localhost:6385/v1/nodes
echo
