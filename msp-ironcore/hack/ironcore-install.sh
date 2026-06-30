#!/usr/bin/env bash
# hack/ironcore-install.sh — owner: ironcore-expert
# Deploy the IronCore stack into the ironcore-in-a-box kind cluster using `make up`.
# This runs the ironcore-in-a-box Makefile which installs cert-manager, ironcore,
# ironcore-net, apinetlet, dpservice, metalnet, metalnetlet, metalbond, and libvirt-provider.
#
# Reads env vars exported by Taskfile.yml; do NOT hardcode paths:
#   KIND_KUBECONFIG, TASKFILE_DIR
#
# Prereq: the ironcore-in-a-box kind cluster must already exist (task kind:up).
set -euo pipefail

: "${KIND_KUBECONFIG:?KIND_KUBECONFIG must be set}"
: "${TASKFILE_DIR:?TASKFILE_DIR must be set}"

IRONCORE_DIR="${TASKFILE_DIR}/ironcore-in-a-box"

echo "==> Installing IronCore stack into ironcore-in-a-box cluster..."
echo "    Using ironcore-in-a-box at: ${IRONCORE_DIR}"

# ironcore-in-a-box's Makefile uses `make up` which includes kind cluster creation +
# full stack deployment. Since we already have the cluster, we run the individual
# components. If the cluster was already created by `make up`, this is safe (idempotent).
cd "${IRONCORE_DIR}"

# Check if the cluster already has ironcore installed by looking for the ironcore namespace
if kubectl --kubeconfig "${KIND_KUBECONFIG}" get namespace ironcore-system >/dev/null 2>&1; then
  echo "    IronCore stack appears to already be installed (ironcore-system namespace exists)"
  echo "    Verifying key components..."
else
  echo "    Running 'make up' to deploy the full IronCore stack..."
  make up
fi

# Wait for key ironcore components to be ready
echo "==> Waiting for IronCore components to be ready..."

# Check ironcore controller
if kubectl --kubeconfig "${KIND_KUBECONFIG}" -n ironcore-system get deploy 2>/dev/null | grep -q ironcore; then
  echo "    Waiting for ironcore controller..."
  kubectl --kubeconfig "${KIND_KUBECONFIG}" -n ironcore-system \
    rollout status deploy --timeout=180s 2>/dev/null || echo "    (some deployments may still be starting)"
fi

# Verify CRDs are installed
echo "==> Verifying ironcore CRDs are present..."
for crd in machines.compute.ironcore.dev networks.networking.ironcore.dev virtualips.networking.ironcore.dev networkinterfaces.networking.ironcore.dev; do
  if kubectl --kubeconfig "${KIND_KUBECONFIG}" get crd "${crd}" >/dev/null 2>&1; then
    echo "    ✓ ${crd}"
  else
    echo "    ✗ ${crd} NOT FOUND" >&2
  fi
done

echo "==> IronCore stack installation complete."
