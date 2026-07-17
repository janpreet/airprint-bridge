#!/usr/bin/env bash
#
# Helm chart tests: helm lint plus assertions on helm template output. No
# cluster needed, these just check the chart renders the right thing given
# different values.
#
# shellcheck disable=SC2034 # OUT is read indirectly, via eval, inside check()
set -euo pipefail

cd "$(dirname "$0")/../.."
CHART=charts/airprint-bridge
FAIL=0

check() {
    local desc="$1"
    if eval "${*:2}"; then
        echo "    OK: $desc"
    else
        echo "FAIL: $desc" >&2
        FAIL=1
    fi
}

echo "==> helm lint"
if ! helm lint "$CHART" --set printer.ip=192.0.2.51 >/dev/null; then
    echo "FAIL: helm lint" >&2
    FAIL=1
else
    echo "    OK: helm lint"
fi

echo "==> missing printer.ip fails to render"
# helm template is expected to fail here; capture its output without letting
# that expected failure trip pipefail before grep gets to look at it.
MISSING_IP_OUTPUT="$(helm template t "$CHART" 2>&1 || true)"
if echo "$MISSING_IP_OUTPUT" | grep -q "printer.ip is required"; then
    echo "    OK: fails with a clear message"
else
    echo "FAIL: rendering without printer.ip should fail with a clear message" >&2
    FAIL=1
fi

echo "==> default values (hostNetwork on, no Service)"
OUT="$(helm template t "$CHART" --set printer.ip=192.0.2.51)"
check "hostNetwork: true is set"           "echo \"\$OUT\" | grep -q 'hostNetwork: true'"
check "dnsPolicy is ClusterFirstWithHostNet" "echo \"\$OUT\" | grep -q 'dnsPolicy: ClusterFirstWithHostNet'"
check "replicas is 1"                       "echo \"\$OUT\" | grep -q 'replicas: 1'"
check "no extra capabilities by default (tested: none needed)" "! echo \"\$OUT\" | grep -q 'securityContext'"
check "PRINTER_IP env var is set correctly" "echo \"\$OUT\" | grep -A1 'name: PRINTER_IP' | grep -q '192.0.2.51'"
check "no Service is rendered by default"   "! echo \"\$OUT\" | grep -q 'kind: Service'"

echo "==> custom queue name and IPP path propagate"
OUT="$(helm template t "$CHART" --set printer.ip=192.0.2.51 --set queueName=OfficePrinter --set printer.ippPath=/ipp/print)"
check "QUEUE_NAME reflects the override"  "echo \"\$OUT\" | grep -A1 'name: QUEUE_NAME' | grep -q 'OfficePrinter'"
check "IPP_PATH is set when provided"      "echo \"\$OUT\" | grep -q 'name: IPP_PATH'"

echo "==> IPP_PATH is omitted when not set (container auto-probes instead)"
OUT="$(helm template t "$CHART" --set printer.ip=192.0.2.51)"
check "no IPP_PATH env var by default" "! echo \"\$OUT\" | grep -q 'name: IPP_PATH'"

echo "==> service.enabled=true renders a Service"
OUT="$(helm template t "$CHART" --set printer.ip=192.0.2.51 --set service.enabled=true --set service.type=ClusterIP)"
check "Service is rendered"    "echo \"\$OUT\" | grep -q 'kind: Service'"
check "Service type is ClusterIP" "echo \"\$OUT\" | grep -q 'type: ClusterIP'"

echo "==> an explicit capability override still renders correctly (escape hatch works)"
OUT="$(helm template t "$CHART" --set printer.ip=192.0.2.51 --set capabilities.add\[0\]=NET_RAW)"
check "requested capability is rendered" "echo \"\$OUT\" | grep -q 'NET_RAW'"

echo "==> hostNetwork can be turned off (dnsPolicy line should disappear with it)"
OUT="$(helm template t "$CHART" --set printer.ip=192.0.2.51 --set hostNetwork=false)"
check "hostNetwork: false is set"        "echo \"\$OUT\" | grep -q 'hostNetwork: false'"
check "dnsPolicy is not forced"          "! echo \"\$OUT\" | grep -q 'dnsPolicy: ClusterFirstWithHostNet'"

if [ "$FAIL" -eq 0 ]; then
    echo
    echo "PASS"
    exit 0
else
    echo
    echo "FAIL"
    exit 1
fi
