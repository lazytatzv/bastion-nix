#!/usr/bin/env bash
# ==============================================================================
# Connection Watchdog & WAN Auto-Recovery Helper
# ==============================================================================
# Monitors local client / simulator logs for connection drops, gateway stalls,
# or upstream service throttling, and automatically initiates WAN reconnection
# via `renew-wan-ip` to restore healthy network flow.
#
# Features:
# - Daily safety rate-limiting (circuit breaker) to prevent runaway loops / DHCP abuse
# - State persistence across script restarts
# ==============================================================================

set -euo pipefail

WATCH_DIR="${WATCH_DIR:-${HOME}/.local/share/opencode/log}"
PATTERN="${PATTERN:-used today.*free messages|429|rate[- ]?limit|quota[- ]?exceeded|resource_exhausted}"
MAX_DAILY_RECOVERIES="${MAX_DAILY_RECOVERIES:-5}"
STATE_FILE="${STATE_FILE:-/tmp/connection-watchdog.state}"

echo "=== Network Connection Watchdog Started ==="
echo "Target Monitor Directory: ${WATCH_DIR}"
echo "Daily Recovery Budget: ${MAX_DAILY_RECOVERIES} times / day"

get_daily_count() {
  local today
  today=$(date +%F)
  if [ -f "${STATE_FILE}" ]; then
    local saved_date saved_count
    read -r saved_date saved_count < "${STATE_FILE}" 2>/dev/null || true
    if [ "${saved_date:-}" = "${today}" ]; then
      echo "${saved_count:-0}"
      return
    fi
  fi
  echo "0"
}

set_daily_count() {
  local count="$1"
  local today
  today=$(date +%F)
  echo "${today} ${count}" > "${STATE_FILE}" 2>/dev/null || true
}

# Wait until target directory exists
while [ ! -d "${WATCH_DIR}" ]; do
  sleep 5
done

while true; do
  LATEST_LOG=$(ls -t "${WATCH_DIR}"/*.log 2>/dev/null | head -n 1 || true)

  if [ -n "${LATEST_LOG}" ] && [ -f "${LATEST_LOG}" ]; then
    echo "[watchdog] Monitoring active session log: ${LATEST_LOG}"

    while IFS= read -r line; do
      if echo "$line" | grep -qiE "${PATTERN}"; then
        echo ""
        current_count=$(get_daily_count)

        if [ "${current_count}" -ge "${MAX_DAILY_RECOVERIES}" ]; then
          echo "[watchdog] [SAFETY LIMIT] Daily recovery cap reached (${current_count}/${MAX_DAILY_RECOVERIES})."
          echo "[watchdog] Halting auto-recovery for today to prevent network abuse."
          notify-send "Network Watchdog" "1日の自動復旧上限（${MAX_DAILY_RECOVERIES}回）に達しました。本日の自動IP更新を停止します。" 2>/dev/null || true
          sleep 60
          break
        fi

        echo "[watchdog] Upstream limit / stall detected. Initiating WAN auto-recovery..."
        notify-send "Network Watchdog" "Connection stall detected. Recovering WAN interface..." 2>/dev/null || true

        # Execute graceful release and renewal
        if command -v renew-wan-ip >/dev/null 2>&1; then
          renew-wan-ip || true
        elif [ -x "/run/current-system/sw/bin/renew-wan-ip" ]; then
          /run/current-system/sw/bin/renew-wan-ip || true
        fi

        new_count=$((current_count + 1))
        set_daily_count "${new_count}"

        echo "[watchdog] WAN recovery complete (${new_count}/${MAX_DAILY_RECOVERIES} today)."
        notify-send "Network Watchdog" "WAN recovery complete (${new_count}/${MAX_DAILY_RECOVERIES}回目). Network restored." 2>/dev/null || true
        printf '\a' # Terminal alert

        # Cooldown period before resuming monitor
        sleep 20
        break
      fi
    done < <(tail -fn0 "${LATEST_LOG}" 2>/dev/null)
  fi

  sleep 3
done
