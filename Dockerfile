ARG WOLFI_SELECTOR=@sha256:1d95114038f76513a9ace6fca107d5582b08c65981f81f61cb56bf7fd2ef216d
ARG RUST_SELECTOR=:1.98.1-alpine3.24@sha256:7cc1c22d77d9432f7fe012a70e6d3e555af54c2a6832700ed7d553f1769ae89f

FROM rust${RUST_SELECTOR} AS builder
WORKDIR /build
COPY reconciled/ .
RUN cargo build --release --locked

FROM cgr.dev/chainguard/wolfi-base${WOLFI_SELECTOR}

LABEL org.opencontainers.image.source="https://github.com/wiesion/zocalo-sftp" \
      org.opencontainers.image.title="zocalo-sftp" \
      org.opencontainers.image.description="Hardened SFTP server for secure file collaboration" \
      org.opencontainers.image.authors="wiesion.ch" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="cgr.dev/chainguard/wolfi-base"

ENV SFTP_AUTH_MODE=pubkey \
    SFTP_ENABLE_METRICS=no \
    SFTP_LOG_LEVEL=ERROR \
    SFTP_METRICS_BIND=0.0.0.0 \
    SFTP_PROJECT_MODE=770 \
    SFTP_RECONCILE_INTERVAL=15 \
    SFTP_RESET_PROJECTS=yes \
    SFTP_RESET_USERS=yes \
    SFTP_USERS_GID=59999 \
    SSHD_ENABLE_IPV4=yes \
    SSHD_ENABLE_IPV6=yes \
    SSHD_LOG_LEVEL=INFO

RUN apk add --no-cache openssh-server tini socat && \
    mkdir -p /run/sshd /config/sshd_config.d

RUN chmod 700 /usr/bin/socat

COPY resources/sshd.conf /etc/ssh/sshd_config.template
COPY resources/issue.sftp /etc/
COPY --chmod=755 resources/entrypoint.sh /
COPY --chmod=755 resources/metrics.sh /usr/local/bin/
COPY --from=builder /build/target/release/sftp-reconciled /usr/local/bin/

COPY reconciled/Cargo.toml reconciled/Cargo.lock /usr/local/share/sftp-reconciled/

ARG BUILD_DATE=""
ARG VCS_REF=""
ARG VERSION=""
LABEL org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.version="${VERSION}"

EXPOSE 22 9100
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD sh -c "sshd -t && timeout 2 socat - TCP:localhost:22 2>/dev/null | grep -q 'SSH-'"
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
CMD ["/usr/bin/sshd", "-D", "-e"]
