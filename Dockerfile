FROM container-registry.oracle.com/graalvm/native-image:25

# ============================================================================
# INSTALL DEPENDENCIES (Oracle Linux uses microdnf, not apt)
# ============================================================================
# Note: We intentionally do NOT install real dmidecode - our fake one handles UUID
RUN microdnf install -y \
      tini \
      ca-certificates \
      curl \
      unzip \
      jq \
      util-linux \
      shadow-utils \
  && microdnf clean all

# ============================================================================
# USER / GROUP SETUP
# ============================================================================
# Create hytale user/group with consistent UID/GID
RUN groupadd -f -g 1000 hytale || true \
  && if ! id -u 1000 >/dev/null 2>&1; then \
       useradd -m -u 1000 -g 1000 -s /usr/sbin/nologin hytale; \
     fi

# ============================================================================
# MACHINE-ID INFRASTRUCTURE
# ============================================================================
# The Hytale server needs a consistent hardware UUID for authentication.
# We set up multiple fallback mechanisms:
#   1. Writable /etc/machine-id
#   2. Writable /var/lib/dbus/machine-id
# ============================================================================

RUN rm -f /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true \
  && mkdir -p /var/lib/dbus \
  && touch /etc/machine-id /var/lib/dbus/machine-id \
  && chmod 666 /etc/machine-id /var/lib/dbus/machine-id \
  && chown root:root /etc/machine-id /var/lib/dbus/machine-id

# ============================================================================
# WORKDIR
# ============================================================================
WORKDIR /home/container

# ============================================================================
# SCRIPT INSTALLATION
# ============================================================================
# Install fake dmidecode FIRST so it appears before any real dmidecode in PATH.
# ============================================================================

COPY scripts/fake-dmidecode.sh /usr/local/bin/dmidecode

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
COPY scripts/diagnose-auth.sh /usr/local/bin/diagnose-auth

# Make all scripts executable
RUN chmod 0755 /usr/local/bin/*

# Verify fake dmidecode is first in PATH
RUN which dmidecode | grep -q '/usr/local/bin/dmidecode' \
  || (echo "ERROR: fake dmidecode not first in PATH" && exit 1)

# Fix ownership
RUN chown -R 1000:1000 /home/container 2>/dev/null || true

# ============================================================================
# RUNTIME
# ============================================================================
USER 1000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10m --retries=3 \
  CMD ["/usr/local/bin/hytale-healthcheck"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/hytale-entrypoint"]
