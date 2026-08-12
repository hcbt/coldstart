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
# Each entry becomes `packages.<name>`. The options themselves live in
# ./image-options.nix, so `devenvModules.default` can present the same set.
{ lib, flake-parts-lib, ... }:
let
  shared = import ./image-options.nix { inherit lib; };
in
{
  options.perSystem = flake-parts-lib.mkPerSystemOption (
    { config, pkgs, ... }:
    {
      options.coldstart.images = lib.mkOption {
        type = lib.types.attrsOf shared.imageType;
        default = { };
        description = "Images to build, one package per attribute.";
      };

      config.packages = shared.buildImages pkgs config.coldstart.images;
    }
  );
}
