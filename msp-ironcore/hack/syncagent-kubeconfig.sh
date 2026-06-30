#!/usr/bin/env bash
# hack/syncagent-kubeconfig.sh — owner: syncagent-expert
#
# Build the kubeconfig the api-syncagent (running INSIDE the ironcore-in-a-box kind cluster) uses
# to reach CLUSTER A's kcp, and store it as a Secret on the ironcore-in-a-box cluster. Idempotent.
#
# What it does:
#   1. Copies cluster A's admin kubeconfig ($PM_KUBECONFIG) and navigates the COPY to the provider
#      workspace ($PROVIDER_WS) with `kubectl ws` (does not disturb the shared admin kubeconfig).
#   2. Minifies+flattens it to a single self-contained cluster/context/user.
#   3. Rewrites the server to https://$KCP_EXTERNAL_HOST:$KCP_PORT/<path> (path preserved) and sets
#      insecure-skip-tls-verify: true (dropping the CA bundle) — this makes cluster A's kcp reachable,
#      and TLS acceptable, from inside the ironcore-in-a-box cluster. Final server:
#      https://root.kcp.localhost:8443/clusters/root:providers:ironcore-provider
#      ($KCP_EXTERNAL_HOST=root.kcp.localhost; see the SNI note below.)
#   4. Stores it on the ironcore-in-a-box cluster as Secret `kcp-kubeconfig` (key `kubeconfig`) in
#      ns kcp-system.
#
# Reads env vars exported by Taskfile.yml; do NOT hardcode paths/hosts/workspaces:
#   PM_KUBECONFIG, KIND_KUBECONFIG, PROVIDER_WS, KCP_EXTERNAL_HOST, KCP_PORT
#
# !! RUNTIME DEPENDENCY ON CLUSTER A — run this only AFTER cluster A is up !!
# $PM_KUBECONFIG points at the Platform Mesh local-setup admin kubeconfig
# (helm-charts/.secret/kcp/admin.kubeconfig). That file is minted by cluster A's start.sh, and the
# provider workspace ($PROVIDER_WS) is created by the provider-portal workstream. So this script
# cannot succeed until the integrator has stood up cluster A (and applied the ironcore-provider
# example-data). Inputs are read at run time; it fails loudly with guidance if cluster A is absent.
#
# !! CONNECTIVITY DEPENDENCY !!
# This script only fixes hop #1 (the bootstrap kubeconfig the agent reads). The agent then follows
# the APIExportEndpointSlice `ironcore.dev` virtual-workspace URL; cluster A's kcp advertises
# that at $KCP_EXTERNAL_HOST:$KCP_PORT (root.kcp.localhost:8443) — the same name, so both hops use it.
# root.kcp.localhost is mandatory because cluster A's Istio gateway routes by SNI and only that name
# has a TLSRoute; insecure-skip-tls-verify still sends SNI from the URL host. The agent Pod resolves
# root.kcp.localhost via the hostAliases block in config/syncagent/values.yaml (it would otherwise
# resolve to 127.0.0.1 = the pod). The A-side advertise/SNI setup is owned by provider-portal/integrator.
# Also: the admin kubeconfig at $PM_KUBECONFIG must be reachable from THIS host (where `kubectl ws`
# runs) — cluster A's gateway on 127.0.0.1:$KCP_PORT, where root.kcp.localhost resolves to loopback.
# The rewrite below pins the agent's copy to root.kcp.localhost + insecure-skip-tls-verify.
set -euo pipefail

: "${PM_KUBECONFIG:?PM_KUBECONFIG must be set}"
: "${KIND_KUBECONFIG:?KIND_KUBECONFIG must be set}"
: "${PROVIDER_WS:?PROVIDER_WS must be set}"
# kcp >= 0.31's `kubectl ws` requires a leading ':' for absolute paths. Accept both 'root:...'
# and ':root:...' forms by normalizing to exactly one leading colon.
PROVIDER_WS=":${PROVIDER_WS#:}"
: "${KCP_EXTERNAL_HOST:?KCP_EXTERNAL_HOST must be set}"
: "${TASKFILE_DIR:?TASKFILE_DIR must be set}"
# KCP_PORT is optional: when set (Taskfile exports 8443) it pins the rewritten server port; when
# unset the port is derived from cluster A's kubeconfig server URL (standalone-run fallback).
KCP_PORT="${KCP_PORT:-}"

# Fail early & clearly if cluster A's admin kubeconfig is not present yet.
if [[ ! -s "${PM_KUBECONFIG}" ]]; then
  echo "ERROR: cluster A admin kubeconfig not found at ${PM_KUBECONFIG}" >&2
  echo "       See README §\"Point at cluster A\"." >&2
  exit 1
fi

# `kubectl ws` is the kcp kubectl plugin. Prefer a bin/ copy if present, otherwise rely on the
# globally-installed plugin (the Platform Mesh local-setup requires kubectl-ws/kubectl-kcp anyway).
export PATH="${TASKFILE_DIR}/bin:${PATH}"

SNAP="$(mktemp -t kcp-syncagent-snap.XXXXXX)"
AGENT_KC="$(mktemp -t kcp-syncagent-kubeconfig.XXXXXX)"
cleanup() { rm -f "${SNAP}" "${AGENT_KC}" "${AGENT_KC}.tmp"; }
trap cleanup EXIT

echo "==> Snapshotting kcp kubeconfig and entering provider workspace: ${PROVIDER_WS}"
cp "${PM_KUBECONFIG}" "${SNAP}"
KUBECONFIG="${SNAP}" kubectl ws "${PROVIDER_WS}"

# Reduce to just the current (provider-ws) context, with certs/tokens embedded inline.
KUBECONFIG="${SNAP}" kubectl config view --raw --minify --flatten > "${AGENT_KC}"

# After --minify there is exactly one cluster; read its name + server.
CLUSTER="$(KUBECONFIG="${AGENT_KC}" kubectl config view -o jsonpath='{.clusters[0].name}')"
OLD_SERVER="$(KUBECONFIG="${AGENT_KC}" kubectl config view -o jsonpath='{.clusters[0].cluster.server}')"
if [[ -z "${OLD_SERVER}" ]]; then
  echo "ERROR: could not read server URL from the provider-workspace kubeconfig" >&2
  exit 1
fi

# Parse https://HOST:PORT/PATH... → keep PATH, swap HOST for $KCP_EXTERNAL_HOST. Use $KCP_PORT when
# set (pins cluster A's front-proxy port, 8443), else fall back to the snapshot's port, else 443.
rest="${OLD_SERVER#*://}"        # HOST:PORT/PATH...
hostport="${rest%%/*}"          # HOST:PORT
path="${rest#"${hostport}"}"    # /PATH... (possibly empty)
port="${KCP_PORT}"
if [[ -z "${port}" ]]; then
  if [[ "${hostport}" == *:* ]]; then
    port="${hostport##*:}"
  else
    port="443"
  fi
fi
NEW_SERVER="https://${KCP_EXTERNAL_HOST}:${port}${path}"

echo "==> Rewriting agent kubeconfig server: ${OLD_SERVER} -> ${NEW_SERVER} (insecure-skip-tls-verify)"
# Drop the CA bundle first (it conflicts with insecure-skip-tls-verify and is host-specific anyway),
# then set the kind-reachable server + insecure flag. The grep filter is name-agnostic and portable
# across BSD/GNU sed.
grep -v 'certificate-authority-data:' "${AGENT_KC}" > "${AGENT_KC}.tmp" && mv "${AGENT_KC}.tmp" "${AGENT_KC}"
KUBECONFIG="${AGENT_KC}" kubectl config set-cluster "${CLUSTER}" \
  --server="${NEW_SERVER}" --insecure-skip-tls-verify=true >/dev/null

echo "==> Ensuring namespace kcp-system on ironcore-in-a-box"
kubectl --kubeconfig "${KIND_KUBECONFIG}" create namespace kcp-system \
  --dry-run=client -o yaml | kubectl --kubeconfig "${KIND_KUBECONFIG}" apply -f -

echo "==> Storing Secret kcp-kubeconfig (key 'kubeconfig') in kcp-system"
kubectl --kubeconfig "${KIND_KUBECONFIG}" create secret generic kcp-kubeconfig \
  --namespace kcp-system \
  --from-file "kubeconfig=${AGENT_KC}" \
  --dry-run=client -o yaml | kubectl --kubeconfig "${KIND_KUBECONFIG}" apply -f -

echo "==> Done. The agent will read the provider-workspace kubeconfig from this Secret."
