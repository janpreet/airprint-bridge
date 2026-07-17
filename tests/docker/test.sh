#!/usr/bin/env bash
#
# Docker smoke test: builds the image and runs it against a fake printer
# address (no real printer needed), then checks the things that actually
# matter: cupsd is the real container process, the printer queue exists and
# is reachable over the network (not just localhost), and /admin is locked
# down. Doesn't hard-fail on the Avahi mDNS check alone, since that can be
# genuinely slower than this script's patience on a cold start without that
# meaning anything is actually broken; it's reported, not required.
set -euo pipefail

cd "$(dirname "$0")/../.."
IMAGE_TAG="airprint-bridge:smoketest"
CONTAINER_NAME="airprint-bridge-smoketest"

# shellcheck disable=SC2317,SC2329 # invoked indirectly via trap, not directly
cleanup() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Building image"
docker build -t "$IMAGE_TAG" . >/dev/null

echo "==> Starting container against a fake printer (192.0.2.51, IETF TEST-NET, never real)"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER_NAME" \
    -e PRINTER_IP=192.0.2.51 \
    -e IPP_PATH=/ipp/print \
    "$IMAGE_TAG" >/dev/null

echo "==> Waiting for setup to finish"
FAIL=0
for _ in $(seq 1 30); do
    if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "^Done\."; then
        break
    fi
    sleep 2
done
LOGS="$(docker logs "$CONTAINER_NAME" 2>&1)"
if ! echo "$LOGS" | grep -q "^Done\."; then
    echo "FAIL: setup never reached completion" >&2
    echo "$LOGS" >&2
    exit 1
fi

echo "==> Checking cupsd is the real container process (PID 1), not orphaned in the background"
MAIN_CMD="$(docker exec "$CONTAINER_NAME" ps -o comm= -p 1)"
if [ "$MAIN_CMD" != "cupsd" ]; then
    echo "FAIL: PID 1 is '$MAIN_CMD', expected cupsd" >&2
    FAIL=1
else
    echo "    OK: PID 1 is cupsd"
fi

echo "==> Checking the printer queue exists"
if docker exec "$CONTAINER_NAME" lpstat -p BridgePrinter >/dev/null 2>&1; then
    echo "    OK: queue exists"
else
    echo "FAIL: BridgePrinter queue not found" >&2
    FAIL=1
fi

echo "==> Checking the printer is reachable over the network, not just localhost"
CONTAINER_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER_NAME")"
STATUS="$(docker exec "$CONTAINER_NAME" curl -s -o /dev/null -w '%{http_code}' "http://${CONTAINER_IP}:631/printers/BridgePrinter")"
if [ "$STATUS" = "200" ]; then
    echo "    OK: printer page reachable (HTTP 200) via ${CONTAINER_IP}"
else
    echo "FAIL: printer page returned HTTP $STATUS via ${CONTAINER_IP}, expected 200" >&2
    FAIL=1
fi

echo "==> Checking /admin is locked down from the network"
ADMIN_STATUS="$(docker exec "$CONTAINER_NAME" curl -s -o /dev/null -w '%{http_code}' "http://${CONTAINER_IP}:631/admin")"
if [ "$ADMIN_STATUS" = "403" ]; then
    echo "    OK: /admin correctly blocked (HTTP 403)"
else
    echo "FAIL: /admin returned HTTP $ADMIN_STATUS via ${CONTAINER_IP}, expected 403" >&2
    FAIL=1
fi

echo "==> Checking Avahi advertising (best-effort, not required to pass)"
if docker exec "$CONTAINER_NAME" avahi-browse -rt _ipp._tcp 2>/dev/null | grep -qi "rp=printers/BridgePrinter"; then
    echo "    OK: seen advertising over mDNS"
else
    echo "    NOTE: not seen yet; this alone doesn't fail the smoke test, see setup.sh's own comment on why"
fi

if [ "$FAIL" -eq 0 ]; then
    echo
    echo "PASS"
    exit 0
else
    echo
    echo "FAIL"
    exit 1
fi
