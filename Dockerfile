FROM container-registry.oracle.com/graalvm/jdk:25

# ============================================================================
# INSTALL DEPENDENCIES (Oracle Linux uses microdnf)
# ============================================================================
ARG TARGETARCH
RUN microdnf install -y \
      ca-certificates \
      curl \
      unzip \
      jq \
      util-linux \
      shadow-utils \
      procps-ng \
  && microdnf clean all \
  && case "$TARGETARCH" in \
       amd64)  TINI_ARCH=amd64 ;; \
       arm64)  TINI_ARCH=arm64 ;; \
       *) echo "Unsupported arch: $TARGETARCH" && exit 1 ;; \
     esac \
  && curl -fsSL https://github.com/krallin/tini/releases/download/v0.19.0/tini-static-${TINI_ARCH} \
       -o /usr/bin/tini \
  && chmod +x /usr/bin/tini

# ============================================================================
# USER / GROUP SETUP
# ============================================================================
RUN groupadd -f -g 1000 hytale || true \
  && if ! id -u 1000 >/dev/null 2>&1; then \
       useradd -m -u 1000 -g 1000 -s /usr/sbin/nologin hytale; \
     fi

# ============================================================================
# MACHINE-ID INFRASTRUCTURE
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

RUN chmod 0755 /usr/local/bin/*

# Verify fake dmidecode is first in PATH
RUN command -v dmidecode | grep -q '/usr/local/bin/dmidecode' \
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