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
