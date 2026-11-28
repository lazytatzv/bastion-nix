# bastion-nix

NixOS router and edge compute node for a clubroom LAN.
Includes WiFi-as-WAN routing, periodic DHCP lease renewal, distributed builds, and local services.

```
                   +------------------------------------+
                   |   Upstream WiFi (Campus WAN)       |
                   +-----------------+------------------+
                                     | wlan0 (DHCP / Auto-Release)
                              [ bastion-nix ]
                                     | enp2s0 (192.168.50.1/24)
                   +-----------------+------------------+
                   |   Clubroom LAN (BBR/CAKE)          |
                   +------------------------------------+
```

---

## Architecture & Modules

Modular NixOS configuration. Each module in `modules/` is decoupled with configurable options and exported via flakes for standalone reuse across other machines.

```
.
├── flake.nix                  # Flake entrypoint & exported nixosModules
├── configuration.nix          # Machine root configuration
├── hardware-configuration.nix # Target hardware configuration
├── Makefile                   # Deployment shortcuts
├── scripts/
│   └── client-watchdog.sh     # Client PC watcher: triggers remote renew-wan-ip via SSH
└── modules/
    ├── default.nix            # Module aggregation
    ├── wifi-as-wan.nix        # WiFi-as-WAN routing, DHCP release, MAC randomization
    ├── router.nix             # Machine profile enabling host modules
    ├── performance.nix        # Zen kernel, BBR + CAKE, sysctl, tmpfs
    ├── proxy.nix              # Caddy reverse proxy (*.lan)
    ├── monitoring.nix         # Prometheus + Node Exporter + Grafana
    ├── services.nix           # NFS NAS, FileBrowser, Tailscale, Docker, Distccd
    ├── runner.nix             # GitHub Actions self-hosted runner
    └── system.nix             # Base system, users, nix-daemon optimization
```

---

## Reusable Flake Modules

Import modules into external flakes (`flake.nix`):

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    bastion-nix.url = "github:lazytatzv/bastion-nix";
  };

  outputs = { self, nixpkgs, bastion-nix, ... }: {
    nixosConfigurations.my-router = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        # Import single module
        bastion-nix.nixosModules.wifiAsWan

        # Or import all modules and toggle via options
        # bastion-nix.nixosModules.default

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

Available exported modules:
* `nixosModules.wifiAsWan` (`services.wifi-as-wan`)
* `nixosModules.performance` (`profiles.performance`)
* `nixosModules.proxy` (`services.clubroom-proxy`)
* `nixosModules.monitoring` (`services.clubroom-monitoring`)
* `nixosModules.services` (`services.clubroom-services`)
* `nixosModules.runner` (`services.bastion-runner`)
* `nixosModules.default` (imports all modules)

---

## Deployment

```bash
# Build and switch configuration
make switch
# or: sudo nixos-rebuild switch --flake .#nixos

# Test without modifying bootloader
make test

# Update flake locks
make update
```

---

## WAN Lease Renewal & Client Watchdog

Upstream WiFi leases global IPs via DHCP. To obtain a new lease without exhausting the DHCP pool, `renew-wan-ip` issues a clean `DHCPRELEASE`, restarts `iwd` with a randomized MAC address, then waits until internet connectivity is confirmed via ping before returning.

### Automated Periodic Renewal (Router-side)

A daily renewal runs at 04:00 with up to 30 minutes of random jitter (`RandomizedDelaySec`), so the reconnect does not happen at exactly the same time every day.

```bash
# Check the timer status on the router
systemctl list-timers rotate-wan-ip

# Trigger manually on the router
renew-wan-ip
```

### Client Watchdog (Run on your Linux PC)

`scripts/client-watchdog.sh` runs on your **client Linux machine** (the one running OpenCode).
It watches local OpenCode logs for connection and provider usage-limit errors.

For `ECONNRESET` or `Connection lost due to` errors, it skips WAN renewal and retries OpenCode. Provider rate limits and quota errors trigger a notification to the home PC and pause automatic refactoring for that watchdog run; they do not renew the WAN IP or retry the request.

#### Setup (one-time)

**Step 1 — Start OpenCode inside a named tmux session**:
```bash
tmux new -s opencode
# (inside the session)
opencode
```

**Step 2 — Run the watchdog in another terminal or tmux pane**:
```bash
./scripts/client-watchdog.sh
```

On startup, the watchdog checks the tmux session and OpenCode log directory:
```
[watchdog] tmux session 'opencode' ............... OK ✓
[watchdog] OpenCode log directory ................ OK ✓
[watchdog] All systems ready! 🚀
```

#### What happens when an error is detected

1. Watchdog detects an error in the OpenCode log
2. For connection errors, it skips WAN renewal and retries OpenCode in tmux.
3. For provider usage limits, it notifies both the client and home PC, then stops automatic retries/refactoring for the current watchdog run.

#### Configuration via environment variables

| Variable | Default | Description |
| :--- | :--- | :--- |
| `TMUX_TARGET` | `opencode` | tmux session name where OpenCode runs |
| `TMUX_AUTO_RETRY` | `true` | Automatically retry connection errors in tmux |
| `AUTO_REFACTOR_ON_IDLE` | `true` | Automatically start one bounded refactoring pass each time a session becomes idle |
| `TMUX_RETRY_PROMPT` | `Please retry the previous request.` | Prompt sent to OpenCode after a connection error |
| `WATCH_DIR` | `~/.local/share/opencode/log` | OpenCode log directory to monitor |

```bash
# Example: use a custom OpenCode tmux session
TMUX_TARGET=mywork ./client-watchdog.sh
```

### Notify your home PC when OpenCode finishes

OpenCode can send a desktop notification to the Arch PC at home when a session becomes idle or a provider limit is detected. This uses the OpenCode `session.idle` event and a direct SSH connection over Tailscale. Only fixed `done` and `limit` event labels are sent; prompts and generated content are not transmitted.

Run this **once from your home Arch PC**, replacing `opencode-work` with your existing SSH alias and `/path/to/clubroom-router-nixos` with the repository path on the OpenCode PC:

```bash
ssh opencode-work 'cat /path/to/clubroom-router-nixos/scripts/setup-opencode-home-notify.sh' \
  | bash -s -- opencode-work /path/to/clubroom-router-nixos
```

The setup creates a notification-only SSH key, installs the OpenCode event hook and updated watchdog script, and installs a restricted notification receiver on the home PC. Only fixed `done` and `limit` notification events are accepted. It configures direct SSH to the home PC's Tailscale IP. No reverse forwarding, port conflict, or background tunnel service is needed. It also removes the old notification reverse-forward setting from the work SSH alias.

OpenCode signals the already-running `client-watchdog.sh` through a FIFO when a session becomes idle. The watchdog notifies the home PC, then automatically sends one conservative, behavior-preserving refactoring task to the `opencode` tmux session. Each completed pass triggers another notification and another pass. Refactoring is paused when a provider usage limit is detected; after the limit is available again, restart the watchdog to resume.

On the OpenCode PC, restart the watchdog and OpenCode once to load the changes. Keep running the watchdog as usual. Both PCs need to be online in Tailscale, and the home PC must be logged into its graphical session. WAN reconnects can interrupt SSH to the work PC, but the watchdog can reconnect to the home PC directly after Tailscale is back.

#### Reconnecting to the work PC from your home Arch PC

The regular `ssh archer` command does not reconnect automatically. To use the reconnecting `archer` shell function, source the repository script from your home Arch PC's `~/.zshrc` (replace the path with the local clone path):

```zsh
echo 'source ~/bastion-nix/scripts/archer-reconnect.zsh' >> ~/.zshrc
source ~/.zshrc
```

Then run `archer`. If SSH disconnects, it retries every 2 seconds; keep the terminal open while it reconnects and press `Ctrl-C` to stop. SSH keepalives detect an unreachable connection after about 45 seconds. This does not make the underlying SSH connection seamless; it starts a new SSH session after the network is reachable again.

#### Manual on-demand lease renewal (from your client PC)

Add this alias to your `~/.bashrc` or `~/.zshrc`:
```bash
alias renew-ip="ssh yano@192.168.50.1 renew-wan-ip"
```

Then just run:
```bash
renew-ip
```

---

## Network Endpoints

Accessible via LAN (`*.lan`) or Tailscale:

| Service | LAN URL | Port | Backend |
| :--- | :--- | :--- | :--- |
| FileBrowser (NAS) | `http://nas.lan` | `8080` | `/data` Web GUI |
| AdGuard Home | `http://adguard.lan` | `3000` | DNS Sinkhole & Upstream Cache |
| Grafana Dashboard | `http://grafana.lan` | `3100` | System metrics & monitoring |
| Prometheus | - | `9090` | Time-series metrics engine |
| Distcc Status | `http://distcc.lan` | `3633` | Distributed compiler monitor |
| Default HTTP Root | `http://router.lan` | `80` | Redirects to NAS |

---

## Distributed Compilation & Remote Builder

Offload C/C++ (ROS 2 / CMake) builds to the router's 8C/16T CPU:

### 1. distcc (ROS 2 / Make / CMake)

Client setup (`~/.bashrc`):
```bash
export DISTCC_HOSTS="192.168.50.1/16"
export CC="distcc gcc"
export CXX="distcc g++"
```

Compile with 16 parallel jobs:
```bash
colcon build --parallel-workers 16
# or: make -j16
```

### 2. Nix Remote Builder

Add to client `~/.config/nix/nix.conf`:
```conf
builders = ssh://yano@192.168.50.1 x86_64-linux - 16 1 kvm,benchmark,big-parallel
```

Then invoke `nix build` or `nix develop` normally; derivations compile on the router's RAM disk.

---

## NFS Storage Mount

Shared directory: `/data`

```bash
# Mount on client
sudo mount -t nfs 192.168.50.1:/data /mnt

# Persistent mount in /etc/fstab
192.168.50.1:/data  /mnt/nfs  nfs  _netdev,nofail,x-systemd.automount  0  0
```
