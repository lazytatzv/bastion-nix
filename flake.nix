{
  description = "NixOS Flake Configuration for RoDEP Clubroom Router & Builder";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }@inputs: {
    # Reusable NixOS Modules for import across external flakes / hosts
    nixosModules = {
      default = ./modules;
      wifiAsWan = ./modules/wifi-as-wan.nix;
      router = ./modules/router.nix;
      performance = ./modules/performance.nix;
      monitoring = ./modules/monitoring.nix;
      proxy = ./modules/proxy.nix;
      services = ./modules/services.nix;
      runner = ./modules/runner.nix;
      system = ./modules/system.nix;
    };

    nixosConfigurations = {
      # Default hostname target (nixos)
      nixos = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./configuration.nix
        ];
      };

      # Alias target (router)
      router = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./configuration.nix
        ];
      };
    };
  };
}
