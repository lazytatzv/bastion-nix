{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.clubroom-proxy;
in {
  options.services.clubroom-proxy = {
    enable = mkEnableOption "Caddy reverse proxy for local services (*.lan)";

    baseDomain = mkOption {
      type = types.str;
      default = "lan";
      description = "Base local domain suffix.";
    };
  };

  config = mkIf cfg.enable {
    services.caddy = {
      enable = true;

      virtualHosts = {
        "http://router.${cfg.baseDomain}" = {
          extraConfig = ''
            redir http://nas.${cfg.baseDomain}{uri}
          '';
        };

        "http://adguard.${cfg.baseDomain}" = {
          extraConfig = ''
            reverse_proxy 127.0.0.1:3000
          '';
        };
        "http://dns.${cfg.baseDomain}" = {
          extraConfig = ''
            reverse_proxy 127.0.0.1:3000
          '';
        };

        "http://nas.${cfg.baseDomain}" = {
          extraConfig = ''
            reverse_proxy 127.0.0.1:8080
          '';
        };
        "http://drive.${cfg.baseDomain}" = {
          extraConfig = ''
            reverse_proxy 127.0.0.1:8080
          '';
        };
        "http://files.${cfg.baseDomain}" = {
          extraConfig = ''
            reverse_proxy 127.0.0.1:8080
          '';
        };

        "http://grafana.${cfg.baseDomain}" = {
          extraConfig = ''
            reverse_proxy 127.0.0.1:3100
          '';
        };
        "http://monitor.${cfg.baseDomain}" = {
          extraConfig = ''
            reverse_proxy 127.0.0.1:3100
          '';
        };
        "http://status.${cfg.baseDomain}" = {
          extraConfig = ''
            reverse_proxy 127.0.0.1:3100
          '';
        };

        "http://distcc.${cfg.baseDomain}" = {
          extraConfig = ''
            reverse_proxy 127.0.0.1:3633
          '';
        };

        ":80" = {
          extraConfig = ''
            reverse_proxy 127.0.0.1:8080
          '';
        };
      };
    };

  };
}
