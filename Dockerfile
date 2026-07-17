FROM debian:bookworm-slim

RUN apt-get update -qq \
    && apt-get install -y -qq cups cups-client avahi-daemon avahi-utils dbus procps curl iproute2 \
    && rm -rf /var/lib/apt/lists/*

# cupsd publishes printers to Avahi over D-Bus, not just by avahi-daemon
# running: there's no systemd here to start the system bus automatically,
# so docker-entrypoint.sh starts dbus-daemon itself before anything else.

COPY setup.sh /usr/local/bin/setup.sh
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/setup.sh /usr/local/bin/docker-entrypoint.sh

EXPOSE 631/tcp 5353/udp

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
