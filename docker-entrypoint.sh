#!/usr/bin/env bash
#
# Container entrypoint. Reads config from the environment, reuses setup.sh
# for everything (same logic as the bare-metal path, no duplication), then
# hands off to cupsd in the foreground so it's the real container process
# and actually receives docker stop / SIGTERM.
#
# Env vars:
#   PRINTER_IP   required, the printer's IP address
#   QUEUE_NAME   optional, default BridgePrinter
#   IPP_PATH     optional, auto-detected by setup.sh if unset
#   BIND_IP      optional, passed through as --bind-ip if set
#
set -euo pipefail

if [ -z "${PRINTER_IP:-}" ]; then
    echo "PRINTER_IP environment variable is required." >&2
    exit 1
fi

# cupsd registers printers with Avahi over D-Bus. There's no systemd here to
# start the system bus, so start it directly; without this, cupsd logs
# "Unable to communicate with avahi-daemon" and nothing actually advertises.
if ! pgrep -x dbus-daemon >/dev/null 2>&1; then
    mkdir -p /var/run/dbus
    dbus-uuidgen --ensure
    dbus-daemon --system --fork
fi

ARGS=(--name "${QUEUE_NAME:-BridgePrinter}")
if [ -n "${IPP_PATH:-}" ]; then
    ARGS+=(--path "$IPP_PATH")
fi
if [ -n "${BIND_IP:-}" ]; then
    ARGS+=(--bind-ip "$BIND_IP")
fi

/usr/local/bin/setup.sh "$PRINTER_IP" "${ARGS[@]}"

# setup.sh's "no init system" mode leaves cupsd running in the background,
# since it doesn't know it's the last thing that will ever run in this
# process tree. Bring it into the foreground now, as the actual PID 1
# workload, so container lifecycle signals reach it directly.
pkill -x cupsd 2>/dev/null || true
exec cupsd -f
