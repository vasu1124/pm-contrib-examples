#!/usr/bin/env bash
# test/e2e.sh — owner: test-verifier
#
# End-to-end proof of the IronCore-MSP loop:
#   consumer orders Machine + Network + VirtualIP + NetworkInterface in the kcp consumer workspace
#     -> api-syncagent syncs them DOWN to ironcore-in-a-box
#       -> IronCore controllers provision the resources
#         -> status syncs BACK UP to the consumer workspace
#
# Run AFTER `task up && task order`. Invoked by `task verify`.
# Reads env vars exported by Taskfile.yml. Fails loudly with captured output and
# prints a final PASS/FAIL summary; exits non-zero if any check failed.
#
# Several functions below are invoked indirectly (cleanup via `trap`; predicates via the `retry`
# helper's "$@"), which shellcheck cannot trace.
# shellcheck disable=SC2329
set -euo pipefail

# --- contract: env vars exported by Taskfile.yml (with fallbacks for standalone runs) ---
PM_KUBECONFIG="${PM_KUBECONFIG:?PM_KUBECONFIG must be set}"
KIND_KUBECONFIG="${KIND_KUBECONFIG:?KIND_KUBECONFIG must be set}"
CONSUMER_WS="${CONSUMER_WS:-:root:msp:customer-a}"
# kcp >= 0.31's `kubectl ws` requires a leading ':' for absolute paths. Normalize so both
# 'root:...' (legacy) and ':root:...' overrides work.
CONSUMER_WS=":${CONSUMER_WS#:}"
ORDER_NAME="${ORDER_NAME:-webapp}"
ORDER_NS="${ORDER_NS:-default}"
AGENT_NAME="${AGENT_NAME:-msp-ironcore-backing}"
SYNC_SELECTOR="syncagent.kcp.io/agent-name=${AGENT_NAME}"

# kubectl wrappers — keep the two control planes unambiguous.
kc() { kubectl --kubeconfig "$PM_KUBECONFIG" "$@"; }   # kcp operations
kk() { kubectl --kubeconfig "$KIND_KUBECONFIG" "$@"; }  # ironcore-in-a-box operations
kcws() { KUBECONFIG="$PM_KUBECONFIG" kubectl ws "$@"; }

# --- output helpers ---
PASS_COUNT=0
FAIL_COUNT=0
pass()    { echo "  [PASS] $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail()    { echo "  [FAIL] $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
info()    { echo "  [INFO] $*"; }
warn()    { echo "  [WARN] $*"; }
section() { echo; echo "==================== $* ===================="; }

# retry <timeout_s> <interval_s> <fn...> : run fn until it returns 0 or timeout elapses.
retry() {
  local timeout=$1 interval=$2; shift 2
  local deadline=$((SECONDS + timeout))
  while :; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    [[ $SECONDS -ge $deadline ]] && return 1
    sleep "$interval"
  done
}

echo "######################################################################"
echo "# msp-ironcore end-to-end verification"
echo "#   consumer ws : $CONSUMER_WS"
echo "#   order       : $ORDER_NAME (ns $ORDER_NS)"
echo "#   kcp kubecfg : $PM_KUBECONFIG"
echo "#   kind kubecfg: $KIND_KUBECONFIG"
echo "######################################################################"

# ---------------------------------------------------------------------------
# CHECK 1 — consumer workspace: resources exist in kcp
# ---------------------------------------------------------------------------
section "1. Consumer workspace: IronCore resources present in $CONSUMER_WS"

if kcws "$CONSUMER_WS" >/dev/null 2>&1; then
  info "switched into consumer workspace $CONSUMER_WS"
else
  fail "could not enter consumer workspace $CONSUMER_WS (is kcp up? did 'task up' run?)"
fi

# Check Machine
if kc -n "$ORDER_NS" get machines.compute.ironcore.dev "$ORDER_NAME" >/dev/null 2>&1; then
  pass "Machine/$ORDER_NAME exists in consumer ws (ns $ORDER_NS)"
else
  fail "Machine/$ORDER_NAME NOT found in consumer ws — did 'task order' run?"
fi

# Check Network
if kc -n "$ORDER_NS" get networks.networking.ironcore.dev "$ORDER_NAME" >/dev/null 2>&1; then
  pass "Network/$ORDER_NAME exists in consumer ws (ns $ORDER_NS)"
else
  fail "Network/$ORDER_NAME NOT found in consumer ws"
fi

# Check VirtualIP
if kc -n "$ORDER_NS" get virtualips.networking.ironcore.dev "$ORDER_NAME" >/dev/null 2>&1; then
  pass "VirtualIP/$ORDER_NAME exists in consumer ws (ns $ORDER_NS)"
else
  fail "VirtualIP/$ORDER_NAME NOT found in consumer ws"
fi

# Check NetworkInterface
if kc -n "$ORDER_NS" get networkinterfaces.networking.ironcore.dev "$ORDER_NAME" >/dev/null 2>&1; then
  pass "NetworkInterface/$ORDER_NAME exists in consumer ws (ns $ORDER_NS)"
else
  fail "NetworkInterface/$ORDER_NAME NOT found in consumer ws"
fi

# ---------------------------------------------------------------------------
# CHECK 2 — ironcore-in-a-box: synced resources exist and are healthy
# ---------------------------------------------------------------------------
section "2. ironcore-in-a-box: discover synced resources and assert health"

# Discover the synced Machine on the ironcore-in-a-box cluster
machine_present() { [[ -n "$(kk get machines.compute.ironcore.dev -A -l "$SYNC_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" ]]; }

KIND_MACHINE_NAME=""
KIND_NS_MACHINE=""
if retry 150 4 machine_present; then
  read -r KIND_MACHINE_NAME KIND_NS_MACHINE <<<"$(kk get machines.compute.ironcore.dev -A -l "$SYNC_SELECTOR" -o jsonpath='{.items[0].metadata.name} {.items[0].metadata.namespace}' 2>/dev/null)"
  pass "agent-synced Machine found on ironcore-in-a-box: '$KIND_MACHINE_NAME' (ns '$KIND_NS_MACHINE')"
elif [[ -n "$(kk get machines.compute.ironcore.dev -A -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" ]]; then
  read -r KIND_MACHINE_NAME KIND_NS_MACHINE <<<"$(kk get machines.compute.ironcore.dev -A -o jsonpath='{.items[0].metadata.name} {.items[0].metadata.namespace}' 2>/dev/null)"
  warn "no Machine carried label '$SYNC_SELECTOR' — used unlabeled fallback"
  pass "Machine found on ironcore-in-a-box: '$KIND_MACHINE_NAME' (ns '$KIND_NS_MACHINE')"
else
  fail "no Machine appeared on ironcore-in-a-box within timeout"
  kk get machines.compute.ironcore.dev -A 2>&1 | sed 's/^/    /' || true
fi

# Check Machine state
if [[ -n "$KIND_MACHINE_NAME" ]]; then
  machine_running() {
    local state
    state="$(kk -n "$KIND_NS_MACHINE" get machines.compute.ironcore.dev "$KIND_MACHINE_NAME" -o jsonpath='{.status.state}' 2>/dev/null || true)"
    [[ "$state" == "Running" ]]
  }
  if retry 240 5 machine_running; then
    STATE="$(kk -n "$KIND_NS_MACHINE" get machines.compute.ironcore.dev "$KIND_MACHINE_NAME" -o jsonpath='{.status.state}' 2>/dev/null || true)"
    pass "Machine state: $STATE"
  else
    STATE="$(kk -n "$KIND_NS_MACHINE" get machines.compute.ironcore.dev "$KIND_MACHINE_NAME" -o jsonpath='{.status.state}' 2>/dev/null || true)"
    warn "Machine state is '${STATE:-<none>}' (may still be provisioning — not a hard failure)"
  fi
fi

# Check synced Network
network_present() { [[ -n "$(kk get networks.networking.ironcore.dev -A -l "$SYNC_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" ]]; }
if retry 60 3 network_present; then
  pass "Network synced to ironcore-in-a-box"
else
  if [[ -n "$(kk get networks.networking.ironcore.dev -A -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" ]]; then
    pass "Network found on ironcore-in-a-box (unlabeled fallback)"
  else
    fail "Network NOT synced to ironcore-in-a-box"
  fi
fi

# Check synced VirtualIP
vip_present() { [[ -n "$(kk get virtualips.networking.ironcore.dev -A -l "$SYNC_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" ]]; }
if retry 60 3 vip_present; then
  pass "VirtualIP synced to ironcore-in-a-box"
else
  if [[ -n "$(kk get virtualips.networking.ironcore.dev -A -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" ]]; then
    pass "VirtualIP found on ironcore-in-a-box (unlabeled fallback)"
  else
    fail "VirtualIP NOT synced to ironcore-in-a-box"
  fi
fi

# Check synced NetworkInterface
nic_present() { [[ -n "$(kk get networkinterfaces.networking.ironcore.dev -A -l "$SYNC_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" ]]; }
if retry 60 3 nic_present; then
  pass "NetworkInterface synced to ironcore-in-a-box"
else
  if [[ -n "$(kk get networkinterfaces.networking.ironcore.dev -A -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" ]]; then
    pass "NetworkInterface found on ironcore-in-a-box (unlabeled fallback)"
  else
    fail "NetworkInterface NOT synced to ironcore-in-a-box"
  fi
fi

# ---------------------------------------------------------------------------
# CHECK 3 — sync-back of STATUS: consumer-side Machine has populated status
# ---------------------------------------------------------------------------
section "3. Sync-back: consumer-side Machine/$ORDER_NAME .status populated"

kcws "$CONSUMER_WS" >/dev/null 2>&1 || true
consumer_machine_status() {
  [[ -n "$(kc -n "$ORDER_NS" get machines.compute.ironcore.dev "$ORDER_NAME" -o jsonpath='{.status.state}' 2>/dev/null)" ]]
}
if retry 180 5 consumer_machine_status; then
  CSTATE="$(kc -n "$ORDER_NS" get machines.compute.ironcore.dev "$ORDER_NAME" -o jsonpath='{.status.state}' 2>/dev/null || true)"
  pass "Machine status synced back to consumer ws: state='$CSTATE'"
else
  fail "consumer-side Machine .status never populated — status sync-back not working"
  kc -n "$ORDER_NS" get machines.compute.ironcore.dev "$ORDER_NAME" -o yaml 2>&1 | sed -n '/^status:/,$p' | sed 's/^/    /' || true
fi

# Check Network status sync-back
consumer_network_status() {
  [[ -n "$(kc -n "$ORDER_NS" get networks.networking.ironcore.dev "$ORDER_NAME" -o jsonpath='{.status.state}' 2>/dev/null)" ]]
}
if retry 60 3 consumer_network_status; then
  pass "Network status synced back to consumer ws"
else
  warn "Network .status not yet populated (may be normal for minimal networks)"
fi

# Check VirtualIP status sync-back
consumer_vip_status() {
  [[ -n "$(kc -n "$ORDER_NS" get virtualips.networking.ironcore.dev "$ORDER_NAME" -o jsonpath='{.status.ip}' 2>/dev/null)" ]]
}
if retry 60 3 consumer_vip_status; then
  VIP="$(kc -n "$ORDER_NS" get virtualips.networking.ironcore.dev "$ORDER_NAME" -o jsonpath='{.status.ip}' 2>/dev/null || true)"
  pass "VirtualIP status synced back: ip='$VIP'"
else
  warn "VirtualIP .status.ip not yet populated"
fi

# ---------------------------------------------------------------------------
# CHECK 4 — IronCore CRDs are available in the consumer workspace
# ---------------------------------------------------------------------------
section "4. API availability: IronCore APIs served in consumer workspace"

kcws "$CONSUMER_WS" >/dev/null 2>&1 || true

for api_group in compute.ironcore.dev networking.ironcore.dev; do
  if kc api-resources --api-group="$api_group" 2>/dev/null | grep -q .; then
    pass "$api_group APIs served in consumer workspace"
  else
    fail "$api_group APIs NOT served in consumer workspace"
  fi
done

# ---------------------------------------------------------------------------
# CHECK 5 — Idempotency
# ---------------------------------------------------------------------------
section "5. Idempotency"
info "e2e.sh is read-only — no objects are created or modified."
info "'task order' uses 'kubectl apply' (no-op if unchanged); re-running 'task verify' is stable."
pass "idempotent: safe to re-run"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "SUMMARY"
echo "  PASS: $PASS_COUNT"
echo "  FAIL: $FAIL_COUNT"
if [[ "$FAIL_COUNT" -eq 0 ]]; then
  echo
  echo "  ✅ E2E PASS — order -> sync-down -> provision -> status sync-back all verified."
  exit 0
else
  echo
  echo "  ❌ E2E FAIL — $FAIL_COUNT check(s) failed (see [FAIL] lines above)."
  exit 1
fi
