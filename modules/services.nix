{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.clubroom-services;
in {
  options.services.clubroom-services = {
    enable = mkEnableOption "Clubroom shared services (Tailscale, NFS, FileBrowser, Docker, Distcc, SSH)";

    dataPath = mkOption {
      type = types.path;
      default = "/data";
      description = "Storage path for NFS and FileBrowser.";
    };

    internalSubnet = mkOption {
      type = types.str;
      default = "192.168.50.0/24";
      description = "Internal network subnet for NFS export and Tailscale advertised routes.";
    };
  };

  config = mkIf cfg.enable {
    # Tailscale VPN (with Subnet Router)
    services.tailscale = {
      enable = true;
      extraUpFlags = [
        "--accept-dns=false"
        "--advertise-routes=${cfg.internalSubnet}"
      ];
    };

    # NFS NAS Server
    services.nfs.server = {
      enable = true;
      exports = ''
        ${toString cfg.dataPath} ${cfg.internalSubnet}(rw,sync,no_subtree_check)
        ${toString cfg.dataPath} 100.64.0.0/10(rw,sync,no_subtree_check)
      '';
      statdPort = 4000;
      lockdPort = 4001;
      mountdPort = 4002;
    };

    # FileBrowser (Web File Manager)
    services.filebrowser = {
      enable = true;
      settings = {
        address = "127.0.0.1";
        port = 8080;
        root = toString cfg.dataPath;
      };
    };

    # Docker Container Engine with BuildKit
    virtualisation.docker = {
      enable = true;
      package = pkgs.docker_29;
      autoPrune = {
        enable = true;
        dates = "weekly";
        flags = [ "--all" "--filter" "until=168h" ];
      };
      daemon.settings = {
        features = {
          buildkit = true;
        };
        "log-driver" = "json-file";
        "log-opts" = {
          "max-size" = "50m";
          "max-file" = "3";
        };
      };
    };

    nixpkgs.config.permittedInsecurePackages = [
      "docker-28.5.2"
    ];

    # Distcc Distributed Compiler Daemon
    services.distccd = {
      enable = true;
      allowedClients = [
        "127.0.0.1"
        cfg.internalSubnet
        "100.64.0.0/10"
      ];
      stats = {
        enable = true;
        port = 3633;
      };
      zeroconf = true;
    };

    # OpenSSH Server
    services.openssh.enable = true;

  };
}
