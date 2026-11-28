#!/usr/bin/env bash
# ==============================================================================
# OpenCode Client Watchdog & Remote WAN Renewal
# ==============================================================================
# Run this script on your Linux client PC where OpenCode runs.
# It watches OpenCode logs for connection and rate-limit/quota errors, renews
# the router's WAN lease for the latter, and reports events to the home PC.
# ==============================================================================

set -euo pipefail

ROUTER_HOST="${ROUTER_HOST:-192.168.50.1}"
ROUTER_USER="${ROUTER_USER:-yano}"
WATCH_DIR="${WATCH_DIR:-${HOME}/.local/share/opencode/log}"
PATTERN="${PATTERN:-used today.*free messages|free usage limit reached|connection lost due to|ECONNRESET|429|rate[- ]?limit|quota[- ]?exceeded|resource_exhausted}"
MAX_DAILY_RECOVERIES="${MAX_DAILY_RECOVERIES:-10}"
EVENT_FIFO="${EVENT_FIFO:-${HOME}/.local/state/opencode/client-watchdog-events.fifo}"
STATE_FILE="${STATE_FILE:-${HOME}/.local/state/opencode/client-watchdog.state}"
LEGACY_STATE_FILE="${LEGACY_STATE_FILE:-/tmp/opencode-client-watchdog.state}"
WATCHDOG_LOCK_FILE="${WATCHDOG_LOCK_FILE:-${HOME}/.local/state/opencode/client-watchdog.lock}"
TMUX_TARGET="${TMUX_TARGET:-opencode}"
TMUX_AUTO_RETRY="${TMUX_AUTO_RETRY:-true}"
AUTO_REFACTOR_ON_IDLE="${AUTO_REFACTOR_ON_IDLE:-true}"
TMUX_RETRY_PROMPT="${TMUX_RETRY_PROMPT:-Please retry the previous request.}"
TMUX_REFACTOR_PROMPT="${TMUX_REFACTOR_PROMPT:-Perform one conservative, behavior-preserving refactoring pass on the current project. Make only small, clearly beneficial changes; do not change behavior or public interfaces, and do not commit or push. Run relevant tests and summarize the result. If no safe refactor is obvious, make no changes and explain why.}"

echo "=========================================================="
echo " OpenCode Client Watchdog -> Bastion Router (${ROUTER_HOST})"
echo "=========================================================="
echo "Target Log Directory : ${WATCH_DIR}"
echo "Daily Recovery Cap   : ${MAX_DAILY_RECOVERIES} times / day"
echo "Router Target        : ${ROUTER_USER}@${ROUTER_HOST}"
echo "Auto-refactor on idle: ${AUTO_REFACTOR_ON_IDLE} (target: '${TMUX_TARGET}')"
echo ""

mkdir -p "$(dirname "${EVENT_FIFO}")"
mkdir -p "$(dirname "${STATE_FILE}")" "$(dirname "${WATCHDOG_LOCK_FILE}")"
if ! command -v flock >/dev/null 2>&1; then
  echo "[watchdog] [ERROR] flock is required to prevent duplicate watchdog instances." >&2
  exit 1
fi
exec 9>"${WATCHDOG_LOCK_FILE}"
if ! flock -n 9; then
  echo "[watchdog] [ERROR] Another client-watchdog instance is already running." >&2
  exit 1
fi

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

        if [ "${AUTO_REFACTOR_ON_IDLE}" = "true" ]; then
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

handle_notification_events &
notification_listener_pid=$!

cleanup() {
  kill "${notification_listener_pid}" 2>/dev/null || true
  wait "${notification_listener_pid}" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 0' INT TERM

get_daily_count() {
  local today saved_date saved_count state_path
  today=$(date +%F)
  state_path="${STATE_FILE}"
  if [ ! -f "${state_path}" ] && [ -f "${LEGACY_STATE_FILE}" ]; then
    state_path="${LEGACY_STATE_FILE}"
  fi
  if [ -f "${state_path}" ]; then
    read -r saved_date saved_count < "${state_path}" 2>/dev/null || true
    if [ "${saved_date:-}" = "${today}" ]; then
      echo "${saved_count:-0}"
      return
    fi
  fi
  echo "0"
}

set_daily_count() {
  printf '%s %s\n' "$(date +%F)" "$1" > "${STATE_FILE}" 2>/dev/null || true
}

# ==============================================================================
# Startup connectivity check
# ==============================================================================
echo "[watchdog] --- Startup Check ---"
ALL_OK=true

# 1. SSH connection to router
if ssh -o BatchMode=yes -o ConnectTimeout=5 "${ROUTER_USER}@${ROUTER_HOST}" "exit" 2>/dev/null; then
  echo "[watchdog] SSH connection to router .............. OK ✓"
else
  echo "[watchdog] SSH connection to router .............. FAIL ✗"
  echo "[watchdog]   → ssh-copy-id ${ROUTER_USER}@${ROUTER_HOST} を実行してSSH鍵を登録してください"
  ALL_OK=false
fi

# 2. renew-wan-ip command exists on router
if ssh -o BatchMode=yes -o ConnectTimeout=5 "${ROUTER_USER}@${ROUTER_HOST}" "command -v renew-wan-ip" 2>/dev/null; then
  echo "[watchdog] renew-wan-ip on router ................ OK ✓"
else
  echo "[watchdog] renew-wan-ip on router ................ FAIL ✗"
  echo "[watchdog]   → ルーターで make switch が完了しているか確認してください"
  ALL_OK=false
fi

# 3. tmux session check
if [ "${AUTO_REFACTOR_ON_IDLE}" = "true" ] || [ "${TMUX_AUTO_RETRY}" = "true" ]; then
  if command -v tmux >/dev/null 2>&1 && tmux has-session -t "${TMUX_TARGET}" 2>/dev/null; then
    echo "[watchdog] tmux session '${TMUX_TARGET}' .............. OK ✓"
  else
    echo "[watchdog] tmux session '${TMUX_TARGET}' .............. WARN ⚠"
    echo "[watchdog]   → tmux new -s ${TMUX_TARGET} でOpenCodeを起動すると自動処理が有効になります"
  fi
fi

# 4. OpenCode log directory check
if [ -d "${WATCH_DIR}" ]; then
  echo "[watchdog] OpenCode log directory ................ OK ✓"
else
  echo "[watchdog] OpenCode log directory ................ WARN ⚠"
  echo "[watchdog]   → ${WATCH_DIR} がまだ存在しません。OpenCodeを起動すると自動検出されます"
fi

echo "[watchdog] ----------------------"
if [ "${ALL_OK}" = "true" ]; then
  echo "[watchdog] All systems ready! 🚀"
else
  echo "[watchdog] Some checks failed. 上記を確認してから再起動することをおすすめします。"
  echo "[watchdog] （このまま続行することも可能です）"
fi
echo ""

# Wait until target directory exists
if [ ! -d "${WATCH_DIR}" ]; then
  echo "[watchdog] Waiting for log directory to appear: ${WATCH_DIR}"
  while [ ! -d "${WATCH_DIR}" ]; do
    sleep 3
  done
fi

echo "[watchdog] Active. Monitoring logs for rate-limit/quota responses..."

while true; do
  LATEST_LOG=$(ls -t "${WATCH_DIR}"/*.log 2>/dev/null | head -n 1 || true)

  if [ -n "${LATEST_LOG}" ] && [ -f "${LATEST_LOG}" ]; then
    while IFS= read -r line; do
      if echo "$line" | grep -qiE "${PATTERN}"; then
        echo ""
        recovery_ready=false
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
          current_count=$(get_daily_count)
          echo "[watchdog] Rate-limit/quota response detected; notifying home PC and renewing WAN IP."
          notify-send "OpenCode Watchdog" "利用制限を検知: ホームへ通知し、ルーターのWAN IP更新を開始します..." 2>/dev/null || true
          if ! timeout 15s ssh -T -o BatchMode=yes -o ConnectTimeout=5 opencode-home-notify limit; then
            echo "[watchdog] [ERROR] Failed to send usage-limit notification to the home PC." >&2
          fi

          if [ "${current_count}" -ge "${MAX_DAILY_RECOVERIES}" ]; then
            echo "[watchdog] [SAFETY CAP] Daily limit reached (${current_count}/${MAX_DAILY_RECOVERIES})."
            echo "[watchdog] Halting auto-recovery for today to avoid excessive DHCP/MAC churn."
            notify-send -u critical "OpenCode Watchdog" "1日の自動復旧上限（${MAX_DAILY_RECOVERIES}回）に達しました。本日の自動IP更新を停止します。" 2>/dev/null || true
          else
            new_count=$((current_count + 1))
            set_daily_count "${new_count}"
            if ssh -o BatchMode=yes -o ConnectTimeout=5 "${ROUTER_USER}@${ROUTER_HOST}" "sudo -n renew-wan-ip"; then
              echo "[watchdog] WAN IP successfully renewed! (${new_count}/${MAX_DAILY_RECOVERIES} today)."
              notify-send -u normal "OpenCode Watchdog" "WAN IP更新完了 (${new_count}/${MAX_DAILY_RECOVERIES}回目)。接続が復旧しました。" 2>/dev/null || true
              printf '\a'
              recovery_ready=true

              if command -v tailscale >/dev/null 2>&1; then
                if tailscale debug restun; then
                  echo "[watchdog] Requested an immediate Tailscale STUN refresh after WAN renewal."
                else
                  echo "[watchdog] [WARN] Could not refresh Tailscale STUN state. Run 'sudo tailscale set --operator=$(id -un)' once to allow this user to refresh it."
                fi
              fi
            else
              echo "[watchdog] [ERROR] WAN renewal attempt failed (${new_count}/${MAX_DAILY_RECOVERIES} attempts today)."
              notify-send -u critical "OpenCode Watchdog" "ルーターへのSSH接続またはIP更新に失敗しました。" 2>/dev/null || true
            fi
          fi

          if [ "${recovery_ready}" = "false" ]; then
            echo "[watchdog] No automatic retry will be sent because WAN recovery did not complete."
          fi
        fi

        if [ "${recovery_ready}" = "true" ] && [ "${TMUX_AUTO_RETRY}" = "true" ] && command -v tmux >/dev/null 2>&1; then
          if tmux has-session -t "${TMUX_TARGET}" 2>/dev/null; then
            echo "[watchdog] Auto-retry: Interrupting and sending retry prompt to tmux session '${TMUX_TARGET}'..."
            sleep 2
            tmux send-keys -t "${TMUX_TARGET}" Escape Escape
            sleep 0.5
            tmux send-keys -l -t "${TMUX_TARGET}" "${TMUX_RETRY_PROMPT}"
            sleep 0.5
            tmux send-keys -t "${TMUX_TARGET}" Enter
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
