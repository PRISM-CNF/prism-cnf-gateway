#!/usr/bin/env bash
set -euo pipefail

NS_NAMESPACE="${NS_NAMESPACE:-nse-ovs-gateway}"
GATEWAY_POD_PREFIX="${GATEWAY_POD_PREFIX:-nse-ovs-gateway-}"
GATEWAY_CONTAINER="${GATEWAY_CONTAINER:-nse}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-60}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-2}"
KUBECTL="${KUBECTL:-kubectl}"

usage() {
  cat <<'EOF'
Usage: ./scripts/check_gateway_cleanup.sh [--timeout-seconds <n>] [--poll-seconds <n>]

Wait until the running gateway pod has no active nsmgw nftables tables.

Options:
  --timeout-seconds <n> Timeout in seconds. Default: 60
  --poll-seconds <n>    Poll interval in seconds. Default: 2
  -h, --help            Show this help text
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout-seconds)
      WAIT_TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    --poll-seconds)
      POLL_INTERVAL_SECONDS="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

run_kubectl() {
  "${KUBECTL}" "$@"
}

get_gateway_pod() {
  run_kubectl get pods -n "${NS_NAMESPACE}" --no-headers \
    -o custom-columns=NAME:.metadata.name,PHASE:.status.phase \
    | awk -v prefix="${GATEWAY_POD_PREFIX}" '$1 ~ ("^" prefix) && $2 == "Running" { print $1; exit }'
}

list_gateway_tables() {
  local pod_name="$1"
  run_kubectl exec -n "${NS_NAMESPACE}" "${pod_name}" -c "${GATEWAY_CONTAINER}" -- \
    sh -eu -c "nft list tables 2>/dev/null | grep '^table bridge nsmgw' || true"
}

gateway_pod="$(get_gateway_pod)"
[[ -n "${gateway_pod}" ]] || { echo "running gateway pod not found in namespace ${NS_NAMESPACE}" >&2; exit 1; }

deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  active_tables="$(list_gateway_tables "${gateway_pod}")"
  if [[ -z "${active_tables}" ]]; then
    echo "Gateway cleanup check: PASS"
    echo "Gateway pod: ${gateway_pod}"
    exit 0
  fi
  sleep "${POLL_INTERVAL_SECONDS}"
done

echo "gateway nftables cleanup timed out after ${WAIT_TIMEOUT_SECONDS}s" >&2
list_gateway_tables "${gateway_pod}" >&2
exit 1
