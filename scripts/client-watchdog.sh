#!/usr/bin/env bash
# ==============================================================================
# OpenCode Client Watchdog & Remote WAN Renewal
# ==============================================================================
# Run this script on your Linux client PC where OpenCode runs.
# It watches local OpenCode logs for rate-limit/quota responses (429),
# and remotely triggers `renew-wan-ip` on the router via SSH.
# ==============================================================================

set -euo pipefail

ROUTER_HOST="${ROUTER_HOST:-192.168.50.1}"
ROUTER_USER="${ROUTER_USER:-yano}"
WATCH_DIR="${WATCH_DIR:-${HOME}/.local/share/opencode/log}"
PATTERN="${PATTERN:-used today.*free messages|free usage limit reached|connection lost due to|ECONNRESET|429|rate[- ]?limit|quota[- ]?exceeded|resource_exhausted}"
MAX_DAILY_RECOVERIES="${MAX_DAILY_RECOVERIES:-10}"
STATE_FILE="${STATE_FILE:-/tmp/opencode-client-watchdog.state}"
TMUX_TARGET="${TMUX_TARGET:-opencode}"
WAN_AUTO_RENEW="${WAN_AUTO_RENEW:-false}"
TMUX_AUTO_RETRY="${TMUX_AUTO_RETRY:-false}"
TMUX_RETRY_PROMPT="${TMUX_RETRY_PROMPT:-Please retry the previous request.}"

echo "=========================================================="
echo " OpenCode Client Watchdog -> Bastion Router (${ROUTER_HOST})"
echo "=========================================================="
echo "Target Log Directory : ${WATCH_DIR}"
echo "Daily Recovery Cap   : ${MAX_DAILY_RECOVERIES} times / day"
echo "Router Target        : ${ROUTER_USER}@${ROUTER_HOST}"
echo "WAN Auto-Renew       : ${WAN_AUTO_RENEW}"
echo "tmux Auto-Retry      : ${TMUX_AUTO_RETRY} (target: '${TMUX_TARGET}', interrupt: 'Escape Escape')"
echo ""

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
if [ "${TMUX_AUTO_RETRY}" = "true" ]; then
  if command -v tmux >/dev/null 2>&1 && tmux has-session -t "${TMUX_TARGET}" 2>/dev/null; then
    echo "[watchdog] tmux session '${TMUX_TARGET}' .............. OK ✓"
  else
    echo "[watchdog] tmux session '${TMUX_TARGET}' .............. WARN ⚠"
    echo "[watchdog]   → tmux new -s ${TMUX_TARGET} でOpenCodeを起動するとAuto-Retryが有効になります"
    echo "[watchdog]   → セッションがなければ、レート制限を検知した際のEnter自動送信はスキップされます"
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
          recovery_ready=true
        elif [ "${WAN_AUTO_RENEW}" != "true" ]; then
          echo "[watchdog] Rate-limit/quota response detected; WAN renewal is disabled."
          echo "[watchdog] Set WAN_AUTO_RENEW=true to explicitly allow disruptive WAN renewal."
        else
          current_count=$(get_daily_count)

          if [ "${current_count}" -ge "${MAX_DAILY_RECOVERIES}" ]; then
            echo "[watchdog] [SAFETY CAP] Daily limit reached (${current_count}/${MAX_DAILY_RECOVERIES})."
            echo "[watchdog] Halting auto-recovery for today to avoid excessive DHCP/MAC churn."
            notify-send -u critical "OpenCode Watchdog" "1日の自動復旧上限（${MAX_DAILY_RECOVERIES}回）に達しました。本日の自動IP更新を停止します。" 2>/dev/null || true
            sleep 60
            break
          fi

          echo "[watchdog] Rate-limit/quota response detected; renewing WAN IP on router (${ROUTER_HOST})..."
          notify-send "OpenCode Watchdog" "利用制限を検知: ルーターのWAN IP更新を開始します..." 2>/dev/null || true

          if ssh -o BatchMode=yes -o ConnectTimeout=5 "${ROUTER_USER}@${ROUTER_HOST}" "renew-wan-ip"; then
            new_count=$((current_count + 1))
            set_daily_count "${new_count}"

            echo "[watchdog] WAN IP successfully renewed! (${new_count}/${MAX_DAILY_RECOVERIES} today)."
            notify-send -u normal "OpenCode Watchdog" "WAN IP更新完了 (${new_count}/${MAX_DAILY_RECOVERIES}回目)。接続が復旧しました。" 2>/dev/null || true
            printf '\a' # Beep
            recovery_ready=true
          else
            echo "[watchdog] [ERROR] Failed to execute renew-wan-ip on router via SSH."
            notify-send -u critical "OpenCode Watchdog" "ルーターへのSSH接続またはIP更新に失敗しました。" 2>/dev/null || true
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
