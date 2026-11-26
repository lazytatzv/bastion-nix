# bastion-nix

Autonomous Fortress Router & Edge Compute Citadel for Clubroom LAN.
Hardened defense, stealth WAN rotation, distributed build artillery, and local edge services.

```
                   +------------------------------------+
                   |   Upstream WiFi (Campus WAN)       |
                   +-----------------+------------------+
                                     | wlan0 (Stealth DHCP / Auto-Release)
                              [ bastion-nix ]
                                     | enp2s0 (192.168.50.1/24)
                   +-----------------+------------------+
                   |   Clubroom Fortress LAN (BBR/CAKE) |
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
│   └── connection-watchdog.sh # Log watcher & auto WAN IP recovery
└── modules/
    ├── default.nix            # Module aggregation
    ├── wifi-as-wan.nix        # WiFi-as-WAN routing, DHCPRELEASE, MAC rotation
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

## WAN IP Rotation & Watchdog

Upstream campus WiFi leases global IPs via DHCP. To rotate IP and avoid DHCP pool exhaustion, `renew-wan-ip` issues a clean `DHCPRELEASE` before restarting `iwd` with a randomized MAC.

* **Automated Rotation**: Scheduled every 2 hours via `systemd.timers.rotate-wan-ip`.
* **On-Demand Rotation**:
  ```bash
  renew-wan-ip
  ```
* **Auto-Recovery Watchdog**:
  ```bash
  ./scripts/connection-watchdog.sh
  ```
  Monitors client logs for rate limits (`429`, `used today.*free messages`) or connection drops, triggering `renew-wan-ip` automatically.

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
