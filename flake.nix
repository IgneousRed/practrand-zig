{
  description = "Locked development tools for practrand-zig";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/619c39f6eac5d1ed6b8f073a9414baf7034b2356";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "aarch64-darwin" "aarch64-linux" "x86_64-linux" ];
      forSystems = nixpkgs.lib.genAttrs systems;
      environments = forSystems (system: import ./nix/environment.nix {
        pkgs = import nixpkgs { inherit system; };
        nixpkgsRev = nixpkgs.rev;
      });
      vulkanEnvironments = forSystems (system: import ./nix/environment.nix {
        pkgs = import nixpkgs { inherit system; };
        nixpkgsRev = nixpkgs.rev;
        withVulkan = true;
      });
    in {
      devShells = forSystems (system: {
        default = environments.${system}.shell;
        vulkan = vulkanEnvironments.${system}.shell;
      });
      lib.dependencyCheck = forSystems (system: import ./nix/dependency-check.nix {
        pkgs = nixpkgs.legacyPackages.${system};
        preferredPython = environments.${system}.python;
      }
        { schema = 1; dependencies = vulkanEnvironments.${system}.dependencies; });
      packages = forSystems (system: {
        dev-environment = environments.${system}.package;
        vulkan-environment = vulkanEnvironments.${system}.package;
        vulkan-sdk = environments.${system}.vulkanSdk;
        practrand-source = import ./nix/practrand.nix { pkgs = nixpkgs.legacyPackages.${system}; };
      });
      dependencyVersions = forSystems (system: environments.${system}.versions);
      vulkanDependencyVersions = forSystems (system: vulkanEnvironments.${system}.versions);
    };
}
