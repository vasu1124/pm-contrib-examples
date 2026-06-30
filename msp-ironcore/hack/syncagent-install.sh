#!/usr/bin/env bash
# hack/syncagent-install.sh — owner: syncagent-expert
# Helm-install (or upgrade) the kcp api-syncagent into the ironcore-in-a-box kind cluster and wait
# until Ready. Idempotent: `helm upgrade --install` converges; the repo add uses --force-update.
#
# Reads env vars exported by Taskfile.yml; do NOT hardcode versions or paths:
#   KIND_KUBECONFIG, KIND_CLUSTER, SYNCAGENT_VERSION, TASKFILE_DIR
#
# DYNAMIC hostAlias IP (portability): the agent Pod must resolve root.kcp.localhost (cluster A's only
# SNI-routed name) to the host-gateway where cluster A's :8443 is published. On Docker Desktop that
# gateway is host.docker.internal's in-node IPv4 — commonly 192.168.65.254, but it varies by machine
# / DD version. We resolve it at install time from INSIDE the kind node and override the hostAliases
# IP from config/syncagent/values.yaml via --set, so the example is portable without manual
# IP-hunting. Falls back to 192.168.65.254 (the proven DD value, also the values.yaml default) if
# resolution fails. NB: the `kind` bridge gateway (172.18.0.1) does NOT work — A's :8443 is published
# on host loopback, unreachable via the bridge interface.
#
# Prereq (ordering): syncagent:kubeconfig has already created Secret `kcp-kubeconfig` in ns
# kcp-system (mounted into the agent Pod); kind:up created the node container
# `${KIND_CLUSTER}-control-plane`.
set -euo pipefail

: "${KIND_KUBECONFIG:?KIND_KUBECONFIG must be set}"
: "${KIND_CLUSTER:?KIND_CLUSTER must be set}"
: "${SYNCAGENT_VERSION:?SYNCAGENT_VERSION must be set}"
: "${TASKFILE_DIR:?TASKFILE_DIR must be set}"

VALUES="${TASKFILE_DIR}/config/syncagent/values.yaml"
RELEASE="kcp-api-syncagent"
FALLBACK_IP="192.168.65.254"   # proven Docker Desktop host-gateway; mirrors the values.yaml default
NODE="${KIND_CLUSTER}-control-plane"

# Resolve the host-gateway IP that root.kcp.localhost must point at, from inside the kind node.
# `getent ahostsv4` forces IPv4 (host.docker.internal can also yield IPv6). Best-effort: the agent's
# kubeconfig uses insecure-skip-tls-verify, so only reachability (not the exact IP) matters.
HOSTGW_IP="$(docker exec "${NODE}" getent ahostsv4 host.docker.internal 2>/dev/null | awk '{print $1; exit}' || true)"
if [ -n "${HOSTGW_IP}" ]; then
  echo "==> Resolved host.docker.internal in ${NODE} -> ${HOSTGW_IP} (hostAlias for root.kcp.localhost)"
else
  HOSTGW_IP="${FALLBACK_IP}"
  echo "==> Could not resolve host.docker.internal in ${NODE}; falling back to ${HOSTGW_IP}"
fi

echo "==> Ensuring kcp Helm repo is present and up to date"
helm repo add kcp https://kcp-dev.github.io/helm-charts --force-update >/dev/null
helm repo update >/dev/null

echo "==> helm upgrade --install ${RELEASE} kcp/api-syncagent --version ${SYNCAGENT_VERSION}"
# --set overrides the values.yaml hostAlias IP with the per-host resolved value (both ip and the
# hostname are pinned so the element is fully specified regardless of helm list-merge semantics).
helm upgrade --install "${RELEASE}" kcp/api-syncagent \
  --version "${SYNCAGENT_VERSION}" \
  --kubeconfig "${KIND_KUBECONFIG}" \
  --namespace kcp-system --create-namespace \
  --values "${VALUES}" \
  --set "hostAliases.enabled=true" \
  --set "hostAliases.values[0].ip=${HOSTGW_IP}" \
  --wait --timeout 180s

echo "==> Waiting for the api-syncagent Deployment to be Ready"
kubectl --kubeconfig "${KIND_KUBECONFIG}" -n kcp-system \
  rollout status "deploy/${RELEASE}" --timeout=180s

echo "==> api-syncagent ${SYNCAGENT_VERSION} installed and Ready (hostAlias root.kcp.localhost -> ${HOSTGW_IP})."
