#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: setup-opencode-home-notify.sh WORK_SSH_ALIAS REMOTE_REPO_PATH" >&2
  exit 2
fi

work_alias="$1"
remote_repo="$2"
home_user="$(id -un)"
home_tailscale_ip="$(tailscale ip -4 | head -n 1)"
authorized_keys="${HOME}/.ssh/authorized_keys"
ssh_config="${HOME}/.ssh/config"
install -d -m 700 "$(dirname "$ssh_config")"
touch "$ssh_config"
chmod 600 "$ssh_config"

tmp_ssh_config="$(mktemp)"
awk '
  tolower($1) == "host" {
    target = 0
    for (i = 2; i <= NF; i++) if ($i == "opencode-home-notify") target = 1
  }
  !target { print }
' "$ssh_config" > "$tmp_ssh_config"
chmod 600 "$tmp_ssh_config"
mv "$tmp_ssh_config" "$ssh_config"

if [[ ! "$work_alias" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "WORK_SSH_ALIAS may contain only letters, numbers, dots, underscores, and hyphens." >&2
  exit 2
fi
if [[ ! "$home_tailscale_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Could not determine this PC's Tailscale IPv4 address. Make sure Tailscale is connected." >&2
  exit 1
fi

tmp_ssh_config="$(mktemp)"
awk -v alias="$work_alias" '
  tolower($1) == "host" {
    target = 0
    for (i = 2; i <= NF; i++) if ($i == alias) target = 1
  }
  target && tolower($1) == "remoteforward" &&
    $2 == "127.0.0.1:2222" && $3 == "127.0.0.1:22" { next }
  target && tolower($1) == "exitonforwardfailure" && tolower($2) == "yes" { next }
  { print }
' "$ssh_config" > "$tmp_ssh_config"
chmod 600 "$tmp_ssh_config"
mv "$tmp_ssh_config" "$ssh_config"

echo "Checking SSH access to ${work_alias}..."
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${work_alias}" true; then
  echo "SSH access to ${work_alias} is not available without an interactive password." >&2
  echo "Set up key-based SSH first (for example: ssh-copy-id ${work_alias}), then rerun this command." >&2
  exit 1
fi

echo "Installing the watchdog, completion hook, and notification key on the OpenCode PC..."
public_key="$(
  ssh "${work_alias}" bash -s -- "${remote_repo}" "${home_user}" "${home_tailscale_ip}" <<'REMOTE'
set -euo pipefail
repo="$1"
home_user="$2"
home_tailscale_ip="$3"
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
tmp_ssh_config="$(mktemp)"
awk '
  tolower($1) == "host" {
    target = 0
    for (i = 2; i <= NF; i++) if ($i == "opencode-home-notify") target = 1
  }
  !target { print }
' "$ssh_config" > "$tmp_ssh_config"
cat >> "$tmp_ssh_config" <<SSH_CONFIG

Host opencode-home-notify
  HostName ${home_tailscale_ip}
  Port 22
  User ${home_user}
  IdentityFile ~/.ssh/opencode_notify_home
  IdentitiesOnly yes
  BatchMode yes
  ConnectTimeout 5
  StrictHostKeyChecking accept-new
SSH_CONFIG
chmod 600 "$tmp_ssh_config"
mv "$tmp_ssh_config" "$ssh_config"
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

echo "Installing the restricted notification receiver..."
receiver_tmp="$(mktemp)"
if ! ssh "${work_alias}" bash -s -- "${remote_repo}" > "$receiver_tmp" <<'REMOTE'
set -euo pipefail
repo="$1"
cat "$repo/scripts/opencode-notify-receiver"
REMOTE
then
  rm -f "$receiver_tmp"
  echo "Could not retrieve the notification receiver from ${work_alias}." >&2
  exit 1
fi
install -Dm755 "$receiver_tmp" "${HOME}/.local/bin/opencode-notify-receiver"
rm -f "$receiver_tmp"

if ! systemctl is-enabled --quiet sshd || ! systemctl is-active --quiet sshd; then
  sudo systemctl enable --now sshd
fi
install -d -m 700 "$(dirname "$authorized_keys")"
touch "$authorized_keys"
chmod 600 "$authorized_keys"

tmp_authorized_keys="$(mktemp)"
awk -v key="$public_key" 'index($0, key) == 0' "$authorized_keys" > "$tmp_authorized_keys"
cat "$tmp_authorized_keys" > "$authorized_keys"
rm -f "$tmp_authorized_keys"
printf 'command="%s",restrict %s\n' "${HOME}/.local/bin/opencode-notify-receiver" "$public_key" >> "$authorized_keys"

echo
echo "Setup complete."
echo "Notifications connect directly to this PC over Tailscale; no SSH port forwarding is used."
echo "Restart the watchdog and OpenCode on the remote PC to load the changes."
