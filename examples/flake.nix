# What a consumer flake looks like. Both documented styles are here, and
# `checks.example-flake` evaluates this file against the working tree — so it
# is tested documentation rather than a snippet that rots.
{
  description = "Example consumer of coldstart";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    coldstart = {
      url = "github:hcbt/coldstart";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, coldstart, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      imports = [ coldstart.flakeModules.default ];

      perSystem =
        { pkgs, ... }:
        {
          # Style 1: typed options. Each entry becomes `packages.<name>`.
          coldstart.images = {
            my-server = {
              packages = [ pkgs.hello ];
              entrypoint = [ "/bin/hello" ];
              withNix = false;
              exposedPorts."16261/udp" = { };
              labels."org.opencontainers.image.source" = "https://github.com/OWNER/REPO";
            };
          };

          packages = {
            # Style 2: the raw call, for anything the module does not express.
            other-server = coldstart.lib.mkImage {
              inherit pkgs;
              name = "other-server";
              packages = [ pkgs.hello ];
              withNix = false;
              user = {
                name = "game";
                uid = 1500;
                gid = 1500;
                home = "/game";
              };
            };

            # Plain manifests, for a cluster that would rather apply YAML than
            # point a GitOps controller at the chart.
            manifests = coldstart.lib.renderChart {
              inherit pkgs;
              releaseName = "my-server";
              namespace = "games";
              values = {
                image.repository = "ghcr.io/OWNER/my-server";
                ports = [
                  {
                    name = "game";
                    containerPort = 16261;
                    protocol = "UDP";
                  }
                ];
                persistence.enabled = true;
              };
            };
          };
        };
    };
}
