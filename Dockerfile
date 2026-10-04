# syntax=docker/dockerfile:1.7
#
# Multi-stage build for XGift (https://github.com/mizorewww/x_gift_bot).
# github.com/mattn/go-sqlite3 needs cgo, so we build on Alpine (musl) and run
# on the same Alpine release to keep libc identical between stages.
# The frontend bundle is committed under internal/site/assets and embedded via
# go:embed, so no Node.js stage is required.

ARG GO_VERSION=1.27
ARG ALPINE_VERSION=3.24

# ---------- builder ----------
FROM golang:${GO_VERSION}-alpine${ALPINE_VERSION} AS builder
# hadolint ignore=DL3018
RUN apk add --no-cache build-base
WORKDIR /src
ENV CGO_ENABLED=1 GOTOOLCHAIN=auto GOFLAGS=-trimpath
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY cmd ./cmd
COPY internal ./internal
# Same build tags as upstream README.
ARG BUILD_TAGS=with_quic,with_utls
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build -tags "${BUILD_TAGS}" -ldflags "-s -w" -o /out/xgift ./cmd/xgift && \
    go build -tags "${BUILD_TAGS}" -ldflags "-s -w" -o /out/xgift-web ./cmd/xgift-web

# ---------- runtime ----------
FROM alpine:${ALPINE_VERSION}
ARG UID=10001
ARG GID=10001
# hadolint ignore=DL3018
RUN apk add --no-cache ca-certificates tzdata && \
    addgroup -S -g "${GID}" xgift && \
    adduser -S -D -H -u "${UID}" -G xgift -h /var/lib/xgift -s /sbin/nologin xgift && \
    mkdir -p /opt/xgift/bin /var/lib/xgift /etc/xgift && \
    # The xgift CLI looks for <bin>/../sqlite/vault.db by default; point it at the data volume.
    ln -s /var/lib/xgift /opt/xgift/sqlite && \
    chown xgift:xgift /var/lib/xgift /etc/xgift && \
    chmod 0700 /var/lib/xgift /etc/xgift
COPY --from=builder /out/xgift /out/xgift-web /opt/xgift/bin/
ENV PATH=/opt/xgift/bin:$PATH \
    TZ=UTC \
    XGIFT_LISTEN=127.0.0.1:8787 \
    XGIFT_DATA_DIR=/var/lib/xgift
WORKDIR /opt/xgift
USER ${UID}:${GID}
VOLUME ["/var/lib/xgift"]
# NOTE: upstream refuses non-loopback listen addresses, so the port is only
# reachable inside the container's network namespace (use network_mode: host
# or a sidecar sharing the namespace; see docker-compose.yml).
EXPOSE 8787
STOPSIGNAL SIGTERM
# Shell form is intentional so ${XGIFT_LISTEN} is expanded at runtime.
# hadolint ignore=DL3025
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD wget -q -O /dev/null "http://${XGIFT_LISTEN}/healthz" || exit 1
CMD ["xgift-web"]
