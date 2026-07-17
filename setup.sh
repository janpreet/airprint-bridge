#!/usr/bin/env bash
#
# airprint-bridge: turn a spare Linux box into an AirPrint bridge for a
# network printer that doesn't speak AirPrint/Bonjour itself. OS-agnostic:
# detects the package manager (apt, dnf/yum, pacman, zypper, apk) and the
# init system (systemd or OpenRC) and adapts accordingly.
#
# Usage:
#   sudo ./setup.sh <printer-ip> [options]
#
# Options:
#   --name <queue-name>   CUPS queue name (default: BridgePrinter)
#   --path <ipp-path>     IPP resource path on the printer, e.g. /ipp/print.
#                         If omitted, the script probes common paths itself.
#   --bind-ip <ip>        IP to verify CUPS on, if auto-detection picks the
#                         wrong interface on a multi-homed box.
#   --remove              Remove the queue this script created and exit.
#   -h, --help            Show this help.
#
# What it does:
#   - installs cups, cups-client, avahi-daemon, avahi-utils if missing,
#     using whichever package manager the host actually has
#   - disables cups-browsed (not needed here, and it's the component behind
#     the 2024 CUPS remote-code-execution CVEs, see README)
#   - adds the printer as a driverless "IPP Everywhere" queue and shares it
#   - makes sure CUPS actually listens on the network (not just localhost)
#     while leaving /admin locked to local access only
#   - verifies the result with a real IPP query and an Avahi browse, not
#     just by trusting that the commands ran without error
#
set -euo pipefail

QUEUE_NAME="BridgePrinter"
IPP_PATH=""
PRINTER_IP=""
BIND_IP=""
REMOVE=false

usage() {
    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --name) QUEUE_NAME="$2"; shift 2 ;;
        --path) IPP_PATH="$2"; shift 2 ;;
        --bind-ip) BIND_IP="$2"; shift 2 ;;
        --remove) REMOVE=true; shift ;;
        -h|--help) usage 0 ;;
        -*) echo "Unknown option: $1" >&2; usage 1 ;;
        *)
            if [ -z "$PRINTER_IP" ]; then PRINTER_IP="$1"; else echo "Unexpected argument: $1" >&2; usage 1; fi
            shift
            ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this with sudo." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# OS / package manager detection
# ---------------------------------------------------------------------------
PKG_MGR=""
for candidate in apt-get dnf yum zypper pacman apk; do
    if command -v "$candidate" >/dev/null 2>&1; then
        PKG_MGR="$candidate"
        break
    fi
done
if [ -z "$PKG_MGR" ]; then
    echo "Couldn't find a supported package manager (apt-get, dnf, yum, zypper, pacman, apk)." >&2
    exit 1
fi

# Package names differ slightly across distros for the same software.
case "$PKG_MGR" in
    apt-get) PKGS=(cups cups-client avahi-daemon avahi-utils) ;;
    dnf|yum) PKGS=(cups cups-client avahi avahi-tools) ;;
    zypper)  PKGS=(cups cups-client avahi avahi-utils) ;;
    pacman)  PKGS=(cups avahi) ;;                     # Arch's cups includes the client tools
    apk)     PKGS=(cups cups-client avahi avahi-tools) ;;
esac

pkg_update() {
    case "$PKG_MGR" in
        apt-get) apt-get update -qq ;;
        dnf)     dnf makecache -q ;;
        yum)     yum makecache -q ;;
        zypper)  zypper --quiet refresh ;;
        pacman)  pacman -Sy --noconfirm >/dev/null ;;
        apk)     apk update -q ;;
    esac
}

pkg_install() {
    case "$PKG_MGR" in
        apt-get) apt-get install -y -qq "${PKGS[@]}" >/dev/null ;;
        dnf)     dnf install -y -q "${PKGS[@]}" >/dev/null ;;
        yum)     yum install -y -q "${PKGS[@]}" >/dev/null ;;
        zypper)  zypper --quiet install -y "${PKGS[@]}" ;;
        pacman)  pacman -S --noconfirm --needed "${PKGS[@]}" >/dev/null ;;
        apk)     apk add -q "${PKGS[@]}" ;;
    esac
}

# systemd vs OpenRC (Alpine and some minimal distros) vs no init system at
# all (containers). In that last case there's no service manager to ask, so
# we start/stop the daemons directly, as background processes.
INIT_SYS=""
if command -v systemctl >/dev/null 2>&1 && systemctl >/dev/null 2>&1; then
    INIT_SYS="systemd"
elif command -v rc-service >/dev/null 2>&1; then
    INIT_SYS="openrc"
else
    INIT_SYS="none"
fi

svc_enable_start() {
    case "$INIT_SYS" in
        systemd) systemctl enable --now "$1" >/dev/null 2>&1 || systemctl restart "$1" ;;
        openrc)  rc-update add "$1" default >/dev/null 2>&1 || true; rc-service "$1" restart ;;
        none)
            case "$1" in
                avahi-daemon) pgrep -x avahi-daemon >/dev/null 2>&1 || avahi-daemon -D ;;
                cups)         pgrep -x cupsd >/dev/null 2>&1 || cupsd ;;
            esac
            ;;
    esac
}

svc_stop_disable() {
    case "$INIT_SYS" in
        systemd) systemctl stop "$1" 2>/dev/null || true; systemctl disable "$1" 2>/dev/null || true ;;
        openrc)  rc-service "$1" stop 2>/dev/null || true; rc-update del "$1" default 2>/dev/null || true ;;
        none)    pkill -f "$1" 2>/dev/null || true ;;
    esac
}

svc_restart() {
    case "$INIT_SYS" in
        systemd) systemctl restart "$1" ;;
        openrc)  rc-service "$1" restart ;;
        none)
            case "$1" in
                avahi-daemon) pkill -x avahi-daemon 2>/dev/null || true; avahi-daemon -D ;;
                cups)         pkill -x cupsd 2>/dev/null || true; cupsd ;;
            esac
            ;;
    esac
}

# Portable-ish primary IP detection (avoids relying on GNU-only `hostname -I`,
# which BusyBox/musl systems like Alpine don't have).
detect_ip() {
    if [ -n "$BIND_IP" ]; then
        echo "$BIND_IP"
        return
    fi
    if command -v ip >/dev/null 2>&1; then
        ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}'
        return
    fi
    hostname -I 2>/dev/null | awk '{print $1}'
}

if $REMOVE; then
    echo "Removing CUPS queue '$QUEUE_NAME'..."
    lpadmin -x "$QUEUE_NAME" 2>/dev/null || true
    echo "Done. Packages (cups, avahi) were left installed; remove them yourself if this box shouldn't be a bridge at all anymore."
    exit 0
fi

if [ -z "$PRINTER_IP" ]; then
    echo "Missing printer IP." >&2
    usage 1
fi

echo "==> Detected package manager: $PKG_MGR, init system: $INIT_SYS"

echo "==> Checking package mirror"
APT_SOURCES_FILE="${APT_SOURCES_FILE:-/etc/apt/sources.list}"
if ! pkg_update 2>/tmp/pkg-update-err.$$; then
    ERR="$(cat /tmp/pkg-update-err.$$ 2>/dev/null || true)"
    if [ "$PKG_MGR" = "apt-get" ] && echo "$ERR" | grep -q "raspbian.raspberrypi.org.*no longer has a Release file"; then
        echo "Detected an EOL Raspbian mirror. Pointing sources.list at the legacy archive."
        sed -i 's|raspbian\.raspberrypi\.org|legacy.raspbian.org|' "$APT_SOURCES_FILE"
        pkg_update
    elif [ "$PKG_MGR" = "apt-get" ] && echo "$ERR" | grep -qE "(deb|security)\.debian\.org.*no longer has a Release file"; then
        echo "Detected an EOL Debian mirror. Pointing sources.list at archive.debian.org."
        sed -i 's|deb\.debian\.org|archive.debian.org|g; s|security\.debian\.org|archive.debian.org|g' "$APT_SOURCES_FILE"
        pkg_update
    else
        echo "$ERR" >&2
        rm -f /tmp/pkg-update-err.$$
        exit 1
    fi
fi
rm -f /tmp/pkg-update-err.$$

echo "==> Installing packages"
pkg_install

echo "==> Disabling cups-browsed"
# We add our printer explicitly below; cups-browsed's job is auto-discovering
# and auto-adding printers advertised by anyone on the network, which is both
# unneeded here and the component behind CVE-2024-47176/47076/47175/47177.
svc_stop_disable cups-browsed

echo "==> Making sure cups and avahi are actually running"
svc_enable_start avahi-daemon
svc_enable_start cups

echo "==> Finding the printer's IPP endpoint"
if [ -z "$IPP_PATH" ]; then
    FOUND=""
    for candidate in /ipp/print /ipp /; do
        if timeout 5 ipptool -q "ipp://${PRINTER_IP}:631${candidate}" \
            /usr/share/cups/ipptool/get-printer-attributes.test >/dev/null 2>&1; then
            FOUND="$candidate"
            break
        fi
    done
    if [ -z "$FOUND" ]; then
        echo "Couldn't auto-detect the IPP path on ${PRINTER_IP}:631." >&2
        echo "Check the printer supports IPP (port 631) and pass it explicitly with --path." >&2
        exit 1
    fi
    IPP_PATH="$FOUND"
    echo "    using ${IPP_PATH}"
fi

echo "==> Adding the printer as a driverless queue"
lpadmin -p "$QUEUE_NAME" -E -v "ipp://${PRINTER_IP}:631${IPP_PATH}" -m everywhere
cupsenable "$QUEUE_NAME"
cupsaccept "$QUEUE_NAME"
lpadmin -p "$QUEUE_NAME" -o printer-is-shared=true

echo "==> Making sure CUPS actually listens on the network"
CUPSD_CONF="${CUPSD_CONF:-/etc/cups/cupsd.conf}"
sed -i 's/^Listen localhost:631/Listen 631/' "$CUPSD_CONF"
if ! grep -q '^Listen 631$' "$CUPSD_CONF"; then
    sed -i '/^Listen \/run\/cups\/cups.sock/i Listen 631' "$CUPSD_CONF"
fi
# Ensure the root Location allows LAN access (this is what actually serves
# print jobs), without touching /admin, which stays locked to local-only.
if ! awk '/<Location \/>/{f=1} f && /Allow all/{found=1} f && /<\/Location>/{f=0} END{exit !found}' "$CUPSD_CONF"; then
    perl -0pi -e 's{(<Location />\s*\n(?:\s*#[^\n]*\n)?\s*Order allow,deny\n)(\s*</Location>)}{$1  Allow all\n$2}' "$CUPSD_CONF"
fi
svc_restart cups
sleep 2

echo "==> Verifying over the actual network (not just localhost)"
OWN_IP="$(detect_ip)"
if [ -z "$OWN_IP" ]; then
    echo "Warning: couldn't auto-detect this box's IP; pass --bind-ip explicitly to verify." >&2
else
    STATUS=$(curl -s -o /dev/null -w '%{http_code}' "http://${OWN_IP}:631/printers/${QUEUE_NAME}" || echo "000")
    if [ "$STATUS" != "200" ]; then
        echo "Warning: printer status page returned HTTP $STATUS from ${OWN_IP}, expected 200." >&2
        echo "Printing may not actually work from other devices yet. Check ${CUPSD_CONF} by hand." >&2
    else
        echo "    printer status page reachable over the network (HTTP 200)"
    fi

    ADMIN_STATUS=$(curl -s -o /dev/null -w '%{http_code}' "http://${OWN_IP}:631/admin" || echo "000")
    if [ "$ADMIN_STATUS" = "200" ]; then
        echo "Warning: /admin is reachable from the network (HTTP 200). It should be locked to local access." >&2
    else
        echo "    admin UI correctly blocked from the network (HTTP $ADMIN_STATUS)"
    fi
fi

echo "==> Checking Avahi is actually advertising it"
# On a cold start (fresh container: dbus + avahi + cups all coming up at
# once) this can genuinely take longer than one quick browse to appear, so
# retry a few times before calling it a real problem.
SEEN_ON_MDNS=false
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if timeout 6 avahi-browse -rt _ipp._tcp 2>/dev/null | grep -qi "rp=printers/${QUEUE_NAME}"; then
        SEEN_ON_MDNS=true
        break
    fi
    sleep 3
done
if $SEEN_ON_MDNS; then
    echo "    seen advertising over mDNS"
else
    echo "Warning: didn't see '${QUEUE_NAME}' in an Avahi browse within ~30s. This check is" >&2
    echo "sometimes slower than reality on a cold container start (dbus + avahi + cups all" >&2
    echo "starting together); it does not necessarily mean advertising failed. Confirm with:" >&2
    echo "    avahi-browse -rt _ipp._tcp" >&2
fi

echo
echo "Done. '${QUEUE_NAME}' should now show up in the AirPrint picker on any"
echo "iOS/iPadOS device on this same network segment (mDNS doesn't cross"
echo "VLANs or subnets, see the README if that's your situation)."
