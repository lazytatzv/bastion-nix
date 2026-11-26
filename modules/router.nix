{ config, lib, pkgs, ... }:

{
  # ==========================================
  # WiFi as WAN Router Module
  # ==========================================
  services.wifi-as-wan = {
    enable = true;
    externalInterface = "wlan0";
    internalInterface = "enp2s0";
    internalIp = "192.168.50.1";
    upstreamDns = [ "127.0.0.1#5335" ];
    autoDisableConflicts = true;
    rotateWanIp = {
      enable = true;
      calendar = "*-*-* 00,02,04,06,08,10,12,14,16,18,20,22:00:00";
    };
  };

  # ==========================================
  # AdGuard Home (DNS & Local Records)
  # ==========================================
  services.adguardhome = {
    enable = true;
    port = 3000;
    settings = {
      dns = {
        bind_hosts = [ "127.0.0.1" ];
        port = 5335;
        upstream_dns = [
          "https://dns.quad9.net/dns-query"
          "https://cloudflare-dns.com/dns-query"
        ];
        cache_size = 536870912;
        cache_ttl_min = 3600;
        cache_optimistic = true;
      };
      filtering = {
        protection_enabled = true;
        filtering_enabled = true;
      };
    };
  };

  services.dnsmasq.settings = {
    address = [
      "/router/192.168.50.1"
      "/lan/192.168.50.1"
    ];
  };

  # ==========================================
  # Modular Feature Profiles
  # ==========================================
  # High-performance Zen kernel & sysctl tuning
  profiles.performance.enable = true;

  # Local Caddy reverse proxy (*.lan)
  services.clubroom-proxy.enable = true;

  # Shared NAS, Tailscale, Docker & Distcc
  services.clubroom-services.enable = true;

  # Prometheus + Node Exporter + Grafana monitoring
  services.clubroom-monitoring.enable = true;

  # GitHub Actions self-hosted runner
  services.rodep-runner.enable = true;

  # ==========================================
  # Host Network & Firewall Rules
  # ==========================================
  networking = {
    useNetworkd = true;
    useDHCP = false;
    firewall = {
      enable = true;
      checkReversePath = false;
      allowPing = true;
      allowedTCPPorts = [ 22 80 443 2049 4000 4001 4002 8189 8000 8001 8889 8888 8554 3000 8080 ];
      allowedUDPPorts = [ 53 67 68 2049 4000 4001 4002 8889 8888 8554 ];
    };
    networkmanager.enable = false;
  };
}
