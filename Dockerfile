
 FROM eclipse-temurin:25-jre
 
 RUN apt-get update \
   && apt-get install -y --no-install-recommends tini ca-certificates curl unzip \
   && rm -rf /var/lib/apt/lists/*
 
 RUN groupadd -f hytale \
   && if ! id -u hytale >/dev/null 2>&1; then useradd -m -u 1000 -o -g hytale -s /usr/sbin/nologin hytale; fi
 
 RUN mkdir -p /data /data/server \
   && chown -R hytale:hytale /data
 
 VOLUME ["/data"]
 WORKDIR /data/server
 
 COPY scripts/entrypoint.sh /usr/local/bin/hytale-entrypoint
 COPY scripts/auto-download.sh /usr/local/bin/hytale-auto-download
 RUN chmod 0755 /usr/local/bin/hytale-entrypoint /usr/local/bin/hytale-auto-download
 
 USER hytale
 
 ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/hytale-entrypoint"]
