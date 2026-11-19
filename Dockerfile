# StreamMKV server image: the Go binary + ffmpeg + (optional) a built-in rtorrent.
#   docker compose up -d        (see docker-compose.yml)
# Multi-arch (amd64, arm64) images are published to ghcr.io/un4ckn0wl3z/streammkv.

FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS build
ARG TARGETOS TARGETARCH VERSION=dev
WORKDIR /src
COPY go.mod ./
COPY *.go ./
COPY web ./web
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /out/streammkv .

FROM alpine:3.22
RUN apk add --no-cache ffmpeg rtorrent ca-certificates tzdata tini su-exec
COPY --from=build /out/streammkv /usr/local/bin/streammkv
COPY deploy/docker/entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh
ENV STREAMMKV_ROOT=/media \
    STREAMMKV_DATA=/data \
    STREAMMKV_CACHE=/data/cache \
    STREAMMKV_LISTEN=:8090 \
    STREAMMKV_USER_LIBS=/media/personal \
    STREAMMKV_DOCKER=1 \
    RTORRENT=1 \
    RTORRENT_PORT=50000 \
    RTORRENT_DHT_PORT=6881 \
    PUID=1000 \
    PGID=1000 \
    TZ=UTC
VOLUME ["/data", "/media"]
EXPOSE 8090 50000 6881/udp
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s CMD wget -qO- "http://127.0.0.1:${STREAMMKV_LISTEN##*:}/" >/dev/null || exit 1
ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
CMD ["streammkv"]
