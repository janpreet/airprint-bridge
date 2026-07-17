#!/usr/bin/env bats
#
# Tests for setup.sh. Everything that would touch the real system (package
# managers, systemd/OpenRC, cups tools, network calls) is faked with stub
# binaries in a per-test PATH, so these are safe to run anywhere, including
# on a dev machine that isn't Linux at all.

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/setup.sh"

setup() {
    MOCK_BIN="$(mktemp -d)"
    MOCK_STATE="$(mktemp -d)"
    CALL_LOG="$MOCK_STATE/calls.log"
    touch "$CALL_LOG"
    export MOCK_BIN MOCK_STATE CALL_LOG
    export PATH="$MOCK_BIN:$PATH"

    # The script assumes GNU sed, which every real target distro here ships
    # by default. This dev machine's /usr/bin/sed is BSD sed, so on macOS
    # only, prefer GNU sed (installed via `brew install gnu-sed`) so tests
    # validate real target-platform behavior instead of macOS quirks.
    if [[ "$(uname)" == "Darwin" ]] && [ -d /usr/local/opt/gnu-sed/libexec/gnubin ]; then
        export PATH="/usr/local/opt/gnu-sed/libexec/gnubin:$PATH"
    fi

    APT_SOURCES_FILE="$MOCK_STATE/sources.list"
    CUPSD_CONF="$MOCK_STATE/cupsd.conf"
    export APT_SOURCES_FILE CUPSD_CONF
}

teardown() {
    rm -rf "$MOCK_BIN" "$MOCK_STATE"
}

# A PATH containing ONLY real coreutils the script genuinely needs (resolved
# from the environment as it was before any test touched PATH) plus whatever
# is in MOCK_BIN. Used when a test needs to guarantee something's absence
# (systemctl, rc-service) regardless of what the host actually has installed,
# the same portability issue as the "no package manager" test above.
build_isolated_path() {
    local real_tools_dir
    real_tools_dir="$(mktemp -d)"
    # type -P (unlike command -v) ignores aliases/functions and only ever
    # returns a real executable path, which matters here: this shell aliases
    # `grep` to `grep`, so command -v would resolve to a self-referential
    # non-path and silently produce a broken symlink.
    for tool in bash sed grep awk perl rm cat sleep; do
        ln -s "$(type -P "$tool")" "$real_tools_dir/$tool"
    done
    echo "$real_tools_dir"
}

# Writes an executable stub to $MOCK_BIN/$1 with body $2. Every stub logs its
# own invocation first, so tests can assert on what was actually called.
mock() {
    local name="$1" body="$2"
    cat > "$MOCK_BIN/$name" <<EOF
#!/usr/bin/env bash
echo "$name \$*" >> "$CALL_LOG"
$body
EOF
    chmod +x "$MOCK_BIN/$name"
}

mock_root_and_apt_systemd() {
    mock id 'if [ "$1" = "-u" ]; then echo 0; fi'
    mock apt-get 'case "$1" in update) exit 0 ;; install) exit 0 ;; esac'
    mock systemctl 'exit 0'
    mock lpadmin 'exit 0'
    mock cupsenable 'exit 0'
    mock cupsaccept 'exit 0'
    mock timeout 'shift; exec "$@"'
    mock ipptool 'exit 0'
    mock curl 'echo 200'
    mock avahi-browse 'echo "rp=printers/BridgePrinter"'
    write_default_cupsd_conf
}

# A minimal but structurally real cupsd.conf, same shape CUPS actually ships.
# Tests that care about the patching logic specifically overwrite this with
# their own variant; everything else just needs a valid file to operate on.
write_default_cupsd_conf() {
    cat > "$CUPSD_CONF" <<'EOF'
LogLevel warn
Listen localhost:631
Listen /run/cups/cups.sock
Browsing On
<Location />
  # Restrict access to the server...
  Order allow,deny
</Location>
<Location /admin>
  # Restrict access to the admin pages...
  Order allow,deny
</Location>
EOF
}

@test "--help prints usage and exits 0" {
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"airprint-bridge:"* ]]
}

@test "unknown option is rejected before anything else runs" {
    run "$SCRIPT" --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown option: --bogus"* ]]
}

@test "refuses to run without root" {
    # deliberately no id mock: uses the real, non-root test-runner user
    run "$SCRIPT" 192.0.2.51
    [ "$status" -eq 1 ]
    [[ "$output" == *"Run this with sudo."* ]]
}

@test "missing printer IP is rejected once root/OS checks pass" {
    mock_root_and_apt_systemd
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Missing printer IP."* ]]
}

@test "--remove calls lpadmin -x with the right queue name" {
    mock_root_and_apt_systemd
    run "$SCRIPT" --remove --name TestQueue
    [ "$status" -eq 0 ]
    grep -q "lpadmin -x TestQueue" "$CALL_LOG"
}

@test "detects apt-get and installs the debian package set" {
    mock_root_and_apt_systemd
    run "$SCRIPT" 192.0.2.51 --bind-ip 203.0.113.5
    [ "$status" -eq 0 ]
    [[ "$output" == *"Detected package manager: apt-get, init system: systemd"* ]]
    grep -q "apt-get install -y -qq cups cups-client avahi-daemon avahi-utils" "$CALL_LOG"
}

@test "detects dnf and installs the fedora package set" {
    mock id 'if [ "$1" = "-u" ]; then echo 0; fi'
    mock dnf 'case "$1" in makecache) exit 0 ;; install) exit 0 ;; esac'
    mock systemctl 'exit 0'
    mock lpadmin 'exit 0'
    mock cupsenable 'exit 0'
    mock cupsaccept 'exit 0'
    mock timeout 'shift; exec "$@"'
    mock ipptool 'exit 0'
    mock curl 'echo 200'
    mock avahi-browse 'echo "rp=printers/BridgePrinter"'
    write_default_cupsd_conf

    run "$SCRIPT" 192.0.2.51 --bind-ip 203.0.113.5
    [ "$status" -eq 0 ]
    [[ "$output" == *"Detected package manager: dnf, init system: systemd"* ]]
    grep -q "dnf install -y -q cups cups-client avahi avahi-tools" "$CALL_LOG"
}

@test "falls back to OpenRC when systemctl is absent" {
    mock id 'if [ "$1" = "-u" ]; then echo 0; fi'
    mock apk 'case "$1" in update) exit 0 ;; add) exit 0 ;; esac'
    mock rc-service 'exit 0'
    mock rc-update 'exit 0'
    mock lpadmin 'exit 0'
    mock cupsenable 'exit 0'
    mock cupsaccept 'exit 0'
    mock timeout 'shift; exec "$@"'
    mock ipptool 'exit 0'
    mock curl 'echo 200'
    mock avahi-browse 'echo "rp=printers/BridgePrinter"'
    write_default_cupsd_conf

    run "$SCRIPT" 192.0.2.51 --bind-ip 203.0.113.5
    [ "$status" -eq 0 ]
    [[ "$output" == *"Detected package manager: apk, init system: openrc"* ]]
    grep -q "rc-service cups-browsed stop" "$CALL_LOG"
    grep -q "rc-service cups restart" "$CALL_LOG"
}

@test "manages daemons directly (no systemctl, no rc-service, e.g. inside a container)" {
    mock id 'if [ "$1" = "-u" ]; then echo 0; fi'
    mock apt-get 'case "$1" in update) exit 0 ;; install) exit 0 ;; esac'
    mock lpadmin 'exit 0'
    mock cupsenable 'exit 0'
    mock cupsaccept 'exit 0'
    mock timeout 'shift; exec "$@"'
    mock ipptool 'exit 0'
    mock curl 'echo 200'
    mock avahi-browse 'echo "rp=printers/BridgePrinter"'
    mock pgrep 'exit 1'     # nothing already running, forces a start
    mock pkill 'exit 0'
    mock avahi-daemon 'exit 0'
    mock cupsd 'exit 0'
    write_default_cupsd_conf

    isolated_bin="$(build_isolated_path)"
    PATH="$isolated_bin:$MOCK_BIN" run "$SCRIPT" 192.0.2.51 --bind-ip 203.0.113.5
    rm -rf "$isolated_bin"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Detected package manager: apt-get, init system: none"* ]]
    grep -q "^avahi-daemon -D" "$CALL_LOG"
    grep -q "^cupsd " "$CALL_LOG"
    grep -q "pkill -f cups-browsed" "$CALL_LOG"
}

@test "retries after rewriting an EOL raspbian mirror" {
    mock id 'if [ "$1" = "-u" ]; then echo 0; fi'
    mock systemctl 'exit 0'
    mock lpadmin 'exit 0'
    mock cupsenable 'exit 0'
    mock cupsaccept 'exit 0'
    mock timeout 'shift; exec "$@"'
    mock ipptool 'exit 0'
    mock curl 'echo 200'
    mock avahi-browse 'echo "rp=printers/BridgePrinter"'
    write_default_cupsd_conf
    echo "deb http://raspbian.raspberrypi.org/raspbian/ buster main contrib non-free rpi" > "$APT_SOURCES_FILE"
    # First "update" call fails like a real EOL mirror would, second succeeds.
    mock apt-get '
if [ "$1" = "update" ]; then
    if [ ! -e "'"$MOCK_STATE"'/apt_failed_once" ]; then
        touch "'"$MOCK_STATE"'/apt_failed_once"
        echo "E: The repository '"'"'http://raspbian.raspberrypi.org/raspbian buster Release'"'"' no longer has a Release file." >&2
        exit 1
    fi
    exit 0
fi
exit 0
'

    run "$SCRIPT" 192.0.2.51 --bind-ip 203.0.113.5
    [ "$status" -eq 0 ]
    [[ "$output" == *"Detected an EOL Raspbian mirror"* ]]
    grep -q "legacy.raspbian.org" "$APT_SOURCES_FILE"
    ! grep -q "raspbian.raspberrypi.org" "$APT_SOURCES_FILE"
    [ "$(grep -c '^apt-get update' "$CALL_LOG")" -eq 2 ]
}

@test "falls back through IPP paths until one responds" {
    mock_root_and_apt_systemd
    # Only the plain "/ipp" path succeeds, not "/ipp/print" (the first guess).
    mock ipptool '
url="$2"
case "$url" in
    *:631/ipp) exit 0 ;;
    *) exit 1 ;;
esac
'
    run "$SCRIPT" 192.0.2.51 --bind-ip 203.0.113.5
    [ "$status" -eq 0 ]
    [[ "$output" == *"using /ipp"* ]]
    grep -q "lpadmin -p BridgePrinter -E -v ipp://192.0.2.51:631/ipp -m everywhere" "$CALL_LOG"
}

@test "fails clearly when no IPP path responds" {
    mock_root_and_apt_systemd
    mock ipptool 'exit 1'
    run "$SCRIPT" 192.0.2.51
    [ "$status" -eq 1 ]
    [[ "$output" == *"Couldn't auto-detect the IPP path"* ]]
}

@test "explicit --path skips IPP auto-detection" {
    mock_root_and_apt_systemd
    mock ipptool 'exit 1'   # would fail every candidate if probing ran at all
    run "$SCRIPT" 192.0.2.51 --path /custom/ipp --bind-ip 203.0.113.5
    [ "$status" -eq 0 ]
    grep -q "lpadmin -p BridgePrinter -E -v ipp://192.0.2.51:631/custom/ipp -m everywhere" "$CALL_LOG"
    ! grep -q "^ipptool" "$CALL_LOG"
}

@test "patches a fresh cupsd.conf to listen beyond localhost and allow the root location" {
    mock_root_and_apt_systemd
    cat > "$CUPSD_CONF" <<'EOF'
LogLevel warn
Listen localhost:631
Listen /run/cups/cups.sock
Browsing On
<Location />
  # Restrict access to the server...
  Order allow,deny
</Location>
<Location /admin>
  # Restrict access to the admin pages...
  Order allow,deny
</Location>
EOF

    run "$SCRIPT" 192.0.2.51 --bind-ip 203.0.113.5
    [ "$status" -eq 0 ]
    grep -q '^Listen 631$' "$CUPSD_CONF"
    ! grep -q '^Listen localhost:631$' "$CUPSD_CONF"
    # root location got opened up...
    awk '/<Location \/>/{f=1} f&&/Allow all/{found=1} f&&/<\/Location>/{exit} END{exit !found}' "$CUPSD_CONF"
    # ...but /admin was left alone, still locked down
    awk '/<Location \/admin>/{f=1} f&&/Allow all/{found=1} f&&/<\/Location>/{exit} END{exit found}' "$CUPSD_CONF"
}

@test "re-running against an already-patched cupsd.conf doesn't duplicate Allow all" {
    mock_root_and_apt_systemd
    cat > "$CUPSD_CONF" <<'EOF'
Listen 631
Listen /run/cups/cups.sock
<Location />
  Order allow,deny
  Allow all
</Location>
<Location /admin>
  Order allow,deny
</Location>
EOF

    run "$SCRIPT" 192.0.2.51 --bind-ip 203.0.113.5
    [ "$status" -eq 0 ]
    [ "$(grep -c 'Allow all' "$CUPSD_CONF")" -eq 1 ]
}

@test "warns but doesn't crash when the printer status page isn't reachable" {
    mock_root_and_apt_systemd
    mock curl 'case "$*" in *admin*) echo 403 ;; *) echo 000 ;; esac'
    cat > "$CUPSD_CONF" <<'EOF'
Listen 631
Listen /run/cups/cups.sock
<Location />
  Order allow,deny
  Allow all
</Location>
<Location /admin>
  Order allow,deny
</Location>
EOF
    run "$SCRIPT" 192.0.2.51 --bind-ip 203.0.113.5
    [ "$status" -eq 0 ]
    [[ "$output" == *"Warning: printer status page returned HTTP 000"* ]]
}

@test "warns when the admin UI is unexpectedly reachable from the network" {
    mock_root_and_apt_systemd
    mock curl 'echo 200'   # admin returning 200 is the bad case
    cat > "$CUPSD_CONF" <<'EOF'
Listen 631
Listen /run/cups/cups.sock
<Location />
  Order allow,deny
  Allow all
</Location>
<Location /admin>
  Order allow,deny
</Location>
EOF
    run "$SCRIPT" 192.0.2.51 --bind-ip 203.0.113.5
    [ "$status" -eq 0 ]
    [[ "$output" == *"Warning: /admin is reachable from the network"* ]]
}

@test "cups-browsed is stopped and disabled before anything else touches services" {
    mock_root_and_apt_systemd
    run "$SCRIPT" 192.0.2.51 --bind-ip 203.0.113.5
    [ "$status" -eq 0 ]
    grep -q "systemctl stop cups-browsed" "$CALL_LOG"
    grep -q "systemctl disable cups-browsed" "$CALL_LOG"
}

@test "no supported package manager is a clear, immediate failure" {
    # Prepending MOCK_BIN to the inherited PATH isn't enough here: on a real
    # Linux box (unlike this dev machine) apt-get/dnf/etc genuinely exist
    # further down PATH, so "absence" has to be a real, isolated PATH, not
    # an accident of what happens to be installed on whatever host runs this.
    mock id 'if [ "$1" = "-u" ]; then echo 0; fi'
    local isolated_bin
    isolated_bin="$(mktemp -d)"
    ln -s "$(command -v bash)" "$isolated_bin/bash"

    PATH="$isolated_bin:$MOCK_BIN" run "$SCRIPT" 192.0.2.51
    [ "$status" -eq 1 ]
    [[ "$output" == *"Couldn't find a supported package manager"* ]]

    rm -rf "$isolated_bin"
}
