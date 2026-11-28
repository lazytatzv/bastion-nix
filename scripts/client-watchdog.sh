#!/usr/bin/env bash
# ==============================================================================
# OpenCode Client Watchdog & Completion Notifications
# ==============================================================================
# Run this script on your Linux client PC where OpenCode runs.
# It watches OpenCode logs for connection and usage-limit errors, and reports
# completed sessions to the home PC.
# ==============================================================================

set -euo pipefail

WATCH_DIR="${WATCH_DIR:-${HOME}/.local/share/opencode/log}"
PATTERN="${PATTERN:-used today.*free messages|free usage limit reached|connection lost due to|ECONNRESET|429|rate[- ]?limit|quota[- ]?exceeded|resource_exhausted}"
LIMIT_STATE_FILE="${LIMIT_STATE_FILE:-/tmp/opencode-client-watchdog.limited}"
EVENT_FIFO="${EVENT_FIFO:-${HOME}/.local/state/opencode/client-watchdog-events.fifo}"
TMUX_TARGET="${TMUX_TARGET:-opencode}"
TMUX_AUTO_RETRY="${TMUX_AUTO_RETRY:-true}"
AUTO_REFACTOR_ON_IDLE="${AUTO_REFACTOR_ON_IDLE:-true}"
TMUX_RETRY_PROMPT="${TMUX_RETRY_PROMPT:-Please retry the previous request.}"
TMUX_REFACTOR_PROMPT="${TMUX_REFACTOR_PROMPT:-Perform one conservative, behavior-preserving refactoring pass on the current project. Make only small, clearly beneficial changes; do not change behavior or public interfaces, and do not commit or push. Run relevant tests and summarize the result. If no safe refactor is obvious, make no changes and explain why.}"

echo "=========================================================="
echo " OpenCode Client Watchdog"
echo "=========================================================="
echo "Target Log Directory : ${WATCH_DIR}"
echo "Auto-refactor on idle: ${AUTO_REFACTOR_ON_IDLE} (target: '${TMUX_TARGET}')"
echo ""

mkdir -p "$(dirname "${EVENT_FIFO}")"
if [ -e "${EVENT_FIFO}" ] && [ ! -p "${EVENT_FIFO}" ]; then
  echo "[watchdog] [ERROR] Notification event path exists and is not a FIFO: ${EVENT_FIFO}" >&2
  exit 1
fi
if [ ! -p "${EVENT_FIFO}" ]; then
  mkfifo -m 600 "${EVENT_FIFO}"
fi
chmod 600 "${EVENT_FIFO}"

handle_notification_events() {
  while true; do
    while IFS= read -r event; do
      if [ "${event}" = "done" ]; then
        if ! timeout 15s ssh -T -o BatchMode=yes -o ConnectTimeout=5 opencode-home-notify done; then
          echo "[watchdog] [ERROR] Failed to send OpenCode completion notification." >&2
        fi

        if [ "$(cat "${LIMIT_STATE_FILE}" 2>/dev/null || true)" = "${watchdog_run_id}" ]; then
          echo "[watchdog] Usage-limit pause is active; leaving OpenCode idle until the watchdog is restarted."
        elif [ "${AUTO_REFACTOR_ON_IDLE}" = "true" ]; then
          if tmux has-session -t "${TMUX_TARGET}" 2>/dev/null; then
            tmux send-keys -t "${TMUX_TARGET}" -l "${TMUX_REFACTOR_PROMPT}"
            tmux send-keys -t "${TMUX_TARGET}" Enter
            echo "[watchdog] Auto-refactoring; sent one bounded refactoring task to '${TMUX_TARGET}'."
          else
            echo "[watchdog] Auto-refactoring is enabled, but tmux session '${TMUX_TARGET}' is unavailable." >&2
          fi
        else
          echo "[watchdog] Completion left idle (AUTO_REFACTOR_ON_IDLE=false)."
        fi
      else
        echo "[watchdog] [ERROR] Ignoring unknown notification event." >&2
      fi
    done < "${EVENT_FIFO}"
  done
}

watchdog_run_id=$$
handle_notification_events &
notification_listener_pid=$!

cleanup() {
  kill "${notification_listener_pid}" 2>/dev/null || true
  wait "${notification_listener_pid}" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 0' INT TERM

# ==============================================================================
# Startup connectivity check
# ==============================================================================
echo "[watchdog] --- Startup Check ---"

# 1. tmux session check
if [ "${AUTO_REFACTOR_ON_IDLE}" = "true" ] || [ "${TMUX_AUTO_RETRY}" = "true" ]; then
  if command -v tmux >/dev/null 2>&1 && tmux has-session -t "${TMUX_TARGET}" 2>/dev/null; then
    echo "[watchdog] tmux session '${TMUX_TARGET}' .............. OK ✓"
  else
    echo "[watchdog] tmux session '${TMUX_TARGET}' .............. WARN ⚠"
    echo "[watchdog]   → tmux new -s ${TMUX_TARGET} でOpenCodeを起動すると自動処理が有効になります"
  fi
fi

# 2. OpenCode log directory check
if [ -d "${WATCH_DIR}" ]; then
  echo "[watchdog] OpenCode log directory ................ OK ✓"
else
  echo "[watchdog] OpenCode log directory ................ WARN ⚠"
  echo "[watchdog]   → ${WATCH_DIR} がまだ存在しません。OpenCodeを起動すると自動検出されます"
fi

echo "[watchdog] ----------------------"
echo "[watchdog] Ready. 🚀"
echo ""

# Wait until target directory exists
if [ ! -d "${WATCH_DIR}" ]; then
  echo "[watchdog] Waiting for log directory to appear: ${WATCH_DIR}"
  while [ ! -d "${WATCH_DIR}" ]; do
    sleep 3
  done
fi

echo "[watchdog] Active. Monitoring logs for connection and usage-limit errors..."

while true; do
  LATEST_LOG=$(ls -t "${WATCH_DIR}"/*.log 2>/dev/null | head -n 1 || true)

  if [ -n "${LATEST_LOG}" ] && [ -f "${LATEST_LOG}" ]; then
    while IFS= read -r line; do
      if echo "$line" | grep -qiE "${PATTERN}"; then
        echo ""
        if echo "$line" | grep -qiE 'connection lost due to|ECONNRESET'; then
          echo "[watchdog] Connection error detected; skipping WAN IP renewal."
          notify-send "OpenCode Watchdog" "通信エラーを検知しました。IP更新なしで再試行します。" 2>/dev/null || true
          if [ "${TMUX_AUTO_RETRY}" = "true" ] && command -v tmux >/dev/null 2>&1 &&
            tmux has-session -t "${TMUX_TARGET}" 2>/dev/null; then
            echo "[watchdog] Auto-retry: Interrupting and sending retry prompt to tmux session '${TMUX_TARGET}'..."
            sleep 2
            tmux send-keys -t "${TMUX_TARGET}" Escape Escape
            sleep 0.5
            tmux send-keys -l -t "${TMUX_TARGET}" "${TMUX_RETRY_PROMPT}"
            sleep 0.5
            tmux send-keys -t "${TMUX_TARGET}" Enter
          fi
        else
          if [ "$(cat "${LIMIT_STATE_FILE}" 2>/dev/null || true)" != "${watchdog_run_id}" ]; then
            printf '%s\n' "${watchdog_run_id}" > "${LIMIT_STATE_FILE}"
            echo "[watchdog] Provider usage/rate limit detected; notifying and pausing automatic refactoring."
            notify-send -u critical "OpenCode Watchdog" "OpenCodeの利用上限/レート制限を検知しました。自動再試行はせず停止します。" 2>/dev/null || true
            if ! timeout 15s ssh -T -o BatchMode=yes -o ConnectTimeout=5 opencode-home-notify limit; then
              echo "[watchdog] [ERROR] Failed to send usage-limit notification to the home PC." >&2
            fi
          else
            echo "[watchdog] Usage-limit notification already sent for this watchdog run."
          fi
        fi

        # Cooldown period before resuming log monitoring
        echo "[watchdog] Cooling down for 20 seconds..."
        sleep 20
        break
      fi
    done < <(tail -fn0 "${LATEST_LOG}" 2>/dev/null)
  fi

  sleep 3
done
