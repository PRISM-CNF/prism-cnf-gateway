#!/usr/bin/env bash
set -euo pipefail

NS_NAMESPACE="${NS_NAMESPACE:-nse-ovs-gateway}"
NSM_SYSTEM_NAMESPACE="${NSM_SYSTEM_NAMESPACE:-nsm-system}"
CLIENT_POD_PREFIX="${CLIENT_POD_PREFIX:-nsc-ovs-client-}"
TEMPLATE_POD_PREFIX="${TEMPLATE_POD_PREFIX:-nse-ovs-gateway-}"
SERVER_POD_PREFIX="${SERVER_POD_PREFIX:-nse-ovs-server-}"
CLIENT_IFACE="${CLIENT_IFACE:-nsm-1}"
CLIENT_CONTAINER="${CLIENT_CONTAINER:-client}"
CLIENT_CMD_CONTAINER="${CLIENT_CMD_CONTAINER:-cmd-nsc}"
TEMPLATE_CONTAINER="${TEMPLATE_CONTAINER:-nse}"
SERVER_CONTAINER="${SERVER_CONTAINER:-server}"
IPERF_PORT="${IPERF_PORT:-5201}"
IPERF_PARALLEL="${IPERF_PARALLEL:-4}"
IPERF_SECONDS="${IPERF_SECONDS:-10}"
KUBECTL="${KUBECTL:-kubectl}"
EXPECT_RESULT="pass"
SKIP_IPERF="false"
DUMP_NFT="false"
INTERFACE_WAIT_SECONDS="${INTERFACE_WAIT_SECONDS:-30}"

usage() {
  cat <<'EOF'
Usage: ./scripts/verify_same_node_chain.sh [--expect-pass|--expect-drop] [--skip-iperf] [--dump-nft]

Verify the same-node NSM OVS gateway chain and print path evidence.

Options:
  --expect-pass   Expect ping and iperf3 to succeed. Default.
  --expect-drop   Expect ping to fail and, unless --skip-iperf is used, iperf3 to fail.
  --skip-iperf    Skip the iperf3 step.
  --dump-nft      Print the full nft ruleset from the gateway pod.
  -h, --help      Show this help text.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expect-pass)
      EXPECT_RESULT="pass"
      shift
      ;;
    --expect-drop)
      EXPECT_RESULT="drop"
      shift
      ;;
    --skip-iperf)
      SKIP_IPERF="true"
      shift
      ;;
    --dump-nft)
      DUMP_NFT="true"
      shift
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

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

run_kubectl() {
  "$KUBECTL" "$@"
}

sanitize_name() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9._:-]+$ ]] || die "unexpected name: $value"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

fmt_count() {
  local value="$1"
  local sign=""
  local digits="$value"
  if [[ "$digits" == -* ]]; then
    sign="-"
    digits="${digits#-}"
  fi
  local out=""
  while ((${#digits} > 3)); do
    out=",${digits: -3}${out}"
    digits="${digits:0:${#digits}-3}"
  done
  printf '%s%s%s' "$sign" "$digits" "$out"
}

fmt_bytes_gib() {
  awk -v value="$1" 'BEGIN { printf "%.3f GiB", value / 1024 / 1024 / 1024 }'
}

kv_get() {
  local file="$1"
  local key="$2"
  awk -F'=' -v key="$key" '$1 == key { print $2; exit }' "$file"
}

delta_from_files() {
  local before_file="$1"
  local after_file="$2"
  local key="$3"
  local before_value after_value
  before_value="$(kv_get "$before_file" "$key")"
  after_value="$(kv_get "$after_file" "$key")"
  [[ -n "$before_value" ]] || die "missing before counter $key in $before_file"
  [[ -n "$after_value" ]] || die "missing after counter $key in $after_file"
  echo $((after_value - before_value))
}

get_running_pod_by_prefix() {
  local namespace="$1"
  local prefix="$2"
  run_kubectl get pods -n "$namespace" --no-headers \
    -o custom-columns=NAME:.metadata.name,PHASE:.status.phase \
    | awk -v prefix="$prefix" '$1 ~ ("^" prefix) && $2 == "Running" { print $1; exit }'
}

get_forwarder_pod_on_node() {
  local node_name="$1"
  run_kubectl get pods -n "$NSM_SYSTEM_NAMESPACE" --no-headers \
    -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName \
    | awk -v node_name="$node_name" '$1 ~ /^forwarder-ovs-/ && $2 == "Running" && $3 == node_name { print $1; exit }'
}

require_container() {
  local namespace="$1"
  local pod_name="$2"
  local container_name="$3"
  if ! run_kubectl get pod -n "$namespace" "$pod_name" \
    -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}' | grep -Fxq "$container_name"; then
    die "container $container_name not found in pod $namespace/$pod_name"
  fi
}

pod_sh() {
  local namespace="$1"
  local pod_name="$2"
  local container_name="$3"
  local command="$4"
  run_kubectl exec -n "$namespace" "$pod_name" -c "$container_name" -- sh -eu -c "$command"
}

gateway_nft_tables() {
  local namespace="$1"
  local pod_name="$2"
  local container_name="$3"
  pod_sh "$namespace" "$pod_name" "$container_name" "nft list tables 2>/dev/null | grep '^table bridge nsmgw' || true"
}

gateway_nft_ruleset() {
  local namespace="$1"
  local pod_name="$2"
  local container_name="$3"
  pod_sh "$namespace" "$pod_name" "$container_name" "nft list ruleset"
}

wait_for_pod_iface() {
  local namespace="$1"
  local pod_name="$2"
  local container_name="$3"
  local iface_name="$4"
  local timeout_seconds="$5"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS < deadline )); do
    if run_kubectl exec -n "$namespace" "$pod_name" -c "$container_name" -- \
      sh -eu -c "ip -o link show dev $iface_name >/dev/null"; then
      return 0
    fi
    sleep 1
  done

  return 1
}

wait_for_pod_link_line() {
  local namespace="$1"
  local pod_name="$2"
  local container_name="$3"
  local iface_name="$4"
  local timeout_seconds="$5"
  local deadline=$((SECONDS + timeout_seconds))
  local link_line=""

  while (( SECONDS < deadline )); do
    link_line="$(run_kubectl exec -n "$namespace" "$pod_name" -c "$container_name" -- \
      sh -eu -c "ip -o link show dev $iface_name 2>/dev/null" || true)"
    link_line="$(trim "$link_line")"
    if [[ -n "$link_line" ]]; then
      printf '%s' "$link_line"
      return 0
    fi
    sleep 1
  done

  return 1
}

wait_for_pod_ipv4() {
  local namespace="$1"
  local pod_name="$2"
  local container_name="$3"
  local iface_name="$4"
  local timeout_seconds="$5"
  local deadline=$((SECONDS + timeout_seconds))
  local ipv4_addr=""

  while (( SECONDS < deadline )); do
    ipv4_addr="$(run_kubectl exec -n "$namespace" "$pod_name" -c "$container_name" -- \
      sh -eu -c "ip -o -4 addr show dev $iface_name 2>/dev/null | awk '{print \$4}' | head -n1" || true)"
    ipv4_addr="$(trim "$ipv4_addr")"
    if [[ -n "$ipv4_addr" ]]; then
      printf '%s' "$ipv4_addr"
      return 0
    fi
    sleep 1
  done

  return 1
}

parse_link_name() {
  local line="$1"
  local token
  token="$(printf '%s\n' "$line" | awk -F': ' '{print $2}' | awk '{print $1}')"
  token="${token%:}"
  printf '%s' "${token%%@*}"
}

parse_link_peer_ifindex() {
  local line="$1"
  local token
  token="$(printf '%s\n' "$line" | awk -F': ' '{print $2}' | awk '{print $1}')"
  token="${token%:}"
  printf '%s\n' "$token" | sed -n 's/.*@if\([0-9][0-9]*\)$/\1/p'
}

capture_netdev_stats() {
  local namespace="$1"
  local pod_name="$2"
  local container_name="$3"
  local iface_name="$4"
  sanitize_name "$iface_name"
  pod_sh "$namespace" "$pod_name" "$container_name" \
    "for key in rx_bytes rx_packets tx_bytes tx_packets; do printf '%s=%s\n' \"\$key\" \"\$(cat /sys/class/net/$iface_name/statistics/\$key)\"; done"
}

capture_ofport_stats() {
  local forwarder_pod="$1"
  local ofport="$2"
  sanitize_name "$ofport"
  run_kubectl exec -n "$NSM_SYSTEM_NAMESPACE" "$forwarder_pod" -- \
    ovs-ofctl dump-ports br-nsm "$ofport" \
    | awk '
        /rx pkts=/ {
          gsub(/,/, "")
          match($0, /pkts=([0-9]+)/, rx_pkts)
          match($0, /bytes=([0-9]+)/, rx_b)
          rx_packets = rx_pkts[1]
          rx_bytes = rx_b[1]
        }
        /tx pkts=/ {
          gsub(/,/, "")
          match($0, /pkts=([0-9]+)/, tx_pkts)
          match($0, /bytes=([0-9]+)/, tx_b)
          tx_packets = tx_pkts[1]
          tx_bytes = tx_b[1]
        }
        END {
          printf "rx_bytes=%s\nrx_packets=%s\ntx_bytes=%s\ntx_packets=%s\n", rx_bytes, rx_packets, tx_bytes, tx_packets
        }'
}

save_snapshot() {
  local file_path="$1"
  shift
  "$@" >"$file_path"
}

forwarder_port_name_for_ifindex() {
  local links_file="$1"
  local ifindex="$2"
  awk -F': ' -v ifindex="$ifindex" '
    $1 == ifindex {
      split($2, fields, " ")
      name = fields[1]
      sub(/:$/, "", name)
      sub(/@.*/, "", name)
      print name
      exit
    }' "$links_file"
}

port_conn_id() {
  local port_name="$1"
  printf '%s' "$port_name" | sed -E 's/^tap(src|dst)-//'
}

lookup_ofport() {
  local forwarder_pod="$1"
  local port_name="$2"
  sanitize_name "$port_name"
  trim "$(run_kubectl exec -n "$NSM_SYSTEM_NAMESPACE" "$forwarder_pod" -- ovs-vsctl get Interface "$port_name" ofport)"
}

render_leg_line() {
  local label="$1"
  local pod_name="$2"
  local iface_name="$3"
  local detail="$4"
  printf "%-14s %-42s %-24s %s\n" "$label" "$pod_name" "$iface_name" "$detail"
}

need_cmd awk
need_cmd grep
need_cmd kubectl
need_cmd sed

client_pod="$(get_running_pod_by_prefix "$NS_NAMESPACE" "$CLIENT_POD_PREFIX")"
template_pod="$(get_running_pod_by_prefix "$NS_NAMESPACE" "$TEMPLATE_POD_PREFIX")"
server_pod="$(get_running_pod_by_prefix "$NS_NAMESPACE" "$SERVER_POD_PREFIX")"

[[ -n "$client_pod" ]] || die "running client pod with prefix $CLIENT_POD_PREFIX not found in namespace $NS_NAMESPACE"
[[ -n "$template_pod" ]] || die "running template pod with prefix $TEMPLATE_POD_PREFIX not found in namespace $NS_NAMESPACE"
[[ -n "$server_pod" ]] || die "running server pod with prefix $SERVER_POD_PREFIX not found in namespace $NS_NAMESPACE"

client_node="$(trim "$(run_kubectl get pod -n "$NS_NAMESPACE" "$client_pod" -o jsonpath='{.spec.nodeName}')")"
[[ -n "$client_node" ]] || die "unable to determine node for pod $client_pod"
forwarder_pod="$(get_forwarder_pod_on_node "$client_node")"
[[ -n "$forwarder_pod" ]] || die "running forwarder-ovs pod not found on node $client_node"

require_container "$NS_NAMESPACE" "$client_pod" "$CLIENT_CONTAINER"
require_container "$NS_NAMESPACE" "$client_pod" "$CLIENT_CMD_CONTAINER"
require_container "$NS_NAMESPACE" "$template_pod" "$TEMPLATE_CONTAINER"
require_container "$NS_NAMESPACE" "$server_pod" "$SERVER_CONTAINER"

client_container="$CLIENT_CONTAINER"
client_cmd_container="$CLIENT_CMD_CONTAINER"
template_container="$TEMPLATE_CONTAINER"
server_container="$SERVER_CONTAINER"

if ! wait_for_pod_iface "$NS_NAMESPACE" "$client_pod" "$client_container" "$CLIENT_IFACE" "$INTERFACE_WAIT_SECONDS"; then
  die "client interface $CLIENT_IFACE did not appear within ${INTERFACE_WAIT_SECONDS}s"
fi

client_link_line="$(wait_for_pod_link_line "$NS_NAMESPACE" "$client_pod" "$client_container" "$CLIENT_IFACE" "$INTERFACE_WAIT_SECONDS" || true)"
[[ -n "$client_link_line" ]] || die "unable to read client interface line for $CLIENT_IFACE"
client_iface="$(parse_link_name "$client_link_line")"
client_peer_ifindex="$(parse_link_peer_ifindex "$client_link_line")"
[[ -n "$client_iface" ]] || die "unable to parse client interface from: $client_link_line"
[[ -n "$client_peer_ifindex" ]] || die "unable to parse client peer ifindex from: $client_link_line"

client_ip="$(wait_for_pod_ipv4 "$NS_NAMESPACE" "$client_pod" "$client_container" "$client_iface" "$INTERFACE_WAIT_SECONDS" || true)"
client_ip="${client_ip%%/*}"
[[ -n "$client_ip" ]] || die "unable to determine client IP on $client_iface"

mapfile -t template_leg_lines < <(pod_sh "$NS_NAMESPACE" "$template_pod" "$template_container" "ip -o link show | grep 'nse-ovs-ga-'")
[[ "${#template_leg_lines[@]}" -eq 2 ]] || die "expected 2 template data interfaces, got ${#template_leg_lines[@]}"
template_bridge_line="$(pod_sh "$NS_NAMESPACE" "$template_pod" "$template_container" "ip -o link show | grep 'nsmbr' | head -n1")"
template_bridge="$(parse_link_name "$template_bridge_line")"
[[ -n "$template_bridge" ]] || die "unable to determine template bridge interface"

template_leg_a="$(parse_link_name "${template_leg_lines[0]}")"
template_leg_a_peer_ifindex="$(parse_link_peer_ifindex "${template_leg_lines[0]}")"
template_leg_b="$(parse_link_name "${template_leg_lines[1]}")"
template_leg_b_peer_ifindex="$(parse_link_peer_ifindex "${template_leg_lines[1]}")"

[[ -n "$template_leg_a_peer_ifindex" ]] || die "unable to parse template leg A peer ifindex"
[[ -n "$template_leg_b_peer_ifindex" ]] || die "unable to parse template leg B peer ifindex"

server_link_line="$(pod_sh "$NS_NAMESPACE" "$server_pod" "$server_container" "ip -o link show | grep 'nse-ovs-ga-' | head -n1")"
server_iface="$(parse_link_name "$server_link_line")"
server_peer_ifindex="$(parse_link_peer_ifindex "$server_link_line")"
[[ -n "$server_iface" ]] || die "unable to parse server interface from: $server_link_line"
[[ -n "$server_peer_ifindex" ]] || die "unable to parse server peer ifindex from: $server_link_line"

server_ip="$(wait_for_pod_ipv4 "$NS_NAMESPACE" "$server_pod" "$server_container" "$server_iface" "$INTERFACE_WAIT_SECONDS" || true)"
server_ip="${server_ip%%/*}"
[[ -n "$server_ip" ]] || die "unable to determine server IP on $server_iface"

forwarder_links_file="$tmpdir/forwarder-links.txt"
run_kubectl exec -n "$NSM_SYSTEM_NAMESPACE" "$forwarder_pod" -- ip -o link show >"$forwarder_links_file"

client_forwarder_port="$(forwarder_port_name_for_ifindex "$forwarder_links_file" "$client_peer_ifindex")"
server_forwarder_port="$(forwarder_port_name_for_ifindex "$forwarder_links_file" "$server_peer_ifindex")"
template_leg_a_forwarder_port="$(forwarder_port_name_for_ifindex "$forwarder_links_file" "$template_leg_a_peer_ifindex")"
template_leg_b_forwarder_port="$(forwarder_port_name_for_ifindex "$forwarder_links_file" "$template_leg_b_peer_ifindex")"

[[ -n "$client_forwarder_port" ]] || die "unable to map client peer ifindex $client_peer_ifindex to forwarder port"
[[ -n "$server_forwarder_port" ]] || die "unable to map server peer ifindex $server_peer_ifindex to forwarder port"
[[ -n "$template_leg_a_forwarder_port" ]] || die "unable to map template leg A peer ifindex $template_leg_a_peer_ifindex to forwarder port"
[[ -n "$template_leg_b_forwarder_port" ]] || die "unable to map template leg B peer ifindex $template_leg_b_peer_ifindex to forwarder port"

client_conn_id="$(port_conn_id "$client_forwarder_port")"
server_conn_id="$(port_conn_id "$server_forwarder_port")"
leg_a_conn_id="$(port_conn_id "$template_leg_a_forwarder_port")"
leg_b_conn_id="$(port_conn_id "$template_leg_b_forwarder_port")"

if [[ "$leg_a_conn_id" == "$client_conn_id" ]]; then
  template_ingress_leg="$template_leg_a"
  template_ingress_forwarder_port="$template_leg_a_forwarder_port"
  template_egress_leg="$template_leg_b"
  template_egress_forwarder_port="$template_leg_b_forwarder_port"
elif [[ "$leg_b_conn_id" == "$client_conn_id" ]]; then
  template_ingress_leg="$template_leg_b"
  template_ingress_forwarder_port="$template_leg_b_forwarder_port"
  template_egress_leg="$template_leg_a"
  template_egress_forwarder_port="$template_leg_a_forwarder_port"
else
  die "unable to match template ingress leg to client connection id $client_conn_id"
fi

if [[ "$(port_conn_id "$template_egress_forwarder_port")" != "$server_conn_id" ]]; then
  die "template egress leg does not map to server connection id $server_conn_id"
fi

client_ofport="$(lookup_ofport "$forwarder_pod" "$client_forwarder_port")"
template_ingress_ofport="$(lookup_ofport "$forwarder_pod" "$template_ingress_forwarder_port")"
template_egress_ofport="$(lookup_ofport "$forwarder_pod" "$template_egress_forwarder_port")"
server_ofport="$(lookup_ofport "$forwarder_pod" "$server_forwarder_port")"

client_before="$tmpdir/client-before.env"
template_ingress_before="$tmpdir/template-ingress-before.env"
template_egress_before="$tmpdir/template-egress-before.env"
server_before="$tmpdir/server-before.env"
client_ofport_before="$tmpdir/client-ofport-before.env"
template_ingress_ofport_before="$tmpdir/template-ingress-ofport-before.env"
template_egress_ofport_before="$tmpdir/template-egress-ofport-before.env"
server_ofport_before="$tmpdir/server-ofport-before.env"

save_snapshot "$client_before" capture_netdev_stats "$NS_NAMESPACE" "$client_pod" "$client_container" "$client_iface"
save_snapshot "$template_ingress_before" capture_netdev_stats "$NS_NAMESPACE" "$template_pod" "$template_container" "$template_ingress_leg"
save_snapshot "$template_egress_before" capture_netdev_stats "$NS_NAMESPACE" "$template_pod" "$template_container" "$template_egress_leg"
save_snapshot "$server_before" capture_netdev_stats "$NS_NAMESPACE" "$server_pod" "$server_container" "$server_iface"
save_snapshot "$client_ofport_before" capture_ofport_stats "$forwarder_pod" "$client_ofport"
save_snapshot "$template_ingress_ofport_before" capture_ofport_stats "$forwarder_pod" "$template_ingress_ofport"
save_snapshot "$template_egress_ofport_before" capture_ofport_stats "$forwarder_pod" "$template_egress_ofport"
save_snapshot "$server_ofport_before" capture_ofport_stats "$forwarder_pod" "$server_ofport"

run_start_rfc3339="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

ping_file="$tmpdir/ping.txt"
iperf_file="$tmpdir/iperf3.txt"
ping_ok="false"
iperf_ok="skipped"

if run_kubectl exec -n "$NS_NAMESPACE" "$client_pod" -c "$client_container" -- \
  ping -c 4 -W 1 "$server_ip" >"$ping_file" 2>&1; then
  ping_ok="true"
fi

if [[ "$EXPECT_RESULT" == "pass" && "$ping_ok" != "true" ]]; then
  cat "$ping_file"
  die "ping failed but pass was expected"
fi

if [[ "$EXPECT_RESULT" == "drop" && "$ping_ok" == "true" ]]; then
  cat "$ping_file"
  die "ping succeeded but drop was expected"
fi

if [[ "$SKIP_IPERF" != "true" ]]; then
  if run_kubectl exec -n "$NS_NAMESPACE" "$client_pod" -c "$client_container" -- \
    iperf3 -c "$server_ip" -p "$IPERF_PORT" -P "$IPERF_PARALLEL" -t "$IPERF_SECONDS" -f g >"$iperf_file" 2>&1; then
    iperf_ok="true"
  else
    iperf_ok="false"
  fi

  if [[ "$EXPECT_RESULT" == "pass" && "$iperf_ok" != "true" ]]; then
    cat "$iperf_file"
    die "iperf3 failed but pass was expected"
  fi

  if [[ "$EXPECT_RESULT" == "drop" && "$iperf_ok" == "true" ]]; then
    cat "$iperf_file"
    die "iperf3 succeeded but drop was expected"
  fi
else
  printf 'iperf3 skipped by request\n' >"$iperf_file"
fi

client_after="$tmpdir/client-after.env"
template_ingress_after="$tmpdir/template-ingress-after.env"
template_egress_after="$tmpdir/template-egress-after.env"
server_after="$tmpdir/server-after.env"
client_ofport_after="$tmpdir/client-ofport-after.env"
template_ingress_ofport_after="$tmpdir/template-ingress-ofport-after.env"
template_egress_ofport_after="$tmpdir/template-egress-ofport-after.env"
server_ofport_after="$tmpdir/server-ofport-after.env"

save_snapshot "$client_after" capture_netdev_stats "$NS_NAMESPACE" "$client_pod" "$client_container" "$client_iface"
save_snapshot "$template_ingress_after" capture_netdev_stats "$NS_NAMESPACE" "$template_pod" "$template_container" "$template_ingress_leg"
save_snapshot "$template_egress_after" capture_netdev_stats "$NS_NAMESPACE" "$template_pod" "$template_container" "$template_egress_leg"
save_snapshot "$server_after" capture_netdev_stats "$NS_NAMESPACE" "$server_pod" "$server_container" "$server_iface"
save_snapshot "$client_ofport_after" capture_ofport_stats "$forwarder_pod" "$client_ofport"
save_snapshot "$template_ingress_ofport_after" capture_ofport_stats "$forwarder_pod" "$template_ingress_ofport"
save_snapshot "$template_egress_ofport_after" capture_ofport_stats "$forwarder_pod" "$template_egress_ofport"
save_snapshot "$server_ofport_after" capture_ofport_stats "$forwarder_pod" "$server_ofport"

client_tx_bytes_delta="$(delta_from_files "$client_before" "$client_after" "tx_bytes")"
client_tx_packets_delta="$(delta_from_files "$client_before" "$client_after" "tx_packets")"
client_rx_bytes_delta="$(delta_from_files "$client_before" "$client_after" "rx_bytes")"
client_rx_packets_delta="$(delta_from_files "$client_before" "$client_after" "rx_packets")"

template_ingress_rx_bytes_delta="$(delta_from_files "$template_ingress_before" "$template_ingress_after" "rx_bytes")"
template_ingress_rx_packets_delta="$(delta_from_files "$template_ingress_before" "$template_ingress_after" "rx_packets")"
template_ingress_tx_bytes_delta="$(delta_from_files "$template_ingress_before" "$template_ingress_after" "tx_bytes")"
template_ingress_tx_packets_delta="$(delta_from_files "$template_ingress_before" "$template_ingress_after" "tx_packets")"

template_egress_rx_bytes_delta="$(delta_from_files "$template_egress_before" "$template_egress_after" "rx_bytes")"
template_egress_rx_packets_delta="$(delta_from_files "$template_egress_before" "$template_egress_after" "rx_packets")"
template_egress_tx_bytes_delta="$(delta_from_files "$template_egress_before" "$template_egress_after" "tx_bytes")"
template_egress_tx_packets_delta="$(delta_from_files "$template_egress_before" "$template_egress_after" "tx_packets")"

server_rx_bytes_delta="$(delta_from_files "$server_before" "$server_after" "rx_bytes")"
server_rx_packets_delta="$(delta_from_files "$server_before" "$server_after" "rx_packets")"
server_tx_bytes_delta="$(delta_from_files "$server_before" "$server_after" "tx_bytes")"
server_tx_packets_delta="$(delta_from_files "$server_before" "$server_after" "tx_packets")"

client_ofport_rx_bytes_delta="$(delta_from_files "$client_ofport_before" "$client_ofport_after" "rx_bytes")"
client_ofport_rx_packets_delta="$(delta_from_files "$client_ofport_before" "$client_ofport_after" "rx_packets")"
client_ofport_tx_bytes_delta="$(delta_from_files "$client_ofport_before" "$client_ofport_after" "tx_bytes")"
client_ofport_tx_packets_delta="$(delta_from_files "$client_ofport_before" "$client_ofport_after" "tx_packets")"

template_ingress_ofport_rx_bytes_delta="$(delta_from_files "$template_ingress_ofport_before" "$template_ingress_ofport_after" "rx_bytes")"
template_ingress_ofport_rx_packets_delta="$(delta_from_files "$template_ingress_ofport_before" "$template_ingress_ofport_after" "rx_packets")"
template_ingress_ofport_tx_bytes_delta="$(delta_from_files "$template_ingress_ofport_before" "$template_ingress_ofport_after" "tx_bytes")"
template_ingress_ofport_tx_packets_delta="$(delta_from_files "$template_ingress_ofport_before" "$template_ingress_ofport_after" "tx_packets")"

template_egress_ofport_rx_bytes_delta="$(delta_from_files "$template_egress_ofport_before" "$template_egress_ofport_after" "rx_bytes")"
template_egress_ofport_rx_packets_delta="$(delta_from_files "$template_egress_ofport_before" "$template_egress_ofport_after" "rx_packets")"
template_egress_ofport_tx_bytes_delta="$(delta_from_files "$template_egress_ofport_before" "$template_egress_ofport_after" "tx_bytes")"
template_egress_ofport_tx_packets_delta="$(delta_from_files "$template_egress_ofport_before" "$template_egress_ofport_after" "tx_packets")"

server_ofport_rx_bytes_delta="$(delta_from_files "$server_ofport_before" "$server_ofport_after" "rx_bytes")"
server_ofport_rx_packets_delta="$(delta_from_files "$server_ofport_before" "$server_ofport_after" "rx_packets")"
server_ofport_tx_bytes_delta="$(delta_from_files "$server_ofport_before" "$server_ofport_after" "tx_bytes")"
server_ofport_tx_packets_delta="$(delta_from_files "$server_ofport_before" "$server_ofport_after" "tx_packets")"

gateway_nft_tables_after="$(gateway_nft_tables "$NS_NAMESPACE" "$template_pod" "$template_container")"
gateway_nft_ruleset_after=""
if [[ "$DUMP_NFT" == "true" ]]; then
  gateway_nft_ruleset_after="$(gateway_nft_ruleset "$NS_NAMESPACE" "$template_pod" "$template_container")"
fi

if ((client_tx_bytes_delta <= 0)); then
  die "client transmitted no payload during verification"
fi

if [[ -z "$gateway_nft_tables_after" ]]; then
  die "gateway nftables session tables not found"
fi

if [[ "$EXPECT_RESULT" == "pass" ]]; then
  if ((template_ingress_rx_bytes_delta <= 0 || template_egress_tx_bytes_delta <= 0)); then
    die "gateway dataplane counters did not move on both sides during pass verification"
  fi

  if ((server_rx_bytes_delta <= 0)); then
    die "server received no traffic during pass verification"
  fi
else
  if ((template_ingress_rx_bytes_delta <= 0)); then
    die "gateway ingress counters did not move during drop verification"
  fi
fi

client_log_hits="$(run_kubectl logs -n "$NS_NAMESPACE" "$client_pod" -c "$client_cmd_container" --since-time="$run_start_rfc3339" | grep -n 'RESELECT_REQUESTED' || true)"
template_log_hits="$(run_kubectl logs -n "$NS_NAMESPACE" "$template_pod" -c "$template_container" --since-time="$run_start_rfc3339" | grep -n 'inline close requested' || true)"

iperf_sender_line="$(awk '/sender$/ { line = $0 } END { print line }' "$iperf_file")"
iperf_receiver_line="$(awk '/receiver$/ { line = $0 } END { print line }' "$iperf_file")"

echo "== Context =="
echo "Namespace           : $NS_NAMESPACE"
echo "Node                : $client_node"
echo "Expected result     : $EXPECT_RESULT"
echo "Forwarder pod       : $forwarder_pod"
echo "Client pod          : $client_pod ($client_iface $client_ip)"
echo "Gateway pod         : $template_pod (bridge $template_bridge, ingress $template_ingress_leg, egress $template_egress_leg)"
echo "Server pod          : $server_pod ($server_iface $server_ip)"
echo

echo "== Ping Output =="
cat "$ping_file"
echo "Ping status         : $ping_ok"
echo

echo "== iperf3 Output =="
cat "$iperf_file"
echo "iperf3 status       : $iperf_ok"
echo

echo "== iperf3 Summary =="
echo "Sender   : ${iperf_sender_line:-not found}"
echo "Receiver : ${iperf_receiver_line:-not found}"
echo

echo "== Gateway nftables Tables =="
echo "${gateway_nft_tables_after}"
echo

if [[ "$DUMP_NFT" == "true" ]]; then
  echo "== Gateway nftables Ruleset =="
  echo "${gateway_nft_ruleset_after}"
  echo
fi

echo "== Path Proof =="
echo "Forward data path: client -> forwarder -> gateway ingress -> bridge -> gateway egress -> forwarder -> server"
render_leg_line "Client TX" "$client_pod" "$client_iface" "+$(fmt_bytes_gib "$client_tx_bytes_delta") / +$(fmt_count "$client_tx_packets_delta") pkts"
render_leg_line "FWD RX" "$forwarder_pod" "$client_forwarder_port/$client_ofport" "+$(fmt_bytes_gib "$client_ofport_rx_bytes_delta") / +$(fmt_count "$client_ofport_rx_packets_delta") pkts"
render_leg_line "FWD TX" "$forwarder_pod" "$template_ingress_forwarder_port/$template_ingress_ofport" "+$(fmt_bytes_gib "$template_ingress_ofport_tx_bytes_delta") / +$(fmt_count "$template_ingress_ofport_tx_packets_delta") pkts"
render_leg_line "Ingress RX" "$template_pod" "$template_ingress_leg" "+$(fmt_bytes_gib "$template_ingress_rx_bytes_delta") / +$(fmt_count "$template_ingress_rx_packets_delta") pkts"
render_leg_line "Bridge" "$template_pod" "$template_bridge" "local handoff inside inline gateway"
render_leg_line "Egress TX" "$template_pod" "$template_egress_leg" "+$(fmt_bytes_gib "$template_egress_tx_bytes_delta") / +$(fmt_count "$template_egress_tx_packets_delta") pkts"
render_leg_line "FWD RX" "$forwarder_pod" "$template_egress_forwarder_port/$template_egress_ofport" "+$(fmt_bytes_gib "$template_egress_ofport_rx_bytes_delta") / +$(fmt_count "$template_egress_ofport_rx_packets_delta") pkts"
render_leg_line "FWD TX" "$forwarder_pod" "$server_forwarder_port/$server_ofport" "+$(fmt_bytes_gib "$server_ofport_tx_bytes_delta") / +$(fmt_count "$server_ofport_tx_packets_delta") pkts"
render_leg_line "Server RX" "$server_pod" "$server_iface" "+$(fmt_bytes_gib "$server_rx_bytes_delta") / +$(fmt_count "$server_rx_packets_delta") pkts"
echo

echo "Reverse path: server -> forwarder -> gateway egress -> bridge -> gateway ingress -> forwarder -> client"
render_leg_line "Server TX" "$server_pod" "$server_iface" "+$(fmt_bytes_gib "$server_tx_bytes_delta") / +$(fmt_count "$server_tx_packets_delta") pkts"
render_leg_line "FWD RX" "$forwarder_pod" "$server_forwarder_port/$server_ofport" "+$(fmt_bytes_gib "$server_ofport_rx_bytes_delta") / +$(fmt_count "$server_ofport_rx_packets_delta") pkts"
render_leg_line "FWD TX" "$forwarder_pod" "$template_egress_forwarder_port/$template_egress_ofport" "+$(fmt_bytes_gib "$template_egress_ofport_tx_bytes_delta") / +$(fmt_count "$template_egress_ofport_tx_packets_delta") pkts"
render_leg_line "Egress RX" "$template_pod" "$template_egress_leg" "+$(fmt_bytes_gib "$template_egress_rx_bytes_delta") / +$(fmt_count "$template_egress_rx_packets_delta") pkts"
render_leg_line "Bridge" "$template_pod" "$template_bridge" "local handoff inside inline gateway"
render_leg_line "Ingress TX" "$template_pod" "$template_ingress_leg" "+$(fmt_bytes_gib "$template_ingress_tx_bytes_delta") / +$(fmt_count "$template_ingress_tx_packets_delta") pkts"
render_leg_line "FWD RX" "$forwarder_pod" "$template_ingress_forwarder_port/$template_ingress_ofport" "+$(fmt_bytes_gib "$template_ingress_ofport_rx_bytes_delta") / +$(fmt_count "$template_ingress_ofport_rx_packets_delta") pkts"
render_leg_line "FWD TX" "$forwarder_pod" "$client_forwarder_port/$client_ofport" "+$(fmt_bytes_gib "$client_ofport_tx_bytes_delta") / +$(fmt_count "$client_ofport_tx_packets_delta") pkts"
render_leg_line "Client RX" "$client_pod" "$client_iface" "+$(fmt_bytes_gib "$client_rx_bytes_delta") / +$(fmt_count "$client_rx_packets_delta") pkts"
echo

echo "== ASCII Diagram =="
cat <<EOF
[$client_pod]
  client:$client_iface ($client_ip)
  TX +$(fmt_bytes_gib "$client_tx_bytes_delta") / +$(fmt_count "$client_tx_packets_delta") pkts
        |
        |  $forwarder_pod:$client_forwarder_port (ofport $client_ofport)
        |  RX +$(fmt_bytes_gib "$client_ofport_rx_bytes_delta") / +$(fmt_count "$client_ofport_rx_packets_delta") pkts
        v
[$template_pod]
  ingress:$template_ingress_leg  RX +$(fmt_bytes_gib "$template_ingress_rx_bytes_delta") / +$(fmt_count "$template_ingress_rx_packets_delta") pkts
  bridge:$template_bridge        local handoff
  egress:$template_egress_leg    TX +$(fmt_bytes_gib "$template_egress_tx_bytes_delta") / +$(fmt_count "$template_egress_tx_packets_delta") pkts
        |
        |  $forwarder_pod:$template_egress_forwarder_port (ofport $template_egress_ofport)
        |  RX +$(fmt_bytes_gib "$template_egress_ofport_rx_bytes_delta") / +$(fmt_count "$template_egress_ofport_rx_packets_delta") pkts
        v
[$server_pod]
  nse:$server_iface ($server_ip)
  RX +$(fmt_bytes_gib "$server_rx_bytes_delta") / +$(fmt_count "$server_rx_packets_delta") pkts
EOF
echo

echo "== Control Plane Checks =="
if [[ -n "$client_log_hits" ]]; then
  echo "cmd-nsc reselect detected:"
  echo "$client_log_hits"
  exit 1
fi
echo "cmd-nsc reselect        : clean"

if [[ -n "$template_log_hits" ]]; then
  echo "gateway close detected:"
  echo "$template_log_hits"
  exit 1
fi
echo "gateway inline close    : clean"
echo

echo "Verification result: PASS (${EXPECT_RESULT})"
