#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: setup-opencode-home-notify.sh WORK_SSH_ALIAS REMOTE_REPO_PATH" >&2
  exit 2
fi

work_alias="$1"
remote_repo="$2"
home_user="$(id -un)"
authorized_keys="${HOME}/.ssh/authorized_keys"
ssh_config="${HOME}/.ssh/config"

if [[ ! "$work_alias" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "WORK_SSH_ALIAS may contain only letters, numbers, dots, underscores, and hyphens." >&2
  exit 2
fi

echo "Checking SSH access to ${work_alias}..."
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${work_alias}" true; then
  echo "SSH access to ${work_alias} is not available without an interactive password." >&2
  echo "Set up key-based SSH first (for example: ssh-copy-id ${work_alias}), then rerun this command." >&2
  exit 1
fi

echo "Installing the watchdog, completion hook, and notification key on the OpenCode PC..."
public_key="$(
  ssh "${work_alias}" bash -s -- "${remote_repo}" "${home_user}" <<'REMOTE'
set -euo pipefail
repo="$1"
home_user="$2"
key="$HOME/.ssh/opencode_notify_home"
ssh_config="$HOME/.ssh/config"
mkdir -p "$HOME/.ssh" "$HOME/.config/opencode/plugins"
chmod 700 "$HOME/.ssh"
if [ ! -f "$key" ]; then
  ssh-keygen -q -t ed25519 -N '' -f "$key" -C opencode-notify-home
fi
install -m 644 "$repo/scripts/opencode-home-notify.js" \
  "$HOME/.config/opencode/plugins/opencode-home-notify.js"
install -Dm755 "$repo/scripts/client-watchdog.sh" \
  "$HOME/.local/bin/client-watchdog.sh"
touch "$ssh_config"
chmod 600 "$ssh_config"
if ! grep -Eq '^[[:space:]]*Host[[:space:]]+opencode-home-notify([[:space:]]|$)' "$ssh_config"; then
  cat >> "$ssh_config" <<SSH_CONFIG

Host opencode-home-notify
  HostName 127.0.0.1
  Port 2222
  User ${home_user}
  IdentityFile ~/.ssh/opencode_notify_home
  IdentitiesOnly yes
  BatchMode yes
  ConnectTimeout 5
  StrictHostKeyChecking accept-new
SSH_CONFIG
fi
cat "$key.pub"
REMOTE
)"

printf '%s\n' "$public_key" | grep -Eq '^ssh-ed25519 [A-Za-z0-9+/=]+( .*)?$' || {
  echo "Could not obtain a valid notification public key from ${work_alias}." >&2
  exit 1
}

echo "Installing the desktop notification dependency..."
if ! command -v notify-send >/dev/null 2>&1; then
  if ! command -v pacman >/dev/null 2>&1; then
    echo "Install libnotify using your distribution's package manager, then rerun this script." >&2
    exit 1
  fi
  sudo pacman -S --needed libnotify
fi

sudo systemctl enable --now sshd
install -d -m 700 "$(dirname "$authorized_keys")"
touch "$authorized_keys"
chmod 600 "$authorized_keys"

tmp_authorized_keys="$(mktemp)"
awk -v key="$public_key" 'index($0, key) == 0' "$authorized_keys" > "$tmp_authorized_keys"
cat "$tmp_authorized_keys" > "$authorized_keys"
rm -f "$tmp_authorized_keys"
notify_command="/usr/bin/env XDG_RUNTIME_DIR=/run/user/\$(/usr/bin/id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$(/usr/bin/id -u)/bus /usr/bin/notify-send --app-name=OpenCode '作業完了' 'OpenCodeの応答が完了しました。'"
printf 'command="%s",restrict %s\n' "$notify_command" "$public_key" >> "$authorized_keys"

install -d -m 700 "$(dirname "$ssh_config")"
touch "$ssh_config"
chmod 600 "$ssh_config"
if ! grep -Eq '^[[:space:]]*Host[[:space:]]+opencode-home-notify([[:space:]]|$)' "$ssh_config"; then
  cat >> "$ssh_config" <<'SSH_CONFIG'

Host opencode-home-notify
  HostName 127.0.0.1
  Port 2222
  User __HOME_USER__
  IdentityFile ~/.ssh/opencode_notify_home
  IdentitiesOnly yes
  BatchMode yes
  ConnectTimeout 5
  StrictHostKeyChecking accept-new
SSH_CONFIG
  sed -i "s/__HOME_USER__/${home_user}/" "$ssh_config"
fi

if ! grep -Fq 'RemoteForward 127.0.0.1:2222 127.0.0.1:22' "$ssh_config"; then
  cat >> "$ssh_config" <<SSH_CONFIG

Host ${work_alias}
  RemoteForward 127.0.0.1:2222 127.0.0.1:22
  ExitOnForwardFailure yes
SSH_CONFIG
fi

echo
echo "Setup complete."
echo "SSH to ${work_alias} as usual; that connection now carries the notification tunnel."
echo "Restart OpenCode on the remote PC once to load the plugin."
