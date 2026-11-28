#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: setup-opencode-home-notify.sh WORK_SSH_ALIAS REMOTE_REPO_PATH" >&2
  exit 2
fi

work_alias="$1"
remote_repo="$2"
home_user="$(id -un)"
receiver_path="${HOME}/.local/bin/opencode-notify-receiver"
authorized_keys="${HOME}/.ssh/authorized_keys"
ssh_config="${HOME}/.ssh/config"
key_file="${HOME}/.ssh/opencode_notify_home"
launcher="${HOME}/.local/bin/ssh-opencode-work"
tmp_receiver="$(mktemp)"
trap 'rm -f "$tmp_receiver"' EXIT

echo "Checking SSH access to ${work_alias}..."
ssh -o BatchMode=yes -o ConnectTimeout=5 "${work_alias}" true

echo "Installing notification plugin and key on the OpenCode PC..."
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

echo "Installing the notification receiver on this PC..."
ssh "${work_alias}" bash -s -- "${remote_repo}" <<'REMOTE' > "$tmp_receiver"
set -euo pipefail
cat "$1/scripts/opencode-notify-receiver"
REMOTE
install -Dm755 "$tmp_receiver" "$receiver_path"

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

if ! grep -Fq "$public_key" "$authorized_keys"; then
  printf 'command="%s",restrict %s\n' "$receiver_path" "$public_key" >> "$authorized_keys"
fi

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

install -d -m 755 "${HOME}/.local/bin"
cat > "$launcher" <<LAUNCHER
#!/usr/bin/env bash
set -euo pipefail
exec ssh -o RemoteForward=127.0.0.1:2222:127.0.0.1:22 \\
  -o ExitOnForwardFailure=yes \\
  -o ServerAliveInterval=30 \\
  -o ServerAliveCountMax=3 \\
  "${work_alias}" "\$@"
LAUNCHER
chmod 755 "$launcher"

echo
echo "Setup complete."
echo "Start the work connection with: ${launcher}"
echo "Keep it open, then restart OpenCode on the remote PC to load the plugin."
