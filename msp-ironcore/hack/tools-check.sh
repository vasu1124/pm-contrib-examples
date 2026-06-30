#!/usr/bin/env bash
# hack/tools-check.sh — Assert required CLIs are present and the Docker daemon is reachable.
# Owner: k8s-expert
#
# Required (fatal if missing):  kubectl, kind, docker, helm, kubectl-ws (or kubectl-kcp), go, make
# Optional (warn only):         (none)
#
# This ironcore-in-a-box variant requires go and make (needed by ironcore-in-a-box's `make up`).
# `kubectl ws` (order/verify/syncagent:kubeconfig) needs the kcp kubectl plugin.
set -euo pipefail

MISSING=()

echo "==> tools-check: verifying required CLIs"
echo ""

# --- Standard CLIs ---
echo "  kubectl:"
if command -v kubectl >/dev/null 2>&1; then
  kubectl version --client 2>/dev/null || kubectl version --client --short 2>/dev/null || true
else
  echo "  [MISSING] kubectl"
  MISSING+=("kubectl")
fi

echo ""
echo "  kind:"
if command -v kind >/dev/null 2>&1; then
  kind version
else
  echo "  [MISSING] kind"
  MISSING+=("kind")
fi

echo ""
echo "  docker:"
if command -v docker >/dev/null 2>&1; then
  docker version --format 'Client: {{.Client.Version}}  Server: {{.Server.Version}}' 2>/dev/null \
    || docker --version
else
  echo "  [MISSING] docker"
  MISSING+=("docker")
fi

echo ""
echo "  helm:"
if command -v helm >/dev/null 2>&1; then
  helm version --short
else
  echo "  [MISSING] helm"
  MISSING+=("helm")
fi

echo ""
echo "  go:"
if command -v go >/dev/null 2>&1; then
  go version
else
  echo "  [MISSING] go (required by ironcore-in-a-box)"
  MISSING+=("go")
fi

echo ""
echo "  make:"
if command -v make >/dev/null 2>&1; then
  make --version | head -n1
else
  echo "  [MISSING] make (required by ironcore-in-a-box)"
  MISSING+=("make")
fi

# --- kubectl plugins (kubectl-ws / kubectl-kcp) ---
echo ""
echo "  kubectl plugins (kcp):"

# kubectl-ws provides 'kubectl ws' — required for workspace navigation.
KWS_OK=false
KKCP_OK=false

if command -v kubectl-ws >/dev/null 2>&1; then
  printf "  %-20s found at %s\n" "kubectl-ws" "$(command -v kubectl-ws)"
  KWS_OK=true
fi

if command -v kubectl-kcp >/dev/null 2>&1; then
  printf "  %-20s found at %s\n" "kubectl-kcp" "$(command -v kubectl-kcp)"
  KKCP_OK=true
fi

# At least one of the two must be present (kcp ships both in some releases, only one in others).
if ! $KWS_OK && ! $KKCP_OK; then
  echo "  [MISSING] kubectl-ws and kubectl-kcp — install both from the kcp release bundle"
  MISSING+=("kubectl-ws/kubectl-kcp")
fi

# --- Docker daemon health ---
echo ""
echo "==> Checking Docker daemon reachability"
if ! docker info >/dev/null 2>&1; then
  echo "  [ERROR] Docker daemon is not reachable. Is Docker Desktop running?"
  MISSING+=("docker-daemon")
else
  echo "  Docker daemon: OK"
fi

# --- Report ---
echo ""
if [ ${#MISSING[@]} -gt 0 ]; then
  echo ""
  echo "==> tools-check: FAILED — missing required tools: ${MISSING[*]}"
  exit 1
fi

echo "==> tools-check: all required tools present"
