# airprint-bridge

Turns a network printer that doesn't speak AirPrint (no Bonjour, just plain
IPP/LPD/raw printing) into one iOS and iPadOS can actually discover and
print to, by standing up a small CUPS + Avahi bridge in front of it.

## Why this needs a bridge at all

AirPrint discovery runs over mDNS, which is multicast. Multicast doesn't
cross VLANs or subnets the way ordinary unicast traffic does, so the bridge
has to sit on the exact same broadcast domain as the phones/tablets that
need to find it, not just be reachable from it over IP. Keep that in mind
wherever you run this: same physical network segment as your iOS devices,
not "somewhere on the network."

## Three ways to run it

### 1. Directly on a spare Linux box (bare metal or VM)

OS-agnostic: detects the package manager (`apt`, `dnf`/`yum`, `zypper`,
`pacman`, `apk`) and init system (systemd or OpenRC) and adapts accordingly.

```bash
sudo ./setup.sh <printer-ip>
```

It will:
- install `cups`, `cups-client`, `avahi-daemon`, `avahi-utils`
- disable `cups-browsed` (see [Security notes](#security-notes))
- probe common IPP paths on the printer and add it as a driverless
  "IPP Everywhere" queue
- make sure CUPS actually listens on the network (not just localhost),
  while keeping the admin UI locked to local access only
- verify the result with a real IPP query and an Avahi browse

Options:

```
--name <queue-name>   CUPS queue name (default: BridgePrinter)
--path <ipp-path>     IPP resource path, e.g. /ipp/print. Auto-probed if omitted.
--bind-ip <ip>        override IP used for the network-reachability check
--remove              remove the queue this script created
```

To remove: `sudo ./setup.sh --remove --name <queue-name>`.

### 2. Docker

```bash
docker build -t airprint-bridge .
docker run -d --name airprint-bridge \
  --network host \
  -e PRINTER_IP=<printer-ip> \
  airprint-bridge
```

No extra `--cap-add` needed: tested with the container's default capability
set (mDNS advertising, IP-route detection, and printing all work with none
added).

`--network host` matters for the same reason as above: without it, the
container's mDNS advertisements never reach the actual LAN.

Environment variables: `PRINTER_IP` (required), `QUEUE_NAME`, `IPP_PATH`,
`BIND_IP` (all optional, same meaning as the script's flags).

### 3. Kubernetes (Helm)

```bash
helm install my-printer charts/airprint-bridge --set printer.ip=<printer-ip>
```

The chart sets `hostNetwork: true` by default, and it isn't optional: mDNS
can't reach real devices from a pod's overlay network. What *is* your call
is which node the pod lands on: it needs to be a node physically on the
same broadcast domain as your iOS devices. See `NOTES.txt` (printed after
install) and use `nodeSelector`/`affinity` in `values.yaml` if your cluster
spans more than one physical network segment.

## Security notes

- **`cups-browsed` is disabled everywhere.** It's the component responsible
  for auto-discovering and auto-adding printers advertised by *anyone* on
  the network, and it was the vector behind CVE-2024-47176/47076/47175/47177
  (a real 2024 CUPS remote-code-execution chain). This project always adds
  exactly one printer explicitly, so browsing is pure unused attack surface.
- **The CUPS admin UI is not exposed.** Only the print path is; there is no
  reason to reach `/admin` over the network for anything this bridge does.
- **This doesn't patch the OS underneath it.** If you're running this on an
  old, EOL distro release, the script papers over one specific symptom (an
  aged-out package mirror) but doesn't make the box current. Consider
  cutting outbound internet access for a box whose only job is bridging a
  LAN printer; there's no legitimate reason for it to reach the internet at
  all, and doing so limits the blast radius of anything unpatched.

## Tests

```bash
shellcheck setup.sh docker-entrypoint.sh
bats tests/script/setup_test.bats      # mocked, safe to run anywhere
bash tests/docker/test.sh              # builds and runs the real image
bash tests/helm/test.sh                # helm lint + template assertions
```

## License

MIT, see [LICENSE](LICENSE).
