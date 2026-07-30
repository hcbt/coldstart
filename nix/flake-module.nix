# A flake-parts module, so a consumer declares images as typed options instead
# of calling mkImage by hand:
#
#   imports = [ inputs.coldstart.flakeModules.default ];
#   perSystem = { pkgs, ... }: {
#     coldstart.images.my-app = {
#       packages = [ pkgs.my-server ];
#       entrypoint = [ "/bin/my-server" ];
#     };
#   };
#
# Each entry becomes `packages.<name>`.
#
# Kept in its own file rather than inline in lib.nix so `checks.flake-module`
# can import and evaluate it without referring to this flake's own outputs.
{ lib, flake-parts-lib, ... }:
let
  mkImage = args: import ./image.nix args;

  userType = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "app";
        description = "Unprivileged account name declared in /etc/passwd.";
      };
      uid = lib.mkOption {
        type = lib.types.int;
        default = 1000;
        description = "uid the workload runs as. Must match the chart's podSecurityContext.runAsUser.";
      };
      gid = lib.mkOption {
        type = lib.types.int;
        default = 1000;
        description = "gid the workload runs as. Must match the chart's podSecurityContext.runAsGroup.";
      };
      home = lib.mkOption {
        type = lib.types.str;
        default = "/app";
        description = "Home directory, and the default working directory.";
      };
      shell = lib.mkOption {
        type = lib.types.str;
        default = "/bin/bash";
        description = "Login shell recorded in /etc/passwd.";
      };
    };
  };

  imageType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        name = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Image name. Defaults to the attribute name.";
        };
        tag = lib.mkOption {
          type = lib.types.str;
          default = "latest";
          description = "Image tag.";
        };
        packages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
          description = "The workload itself.";
        };
        extraPackages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
          description = "Toolchain the workload shells out to, on top of the base set.";
        };
        basePackages = lib.mkOption {
          type = lib.types.nullOr (lib.types.listOf lib.types.package);
          default = null;
          defaultText = lib.literalExpression "bash, coreutils, findutils, gnugrep, gnused, gnutar, gzip";
          description = "Overrides the base set. Set to `[ ]` for a genuinely minimal image.";
        };
        withNix = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Include Nix and a nix.conf that works inside a container.";
        };
        includeNixDB = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Seed /nix/var/nix/db so nix commands work inside the container.";
        };
        withSkopeo = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Include skopeo and a permissive containers trust policy.";
        };
        withCacert = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Include TLS roots and point SSL_CERT_FILE at them.";
        };
        nixSettings = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
          example = lib.literalExpression ''
            {
              substituters = [ "https://cache.nixos.org" "https://devenv.cachix.org" ];
            }
          '';
          description = "Merged over the default /etc/nix/nix.conf settings.";
        };
        env = lib.mkOption {
          type = lib.types.attrsOf (lib.types.nullOr lib.types.str);
          default = { };
          description = "Merged over the default environment; null removes a default.";
        };
        labels = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          example = lib.literalExpression ''
            { "org.opencontainers.image.source" = "https://github.com/OWNER/REPO"; }
          '';
          description = "OCI image labels.";
        };
        user = lib.mkOption {
          type = userType;
          default = { };
          description = "The unprivileged account the image declares.";
        };
        entrypoint = lib.mkOption {
          type = lib.types.nullOr (lib.types.listOf lib.types.str);
          default = null;
          description = "OCI Entrypoint. Null declares none and lets the caller supply it.";
        };
        command = lib.mkOption {
          type = lib.types.nullOr (lib.types.listOf lib.types.str);
          default = null;
          description = "OCI Cmd. Null declares none and lets the caller supply it.";
        };
        exposedPorts = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
          example = lib.literalExpression ''{ "16261/udp" = { }; }'';
          description = "Declarative port metadata; publishes nothing by itself.";
        };
        workingDir = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          defaultText = lib.literalExpression "the user's home";
          description = "Working directory inside the container.";
        };
        extraConfig = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
          description = "Merged over the generated OCI `config` block.";
        };
        extraContents = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
          description = "Extra store paths included verbatim.";
        };
      };
    }
  );
in
{
  options.perSystem = flake-parts-lib.mkPerSystemOption (
    { config, pkgs, ... }:
    {
      options.coldstart.images = lib.mkOption {
        type = lib.types.attrsOf imageType;
        default = { };
        description = "Images to build, one package per attribute.";
      };

      config.packages = lib.mapAttrs (
        _: image:
        mkImage (
          {
            inherit pkgs;
            inherit (image)
              name
              tag
              packages
              extraPackages
              withNix
              includeNixDB
              withSkopeo
              withCacert
              nixSettings
              env
              labels
              user
              entrypoint
              command
              exposedPorts
              workingDir
              extraConfig
              extraContents
              ;
          }
          # `null` means "leave mkImage's own default alone", which an option
          # with a package-list type cannot express on its own.
          // lib.optionalAttrs (image.basePackages != null) { inherit (image) basePackages; }
        )
      ) config.coldstart.images;
    }
  );
}
