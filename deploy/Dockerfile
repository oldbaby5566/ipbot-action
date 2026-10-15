FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 one-ip \
    && useradd --system --uid 10001 --gid one-ip --home-dir /opt/one-ip one-ip
WORKDIR /opt/one-ip
COPY one-ip-backend /usr/local/bin/one-ip-backend
COPY fonts ./fonts
RUN install -d -o one-ip -g one-ip /opt/one-ip/data
ENV ENV=prod BIND_ADDR=0.0.0.0:27528 DATA_DIR=/opt/one-ip/data
EXPOSE 27528 5353/udp 5353/tcp 3478/udp
USER one-ip:one-ip
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl --fail --silent --show-error --max-time 4 --output /dev/null http://127.0.0.1:27528/readyz
ENTRYPOINT ["one-ip-backend", "run"]
