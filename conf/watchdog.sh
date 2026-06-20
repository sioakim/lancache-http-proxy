#!/bin/sh
# lancache-http-proxy watchdog — self-heals the stack and alerts on failures.
#
# Why this exists: lancache-dns and the proxy-relay share lancache's network
# namespace (network_mode: service:lancache). When the lancache container is
# RECREATED (image update, host reboot, manual recreate) the sidecars are
# orphaned and EXIT 255 ("cannot join network of a non running container").
# `restart: unless-stopped` does NOT recover them, and they are NOT "unhealthy"
# (they're stopped), so autoheal-style tools miss it too — DNS + proxy stay dead
# until a human notices. This watchdog (its OWN netns, so it survives a lancache
# recreate) checks the stack on an interval, restarts any down container (a
# fresh start re-joins the current netns), and notifies on down/heal/recovery.
#
# Config (env, all optional):
#   WATCHDOG_CONTAINERS  space-separated names to watch. The FIRST is treated as
#                        the netns owner. Default:
#                        "lancache lancache-dns lancache-proxy-relay"
#   WATCHDOG_INTERVAL    seconds between checks (default 60)
#   PUSHOVER_APP_TOKEN / PUSHOVER_USER_KEY   phone push via Pushover
#   WATCHDOG_WEBHOOK_URL POST {"content":"..."} (Discord-style; adapt for Slack)
# With no notifier configured it just logs to stdout (docker logs).

set -u
MON="${WATCHDOG_CONTAINERS:-lancache lancache-dns lancache-proxy-relay}"
INTERVAL="${WATCHDOG_INTERVAL:-60}"
STATE_DIR="${STATE_DIR:-/state}"
OWNER="${MON%% *}"          # first container = the netns owner
mkdir -p "$STATE_DIR"

enc() { echo "$1" | sed 's/&/%26/g; s/ /%20/g'; }

notify() {  # $1 title  $2 message  $3 priority(0|1)
  echo "$(date) [alert p${3:-0}] $1 - $2"
  if [ -n "${PUSHOVER_APP_TOKEN:-}" ] && [ -n "${PUSHOVER_USER_KEY:-}" ]; then
    wget -q -O /dev/null --timeout=10 --header="User-Agent: lancache-watchdog/1.0" \
      --post-data="token=${PUSHOVER_APP_TOKEN}&user=${PUSHOVER_USER_KEY}&priority=${3:-0}&title=$(enc "$1")&message=$(enc "$2")" \
      https://api.pushover.net/1/messages.json 2>/dev/null || true
  fi
  if [ -n "${WATCHDOG_WEBHOOK_URL:-}" ]; then
    body=$(printf '%s: %s' "$1" "$2" | sed 's/\\/\\\\/g; s/"/\\"/g')
    wget -q -O /dev/null --timeout=10 \
      --header="Content-Type: application/json" --header="User-Agent: lancache-watchdog/1.0" \
      --post-data="{\"content\":\"${body}\"}" "$WATCHDOG_WEBHOOK_URL" 2>/dev/null || true
  fi
}

status_of() {  # echoes: down | unhealthy | ok
  r=$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)
  [ "$r" != "true" ] && { echo down; return; }
  h=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null)
  [ "$h" = "unhealthy" ] && echo unhealthy || echo ok
}

heal() {  # $1 container — a fresh start re-joins the current netns
  docker start "$1" >/dev/null 2>&1
  if [ "$1" = "$OWNER" ]; then          # owner came back -> sidecars must rejoin it
    sleep 8
    for j in $MON; do [ "$j" != "$OWNER" ] && docker restart "$j" >/dev/null 2>&1; done
  fi
}

echo "$(date) lancache-watchdog up; monitoring [$MON] every ${INTERVAL}s (owner=$OWNER)"
notify "LanCache Watchdog" "Watchdog started - monitoring: $MON" 0

while true; do
  for c in $MON; do
    sf="$STATE_DIR/$c"; prev=$(cat "$sf" 2>/dev/null || echo ok)
    cur=$(status_of "$c")

    if [ "$cur" = "down" ]; then
      heal "$c"; sleep 3; cur=$(status_of "$c")
      if [ "$cur" != "down" ]; then
        if [ "$prev" = "downfail" ]; then notify "LanCache recovered" "$c is back up." 0
        else notify "LanCache auto-healed" "$c was DOWN - restarted automatically, now running." 0; fi
        echo ok > "$sf"
      else
        [ "$prev" != "downfail" ] && notify "LanCache DOWN" "$c is DOWN and auto-restart FAILED. Needs attention." 1
        echo downfail > "$sf"
      fi

    elif [ "$cur" = "unhealthy" ]; then
      [ "$prev" != "unhealthy" ] && notify "LanCache unhealthy" "$c is running but UNHEALTHY - downloads may be degraded; check it." 0
      echo unhealthy > "$sf"

    else  # ok
      case "$prev" in
        downfail|unhealthy) notify "LanCache recovered" "$c is healthy again." 0 ;;
      esac
      echo ok > "$sf"
    fi
  done
  sleep "$INTERVAL"
done
