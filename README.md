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
It watches local OpenCode logs for rate-limit/quota responses (`429`, `resource_exhausted`, `used today`, etc.), then SSH-triggers `renew-wan-ip` on the router.

For `ECONNRESET` or `Connection lost due to` errors, it skips WAN renewal and retries OpenCode. For rate-limit/quota errors, it renews the WAN IP first, then retries.

#### Setup (one-time)

**Step 1 — Register your SSH key on the router** (from your client PC):
```bash
ssh-copy-id yano@192.168.50.1
```

**Step 2 — Copy the watchdog script to your client PC**:
```bash
scp yano@192.168.50.1:/etc/nixos/scripts/client-watchdog.sh .
chmod +x client-watchdog.sh
```

**Step 3 — Start OpenCode inside a named tmux session**:
```bash
tmux new -s opencode
# (inside the session)
opencode
```

**Step 4 — Run the watchdog in another terminal or tmux pane**:
```bash
./client-watchdog.sh
```

On startup, the watchdog runs a self-check and prints:
```
[watchdog] SSH connection to router .............. OK ✓
[watchdog] renew-wan-ip on router ................ OK ✓
[watchdog] tmux session 'opencode' ............... OK ✓
[watchdog] OpenCode log directory ................ OK ✓
[watchdog] All systems ready! 🚀
```

#### What happens when an error is detected

1. Watchdog detects an error in the OpenCode log
2. For `ECONNRESET` or `Connection lost due to`, it skips WAN renewal. For rate-limit/quota errors, it SSH-triggers `renew-wan-ip` on the router.
3. If renewed, the router reconnects with a randomized MAC and waits for internet connectivity.
4. Watchdog sends `Escape` twice, types the retry prompt, and presses `Enter` in the `opencode` tmux session.

#### Configuration via environment variables

| Variable | Default | Description |
| :--- | :--- | :--- |
| `ROUTER_HOST` | `192.168.50.1` | Router LAN IP |
| `ROUTER_USER` | `yano` | SSH user on the router |
| `TMUX_TARGET` | `opencode` | tmux session name where OpenCode runs |
| `TMUX_AUTO_RETRY` | `true` | Automatically interrupt and retry in tmux after recovery |
| `TMUX_RETRY_PROMPT` | `Please retry the previous request.` | Prompt sent to OpenCode after interrupting |
| `MAX_DAILY_RECOVERIES` | `10` | Safety cap: max auto-recoveries per day |
| `WATCH_DIR` | `~/.local/share/opencode/log` | OpenCode log directory to monitor |

```bash
# Example: custom session name and higher daily cap
TMUX_TARGET=mywork MAX_DAILY_RECOVERIES=20 ./client-watchdog.sh
```

### Notify your home PC when OpenCode finishes

OpenCode can send a desktop notification to the Arch PC at home when a session becomes idle. This uses the OpenCode `session.idle` event and a direct SSH connection over Tailscale. Only a fixed `done` event is sent; prompts and generated content are not transmitted.

Run this **once from your home Arch PC**, replacing `opencode-work` with your existing SSH alias and `/path/to/clubroom-router-nixos` with the repository path on the OpenCode PC:

```bash
ssh opencode-work 'cat /path/to/clubroom-router-nixos/scripts/setup-opencode-home-notify.sh' \
  | bash -s -- opencode-work /path/to/clubroom-router-nixos
```

The setup creates a notification-only SSH key, installs the OpenCode event hook and updated watchdog script, and writes a forced `notify-send` command into the home PC's `authorized_keys`; there is no receiver script to run. It configures direct SSH to the home PC's Tailscale IP. No reverse forwarding, port conflict, or background tunnel service is needed. It also removes the old notification reverse-forward setting from the work SSH alias. OpenCode signals the already-running `client-watchdog.sh` through a FIFO when a session becomes idle; the watchdog sends the desktop notification. Its existing quota/IP-recovery behavior is unchanged.

The notification offers **次の指示を手動で入力** and **完了・放置** actions. Neither action sends a prompt to OpenCode: the first leaves the session ready for you to type a new task, and the second simply leaves it idle. Dismissing the notification also leaves it idle. The notification desktop must support actions (for example, GNOME Shell or KDE Plasma).

On the OpenCode PC, restart the watchdog once so it uses the updated script, and restart OpenCode once to load the event hook. Keep running the watchdog as you normally do. Both PCs need to be online in Tailscale, and the home PC must be logged into its graphical session. WAN reconnects can interrupt SSH to the work PC, but the watchdog can reconnect to the home PC directly after Tailscale is back.

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
