FROM eclipse-temurin:25-jre

RUN apt-get update \
  && apt-get install -y --no-install-recommends tini ca-certificates curl unzip jq \
  && rm -rf /var/lib/apt/lists/*

# Create hytale user/group without hardcoding UID
# Pelican will handle user switching via its own mechanisms
RUN groupadd -f hytale \
  && useradd -m -g hytale -s /usr/sbin/nologin hytale

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

RUN chmod 0755 /usr/local/bin/hytale-entrypoint \
    /usr/local/bin/hytale-cfg-interpolate \
    /usr/local/bin/hytale-auto-download \
    /usr/local/bin/hytale-curseforge-mods \
    /usr/local/bin/hytale-prestart-downloads \
    /usr/local/bin/hytale-cli \
    /usr/local/bin/hytale-healthcheck \
    /usr/local/bin/hytale-save-auth-tokens \
    /usr/local/bin/hytale-extract-auth-tokens

# Don't set USER - Pelican manages this dynamically

HEALTHCHECK --interval=30s --timeout=5s --start-period=10m --retries=3 CMD ["/usr/local/bin/hytale-healthcheck"]

ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/hytale-entrypoint"]