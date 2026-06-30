#!/usr/bin/env bash
# hack/syncagent-publish.sh — owner: syncagent-expert
# Apply the on-cluster RBAC + all PublishedResources for IronCore APIs. Idempotent (apply).
#
# Reads env vars exported by Taskfile.yml; do NOT hardcode paths:
#   KIND_KUBECONFIG, TASKFILE_DIR
#
# Prereq (Taskfile `up` ordering): syncagent:install has already installed the PublishedResource
# CRD (chart crds.enabled=true) before these PublishedResource objects are applied.
set -euo pipefail

: "${KIND_KUBECONFIG:?KIND_KUBECONFIG must be set}"
: "${TASKFILE_DIR:?TASKFILE_DIR must be set}"

RBAC="${TASKFILE_DIR}/config/syncagent/rbac.yaml"
PR_DIR="${TASKFILE_DIR}/config/syncagent"

echo "==> Applying api-syncagent RBAC + all PublishedResources on ironcore-in-a-box"
kubectl --kubeconfig "${KIND_KUBECONFIG}" apply \
  -f "${RBAC}" \
  -f "${PR_DIR}/publishedresource-machine.yaml" \
  -f "${PR_DIR}/publishedresource-network.yaml" \
  -f "${PR_DIR}/publishedresource-virtualip.yaml" \
  -f "${PR_DIR}/publishedresource-networkinterface.yaml"

# Best-effort readiness signal (NON-FATAL by design). The agent sets
# .status.resourceSchemaName on each PublishedResource only AFTER it has read the CRD and
# successfully created the APIResourceSchema in kcp — so a populated value also proves the agent
# reached kcp (the main connectivity risk). On timeout we only WARN — provider:bind has
# its own wait — so this can never make `task up` fail where it otherwise would not.

PUBLISHED_RESOURCES="ironcore-machines ironcore-networks ironcore-virtualips ironcore-networkinterfaces"

echo "==> Waiting (best-effort, up to 120s) for the agent to publish APIResourceSchemas..."
all_published=true
deadline=$(( SECONDS + 120 ))
for pr in ${PUBLISHED_RESOURCES}; do
  schema=""
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    schema="$(kubectl --kubeconfig "${KIND_KUBECONFIG}" get publishedresources.syncagent.kcp.io "${pr}" \
      -o jsonpath='{.status.resourceSchemaName}' 2>/dev/null || true)"
    if [ -n "${schema}" ]; then
      break
    fi
    sleep 2
  done

  if [ -n "${schema}" ]; then
    echo "    ✓ ${pr} → APIResourceSchema: ${schema}"
  else
    echo "    ✗ ${pr}: no .status.resourceSchemaName yet" >&2
    all_published=false
  fi
done

if [ "${all_published}" = true ]; then
  echo "==> All IronCore APIs published successfully."
else
  echo "WARNING: Some PublishedResources still have no .status.resourceSchemaName after 120s." >&2
  echo "         The agent may not have reached kcp yet (provider:bind will still wait). If the bind" >&2
  echo "         later times out, inspect the agent logs:" >&2
  echo "         kubectl --kubeconfig \"\${KIND_KUBECONFIG}\" -n kcp-system logs -l app.kubernetes.io/name=kcp-api-syncagent --tail=100" >&2
fi
