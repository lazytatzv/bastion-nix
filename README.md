# bastion-nix

NixOS configuration for a Wi-Fi-WAN router and edge compute server. The host routes a clubroom LAN through upstream Wi-Fi and also provides shared storage, local web services, monitoring, Tailscale access, and build capacity.

## Network overview

```text
Upstream Wi-Fi (wlan0, DHCP)
          |
     bastion-nix
          |
LAN (enp2s0, 192.168.50.1/24)
  ├── DHCP and DNS
  ├── NFS and FileBrowser
  ├── Caddy local reverse proxy
  └── Tailscale subnet route
```

The checked-in host profile uses `wlan0` for WAN, `enp2s0` for LAN, and `192.168.50.1/24` as the router address. These are deployment-specific defaults; review them before using this configuration on different hardware or a different network.

## Repository layout

```text
.
├── flake.nix
├── configuration.nix
├── hardware-configuration.nix
├── Makefile
├── modules/
│   ├── default.nix
│   ├── wifi-as-wan.nix
│   ├── router.nix
│   ├── performance.nix
│   ├── proxy.nix
│   ├── monitoring.nix
│   ├── services.nix
│   ├── runner.nix
│   └── system.nix
└── scripts/
    ├── archer-reconnect.zsh
    ├── client-watchdog.sh
    ├── opencode-home-notify.js
    ├── opencode-notify-receiver
    └── setup-opencode-home-notify.sh
```

`configuration.nix` imports the hardware configuration and module set. `modules/router.nix` enables the services and network profile for this host. The flake exposes the modules for reuse by other NixOS configurations.

## Deploying this host

The Makefile targets the `bastion` flake configuration:

```bash
# Build and activate now
make switch

# Activate for the current boot without changing the boot default
make test

# Build and set as the next boot configuration
make boot

# Update flake inputs
make update
```

Equivalent direct commands include:

```bash
sudo nixos-rebuild switch --flake .#bastion
nix flake check
```

The flake also provides `nixos`, `bastion`, and `router` configuration names; all currently use the same `configuration.nix`. `make cp` is a legacy helper that copies repository files into `/etc/nixos`; prefer deploying from the flake checkout instead.

## Modules and reuse

The exported modules are:

| Flake output | Main options |
| --- | --- |
| `nixosModules.default` | Imports all modules |
| `nixosModules.wifiAsWan` | `services.wifi-as-wan.*` |
| `nixosModules.performance` | `profiles.performance.*` |
| `nixosModules.proxy` | `services.clubroom-proxy.*` |
| `nixosModules.monitoring` | `services.clubroom-monitoring.*` |
| `nixosModules.services` | `services.clubroom-services.*` |
| `nixosModules.runner` | `services.bastion-runner.*` |
| `nixosModules.system` | Base NixOS settings |
| `nixosModules.router` | This repository's host profile; requires the related option modules |

Example importing one module from another flake:

```nix
{
  inputs.bastion-nix.url = "github:lazytatzv/bastion-nix";

  outputs = { self, nixpkgs, bastion-nix, ... }: {
    nixosConfigurations.my-router = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        bastion-nix.nixosModules.wifiAsWan
        {
          services.wifi-as-wan = {
            enable = true;
            externalInterface = "wlan0";
            internalInterface = "eth0";
            internalIp = "192.168.1.1";
          };
        }
      ];
    };
  };
}
```

`nixosModules.default` imports all modules, including the repository-specific router, runner, and base-system settings. For a different machine, import only the modules you need and provide the necessary hardware and host configuration.

## Router and WAN lease management

The `wifi-as-wan` module uses `systemd-networkd` for WAN DHCP and the LAN address, `iwd` for upstream Wi-Fi, `dnsmasq` for LAN DHCP/DNS, and nftables-backed NixOS NAT/firewall configuration. It sends DHCP release when bringing down the WAN interface.

`renew-wan-ip` performs a manual WAN lease renewal:

1. Brings the WAN interface down to release its DHCP lease.
2. Restarts `iwd` (configured for per-network MAC randomization).
3. Brings the interface back up and waits up to 30 seconds for a ping to `1.1.1.1`.
4. Returns a failure status if connectivity does not return in time.

The host also schedules a daily renewal at 04:00 with up to 30 minutes of systemd randomized delay. This can briefly interrupt the internet connection for all LAN clients.

```bash
# On the router: inspect the timer and its next run
systemctl list-timers rotate-wan-ip

# On the router: renew the WAN lease now
sudo renew-wan-ip
```

The router profile enables `autoDisableConflicts` because NetworkManager and `systemd-resolved` conflict with this network setup. A different host using the module must either disable the conflicting services or explicitly enable that option.

## Services

| Service | LAN access | Details |
| --- | --- | --- |
| Router / default site | `http://router.lan` | Redirects to the NAS/FileBrowser site |
| AdGuard Home | `http://adguard.lan` or `http://dns.lan` | Web UI on port 3000; DNS upstream resolver listens on localhost port 5335 |
| FileBrowser | `http://nas.lan`, `http://drive.lan`, or `http://files.lan` | Serves `/data` on port 8080 |
| Grafana | `http://grafana.lan`, `http://monitor.lan`, or `http://status.lan` | Proxied to Grafana on localhost port 3100 |
| Prometheus | Router localhost `127.0.0.1:9090` | Scrape and query endpoint; not directly LAN-accessible by default |
| distcc status | `http://distcc.lan` | Caddy proxy to port 3633 |
| distccd | `192.168.50.1:3632` | Distributed compiler daemon |
| NFS | `192.168.50.1:/data` | Exported to the configured LAN subnet and Tailscale CGNAT range |

Local `*.lan` names are mapped to the router address by dnsmasq and routed by Caddy. Access from Tailscale depends on the subnet route being enabled/approved in the tailnet as well as client routing and DNS configuration.

The services module also enables Tailscale, Docker with BuildKit, and the GitHub Actions self-hosted runner. The runner is configured for the repository URL in `modules/router.nix`; its registration token is read from `/var/lib/github-runner/token` and must be provisioned on the host.

## Monitoring and performance profile

The monitoring module configures Node Exporter on localhost port 9100, Prometheus on localhost port 9090 with 30-day retention, and Grafana on localhost port 3100. Caddy exposes Grafana on the LAN.

The performance module selects the Zen kernel by default, configures BBR and CAKE, uses a RAM-backed `/tmp` (default 16 GiB), enables zram, and tunes CPU, VM, and I/O settings. It also sets the kernel parameter `mitigations=off`; this trades security mitigations for performance and should be reviewed before reusing this profile on a machine that handles untrusted workloads or sensitive data.

## OpenCode client watchdog

`scripts/client-watchdog.sh` runs on the Linux PC where OpenCode is running. It tails OpenCode logs in `~/.local/share/opencode/log`, uses SSH to access the router, and expects OpenCode to run inside a tmux session named `opencode`.

Start OpenCode and the watchdog in separate terminals:

```bash
tmux new -s opencode
# Inside tmux:
opencode
```

```bash
./scripts/client-watchdog.sh
```

Behavior:

* `ECONNRESET` and `Connection lost due to` are treated as connection failures. If enabled and the tmux session exists, the watchdog interrupts the current prompt and sends `Please retry the previous request.` It does not renew the WAN lease for these connection errors.
* Rate-limit/quota patterns (including `429`, `QuotaExceeded`, and `Free usage limit reached`) trigger notifications on the client and home PC, then run `renew-wan-ip` on the router. If WAN renewal succeeds, the watchdog sends the retry prompt to OpenCode. A daily safety cap (10 renewals by default) prevents further automatic renewals after it is reached.
* `session.idle` events from the OpenCode plugin are passed to the watchdog through a local FIFO. On each idle event, it sends a completion notification to the home PC and, by default, submits one conservative behavior-preserving refactoring task to the OpenCode tmux session. The next idle event repeats this cycle. The prompt asks OpenCode to run relevant tests and not commit or push.
* This is intentionally a repeated automation loop: stop the watchdog or set `AUTO_REFACTOR_ON_IDLE=false` if you do not want another pass to start after each completion. Do not run multiple watchdog instances for the same OpenCode session.

Configuration environment variables:

| Variable | Default | Description |
| --- | --- | --- |
| `WATCH_DIR` | `~/.local/share/opencode/log` | OpenCode log directory to monitor |
| `TMUX_TARGET` | `opencode` | tmux session containing OpenCode |
| `TMUX_AUTO_RETRY` | `true` | Retry detected connection failures in tmux |
| `TMUX_RETRY_PROMPT` | `Please retry the previous request.` | Prompt used for connection-error retry |
| `ROUTER_HOST` | `192.168.50.1` | Router LAN address |
| `ROUTER_USER` | `yano` | SSH account on the router |
| `MAX_DAILY_RECOVERIES` | `10` | Maximum automatic WAN renewals per day |
| `AUTO_REFACTOR_ON_IDLE` | `true` | Submit a bounded refactoring task on each idle event |
| `TMUX_REFACTOR_PROMPT` | Built-in conservative refactor prompt | Override the automatic refactor prompt |
| `PATTERN` | Built-in connection/quota regex | Override log patterns watched by the script |
| `EVENT_FIFO` | `~/.local/state/opencode/client-watchdog-events.fifo` | Local FIFO used by the OpenCode plugin |
| `STATE_FILE` | `/tmp/opencode-client-watchdog.state` | Date and count of automatic WAN renewals |

Example with a different tmux session and no automatic refactoring:

```bash
TMUX_TARGET=mywork AUTO_REFACTOR_ON_IDLE=false ./scripts/client-watchdog.sh
```

### Inspecting OpenCode logs

On the OpenCode PC:

```bash
# List recent log files
ls -lt ~/.local/share/opencode/log | head

# Show the newest log's last 100 lines
f=$(ls -t ~/.local/share/opencode/log/*.log 2>/dev/null | head -n 1)
[ -n "$f" ] && tail -n 100 "$f" || echo "No OpenCode log found"

# Find likely errors in the newest log
if [ -n "$f" ]; then
  grep -Ein 'error|failed|timeout|rate.limit|quota|ECONNRESET|connection|retry' "$f" | tail -n 80
else
  echo "No OpenCode log found"
fi
```

Logs can contain prompt or project data. Review and redact sensitive content before sharing log excerpts.

## Completion and usage-limit notifications to a home PC

The OpenCode plugin at `scripts/opencode-home-notify.js` subscribes to OpenCode's `session.idle` event and sends only the fixed `done` event through the local FIFO. The watchdog sends the desktop notification over direct SSH on Tailscale. For a recognized provider limit, the watchdog sends the fixed `limit` event and continues its existing WAN renewal and retry flow. Neither event contains prompts or generated content.

### Prerequisites

* The home Arch PC and OpenCode PC are both connected to Tailscale.
* The home PC has an active graphical session and `notify-send` (the setup script can install `libnotify` on Arch).
* SSH works from the home PC to the OpenCode PC using a host alias and key-based, non-interactive authentication.
* The OpenCode PC has a local checkout of this repository, and the OpenCode client watchdog runs in the same user account as OpenCode.

### Install or update the integration

Run this from the home Arch PC, replacing the alias and remote checkout path with the actual values:

```bash
ssh opencode-work 'cat /home/yano/bastion-nix/scripts/setup-opencode-home-notify.sh' \
  | bash -s -- opencode-work /home/yano/bastion-nix
```

The setup script installs the plugin and watchdog on the OpenCode PC, configures a dedicated SSH key and Tailscale SSH alias, installs a restricted notification receiver on the home PC, and adds a forced command for that key to `authorized_keys`. The receiver accepts only the fixed `done` and `limit` event names. The setup removes the old reverse port-forward configuration for this notification path; no reverse tunnel or port 2222 is used.

After setup, restart both OpenCode and the client watchdog on the OpenCode PC. Keep the watchdog running. The home PC must remain logged into its desktop session to display notifications.

## Reconnecting to the OpenCode PC from home

`ssh archer` itself does not reconnect. The optional zsh function in `scripts/archer-reconnect.zsh` retries after the SSH process exits unsuccessfully and uses SSH keepalives to detect a dead connection. It starts a new SSH session after connectivity returns; it cannot preserve the old session.

On the home Arch PC, add the source line to `~/.zshrc` (adjust the path to the local repository clone), then load it:

```zsh
echo 'source ~/bastion-nix/scripts/archer-reconnect.zsh' >> ~/.zshrc
source ~/.zshrc
```

Connect using the function name, not `ssh archer`:

```zsh
archer
```

It retries every two seconds after a disconnect. Keep the terminal open; press `Ctrl-C` to stop retrying. The function assumes the SSH host alias `archer` is already configured in `~/.ssh/config`.

## Remote compilation

### distcc

On a Linux client with distcc installed, configure the router as a compiler host:

```bash
export DISTCC_HOSTS="192.168.50.1/16"
export CC="distcc gcc"
export CXX="distcc g++"
```

Then use the normal build tool with parallel jobs, for example:

```bash
colcon build --parallel-workers 16
make -j16
```

Ensure the client and router have compatible compiler versions and target environments. distcc is intended for compatible C/C++ compilation, not arbitrary build steps.

### Nix remote builder

Add the router as a builder in the client's Nix configuration (for example `~/.config/nix/nix.conf`):

```conf
builders = ssh://yano@192.168.50.1 x86_64-linux - 16 1 kvm,benchmark,big-parallel
```

The router's SSH account and Nix daemon must be configured to accept the client's key and builder connection. Nix may schedule eligible derivations on the router when running `nix build`.

## NFS client mount

The server exports `/data` to the configured LAN subnet and Tailscale CGNAT range. On a client:

```bash
sudo mkdir -p /mnt/nfs
sudo mount -t nfs 192.168.50.1:/data /mnt/nfs
```

Optional `/etc/fstab` entry:

```fstab
192.168.50.1:/data  /mnt/nfs  nfs  _netdev,nofail,x-systemd.automount  0  0
```

Check export and firewall policy before exposing this writable share to additional networks.
