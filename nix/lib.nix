# The public surface: everything a consumer flake imports.
#
#   inputs.coldstart.lib.mkImage          build the image from any nixpkgs
#   inputs.coldstart.lib.renderChart      render the chart to plain manifests
#   inputs.coldstart.lib.chart            the chart source, for ArgoCD/helm
#   inputs.coldstart.flakeModules.default typed options instead of the raw call
#   inputs.coldstart.nixosModules.default the systemd-nspawn container
{ lib, ... }:
let
  mkImage = args: import ./image.nix args;
  chart = ../chart;

  # Renders the chart to a single manifest file with no cluster and no network,
  # for consumers that would rather commit/apply plain YAML than point a GitOps
  # controller at this repository.
  renderChart =
    {
      pkgs,
      releaseName ? "coldstart",
      namespace ? "default",
      values ? { },
      valuesFiles ? [ ],
      extraArgs ? [ ],
    }:
    let
      valuesFile = pkgs.writeText "coldstart-values.json" (builtins.toJSON values);
      allValues = valuesFiles ++ [ valuesFile ];
    in
    pkgs.runCommand "coldstart-manifests.yaml"
      {
        nativeBuildInputs = [ pkgs.kubernetes-helm ];
      }
      ''
        # helm insists on writable HOME-derived directories even for an offline
        # `template`, and $HOME is not set in the build sandbox.
        export HELM_CACHE_HOME="$TMPDIR/cache" HELM_CONFIG_HOME="$TMPDIR/config" HELM_DATA_HOME="$TMPDIR/data"
        helm template ${lib.escapeShellArg releaseName} ${chart} \
          --namespace ${lib.escapeShellArg namespace} \
          ${lib.concatMapStringsSep " " (f: "--values ${f}") allValues} \
          ${lib.escapeShellArgs extraArgs} > $out
      '';
in
{
  flake = {
    lib = {
      inherit mkImage renderChart chart;
    };

    flakeModules.default = import ./flake-module.nix;
    nixosModules.default = import ./nixos-module.nix;
  };
}
