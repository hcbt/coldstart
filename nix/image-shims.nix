# The things the image has to supply itself, because nothing upstream does.
#
# Both are absences rather than misconfigurations, so neither shows up when the
# image is built, or inspected, or started — only when the workload happens to
# need them. Both cost a full deploy round-trip to find.
#
# Kept out of image.nix so `checks.nix` can exercise them directly: proving
# either one works means RUNNING it, and building a whole image to do that
# would pull the workload's entire closure into `nix flake check`.
{ pkgs }:
let
  inherit (pkgs) lib;
in
{
  # `#!/usr/bin/env <interp>` is the dominant portable shebang, and the kernel
  # resolves that path literally — no PATH search, no fallback, no error the
  # script itself can handle. Nix patches its own shebangs to absolute store
  # paths, so nothing in the base image needs /usr/bin/env and its absence stays
  # invisible until the first script Nix did not patch tries to run:
  #
  #   /usr/bin/env: bad interpreter: No such file or directory
  #
  # Game servers and other prebuilt vendor payloads are full of such scripts —
  # they ship their own launcher and Nix never touches it.
  #
  # A symlink to the `env` already in the image, so this adds no closure.
  usrBinEnv = pkgs.runCommand "usr-bin-env" { } ''
    mkdir -p $out/usr/bin
    ln -s ${lib.getExe' pkgs.coreutils-full "env"} $out/usr/bin/env
  '';

  # skopeo refuses to do anything without a trust policy, and nixpkgs ships no
  # default one ("no policy.json file found"). Accept any image: a container
  # that pushes images only ever pushes ones it just built itself.
  containersPolicy = pkgs.writeTextDir "etc/containers/policy.json" (
    builtins.toJSON {
      default = [ { type = "insecureAcceptAnything"; } ];
    }
  );
}
