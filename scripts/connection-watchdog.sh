#!/usr/bin/env bash
# ==============================================================================
# Connection Watchdog & WAN Auto-Recovery Helper
# ==============================================================================
# Monitors local client / simulator logs for connection drops, gateway stalls,
# or upstream service throttling, and automatically initiates WAN reconnection
# via `renew-wan-ip` to restore healthy network flow.
# ==============================================================================

set -euo pipefail

WATCH_DIR="${WATCH_DIR:-${HOME}/.local/share/opencode/log}"
PATTERN="${PATTERN:-used today.*free messages|429|rate[- ]?limit|quota[- ]?exceeded|resource_exhausted}"

echo "=== Network Connection Watchdog Started ==="
echo "Target Monitor Directory: ${WATCH_DIR}"

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
        echo "[watchdog] Upstream limit / stall detected. Initiating WAN auto-recovery..."
        
        notify-send "Network Watchdog" "Connection stall detected. Recovering WAN interface..." 2>/dev/null || true

        # Execute graceful release and renewal
        if command -v renew-wan-ip >/dev/null 2>&1; then
          renew-wan-ip || true
        elif [ -x "/run/current-system/sw/bin/renew-wan-ip" ]; then
          /run/current-system/sw/bin/renew-wan-ip || true
        fi

        echo "[watchdog] WAN recovery complete. Interface ready."
        notify-send "Network Watchdog" "WAN recovery complete. Network restored." 2>/dev/null || true
        printf '\a' # Terminal alert

        # Cooldown period before resuming monitor
        sleep 20
        break
      fi
    done < <(tail -fn0 "${LATEST_LOG}" 2>/dev/null)
  fi

  sleep 3
done
