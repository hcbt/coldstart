{
  description = "Run a Nix-built workload as a container — an OCI image and Helm chart for Kubernetes, or a systemd-nspawn NixOS container on an existing host";

  inputs = {
    # The shared scaffolding: treefmt, the git hooks, mkDevShell, the app
    # helpers, and the generated GitHub-side files.
    nivis.url = "github:hcbt/nivis/v0.8.2";

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
            runner = nivis.lib.repo.runners.githubHosted;
            checks = true;
            initialVersion = "0.1.0";
            name = "coldstart";
            gitignoreExtra = ''
              # devenv, if a shell ever uses it here
              .devenv
            '';
            extraFiles = import ./nix/workflows.nix { };
          };
        })

        ./nix/lib.nix # flake.lib.*, flakeModules.default, nixosModules.default
        ./nix/packages.nix # the reference image + the packaged chart
        ./nix/checks.nix # chart lint + render assertions, image evaluation
        # The dev shell, inline rather than imported from nix/shells.nix:
        # editor Nix integrations that read flake.nix textually cannot see a
        # devShell defined in an imported module, even though the flake output
        # is identical either way.
        (
          # `nix develop` / direnv. nivis' mkDevShell brings prek, the treefmt wrapper,
          # the pinned shell utilities and the pre-commit devShell fragment; only the
          # chart tooling is specific to this repo.
          { ... }:
          {
            perSystem =
              { pkgs, mkDevShell, ... }:
              {
                devShells.default = mkDevShell {
                  packages = [
                    pkgs.kubernetes-helm
                    pkgs.kubectl
                    pkgs.kubeconform
                    pkgs.yq-go
                  ];
                };
              };
          }
        )
        ./nix/format.nix # the repo-specific half of treefmt and the hooks
      ];
    };
}
