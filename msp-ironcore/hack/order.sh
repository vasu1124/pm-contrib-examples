#!/usr/bin/env bash
# hack/order.sh — owner: ironcore-expert
# Apply the IronCore resource order into the kcp consumer workspace.
# Reads env vars exported by Taskfile.yml; do NOT hardcode paths or workspace names.
# Idempotent: kubectl apply is a no-op when the resource is already current.
set -euo pipefail

: "${PM_KUBECONFIG:?PM_KUBECONFIG must be set}"
: "${CONSUMER_WS:?CONSUMER_WS must be set}"
: "${TASKFILE_DIR:?TASKFILE_DIR must be set}"
# kcp >= 0.31's `kubectl ws` requires a leading ':' for absolute paths. Accept both 'root:...'
# and ':root:...' forms.
CONSUMER_WS=":${CONSUMER_WS#:}"

# Use the pinned kcp kubectl-ws plugin from bin/ (same pattern as syncagent-kubeconfig.sh).
export PATH="${TASKFILE_DIR}/bin:${PATH}"

MANIFEST="${TASKFILE_DIR}/config/samples/order-machine.yaml"

echo "==> Switching to consumer workspace: ${CONSUMER_WS}"
# kubectl-ws is a plugin; flags cannot precede the plugin name — pass kubeconfig via env.
KUBECONFIG="${PM_KUBECONFIG}" kubectl ws "${CONSUMER_WS}"

echo "==> Applying IronCore resource order from ${MANIFEST}..."
kubectl --kubeconfig "${PM_KUBECONFIG}" apply -f "${MANIFEST}"

echo "==> Order submitted. IronCore resources are now in workspace ${CONSUMER_WS}."
echo "    api-syncagent will sync them to the ironcore-in-a-box cluster; watch with:"
echo "    kubectl --kubeconfig \"\${PM_KUBECONFIG}\" get machines.compute.ironcore.dev -n default -w"
