{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.clubroom-monitoring;
in {
  options.services.clubroom-monitoring = {
    enable = mkEnableOption "Clubroom Prometheus and Grafana monitoring stack";

    grafanaPort = mkOption {
      type = types.port;
      default = 3100;
      description = "HTTP port for Grafana.";
    };

    grafanaDomain = mkOption {
      type = types.str;
      default = "grafana.lan";
      description = "Domain name for Grafana.";
    };
  };

  config = mkIf cfg.enable {
    # Node Exporter (Hardware & OS Metrics Collector)
    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9100;
      enabledCollectors = [
        "systemd"
        "processes"
        "cpufreq"
        "hwmon"
        "diskstats"
        "filesystem"
        "loadavg"
        "meminfo"
        "netdev"
        "netstat"
        "stat"
        "time"
        "uname"
        "vmstat"
      ];
    };

    # Prometheus (Metric Storage Engine)
    services.prometheus = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9090;
      retentionTime = "30d";
      scrapeConfigs = [
        {
          job_name = "node";
          scrape_interval = "10s";
          static_configs = [
            {
              targets = [ "127.0.0.1:9100" ];
              labels = {
                instance = "clubroom-router";
              };
            }
          ];
        }
      ];
    };

    # Grafana (Metrics Visualization Dashboard)
    services.grafana = {
      enable = true;
      settings = {
        server = {
          http_addr = "127.0.0.1";
          http_port = cfg.grafanaPort;
          domain = cfg.grafanaDomain;
        };
        "auth.anonymous" = {
          enabled = true;
          org_name = "Main Org.";
          org_role = "Viewer";
        };
        security = {
          admin_user = "admin";
          secret_key = "SW2YcwTIb9zpOOhoPsMm";
        };
      };

      provision = {
        enable = true;
        datasources.settings.datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            access = "proxy";
            url = "http://127.0.0.1:9090";
            isDefault = true;
            editable = true;
          }
        ];
      };
    };
  };
}
