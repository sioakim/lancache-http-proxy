#!/bin/bash
# Healthcheck for the proxy-relay (squid) sidecar.
#
# Reports UNHEALTHY when the upstream parent proxy is not actually serving our
# traffic, so an outage/misconfig is visible. (Downloads keep working either way
# via nginx's direct-fallback; this only surfaces the degraded state.)
#
# How: send a HEAD through the local relay (never_direct forces it via the
# parent) and read the response head. UNHEALTHY iff:
#   - no HTTP status line comes back (relay down / hung), or
#   - squid generated the response itself (X-Squid-Error header, e.g.
#     ERR_CANNOT_FORWARD = dead/unreachable parent), or
#   - the parent returns 407 (it requires auth this relay can't satisfy).
# Any other status the parent actually FORWARDED (200/206/404/405/...) means the
# parent is up and serving us -> HEALTHY. The probe object's own availability
# must NOT gate health.
#
# Overridable via env on the proxy-relay service:
#   HEALTHCHECK_HOST  a stable game-CDN host to probe  (default steamcdn-a.akamaihd.net)
#   HEALTHCHECK_PATH  a small object on it             (default the steamcmd tarball)
# (The relay's listen port is fixed at 3129 in squid.conf.template + 30_primary_proxy.conf.)

set -u
HOST="${HEALTHCHECK_HOST:-steamcdn-a.akamaihd.net}"
OBJ="${HEALTHCHECK_PATH:-/client/installer/steamcmd_linux.tar.gz}"

exec 3<>"/dev/tcp/127.0.0.1/3129" || exit 1
printf 'HEAD %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n' "$OBJ" "$HOST" >&3 || exit 1

got_status=0
while IFS= read -r -t 5 line <&3; do
  line=${line%$'\r'}
  [ -z "$line" ] && break                    # blank line = end of headers
  case "$line" in
    HTTP/*)
      got_status=1
      set -- $line
      [ "${2:-}" = "407" ] && exit 1 ;;       # parent requires auth we lack
    [Xx]-[Ss]quid-[Ee]rror:*) exit 1 ;;        # squid-generated error => parent not forwarding
  esac
done

[ "$got_status" -eq 1 ] && exit 0 || exit 1
