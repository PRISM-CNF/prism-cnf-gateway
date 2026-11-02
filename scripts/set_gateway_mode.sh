#!/usr/bin/env bash
set -euo pipefail

NS_NAMESPACE="${NS_NAMESPACE:-nse-ovs-gateway}"
CONFIGMAP_NAME="${CONFIGMAP_NAME:-nse-ovs-gateway-rules}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-nse-ovs-gateway}"
MODE=""
WAIT_TIMEOUT="${WAIT_TIMEOUT:-120s}"
POD_FILE_WAIT_SECONDS="${POD_FILE_WAIT_SECONDS:-90}"
RELOAD_SETTLE_SECONDS="${RELOAD_SETTLE_SECONDS:-5}"
RESTART_DEPLOYMENT="false"
KUBECTL="${KUBECTL:-kubectl}"

usage() {
  cat <<'EOF'
Usage: ./scripts/set_gateway_mode.sh --mode <allowlist|denylist> [--restart] [--timeout <duration>]

Update the live gateway ConfigMap rules mode. By default the gateway hot-reloads the
mounted rules file without restarting the deployment.

Options:
  --mode <mode>       Required. allowlist or denylist
  --restart           Restart the gateway deployment after updating the ConfigMap
  --no-restart        Deprecated alias for the default live-reload behavior
  --timeout <value>   Rollout status timeout. Default: 120s
  -h, --help          Show this help text
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --no-restart)
      RESTART_DEPLOYMENT="false"
      shift
      ;;
    --restart)
      RESTART_DEPLOYMENT="true"
      shift
      ;;
    --timeout)
      WAIT_TIMEOUT="${2:-}"
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

case "${MODE}" in
  allowlist|denylist)
    ;;
  *)
    echo "invalid or missing mode: ${MODE:-<empty>}" >&2
    usage >&2
    exit 1
    ;;
esac

run_kubectl() {
  "${KUBECTL}" "$@"
}

current_gateway_pod() {
  run_kubectl get pods -n "${NS_NAMESPACE}" \
    -l app=nse-ovs-gateway \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

current_gateway_mode() {
  local pod_name
  pod_name="$(current_gateway_pod)"
  [[ -n "${pod_name}" ]] || return 1

  run_kubectl exec -n "${NS_NAMESPACE}" "${pod_name}" -c nse -- \
    sh -c "awk '/^mode:/{print \$2; exit}' /etc/nse-gateway/rules.yaml 2>/dev/null" 2>/dev/null || true
}

wait_for_gateway_mode() {
  local deadline
  deadline=$((SECONDS + POD_FILE_WAIT_SECONDS))

  while (( SECONDS < deadline )); do
    if [[ "$(current_gateway_mode)" == "${MODE}" ]]; then
      return 0
    fi
    sleep 2
  done

  return 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
tmp_rules="$(mktemp)"
trap 'rm -f "${tmp_rules}"' EXIT

load_current_rules() {
  run_kubectl get configmap "${CONFIGMAP_NAME}" -n "${NS_NAMESPACE}" \
    -o jsonpath='{.data.rules\.yaml}' 2>/dev/null || true
}

load_repo_default_rules() {
  awk '
    /rules\.yaml: \|/ { in_rules = 1; next }
    in_rules {
      sub(/^    /, "")
      print
    }
  ' "${repo_root}/k8s/15-gateway-rules.yaml"
}

replace_mode() {
  local rules_content="$1"
  local mode="$2"
  if printf '%s\n' "${rules_content}" | grep -q '^mode:'; then
    printf '%s\n' "${rules_content}" | sed "0,/^mode:[[:space:]].*/s//mode: ${mode}/"
  else
    printf 'mode: %s\n%s\n' "${mode}" "${rules_content}"
  fi
}

rules_content="$(load_current_rules)"
if [[ -z "${rules_content}" ]]; then
  rules_content="$(load_repo_default_rules)"
fi
[[ -n "${rules_content}" ]] || { echo "unable to load gateway rules content" >&2; exit 1; }

replace_mode "${rules_content}" "${MODE}" >"${tmp_rules}"

echo "== Apply ConfigMap =="
echo "Namespace : ${NS_NAMESPACE}"
echo "ConfigMap : ${CONFIGMAP_NAME}"
echo "Mode      : ${MODE}"

run_kubectl create configmap "${CONFIGMAP_NAME}" \
  -n "${NS_NAMESPACE}" \
  --from-file=rules.yaml="${tmp_rules}" \
  --dry-run=client -o yaml | run_kubectl apply -f -

if [[ "${RESTART_DEPLOYMENT}" == "true" ]]; then
  echo "== Restart Deployment =="
  run_kubectl rollout restart deployment/"${DEPLOYMENT_NAME}" -n "${NS_NAMESPACE}"
  run_kubectl rollout status deployment/"${DEPLOYMENT_NAME}" -n "${NS_NAMESPACE}" --timeout="${WAIT_TIMEOUT}"
else
  echo "== Wait For Live Reload =="
  if ! wait_for_gateway_mode; then
    echo "gateway pod did not observe mode=${MODE} within ${POD_FILE_WAIT_SECONDS}s" >&2
    exit 1
  fi

  if [[ "${RELOAD_SETTLE_SECONDS}" != "0" ]]; then
    sleep "${RELOAD_SETTLE_SECONDS}"
  fi
fi

echo "== Live Rules =="
run_kubectl get configmap "${CONFIGMAP_NAME}" -n "${NS_NAMESPACE}" -o jsonpath='{.data.rules\.yaml}'
printf '\n'
