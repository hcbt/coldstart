# Reference outputs. The image here exists to prove the builder works and to
# give CI something to build; consumers are expected to build their own with
# `lib.mkImage` rather than pull this one.
#
#   nix build .#example-image
#   nix build .#chart
{ }:
{ pkgs, lib }:
{
  # `helm package` output, for consumers that publish the chart to an OCI
  # registry or a chart museum instead of pointing a GitOps controller at
  # this repository.
  chart =
    pkgs.runCommand "coldstart-chart"
      {
        nativeBuildInputs = [ pkgs.kubernetes-helm ];
      }
      ''
        export HELM_CACHE_HOME="$TMPDIR/cache" HELM_CONFIG_HOME="$TMPDIR/config" HELM_DATA_HOME="$TMPDIR/data"
        mkdir -p $out
        helm package ${../chart} --destination $out
      '';
}
# dockerTools cannot build a Linux image from Darwin, so the image is
# only an output where it can actually be built.
// lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
  # No org.opencontainers.image.source label: that label links a package
  # to the repository publishing it, so it belongs in the consumer's own
  # call, not in a reference build.
  example-image = import ./image.nix {
    inherit pkgs;
    name = "coldstart-example";
    packages = [ pkgs.hello ];
    entrypoint = [ (lib.getExe pkgs.hello) ];
    # Nothing here builds derivations, so the ~200M of Nix closure would
    # be dead weight — which is exactly the judgement `withNix` exists to
    # let a consumer make.
    withNix = false;
  };
}
