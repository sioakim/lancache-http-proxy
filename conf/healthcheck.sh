#!/bin/bash
# Healthcheck for the proxy-relay (squid) sidecar.
#
# Reports UNHEALTHY when the upstream parent proxy is not serving, so an outage
# is visible instead of silently degrading to slow direct downloads.
#
# How: send a HEAD request *through* the local relay. The relay uses
# `never_direct`, so every request is forced via the parent proxy. A working
# parent returns a success status line; a dead parent makes squid return a 5xx
# generated locally (ERR_CANNOT_FORWARD), which fails the check.
#
# Overridable via env (set in docker-compose.yml):
#   RELAY_PORT       loopback port the relay listens on        (default 3129)
#   HEALTHCHECK_HOST a stable game-CDN host to probe           (default steamcdn-a.akamaihd.net)
#   HEALTHCHECK_PATH a small, always-present object on it      (default the steamcmd tarball)

set -u
PORT="${RELAY_PORT:-3129}"
HOST="${HEALTHCHECK_HOST:-steamcdn-a.akamaihd.net}"
OBJ="${HEALTHCHECK_PATH:-/client/installer/steamcmd_linux.tar.gz}"

exec 3<>"/dev/tcp/127.0.0.1/${PORT}" || exit 1
printf 'HEAD %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n' "$OBJ" "$HOST" >&3 || exit 1
read -r status <&3 || exit 1

case "$status" in
  *" 200"*|*" 204"*|*" 206"*|*" 301"*|*" 302"*|*" 307"*) exit 0 ;;
  *) exit 1 ;;
esac
