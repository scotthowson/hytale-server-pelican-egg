FROM eclipse-temurin:25-jre

RUN apt-get update \
  && apt-get install -y --no-install-recommends tini ca-certificates curl unzip jq dmidecode \
  && rm -rf /var/lib/apt/lists/*

# Create hytale user/group with UID 1000 for default (non-Pelican) usage
# Use -f to ignore if group already exists, and check if user exists before creating
RUN groupadd -f -g 1000 hytale || true \
  && if ! id -u 1000 >/dev/null 2>&1; then \
       useradd -m -u 1000 -g 1000 -s /usr/sbin/nologin hytale; \
     fi

# Setup machine-id infrastructure for hardware UUID
# Create writable files in all locations Java's HardwareUtil might check
# These will be overridden by host volume mounts in production
RUN rm -f /etc/machine-id /var/lib/dbus/machine-id \
  && mkdir -p /var/lib/dbus \
  && touch /etc/machine-id /var/lib/dbus/machine-id \
  && chmod 666 /etc/machine-id /var/lib/dbus/machine-id

# Use /home/container for Pelican compatibility instead of /data
WORKDIR /home/container

# Copy all scripts from scripts/ folder
COPY scripts/entrypoint.sh /usr/local/bin/hytale-entrypoint
COPY scripts/cfg-interpolate.sh /usr/local/bin/hytale-cfg-interpolate
COPY scripts/auto-download.sh /usr/local/bin/hytale-auto-download
COPY scripts/curseforge-mods.sh /usr/local/bin/hytale-curseforge-mods
COPY scripts/prestart-downloads.sh /usr/local/bin/hytale-prestart-downloads
COPY scripts/hytale-cli.sh /usr/local/bin/hytale-cli
COPY scripts/healthcheck.sh /usr/local/bin/hytale-healthcheck
COPY scripts/save-auth-tokens.sh /usr/local/bin/hytale-save-auth-tokens
COPY scripts/extract-auth-tokens.sh /usr/local/bin/hytale-extract-auth-tokens
COPY scripts/check-machine-id.sh /usr/local/bin/check-machine-id
COPY scripts/debug-hardware-uuid.sh /usr/local/bin/debug-hardware-uuid

RUN chmod 0755 /usr/local/bin/hytale-entrypoint \
    /usr/local/bin/hytale-cfg-interpolate \
    /usr/local/bin/hytale-auto-download \
    /usr/local/bin/hytale-curseforge-mods \
    /usr/local/bin/hytale-prestart-downloads \
    /usr/local/bin/hytale-cli \
    /usr/local/bin/hytale-healthcheck \
    /usr/local/bin/hytale-save-auth-tokens \
    /usr/local/bin/hytale-extract-auth-tokens \
    /usr/local/bin/check-machine-id \
    /usr/local/bin/debug-hardware-uuid

# Set default user to UID 1000 (satisfies CI tests)
# Pelican will override this at runtime with --user flag
USER 1000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10m --retries=3 CMD ["/usr/local/bin/hytale-healthcheck"]

ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/hytale-entrypoint"]
