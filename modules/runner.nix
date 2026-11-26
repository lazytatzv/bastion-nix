{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.rodep-runner;
in {
  options.services.rodep-runner = {
    enable = mkEnableOption "GitHub Actions Self-Hosted Runner for rodep-soft";

    url = mkOption {
      type = types.str;
      default = "https://github.com/rodep-soft";
      description = "GitHub repository or organization URL.";
    };

    tokenFile = mkOption {
      type = types.str;
      default = "/var/lib/github-runner/token";
      description = "Path to token file.";
    };

    user = mkOption {
      type = types.str;
      default = "yano";
      description = "User to run the runner as.";
    };
  };

  config = mkIf cfg.enable {
    services.github-runners.rodep-builder = {
      enable = true;
      url = cfg.url;
      tokenFile = cfg.tokenFile;
      user = cfg.user;
      workDir = "/var/lib/github-runner/work";
      replace = true;
      extraPackages = with pkgs; [
        docker_29
        git
        ccache
        zstd
        coreutils
      ];
      extraEnvironment = {
        CCACHE_DIR = "/home/${cfg.user}/.cache/ccache";
        CCACHE_MAXSIZE = "50G";
        DOCKER_BUILDKIT = "1";
      };
      serviceOverrides = {
        ProtectProc = "default";
        ProcSubset = "all";
        ProtectControlGroups = false;
      };
    };
  };
}
