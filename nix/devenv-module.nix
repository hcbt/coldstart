# A devenv module, so a devenv project declares images as typed options
# instead of calling mkImage by hand:
#
#   # devenv.yaml
#   inputs:
#     coldstart:
#       url: github:hcbt/coldstart
#       flake: false
#   imports:
#     - coldstart/nix/devenv-module.nix
#
#   # devenv.nix
#   coldstart.images.my-app = {
#     packages = [ pkgs.my-server ];
#     entrypoint = [ "/bin/my-server" ];
#   };
#
# Each entry becomes `outputs.<name>`, built with `devenv build outputs.<name>`.
#
# This exists because devenv `outputs` is typed `outputOf lib.types.attrs`, and
# a Nix function fails that check — so `lib.mkImage` cannot be published to a
# devenv project the way it is published to a flake. Options can.
{
  lib,
  config,
  pkgs,
  ...
}:
let
  shared = import ./image-options.nix { inherit lib; };
in
{
  options.coldstart.images = lib.mkOption {
    type = lib.types.attrsOf shared.imageType;
    default = { };
    description = "Images to build, one output per attribute.";
  };

  config.outputs = shared.buildImages pkgs config.coldstart.images;
}
