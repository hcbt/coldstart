{
  description = "Run a Nix-built workload as a container — an OCI image and Helm chart for Kubernetes, or a systemd-nspawn NixOS container on an existing host";

  inputs = {
    # The shared scaffolding: treefmt, the git hooks, mkDevShell, the app
    # helpers, and the generated GitHub-side files.
    nivis.url = "github:hcbt/nivis/v0.7.0";

    # flake-parts builds `pkgs` from the CONSUMING flake's own nixpkgs input,
    # so this cannot be dropped.
    nixpkgs.follows = "nivis/nixpkgs";
  };

  outputs =
    inputs@{ nivis, ... }:
    nivis.inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = nivis.lib.defaultSystems;

      imports = [
        (nivis.flakeModules.default {
          srcRoot = ./.;
          repo = {
            # Public repo, so GitHub-hosted runners are available and the Nix
            # installer is needed.
            checks = true;
            initialVersion = "0.1.0";
          };
        })

        ./nix/lib.nix # flake.lib.*, flakeModules.default, nixosModules.default
        ./nix/packages.nix # the reference image + the packaged chart
        ./nix/checks.nix # chart lint + render assertions, image evaluation
        ./nix/shells.nix # `nix develop`
        ./nix/format.nix # the repo-specific half of treefmt and the hooks
      ];
    };
}
