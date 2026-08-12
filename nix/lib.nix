# The public surface: everything a consumer flake imports.
#
#   inputs.coldstart.lib.mkImage          build the image from any nixpkgs
#   inputs.coldstart.lib.renderChart      render the chart to plain manifests
#   inputs.coldstart.lib.chart            the chart source, for ArgoCD/helm
#   inputs.coldstart.flakeModules.default typed options instead of the raw call
#   inputs.coldstart.nixosModules.default the systemd-nspawn container
{ lib }:
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
  lib = {
    inherit mkImage renderChart chart;
  };

  # Still exported, even though this flake no longer runs flake-parts itself.
  # It is a file reference, so publishing it costs nothing — and a consumer that
  # does run flake-parts can still take the typed options instead of calling
  # `lib.mkImage` by hand.
  flakeModules.default = import ./flake-module.nix;

  # The same options as `flakeModules.default`, for a project that runs devenv
  # rather than a flake. A PATH, not an imported module: devenv resolves its
  # own imports, and a consumer names it as
  # `coldstart/nix/devenv-module.nix` under a `flake: false` input.
  #
  # It exists because devenv `outputs` is typed `outputOf lib.types.attrs`, so
  # a Nix function fails the check — `lib.mkImage` cannot reach a devenv
  # project as a function, but the options can.
  devenvModules.default = ./devenv-module.nix;
  nixosModules.default = import ./nixos-module.nix;
}
